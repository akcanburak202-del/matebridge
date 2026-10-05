package dev.matebridge.client.video

import android.media.MediaFormat
import android.view.Surface
import dev.matebridge.client.protocol.KeyframeRequest
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.VideoFrame
import dev.matebridge.client.session.MbLog
import dev.matebridge.client.stream.StatsFormat

/** Anything that produces VIDEO_FRAMEs pushes them here (session in T-015, file player in debug). */
fun interface VideoFrameSink {
    fun onFrame(frame: VideoFrame)
}

/**
 * MediaCodec decoder bound to a Surface, through the [DecoderCodec] seam (T-158). One decoder thread per attachment;
 * all codec calls happen on it (outputs on its companion `mb-decoder-out` thread). Frames go through [FrameQueue]
 * (bounded, newest wins, keyframe gated).
 *
 * Lifecycle: [attachSurface] when the SurfaceView surface exists, [detachSurface] when it is
 * destroyed or the activity stops. Each attachment is a [CodecGeneration]; a new generation's thread
 * first waits for the previous generation to finish (its decoder and output threads exited), so two codecs never run
 * at once. T-161: that wait is bounded ([PREVIOUS_WAIT_MS]); on timeout the new generation reports
 * [FaultCause.STUCK] and opens no codec (see [GenerationHandoff]). [detachSurface]
 * blocks the UI thread for at most [JOIN_MS] (the surface must be free before it is destroyed);
 * [attachSurface] and [reconfigure] never block: the new thread does the waiting itself.
 * Keep ONE renderer for the whole app run and call [reconfigure] on a new STREAM_CONFIG.
 *
 * Decoder errors restart the codec on the same surface (queue reset, last CODEC_CONFIG replayed,
 * KEYFRAME_REQUEST(DECODE_ERROR)), at most 3 times per 10 s, after a backoff of 100 ms / 500 ms / 1 s (T-161,
 * [RestartPolicy]); after that [onGiveUp] is called. Each codec instance keeps its own [CodecState]; a thread that
 * outlives its codec touches shared state only while that codec is current.
 * [onKeyframeRequest] and [onGiveUp] are called from arbitrary threads.
 *
 * T-159: every [attachSurface] / [reconfigure] / [restartCodec] starts a new generation and reports its lifecycle
 * through [onHealthEvent] (see [HealthEvent]; a restart after `decode_error` is not a new generation); per-frame decode
 * progress goes to [progress]. [stopFeeding] (also done on give-up) stops taking frames and keyframe retries for the
 * current generation.
 *
 * T-219: the queue is consumed by generation, not just by codec: [start] makes the new generation the queue's only
 * consumer ([FrameQueue.assignConsumer]) before its frames are admitted, and [retire] revokes the old one, so a retired
 * input loop that wakes late takes nothing and the new generation gets its CODEC_CONFIG and keyframe.
 */
class VideoRenderer(
    initialConfig: StreamConfig,
    private val onKeyframeRequest: (Int) -> Unit,
    private val onGiveUp: (String) -> Unit = {},
    /** Vsync grid fed by the UI thread's Choreographer; without samples frames render immediately. */
    private val vsync: VsyncClock = VsyncClock(),
    /**
     * [BUFFER_ADAPTIVE] (adaptive pacing, T-052), or a fixed jitter buffer in content frames, 0..2.
     * 0 = render each frame as soon as decoded (T-015 behavior).
     */
    bufferFrames: Int = 1,
    /** False when the presenter (GL path) reports shown times itself; the codec callback would double count. */
    codecReportsShown: Boolean = true,
    /** T-158: creates the decoder; tests pass a fake. */
    private val codecFactory: DecoderCodec.Factory = MediaCodecDecoder.FACTORY,
    /** T-158: clock, logcat and thread calls of the decoder threads; tests pass a JVM implementation. */
    private val env: DecoderEnv = AndroidDecoderEnv,
    /**
     * T-159: generation lifecycle for [VideoHealth]. [HealthEvent.Generation] is called synchronously on the caller's
     * (UI) thread before the generation's decoder thread starts; the rest come from the decoder threads.
     */
    private val onHealthEvent: (HealthEvent) -> Unit = {},
    /**
     * T-160: called by [reconfigure] (caller's thread) once the queue holds nothing of the previous config and the new
     * generation is started, and before its KEYFRAME_REQUEST(STARTUP): frames of [StreamConfig] may be fed from now on,
     * so the host's answer to that request is never dropped.
     */
    private val onConfigInstalled: (StreamConfig) -> Unit = {},
    /** T-161: clock and wait of the generation hand-off and the restart backoff; tests pass a fake clock. */
    handoffTimer: HandoffTimer = HandoffTimer.SYSTEM,
    /** T-161: longest wait for the previous generation before it is reported stuck. */
    private val previousWaitMs: Long = PREVIOUS_WAIT_MS,
    /** T-161: backoff before the 1st / 2nd / 3rd codec restart of a [RestartPolicy] window. */
    private val restartDelaysMs: LongArray = RestartPolicy.DELAYS_MS,
    /** T-217 dev knob (`dec_lowlat`, `dec_oprate`): decoder latency keys; [DecoderLatencyKnobs.DEFAULT] adds none. */
    private val decoderTuning: DecoderLatencyKnobs = DecoderLatencyKnobs.DEFAULT,
    /** T-231 dev knob (`color_range`, `color_standard`, `color_transfer`); [ColorOverrides.AUTO] = today's colour keys. */
    private val colorOverrides: ColorOverrides = ColorOverrides.AUTO,
) : VideoFrameSink {
    companion object {
        const val JOIN_MS = 300L
        /** T-161 (decision 0019): longest wait of a new generation for the previous one; then `stuck`. */
        const val PREVIOUS_WAIT_MS = 2_000L
        /** How long a stopping codec waits for its output thread before leaving it as a straggler. */
        private const val OUTPUT_JOIN_MS = 500L
        const val BUFFER_ADAPTIVE = -1
        private const val PTS_MAP_MAX = 64
        /** Blocking wait of the output thread per dequeue; bounds shutdown latency only. */
        private const val OUTPUT_WAIT_US = 5_000L
        /** Margin added to the presentation deadline when deciding how long an output may be held back (T-057). */
        const val DISPATCH_MARGIN_NS = 1_000_000L
        const val TRACE_DUMP_EVERY = 10
        /** Park of the input thread per wait for a frame; an offer wakes it at once, so this bounds shutdown latency only. */
        private const val INPUT_WAIT_NS = 4_000_000L
    }

    private val tag = "MB/decoder"

    /** Current stream configuration; replaced by [reconfigure]. Read once per codec creation. */
    @Volatile private var config: StreamConfig = initialConfig
    val stats = VideoStats()

    /** Read at each codec start; switch before re-attaching a surface (GL -> SurfaceView fallback). */
    @Volatile var codecReportsShown: Boolean = codecReportsShown

    /** [BUFFER_ADAPTIVE] or jitter buffer size in content frames (0..2); takes effect on the next frame. */
    @Volatile var bufferFrames: Int = bufferFrames.coerceIn(BUFFER_ADAPTIVE, 2)
        set(v) { field = v.coerceIn(BUFFER_ADAPTIVE, 2) }

    /** T-069 experiment: per-frame pace trace, dumped to [paceTraceFile] every [TRACE_DUMP_EVERY] stats windows and by [flushPaceTrace]. */
    @Volatile var paceTrace: PaceTrace? = null
        set(v) {
            field = v; queue.trace = v; PaceTrace.active = v // T-073: the receive path stamps the same trace
            dev.matebridge.client.security.Records.stampOpens = v != null // T-077: record open stamps
        }
    @Volatile var paceTraceFile: java.io.File? = null
    private var traceWindows = 0
    private val traceWriter by lazy {
        java.util.concurrent.Executors.newSingleThreadExecutor { r -> Thread(r, "mb-pace-trace").also { it.isDaemon = true } }
    }

    /** Writes the trace file on a background thread (no-op when the trace is off). */
    fun flushPaceTrace() {
        val t = paceTrace ?: return
        val f = paceTraceFile ?: return
        traceWriter.execute { try { t.dumpTo(f) } catch (e: Exception) { env.log('W', tag, "${env.elapsedRealtimeMs()} W decoder ev=pace_trace_write err=${e.javaClass.simpleName}") } }
    }

    /**
     * T-161: state of the running codec (gauge, pacers, presentation counters), null between codecs; cleared only by
     * its own run.
     */
    @Volatile private var live: CodecState? = null

    /** Slack D of the adaptive pacer for the latest frame, in microseconds (0 when not adaptive/unknown). */
    fun paceDUs(): Long = (live?.adaptive?.lastDNs ?: 0L) / 1000

    private var lastRephases = 0L

    /**
     * Once per stats second (called by the activity's stats tick): feeds the adaptive pacer the skip percentage of the
     * window just ended and paces the trace dump. T-141: the scheduler's log line moved to [logPresent].
     */
    fun onSkipWindow(skipPct: Double?) {
        live?.adaptive?.onSkipWindow(skipPct)
        if (paceTrace != null && ++traceWindows >= TRACE_DUMP_EVERY) { traceWindows = 0; flushPaceTrace() }
    }

    /**
     * The scheduler's own line (`MB/render ev=present`, see [StatsFormat.presentFields]) for the log window that just
     * ended (T-141: 10 s by default); its counters cover the window since the running codec started (review P2-3: they
     * belong to the codec, so a codec restart within the window drops the earlier codec's counts). [write] false only
     * starts a new window.
     */
    fun logPresent(write: Boolean = true) {
        val st = live
        val c = st?.counters?.snapshot(reset = true) ?: PresentCounters.Snapshot(0, 0)
        val p95 = st?.gauge?.p95AndReset()
        val pacer = st?.adaptive
        val rephases = pacer?.rephases ?: 0L
        val rephaseDelta = (rephases - lastRephases).coerceAtLeast(0)
        lastRephases = rephases
        val holds = stats.holdWindow(reset = true) // T-220: the presentation metric over the same window, every pacer
        if (!write) return
        MbLog.i(
            "present",
            // T-183: the inflight limit is retired; `inflight_limit=` stays in the line with a constant 0.
            StatsFormat.presentFields(c.slotDups, c.lateDrops, p95, vsync.leadNs(), paceDUs(), 0, pacer?.phaseLock == true, rephaseDelta, c.lateMarginP50Us, c.lateMarginMinUs) +
                " " + holds.logFields(),
            "render",
        )
    }
    private val queue = FrameQueue(stats, FrameQueue.depthForFps(initialConfig.fps))

    init {
        // T-121: root-cause line for every overflow and a line per keyframe request (both rare: the gate and the
        // request limit bound them).
        queue.onOverflow = { o ->
            env.log('W', tag, "${env.elapsedRealtimeMs()} W decoder ev=queue_overflow pending=${o.pending} limit=${o.limit} " +
                "in_codec=${live?.gauge?.current() ?: 0} decode_last_us=${stats.lastDecodeUs} since_kf=${o.sinceKeyframe} " +
                "gaps_us=${if (o.gapsUs.isEmpty()) "-" else o.gapsUs.joinToString(",")} " +
                "req=${if (o.requested) "sent" else "held"} since_req_ms=${o.sinceRequestMs}")
        }
        queue.onRequest = { reason, source ->
            env.log('I', tag, "${env.elapsedRealtimeMs()} I decoder ev=kf_request reason=$reason src=${source.logName}")
        }
    }

    private var current: CodecGeneration? = null // UI thread only
    private var generations = 0 // UI thread only

    /** T-161: bounded hand-off between generations (owner = the last generation that may hold a codec). */
    private val handoff = GenerationHandoff(handoffTimer)

    /** T-161 (tests): decoder threads waiting for the previous generation right now. */
    internal val handoffWaitingThreads: Int get() = handoff.waitingThreads

    /**
     * T-159: the current generation (frames are fed to it) and whether its feeding was stopped. Review P2-2: both change
     * only under [feedLock], and a decoder thread may block feeding only for the generation that is still fed
     * ([blockFeedingIfCurrent]), so a stale generation can neither unblock nor block the current one.
     */
    private val feedLock = Any()
    @Volatile private var feedGen = 0
    @Volatile private var feedBlocked = false

    /** T-159: decode progress of the current generation (inputs pending since the last output), read by [VideoHealth]. */
    val progress = DecodeProgress()

    /** T-159: false after [stopFeeding] or a give-up, until the next generation. */
    val feeding: Boolean get() = !feedBlocked

    /** T-159: video FAULT: drop incoming frames and keyframe retries until the next generation. Any thread. */
    fun stopFeeding() = synchronized(feedLock) { feedBlocked = true }

    /**
     * Review P2-2: a decoder thread's fault for [gen]: stops feeding and runs [publish] (fault callbacks) atomically,
     * only if [gen] is still the fed generation. False (nothing changed) for a stale generation. Review 2: the lock
     * covers only the check and the flag; the caller publishes its fault after it (a fault that loses the race to a
     * new generation is dropped by [VideoHealth]'s generation check).
     */
    private fun blockFeedingIfCurrent(gen: Int): Boolean = synchronized(feedLock) {
        if (gen != feedGen) return false
        feedBlocked = true
        true
    }

    /** Codec description for on-screen diagnostics. */
    @Volatile var codecInfo: String = "-"
        private set

    /** True while a surface is attached. The session must not feed frames while false. */
    @Volatile var attached = false
        private set

    /**
     * T-121: true when a periodic keyframe retry is due (gate closed and no request for [FrameQueue.HOLDOFF_MS]);
     * the caller must then send one, which this counts as sent. Keeps the retry from following an overflow request.
     */
    fun takeKeyframeRetry(): Boolean = feeding && queue.takeRetry()

    /** T-141 (review P2): armed by the activity's vsync loop when it falls asleep; see [FirstOutputBypass]. */
    val firstOutput = FirstOutputBypass()

    /** True while non-keyframes are refused until a keyframe arrives (pure query). */
    fun isWaitingKeyframe() = queue.isWaitingKeyframe()

    /**
     * T-121 queue fields for the `MB/decoder ev=stats` line (`kf_req= kf_held= overflows= max_pending= limit=`);
     * with [reset] a new window starts.
     */
    fun queueStatsFields(reset: Boolean = true): String {
        val q = queue.counters(reset)
        return "kf_req=${q.kfRequests} kf_held=${q.kfHeld} overflows=${q.overflows} max_pending=${q.maxPending} " +
            "limit=${queue.maxPending}"
    }

    override fun onFrame(frame: VideoFrame) {
        if (!feeding) return // T-159: FAULT; a fed dead decoder overflows and loops keyframe requests
        queue.offer(frame)?.let(onKeyframeRequest)
    }

    fun attachSurface(surface: Surface) = attachTarget(surface)

    /** [attachSurface] with the output surface as an opaque handle (T-158: JVM tests pass a plain object). */
    internal fun attachTarget(surface: Any) {
        retire(wait = false)
        attached = true
        onKeyframeRequest(queue.reset())
        start(surface)
    }

    fun detachSurface() {
        val gen = current?.gen
        attached = false
        retire(wait = true)
        if (gen != null) onHealthEvent(HealthEvent.Detached(gen))
    }

    /**
     * T-159 recovery step: a new generation on the attached surface (new codec, stored CODEC_CONFIG replayed,
     * KEYFRAME_REQUEST(STARTUP)), without blocking. No-op without a surface.
     */
    fun restartCodec() {
        val surface = current?.surface ?: return
        retire(wait = false)
        onKeyframeRequest(queue.reset(KeyframeRequest.STARTUP))
        start(surface)
    }

    /**
     * New STREAM_CONFIG: drops queued frames and stored parameter sets. If a surface is attached the
     * codec is restarted on it without blocking the caller (the new thread waits for the old one).
     */
    fun reconfigure(newConfig: StreamConfig) {
        config = newConfig
        queue.maxPending = FrameQueue.depthForFps(newConfig.fps)
        val surface = current?.surface
        retire(wait = false)
        val reason = queue.reset(KeyframeRequest.STARTUP, keepConfig = false)
        if (surface != null) start(surface)
        // T-160: only now may the session deliver this config's frames (the queue holds nothing of the old one and the
        // new generation is fed). Before the STARTUP request, so the host's answer to it is never gated away.
        onConfigInstalled(newConfig)
        if (surface != null) onKeyframeRequest(reason)
    }

    private fun start(surface: Any) {
        val gen = ++generations
        progress.begin(gen)
        synchronized(feedLock) { feedGen = gen; feedBlocked = false } // a new generation is fed again
        val att = CodecGeneration(gen, surface)
        att.thread = Thread({ decodeLoop(att) }, "mb-decoder")
        current = att
        // T-219: only this generation's input loop takes frames from now on (before any frame of its config is fed).
        queue.assignConsumer(gen)
        onHealthEvent(HealthEvent.Generation(gen))
        handoff.threadStarted(att) // counted before it runs: the generation is unfinished from now on
        att.thread.start()
    }

    /**
     * Signals the current generation to stop (wakes its hand-off or backoff wait at once); optionally waits briefly.
     * The next generation's thread waits for it through [handoff].
     */
    private fun retire(wait: Boolean) {
        val att = current ?: return
        current = null
        val startNs = System.nanoTime()
        // Review 2: bounded (RETIRE_LOCK_WAIT_MS) even while an output bookkeeping section runs; the whole detach stays
        // within JOIN_MS because the join gets only what is left.
        val locked = handoff.retire(att)
        // T-219: after `active` is false (so the old loop exits instead of spinning): the old input loop takes nothing
        // more, even if it is already past its `active` check; a parked one is woken and leaves.
        queue.revokeConsumer(att.gen)
        if (!locked) {
            env.log('W', tag, "${env.elapsedRealtimeMs()} W decoder ev=retire_lock_slow vgen=${att.gen} " +
                "wait_ms=${GenerationHandoff.RETIRE_LOCK_WAIT_MS}")
        }
        if (wait) {
            val leftMs = JOIN_MS - java.util.concurrent.TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startNs)
            att.thread.join(leftMs.coerceAtLeast(1))
            if (att.thread.isAlive) env.log('W', tag, "${env.elapsedRealtimeMs()} W decoder ev=detach_slow")
        }
    }

    private fun mime(config: StreamConfig) = if (config.codec == StreamConfig.CODEC_H264) MediaFormat.MIMETYPE_VIDEO_AVC
    else MediaFormat.MIMETYPE_VIDEO_HEVC

    /**
     * T-217: the decoder input format. With [DecoderLatencyKnobs.DEFAULT] these are exactly the pre-T-217 keys, values
     * and order; a tuning changes the operating rate in place and appends its extra keys at the end.
     */
    private fun decoderFormat(
        config: StreamConfig,
        mime: String,
        lowLatency: Boolean?,
        tuning: DecoderLatencyKnobs,
    ): DecoderFormat {
        val format = DecoderFormat(mime, config.widthPx, config.heightPx)
        format.setInteger(MediaFormat.KEY_PRIORITY, 0) // real-time
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, config.widthPx * config.heightPx * 3 / 2)
        if (config.fps > 0) format.setInteger(MediaFormat.KEY_FRAME_RATE, config.fps)
        tuning.operatingRate(config.fps)?.let { format.setInteger(MediaFormat.KEY_OPERATING_RATE, it) }
        // T-231: [ColorOverrides.AUTO] puts exactly the pre-T-231 keys (ColorMapping); a knob replaces a value in place
        // or leaves its key out. The T-217 fallback format gets the same colour keys (the knobs are independent).
        for ((k, v) in colorKeys(config)) format.setInteger(k, v)
        if (lowLatency == true) format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        for ((k, v) in tuning.extraKeys) format.setInteger(k, v)
        return format
    }

    /** T-231: the colour keys of the decoder format for [config], in format order (absent = left unset). */
    private fun colorKeys(config: StreamConfig): Map<String, Int> {
        val m = LinkedHashMap<String, Int>()
        colorOverrides.standard(config)?.let { m[MediaFormat.KEY_COLOR_STANDARD] = it }
        colorOverrides.transfer(config)?.let { m[MediaFormat.KEY_COLOR_TRANSFER] = it }
        colorOverrides.range(config)?.let { m[MediaFormat.KEY_COLOR_RANGE] = it }
        return m
    }

    /** `configure` + `start`; on failure releases [codec] and rethrows. */
    private fun configureAndStart(codec: DecoderCodec, format: DecoderFormat, surface: Any) {
        try {
            codec.configure(format, surface)
            codec.start()
        } catch (e: Exception) {
            try { codec.release() } catch (_: Exception) {}
            throw e
        }
    }

    /** [onColorKeys]: T-231, the colour keys this codec is configured with (called once, before configure). */
    private fun createCodec(surface: Any, onColorKeys: (Map<String, Int>) -> Unit = {}): DecoderCodec {
        val config = this.config
        onColorKeys(colorKeys(config))
        val mime = mime(config)
        if (!ColorMapping.primariesConveyed(config.colorPrimaries, config.matrix)) {
            // MediaFormat has no primaries key; a Display P3 stream is decoded but not tagged (BT.2020 rides on the standard).
            env.log('W', tag, "${env.elapsedRealtimeMs()} W decoder ev=color_unsupported primaries=${config.colorPrimaries}")
        }

        var codec = codecFactory.create(mime)
        val supported = codec.lowLatencySupport(mime) // null: API < 30
        val lowLatency = when (supported) { null -> "n/a"; true -> "on"; false -> "unsupported" }
        val tuning = decoderTuning
        var rejected = false
        try {
            configureAndStart(codec, decoderFormat(config, mime, supported, tuning), surface)
        } catch (e: Exception) {
            if (tuning.isDefault) throw e
            // T-217: the knob must never cost the stream: exactly one retry, on a fresh codec, with the default format.
            env.log('W', tag, "${env.elapsedRealtimeMs()} W decoder ev=dec_lowlat_rejected lowlat=${tuning.lowLat.id} " +
                "oprate=${tuning.opRate.id} keys=${tuning.changedKeys().joinToString(",")} err=${e.javaClass.simpleName}")
            rejected = true
            codec = codecFactory.create(mime)
            configureAndStart(codec, decoderFormat(config, mime, supported, DecoderLatencyKnobs.DEFAULT), surface)
        }
        val rate = (if (rejected) DecoderLatencyKnobs.DEFAULT else tuning).operatingRate(config.fps)
        // T-217 `codec_start`: the requested knob value, or `rejected` when it fell back to the default format.
        val lowlat = if (rejected && tuning.lowLat != DecoderLatencyKnobs.LowLat.OFF) "rejected" else tuning.lowLat.id
        val oprate = if (rejected && tuning.opRate != DecoderLatencyKnobs.OpRate.FPS) "rejected" else tuning.opRate.id
        codecInfo = "${codec.name} ${config.widthPx}x${config.heightPx} lowLatency=$lowLatency"
        val accepted = try {
            val f = codec.inputFormat
            fun key(k: String): String = when {
                !f.containsKey(k) -> "unset"
                else -> runCatching { f.getInteger(k).toString() }
                    .getOrElse { runCatching { f.getFloat(k).toString() }.getOrDefault("?") }
            }
            "priority=${key(MediaFormat.KEY_PRIORITY)} operating_rate=${key(MediaFormat.KEY_OPERATING_RATE)} " +
                "low_latency_fmt=${key(MediaFormat.KEY_LOW_LATENCY)}"
        } catch (e: Exception) { "input_format=unavailable" }
        // T-168 (PF7): createDecoderByType takes the platform default; say whether it is a hardware decoder.
        val hw = flag(codec.isHardwareAccelerated)
        val swOnly = flag(codec.isSoftwareOnly)
        env.log('I', tag, "${env.elapsedRealtimeMs()} I decoder ev=codec_start name=${codec.name} mime=$mime " +
            "size=${config.widthPx}x${config.heightPx} low_latency=$lowLatency requested_rate=${rate ?: "none"} " +
            "is_hw=$hw sw_only=$swOnly lowlat=$lowlat oprate=$oprate accepted $accepted")
        if (codec.isHardwareAccelerated == false || codec.isSoftwareOnly == true) {
            env.log('W', tag, "${env.elapsedRealtimeMs()} W decoder ev=codec_software name=${codec.name} mime=$mime " +
                "is_hw=$hw sw_only=$swOnly")
        }
        logVendorParameters(codec)
        return codec
    }

    /** T-217: component names whose vendor parameters were logged (decoder threads, one codec at a time). */
    private val vendorParamsLogged = java.util.Collections.synchronizedSet(HashSet<String>())

    /** T-217: `ev=vendor_params`, once per component name per renderer; key names only, never values. */
    private fun logVendorParameters(codec: DecoderCodec) {
        if (!vendorParamsLogged.add(codec.name)) return
        val names = try { codec.supportedVendorParameters } catch (e: Exception) { null }
        env.log('I', tag, "${env.elapsedRealtimeMs()} I decoder ev=vendor_params name=${codec.name} " +
            VendorParams.fields(names))
    }

    /** `1` / `0`, or `?` when unknown. */
    private fun flag(b: Boolean?) = when (b) { null -> "?"; true -> "1"; false -> "0" }

    private fun decodeLoop(att: CodecGeneration) {
        try {
            // T-161: wait (bounded) until the previous generation's decoder and output threads have exited.
            val handed = try { handoff.acquire(att, previousWaitMs) } catch (_: InterruptedException) { GenerationHandoff.Result.Retired }
            when (handed) {
                GenerationHandoff.Result.Ready -> {}
                GenerationHandoff.Result.Retired -> return
                is GenerationHandoff.Result.Stuck -> { reportStuck(att, handed); return }
            }
            onHealthEvent(HealthEvent.Running(att.gen))
            // T-077: the input hand-off is on the frame's critical path; ask the scheduler for prompt wake-ups.
            try { env.setDisplayPriority() } catch (_: Exception) {}
            decodeAttempts(att)
        } finally {
            onHealthEvent(HealthEvent.Exited(att.gen))
            handoff.threadExited(att)
        }
    }

    /**
     * T-161: the previous codec did not finish within [previousWaitMs] (a native stop/release/dequeue hangs): the
     * previous generation's, or (review P2-1) this generation's own previous codec when its output thread is a
     * straggler (`prev_vgen` = `vgen`). No codec is opened: the hardware decoder may still be held. Video FAULT
     * (decision 0019) through [onHealthEvent], only while this generation is still the fed one (review P2-2).
     */
    private fun reportStuck(att: CodecGeneration, stuck: GenerationHandoff.Result.Stuck) {
        val prev = stuck.previous
        env.log('W', tag, "${env.elapsedRealtimeMs()} W decoder ev=decoder_previous_stuck vgen=${att.gen} " +
            "prev_vgen=${prev.gen} waited_ms=${stuck.waitedMs} out_straggler=${if (prev.outputStraggler) 1 else 0}")
        // Nothing consumes this generation's frames.
        if (blockFeedingIfCurrent(att.gen)) onHealthEvent(HealthEvent.Fault(att.gen, FaultCause.STUCK))
    }

    private fun decodeAttempts(att: CodecGeneration) {
        val policy = RestartPolicy(delaysMs = restartDelaysMs)
        while (att.active) {
            val failure = runCodec(att)
            if (!att.active) break
            env.log('E', tag, "${env.elapsedRealtimeMs()} E decoder ev=decode_error err=$failure")
            if (!policy.allow(env.elapsedRealtimeMs())) {
                env.log('E', tag, "${env.elapsedRealtimeMs()} E decoder ev=give_up")
                // T-159: no more frames or keyframe retries for a dead generation (review P2-2: if still the fed one).
                if (blockFeedingIfCurrent(att.gen)) {
                    onGiveUp("decoder failed repeatedly: $failure")
                    onHealthEvent(HealthEvent.Fault(att.gen, FaultCause.GIVE_UP))
                }
                handoff.retire(att)
                queue.revokeConsumer(att.gen) // T-219: a dead generation consumes nothing
                break
            }
            // T-161: back off before the restart; a retire() (detach, new generation) ends the wait at once.
            val stillActive = try { handoff.pause(att, policy.delayMs()) } catch (_: InterruptedException) { false }
            if (!stillActive) break
            // Review P2-1: never a new codec while the previous codec's output thread is still alive (bounded wait).
            val own = try { handoff.awaitOwnThreads(att, previousWaitMs) } catch (_: InterruptedException) { GenerationHandoff.Result.Retired }
            if (own is GenerationHandoff.Result.Stuck) { reportStuck(att, own); break }
            if (own != GenerationHandoff.Result.Ready) break
            // T-219: only while this generation still owns the queue; a retired one must not drop the next one's frames.
            val restart = queue.resetIfOwner(att.gen, KeyframeRequest.DECODE_ERROR) ?: break
            onKeyframeRequest(restart)
        }
    }

    /** Runs one codec instance until detach or error. Returns the error name, or null on detach. */
    private fun runCodec(att: CodecGeneration): String? {
        var codec: DecoderCodec? = null
        var error: String? = null
        var outThread: Thread? = null
        val st = CodecState(att, PTS_MAP_MAX) // T-161: this codec's own state; `running` replaces outRunning
        val outError = java.util.concurrent.atomic.AtomicReference<String?>(null)
        try {
            // T-168: frame_seq restarts per video connection; no per-frame entry of an earlier codec may pair with ours.
            // Decoder thread, before this codec's first input (the previous codec's threads no longer touch stats).
            stats.resetFrames()
            var requestedColors: Map<String, Int> = emptyMap()
            codec = createCodec(att.surface) { requestedColors = it }
            var held: VideoFrame? = null
            val frameIntervalNs = if (config.fps > 0) 1_000_000_000L / config.fps else 0
            val pacer = FramePacer(vsync, bufferFrames, frameIntervalNs)
            val adaptivePacer = AdaptivePacer(vsync, frameIntervalNs)
            val trace = paceTrace
            val probe = if (trace != null) PaceProbe() else null
            adaptivePacer.probe = probe
            // T-059: the host thins frames to the reported panel rate; follow the measured arrivals, never the codec.
            val arrival = st.arrival
            // T-220: with the measured content cadence (a 60 fps game in a 120 fps stream on 120 Hz: two periods).
            val intervalOf: (Long) -> Long = { period ->
                FrameInterval.resolve(frameIntervalNs, period, arrival.intervalNs, arrival.cadenceNs)
            }
            pacer.intervalProvider = intervalOf
            adaptivePacer.intervalProvider = intervalOf
            st.adaptive = adaptivePacer
            live = st
            val gauge = st.gauge
            val reportsShown = codecReportsShown
            val sink = CodecSink(codec, st, expectCallback = reportsShown, trace = trace)
            val releaser = SlotReleaser(sink, st.counters)
            releaser.trace = trace
            if (reportsShown) {
                codec.setOnFrameRenderedListener { pts, nanoTime -> // on the main looper (adapter)
                    // T-161: a late callback of a stopped codec must not count. Main thread: a plain check, never the
                    // shared lock (review 2: the UI thread must not wait on output bookkeeping).
                    if (st.current) {
                        val period = vsync.periodNs
                        val fi = FrameInterval.resolve(frameIntervalNs, period, arrival.intervalNs, arrival.cadenceNs)
                        val cadence = Math.round(fi.toDouble() / period).coerceAtLeast(1) * period
                        stats.onShownPaced(st.readyByPts.get(pts), nanoTime, period, cadence)
                        // T-168 cap_cb; T-225: the callback times are also the presentation metric (`skip_pct`).
                        stats.onRenderCallback(pts, st.captureByPts.get(pts), nanoTime / 1000, nanoTime, period)
                        trace?.onCallback(pts, nanoTime, period)
                    }
                }
            }
            // Outputs are drained on their own thread with a blocking dequeue, so a decoded frame is handled the
            // moment it is ready instead of after the input side's 4 ms poll/dequeue waits (T-052).
            val c = codec
            val colors = requestedColors
            val t = Thread({
                val outInfo = DecoderCodec.OutputInfo()
                var loggedFormat = false
                val formatGate = OutputFormatLogGate() // T-231: `ev=decoder_output_format`, per codec
                st.lastOutputNs = System.nanoTime()
                try {
                    while (st.current) {
                        val now = System.nanoTime()
                        val untilDeadline = releaser.untilDeadlineNs(now)
                        // T-141: an output (or the held buffer's deadline) ends the wait at once; the timeout only bounds
                        // how fast a stop is seen, so it grows while no output comes.
                        val maxWaitUs = IdleWait.waitNs(now - st.lastOutputNs, OUTPUT_WAIT_US * 1000) / 1000
                        val waitUs = if (untilDeadline == null) maxWaitUs
                        else (untilDeadline / 1000).coerceIn(0, maxWaitUs)
                        val changed = drainOutput(c, outInfo, pacer, adaptivePacer, sink, releaser, st, waitUs)
                        if (!st.current) break // T-161: a stopped codec's held buffers go back with stop()
                        releaser.flushDue(System.nanoTime())
                        if (changed && !loggedFormat) {
                            loggedFormat = true
                            logOutputFormat(c)
                        }
                        if (changed) logDecoderOutputFormat(c, formatGate, att.gen, colors)
                    }
                } catch (e: Exception) {
                    if (st.running) outError.set(e.javaClass.simpleName)
                } finally {
                    handoff.threadExited(att) // T-161: the generation is finished only when this thread is gone too
                }
            }, "mb-decoder-out")
            outThread = t
            handoff.threadStarted(att)
            try { t.start() } catch (e: Throwable) { handoff.threadExited(att); throw e }
            // T-077: a free input buffer is taken while waiting for the frame, and the queue hands frames over with
            // park/unpark, so an arriving frame costs only the copy and queueInputBuffer.
            val inSlot = InputBufferSlot { timeoutUs -> c.dequeueInputBuffer(timeoutUs) }
            var takenNs = 0L
            var lastFrameNs = System.nanoTime()
            while (att.active && outError.get() == null) {
                inSlot.prefetch()
                // T-141: an offer unparks the wait at once; the timeout only bounds how fast a stop is seen.
                // T-219: frames of this generation only; once retired it gets null and the loop ends on `active`.
                val fromQueue = if (held == null) queue.awaitNext(IdleWait.waitNs(System.nanoTime() - lastFrameNs, INPUT_WAIT_NS), att.gen) else null
                if (fromQueue != null) lastFrameNs = System.nanoTime()
                if (fromQueue != null && trace != null) takenNs = lastFrameNs
                val frame = held ?: fromQueue
                held = null
                if (frame == null) continue
                val idx = inSlot.take(4_000)
                if (idx < 0) { held = frame; continue }
                val inbufNs = if (trace != null) System.nanoTime() else 0L
                val buf = codec.getInputBuffer(idx)!!
                if (buf.capacity() < frame.data.size) {
                    env.log('E', tag, "${env.elapsedRealtimeMs()} E decoder ev=frame_too_large size=${frame.data.size} cap=${buf.capacity()}")
                    codec.queueInputBuffer(idx, 0, 0, 0, 0) // hand the empty buffer back
                    stats.onDropped(1)
                    queue.onDecoderErrorIfOwner(att.gen)?.let(onKeyframeRequest) // T-219: not for a retired generation
                    continue
                }
                buf.clear()
                buf.put(frame.data.value)
                val copiedNs = if (trace != null) System.nanoTime() else 0L
                val flags = if (frame.isCodecConfig) DecoderCodec.BUFFER_FLAG_CODEC_CONFIG else 0
                stats.onInput(frame.frameSeq, nowUs(), if (frame.isCodecConfig) null else frame.captureTimeUs)
                if (!frame.isCodecConfig) { st.captureByPts.put(frame.frameSeq, frame.captureTimeUs); arrival.onFrame(frame.captureTimeUs) }
                if (!frame.isCodecConfig) gauge.onQueued(System.nanoTime())
                codec.queueInputBuffer(idx, 0, frame.data.size, frame.frameSeq, flags)
                if (!frame.isCodecConfig) progress.onInput(att.gen, env.elapsedRealtimeMs()) // T-159 no-output rule
                trace?.onInput(frame.frameSeq, System.nanoTime(), takenNs, inbufNs, copiedNs, inSlot.lastPrefetched)
            }
            if (att.active) error = outError.get()
        } catch (e: Exception) {
            error = e.javaClass.simpleName
        } finally {
            st.stop() // waits for an output bookkeeping section in progress; none starts after it
            val out = outThread
            try { out?.join(OUTPUT_JOIN_MS) } catch (_: InterruptedException) {}
            if (out != null && out.isAlive) {
                // T-161: still inside a codec call; it cannot touch shared state any more (st is no longer current),
                // and the next generation's hand-off waits for it.
                att.outputStraggler = true
                env.log('W', tag, "${env.elapsedRealtimeMs()} W decoder ev=output_straggler vgen=${att.gen} " +
                    "join_ms=$OUTPUT_JOIN_MS")
            }
            if (live === st) live = null // only this codec's own entry (codecs of one renderer never overlap)
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            env.log('I', tag, "${env.elapsedRealtimeMs()} I decoder ev=codec_stop")
        }
        return error
    }

    /**
     * Output-buffer release with bookkeeping (stats, this codec's occupancy). Output thread only. T-161: the shared
     * [stats] count only while [st] is current. T-168: knows which frame each held buffer carries ([tag]), so a release
     * adds a capture -> release sample and a discard does not; [expectCallback] in codec-render mode.
     */
    private inner class CodecSink(
        private val codec: DecoderCodec, private val st: CodecState, private val expectCallback: Boolean,
        private val trace: PaceTrace?,
    ) : SlotReleaser.Sink {
        /** Output buffer index -> pts (frame_seq) of the frame in it; bounded by the codec's output buffers. */
        private val ptsOf = HashMap<Int, Long>()
        /** T-220: output buffer index -> its pace-trace row (trace on only). */
        private val traceIdOf = HashMap<Int, Long>()

        fun tag(idx: Int, ptsUs: Long, traceId: Long = -1L) {
            ptsOf[idx] = ptsUs
            if (trace != null) traceIdOf[idx] = traceId
        }

        override fun release(idx: Int, renderNs: Long) = render(idx, renderNs) { codec.releaseOutputBuffer(idx, renderNs) }
        override fun discard(idx: Int) {
            codec.releaseOutputBuffer(idx, false)
            ptsOf.remove(idx)
            traceIdOf.remove(idx)
            st.ifCurrent { stats.onDiscarded() }
            st.gauge.onDone(System.nanoTime())
        }
        fun releaseNow(idx: Int) = render(idx, 0L) { codec.releaseOutputBuffer(idx, true) }

        /**
         * A release for rendering ([releaseCall], the codec call, runs outside the shared lock). T-168 review: in
         * codec-render mode the frame is awaited BEFORE the call, because its frame-rendered callback (main looper) may
         * run before the call returns; a call that throws takes the registration back. T-220: [renderNs] is the render
         * time handed to the codec (0 = at once); with the clock and grid once the call returned it gives the vsync the
         * frame is due on ([HoldMeter.releasedSlot]: a call that stalled past the deadline counts for the next vsync),
         * the same way for every pacer. The pace trace records that vsync too (`latch_slot_ns`).
         */
        private inline fun render(idx: Int, renderNs: Long, releaseCall: () -> Unit) {
            val pts = ptsOf.remove(idx)
            val traceId = traceIdOf.remove(idx) ?: -1L
            val captureUs = if (pts != null) st.captureByPts.get(pts) else null // own lock, outside the shared one
            val tracked = expectCallback && pts != null && st.ifCurrent { stats.awaitCallback(pts) }
            var slotNs = 0L
            var periodNs = 0L
            try {
                HoldMeter.releasedSlot(vsync, renderNs, releaseClock, releaseCall) { s, p -> slotNs = s; periodNs = p }
            } catch (e: Exception) {
                if (tracked && pts != null) st.ifCurrent { stats.cancelCallback(pts) }
                throw e
            }
            val nowNs = System.nanoTime()
            st.ifCurrent { stats.onReleased(pts, captureUs, nowNs / 1000, slotNs, periodNs) }
            if (traceId >= 0) trace?.onLatch(traceId, slotNs, periodNs)
            st.gauge.onDone(nowNs)
        }
    }

    /** How long an output may be held for a possible same-slot successor: the compositor needs it this long before the slot. */
    private fun dispatchLeadNs(): Long {
        val g = vsync.grid()
        return if (g.deadlineNs > 0) g.deadlineNs + DISPATCH_MARGIN_NS else g.periodNs
    }

    /**
     * Takes every ready output. [BUFFER_ADAPTIVE] uses [AdaptivePacer] (capture-time based playout delay);
     * with [bufferFrames] == 0 only the newest is rendered at once and the skipped ones count as dropped
     * (T-015 behavior). Otherwise each frame gets a vsync slot and render timestamp from its pacer and goes to
     * [releaser]: at most one release per slot, at most one replaceable buffer held back across drains until its
     * dispatch deadline (T-057). Returns true once an output-format change has been seen (one-time logging).
     */
    private fun drainOutput(
        codec: DecoderCodec, info: DecoderCodec.OutputInfo, pacer: FramePacer, adaptivePacer: AdaptivePacer,
        sink: CodecSink, releaser: SlotReleaser, st: CodecState, firstWaitUs: Long = 0,
    ): Boolean {
        var waitUs = firstWaitUs // only the first dequeue blocks; the rest of a burst is taken without waiting
        val mode = bufferFrames
        pacer.bufferFrames = mode
        val useAdaptive = mode == BUFFER_ADAPTIVE
        val paced = useAdaptive || mode > 0
        val gen = st.generation.gen
        stats.setGapThresholdUs(vsync.periodNs * 3 / 2 / 1000)
        var prev = -1
        var formatChanged = false
        while (true) {
            val idx = codec.dequeueOutputBuffer(info, waitUs)
            if (idx == DecoderCodec.INFO_OUTPUT_FORMAT_CHANGED) { formatChanged = true; continue }
            if (idx < 0) break
            val isFrame = info.flags and DecoderCodec.BUFFER_FLAG_CODEC_CONFIG == 0
            val readyNs = System.nanoTime()
            var d: FramePacer.Decision? = null
            var tag = -1L
            var firstOfGeneration = false
            // Review P2-3: the shared bookkeeping of this output (decode progress, stats, first-output bypass, pacing,
            // trace) runs atomically with the "still current?" check; a retire waits for it (bounded), so an output of a
            // retired codec never touches the next generation's state. Review 2: in-memory work only; codec calls and
            // callbacks ([onHealthEvent]) run after the lock is released.
            val current = st.ifCurrent {
                outputSectionHook?.invoke()
                st.lastOutputNs = readyNs
                if (isFrame) {
                    // T-159: health is timed on decoder output, not on onFrameRendered (panels may throttle presentation).
                    firstOfGeneration = progress.onOutput(gen)
                    stats.onOutput(info.presentationTimeUs, nowUs(), readyNs / 1000)
                    st.readyByPts.put(info.presentationTimeUs, readyNs)
                }
                if (paced && isFrame) {
                    val captureUs = st.captureByPts.get(info.presentationTimeUs)
                    val trace = releaser.trace
                    val probe = adaptivePacer.probe
                    probe?.clear()
                    // T-141: the first output after an idle sleep is released at once (null), independent of the clock.
                    val tookBypass = firstOutput.take()
                    val decision = if (tookBypass) null
                    else if (!useAdaptive) pacer.schedule(readyNs)
                    else adaptivePacer.schedule(captureUs, readyNs)
                    giveBackIfRetired(st, tookBypass)
                    if (decision == null) {
                        // T-220: the row id too, so the release-time vsync of a bypassed frame lands in the trace
                        tag = trace?.record(info.presentationTimeUs, captureUs ?: 0, readyNs, null, 0, false, false, 0, PaceTrace.ACTION_NOW) ?: -1L
                    } else {
                        stats.onPaceAdd(decision.addedNs / 1000)
                        if (decision.slotNs != 0L) stats.onReadySlot((decision.slotNs - readyNs) / 1000) // T-168 ready_slot
                        if (useAdaptive) stats.onScheduled(decision.skipped)
                        if (decision.lateDrop) st.counters.onLateDrop(if (decision.ownSlotNs != 0L) (decision.ownSlotNs - readyNs) / 1000 else null)
                        tag = trace?.record(info.presentationTimeUs, captureUs ?: 0, readyNs, probe, decision.slotNs, decision.lateDrop, decision.collided, decision.ownSlotNs) ?: -1L
                    }
                    d = decision
                } else if (isFrame) {
                    giveBackIfRetired(st, firstOutput.take()) // unpaced: released at once anyway; must not linger
                }
            }
            if (firstOfGeneration) onHealthEvent(HealthEvent.FirstOutput(gen)) // stale gens are dropped by VideoHealth
            if (!current) {
                // T-161: the codec was stopped while this thread sat in dequeue (a straggler) or before its bookkeeping:
                // hand the buffers back without touching stats, the first-output bypass or decode progress, which
                // belong to the current codec.
                if (prev >= 0) codec.releaseOutputBuffer(prev, false)
                codec.releaseOutputBuffer(idx, false)
                return formatChanged
            }
            waitUs = 0
            if (isFrame) sink.tag(idx, info.presentationTimeUs, tag) // T-168: which frame a later release/discard is (T-220: and its trace row)
            if (paced) {
                if (!isFrame) { codec.releaseOutputBuffer(idx, false); continue }
                val decision = d
                if (decision == null) {
                    releaser.flushAll()
                    sink.releaseNow(idx)
                    continue
                }
                releaser.submit(idx, decision.slotNs, decision.renderNs, decision.slotNs - dispatchLeadNs(), readyNs, vsync.periodNs, tag)
                continue
            }
            if (prev >= 0) sink.discard(prev)
            prev = idx
        }
        if (prev >= 0) sink.releaseNow(prev)
        return formatChanged
    }

    /**
     * Review 2: a retire that timed out on the shared lock ([GenerationHandoff.retire] false) can land inside an output
     * section; a bypass taken there may have been armed for the next generation, so a retired codec hands it back.
     */
    private fun giveBackIfRetired(st: CodecState, tookBypass: Boolean) {
        if (tookBypass && !st.current) firstOutput.arm()
    }

    /** Tests only (T-219 barrier): runs on the input thread inside the queue wait, right before each park. */
    internal var inputParkHook: (() -> Unit)?
        get() = queue.parkHook
        set(v) { queue.parkHook = v }

    /** Tests only: runs inside each output's bookkeeping section (under the shared lock, after the "current" check). */
    @Volatile internal var outputSectionHook: (() -> Unit)? = null

    /** T-220: clock read once a release call returned (the presentation metric's vsync); tests pass a fake. */
    @Volatile internal var releaseClock: () -> Long = { System.nanoTime() }

    private fun logOutputFormat(codec: DecoderCodec) {
        val f = codec.outputFormat
        fun key(k: String) = if (f.containsKey(k)) f.getInteger(k).toString() else "unset"
        env.log('I', tag, "${env.elapsedRealtimeMs()} I decoder ev=output_format " +
            "range=${key(MediaFormat.KEY_COLOR_RANGE)} standard=${key(MediaFormat.KEY_COLOR_STANDARD)} " +
            "transfer=${key(MediaFormat.KEY_COLOR_TRANSFER)} " +
            "size=${key(MediaFormat.KEY_WIDTH)}x${key(MediaFormat.KEY_HEIGHT)} " +
            "crop=${key("crop-left")},${key("crop-top")},${key("crop-right")},${key("crop-bottom")}")
    }

    /**
     * T-231: `ev=decoder_output_format` after an output-format change ([OutputFormatLogGate]: the same fields are not
     * repeated, bounded per codec). [requested]: the colour keys this codec was configured with (`req_*`).
     */
    private fun logDecoderOutputFormat(codec: DecoderCodec, gate: OutputFormatLogGate, gen: Int, requested: Map<String, Int>) {
        val fields = try { OutputFormatReport.fields(codec.outputFormat, requested) } catch (e: Exception) { "output_format=unavailable" }
        if (!gate.take(fields)) return
        env.log('I', tag, "${env.elapsedRealtimeMs()} I decoder ev=decoder_output_format gen=$gen $fields")
    }

    private fun nowUs() = env.elapsedRealtimeNanos() / 1000
}
