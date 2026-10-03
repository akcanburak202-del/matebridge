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
 * destroyed or the activity stops. Each attachment has its own token; a new attachment's thread
 * first waits for the previous thread to exit, so two codecs never run at once. [detachSurface]
 * blocks the UI thread for at most [JOIN_MS] (the surface must be free before it is destroyed);
 * [attachSurface] and [reconfigure] never block: the new thread does the waiting itself.
 * Keep ONE renderer for the whole app run and call [reconfigure] on a new STREAM_CONFIG.
 *
 * Decoder errors restart the codec on the same surface (queue reset, last CODEC_CONFIG replayed,
 * KEYFRAME_REQUEST(DECODE_ERROR)), at most 3 times per 10 s; after that [onGiveUp] is called.
 * [onKeyframeRequest] and [onGiveUp] are called from arbitrary threads.
 *
 * T-159: every [attachSurface] / [reconfigure] / [restartCodec] starts a new generation and reports its lifecycle
 * through [onHealthEvent] (see [HealthEvent]; a restart after `decode_error` is not a new generation); per-frame decode
 * progress goes to [progress]. [stopFeeding] (also done on give-up) stops taking frames and keyframe retries for the
 * current generation.
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
) : VideoFrameSink {
    companion object {
        const val JOIN_MS = 300L
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

    @Volatile private var adaptive: AdaptivePacer? = null

    /**
     * T-080 experiment: non-null = the adaptive mode schedules with [ConstantPlayoutPacer] (constant playout delay)
     * instead of the phase lock. Read at each codec start.
     */
    @Volatile var cpdConfig: CpdConfig? = null
    @Volatile private var cpdActive: ConstantPlayoutPacer? = null

    /**
     * Upper bound on frames inside the decoder (queued input minus released/discarded output, held buffers
     * included): 0 = unlimited (the pre-T-057 behavior), else 2..4 for experiments. Read on each frame.
     */
    @Volatile var maxInFlight: Int = 0

    /** T-069 experiment: per-frame pace trace, dumped to [paceTraceFile] every [TRACE_DUMP_EVERY] stats windows and by [flushPaceTrace]. */
    @Volatile var paceTrace: PaceTrace? = null
        set(v) {
            field = v; queue.trace = v; PaceTrace.active = v // T-073: the receive path stamps the same trace
            dev.matebridge.client.security.Records.stampOpens = v != null // T-077: record open stamps
        }
    @Volatile var paceTraceFile: java.io.File? = null

    /** T-079 experiment: the decoder threads join this hint session; set before the first [attachSurface]. */
    @Volatile var perfHint: PerfHint? = null
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

    private val counters = PresentCounters()
    private val gauge = InFlightGauge()

    /** KEY_OPERATING_RATE policy, see [OperatingRate]; read at each codec start. */
    @Volatile var operatingRate: Int = OperatingRate.STREAM_FPS

    // frameSeq (codec pts) -> host capture time (us) / time the decoded frame became ready (ns, System.nanoTime).
    private val captureByPts = BoundedMap()
    private val arrival = ArrivalTracker()
    private val readyByPts = BoundedMap()

    private class BoundedMap {
        private val m = object : LinkedHashMap<Long, Long>() {
            override fun removeEldestEntry(e: MutableMap.MutableEntry<Long, Long>) = size > PTS_MAP_MAX
        }
        @Synchronized fun put(k: Long, v: Long) { m[k] = v }
        @Synchronized fun get(k: Long): Long? = m[k]
        @Synchronized fun clear() = m.clear()
    }

    /** Slack D of the adaptive pacer for the latest frame, in microseconds (0 when not adaptive/unknown). */
    fun paceDUs(): Long = (cpdActive?.lastDNs ?: adaptive?.lastDNs ?: 0L) / 1000

    private var lastRephases = 0L
    private var lastRecenters = 0L

    /**
     * Once per stats second (called by the activity's stats tick): feeds the adaptive pacer the skip percentage of the
     * window just ended and paces the trace dump. T-141: the scheduler's log line moved to [logPresent].
     */
    fun onSkipWindow(skipPct: Double?) {
        adaptive?.onSkipWindow(skipPct)
        if (paceTrace != null && ++traceWindows >= TRACE_DUMP_EVERY) { traceWindows = 0; flushPaceTrace() }
    }

    /**
     * The scheduler's own line (`MB/render ev=present`, see [StatsFormat.presentFields]) for the log window that just
     * ended (T-141: 10 s by default); its counters cover the whole window. [write] false only starts a new window.
     */
    fun logPresent(write: Boolean = true) {
        val c = counters.snapshot(reset = true)
        val p95 = gauge.p95AndReset()
        val pacer = adaptive
        val rephases = pacer?.rephases ?: 0L
        val rephaseDelta = (rephases - lastRephases).coerceAtLeast(0)
        lastRephases = rephases
        val recenters = pacer?.recenters ?: 0L
        val recenterDelta = (recenters - lastRecenters).coerceAtLeast(0)
        lastRecenters = recenters
        if (!write) return
        MbLog.i(
            "present",
            StatsFormat.presentFields(c.slotDups, c.lateDrops, p95, vsync.leadNs(), paceDUs(), maxInFlight, pacer?.phaseLock == true, rephaseDelta, c.lateMarginP50Us, c.lateMarginMinUs, if (vsync.recenter) recenterDelta else null),
            "render",
        )
    }
    private val queue = FrameQueue(stats, FrameQueue.depthForFps(initialConfig.fps))

    init {
        // T-121: root-cause line for every overflow and a line per keyframe request (both rare: the gate and the
        // request limit bound them).
        queue.onOverflow = { o ->
            env.log('W', tag, "${env.elapsedRealtimeMs()} W decoder ev=queue_overflow pending=${o.pending} limit=${o.limit} " +
                "in_codec=${gauge.current()} decode_last_us=${stats.lastDecodeUs} since_kf=${o.sinceKeyframe} " +
                "gaps_us=${if (o.gapsUs.isEmpty()) "-" else o.gapsUs.joinToString(",")} " +
                "req=${if (o.requested) "sent" else "held"} since_req_ms=${o.sinceRequestMs}")
        }
        queue.onRequest = { reason, source ->
            env.log('I', tag, "${env.elapsedRealtimeMs()} I decoder ev=kf_request reason=$reason src=${source.logName}")
        }
    }

    private class Attachment(val surface: Any, val previous: Thread?, val gen: Int) {
        @Volatile var active = true
        lateinit var thread: Thread
    }

    private var current: Attachment? = null // UI thread only
    private var lingering: Thread? = null // last retired decoder thread; the next one waits for it (UI thread only)
    private var generations = 0 // UI thread only

    /** T-159: the current generation (frames are fed to it) and the one whose feeding was stopped, if any. */
    @Volatile private var feedGen = 0
    @Volatile private var feedBlockedGen = -1

    /** T-159: decode progress of the current generation (inputs pending since the last output), read by [VideoHealth]. */
    val progress = DecodeProgress()

    /** T-159: false after [stopFeeding] or a give-up, until the next generation. */
    val feeding: Boolean get() = feedBlockedGen != feedGen

    /** T-159: video FAULT: drop incoming frames and keyframe retries until the next generation. Any thread. */
    fun stopFeeding() { feedBlockedGen = feedGen }

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
        if (surface != null) {
            onKeyframeRequest(reason)
            start(surface)
        }
    }

    private fun start(surface: Any) {
        val gen = ++generations
        progress.begin(gen)
        feedGen = gen // a new generation is fed again
        val att = Attachment(surface, lingering, gen)
        att.thread = Thread({ decodeLoop(att) }, "mb-decoder")
        current = att
        onHealthEvent(HealthEvent.Generation(gen))
        att.thread.start()
    }

    /** Signals the current thread to stop; optionally waits briefly. The thread is remembered for the next start. */
    private fun retire(wait: Boolean) {
        val att = current ?: return
        att.active = false
        current = null
        lingering = att.thread
        if (wait) {
            att.thread.join(JOIN_MS)
            if (att.thread.isAlive) env.log('W', tag, "${env.elapsedRealtimeMs()} W decoder ev=detach_slow")
        }
    }

    private fun mime(config: StreamConfig) = if (config.codec == StreamConfig.CODEC_H264) MediaFormat.MIMETYPE_VIDEO_AVC
    else MediaFormat.MIMETYPE_VIDEO_HEVC

    private fun createCodec(surface: Any): DecoderCodec {
        val config = this.config
        val mime = mime(config)
        val format = DecoderFormat(mime, config.widthPx, config.heightPx)
        format.setInteger(MediaFormat.KEY_PRIORITY, 0) // real-time
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, config.widthPx * config.heightPx * 3 / 2)
        if (config.fps > 0) format.setInteger(MediaFormat.KEY_FRAME_RATE, config.fps)
        val rate = OperatingRate.resolve(operatingRate, config.fps)
        if (rate != null) format.setInteger(MediaFormat.KEY_OPERATING_RATE, rate)
        ColorMapping.standard(config.matrix)?.let { format.setInteger(MediaFormat.KEY_COLOR_STANDARD, it) }
        ColorMapping.transfer(config.transfer)?.let { format.setInteger(MediaFormat.KEY_COLOR_TRANSFER, it) }
        format.setInteger(MediaFormat.KEY_COLOR_RANGE, ColorMapping.range(config.fullRange))
        if (config.colorPrimaries != 1) {
            // MediaFormat has no primaries key; a Display P3 stream is decoded but not tagged.
            env.log('W', tag, "${env.elapsedRealtimeMs()} W decoder ev=color_unsupported primaries=${config.colorPrimaries}")
        }

        val codec = codecFactory.create(mime)
        var lowLatency = "n/a"
        val supported = codec.lowLatencySupport(mime) // null: API < 30
        if (supported != null) {
            if (supported) format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            lowLatency = if (supported) "on" else "unsupported"
        }
        try {
            codec.configure(format, surface)
            codec.start()
        } catch (e: Exception) {
            try { codec.release() } catch (_: Exception) {}
            throw e
        }
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
        env.log('I', tag, "${env.elapsedRealtimeMs()} I decoder ev=codec_start name=${codec.name} mime=$mime " +
            "size=${config.widthPx}x${config.heightPx} low_latency=$lowLatency requested_rate=${rate ?: "none"} accepted $accepted")
        return codec
    }

    private fun decodeLoop(att: Attachment) {
        try { att.previous?.join() } catch (_: InterruptedException) { onHealthEvent(HealthEvent.Exited(att.gen)); return }
        onHealthEvent(HealthEvent.Running(att.gen))
        // T-077: the input hand-off is on the frame's critical path; ask the scheduler for prompt wake-ups.
        try { env.setDisplayPriority() } catch (_: Exception) {}
        val hint = perfHint
        val tid = env.myTid()
        hint?.register(PerfHint.ROLE_IN, tid)
        try {
            decodeAttempts(att)
        } finally {
            hint?.unregister(PerfHint.ROLE_IN, tid)
            onHealthEvent(HealthEvent.Exited(att.gen))
        }
    }

    private fun decodeAttempts(att: Attachment) {
        val policy = RestartPolicy()
        while (att.active) {
            val failure = runCodec(att)
            if (!att.active) break
            env.log('E', tag, "${env.elapsedRealtimeMs()} E decoder ev=decode_error err=$failure")
            if (!policy.allow(env.elapsedRealtimeMs())) {
                env.log('E', tag, "${env.elapsedRealtimeMs()} E decoder ev=give_up")
                att.active = false
                feedBlockedGen = att.gen // T-159: no more frames or keyframe retries for a dead generation
                onGiveUp("decoder failed repeatedly: $failure")
                onHealthEvent(HealthEvent.Fault(att.gen, FaultCause.GIVE_UP))
                break
            }
            onKeyframeRequest(queue.reset(KeyframeRequest.DECODE_ERROR))
        }
    }

    /** Runs one codec instance until detach or error. Returns the error name, or null on detach. */
    private fun runCodec(att: Attachment): String? {
        var codec: DecoderCodec? = null
        var error: String? = null
        var outThread: Thread? = null
        val outRunning = java.util.concurrent.atomic.AtomicBoolean(true)
        val outError = java.util.concurrent.atomic.AtomicReference<String?>(null)
        try {
            codec = createCodec(att.surface)
            var held: VideoFrame? = null
            val frameIntervalNs = if (config.fps > 0) 1_000_000_000L / config.fps else 0
            val pacer = FramePacer(vsync, bufferFrames, frameIntervalNs)
            val adaptivePacer = AdaptivePacer(vsync, frameIntervalNs)
            val trace = paceTrace
            val probe = if (trace != null) PaceProbe() else null
            adaptivePacer.probe = probe
            // T-059: the host thins frames to the reported panel rate; follow the measured arrivals, never the codec.
            val intervalOf: (Long) -> Long = { period -> FrameInterval.resolve(frameIntervalNs, period, arrival.intervalNs) }
            pacer.intervalProvider = intervalOf
            adaptivePacer.intervalProvider = intervalOf
            val cpd = cpdConfig?.let { cfg ->
                ConstantPlayoutPacer(vsync, cfg, frameIntervalNs).also { it.probe = probe; it.intervalProvider = intervalOf }
            }
            cpdActive = cpd
            arrival.reset()
            adaptive = adaptivePacer
            captureByPts.clear(); readyByPts.clear()
            gauge.reset()
            val sink = CodecSink(codec)
            val releaser = SlotReleaser(sink, counters)
            releaser.trace = trace
            if (codecReportsShown) {
                codec.setOnFrameRenderedListener { pts, nanoTime -> // on the main looper (adapter)
                    val period = vsync.periodNs
                    val fi = FrameInterval.resolve(frameIntervalNs, period, arrival.intervalNs)
                    val cadence = Math.round(fi.toDouble() / period).coerceAtLeast(1) * period
                    stats.onShownPaced(readyByPts.get(pts), nanoTime, period, cadence)
                }
            }
            // Outputs are drained on their own thread with a blocking dequeue, so a decoded frame is handled the
            // moment it is ready instead of after the input side's 4 ms poll/dequeue waits (T-052).
            val c = codec
            val hint = perfHint
            val t = Thread({
                val outInfo = DecoderCodec.OutputInfo()
                var loggedFormat = false
                val outTid = env.myTid()
                hint?.register(PerfHint.ROLE_OUT, outTid)
                lastOutputNs = System.nanoTime()
                try {
                    while (att.active && outRunning.get()) {
                        val now = System.nanoTime()
                        val untilDeadline = releaser.untilDeadlineNs(now)
                        // T-141: an output (or the held buffer's deadline) ends the wait at once; the timeout only bounds
                        // how fast a stop is seen, so it grows while no output comes.
                        val maxWaitUs = IdleWait.waitNs(now - lastOutputNs, OUTPUT_WAIT_US * 1000) / 1000
                        val waitUs = if (untilDeadline == null) maxWaitUs
                        else (untilDeadline / 1000).coerceIn(0, maxWaitUs)
                        val changed = drainOutput(c, outInfo, pacer, adaptivePacer, cpd, sink, releaser, att.gen, waitUs)
                        releaser.flushDue(System.nanoTime())
                        if (changed && !loggedFormat) {
                            loggedFormat = true
                            logOutputFormat(c)
                        }
                    }
                } catch (e: Exception) {
                    if (outRunning.get()) outError.set(e.javaClass.simpleName)
                } finally {
                    hint?.unregister(PerfHint.ROLE_OUT, outTid)
                }
            }, "mb-decoder-out")
            outThread = t
            t.start()
            // T-077: a free input buffer is taken while waiting for the frame, and the queue hands frames over with
            // park/unpark, so an arriving frame costs only the copy and queueInputBuffer.
            val inSlot = InputBufferSlot { timeoutUs -> c.dequeueInputBuffer(timeoutUs) }
            var takenNs = 0L
            var lastFrameNs = System.nanoTime()
            while (att.active && outError.get() == null) {
                inSlot.prefetch()
                // T-141: an offer unparks the wait at once; the timeout only bounds how fast a stop is seen.
                val fromQueue = if (held == null) queue.awaitNext(IdleWait.waitNs(System.nanoTime() - lastFrameNs, INPUT_WAIT_NS)) else null
                if (fromQueue != null) lastFrameNs = System.nanoTime()
                if (fromQueue != null && trace != null) takenNs = lastFrameNs
                val frame = held ?: fromQueue
                held = null
                if (frame == null) continue
                if (!frame.isCodecConfig && !gauge.canQueue(maxInFlight, System.nanoTime())) {
                    // Decoder occupancy limit (experiment): keep the frame, try again shortly.
                    if (held == null) gauge.onHeld()
                    held = frame
                    java.util.concurrent.locks.LockSupport.parkNanos(1_000_000L)
                    continue
                }
                val idx = inSlot.take(4_000)
                if (idx < 0) { held = frame; continue }
                val inbufNs = if (trace != null) System.nanoTime() else 0L
                val buf = codec.getInputBuffer(idx)!!
                if (buf.capacity() < frame.data.size) {
                    env.log('E', tag, "${env.elapsedRealtimeMs()} E decoder ev=frame_too_large size=${frame.data.size} cap=${buf.capacity()}")
                    codec.queueInputBuffer(idx, 0, 0, 0, 0) // hand the empty buffer back
                    stats.onDropped(1)
                    onKeyframeRequest(queue.onDecoderError())
                    continue
                }
                buf.clear()
                buf.put(frame.data.value)
                val copiedNs = if (trace != null) System.nanoTime() else 0L
                val flags = if (frame.isCodecConfig) DecoderCodec.BUFFER_FLAG_CODEC_CONFIG else 0
                stats.onInput(frame.frameSeq, nowUs(), if (frame.isCodecConfig) null else frame.captureTimeUs)
                if (!frame.isCodecConfig) { captureByPts.put(frame.frameSeq, frame.captureTimeUs); arrival.onFrame(frame.captureTimeUs) }
                if (!frame.isCodecConfig) gauge.onQueued(System.nanoTime())
                codec.queueInputBuffer(idx, 0, frame.data.size, frame.frameSeq, flags)
                if (!frame.isCodecConfig) progress.onInput(att.gen, env.elapsedRealtimeMs()) // T-159 no-output rule
                if (trace != null || hint != null) {
                    val doneNs = System.nanoTime()
                    trace?.onInput(frame.frameSeq, doneNs, takenNs, inbufNs, copiedNs, inSlot.lastPrefetched)
                    if (!frame.isCodecConfig) hint?.onInput(frame.frameSeq, doneNs) // T-079: recv -> queueInputBuffer
                }
            }
            if (att.active) error = outError.get()
        } catch (e: Exception) {
            error = e.javaClass.simpleName
        } finally {
            outRunning.set(false)
            try { outThread?.join(500) } catch (_: InterruptedException) {}
            adaptive = null
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            env.log('I', tag, "${env.elapsedRealtimeMs()} I decoder ev=codec_stop")
        }
        return error
    }

    private var formatChanged = false
    /** Output thread: time of the latest dequeued output (T-141 idle wait). */
    private var lastOutputNs = 0L

    /** Output-buffer release with bookkeeping (stats, decoder occupancy). Output thread only. */
    private inner class CodecSink(private val codec: DecoderCodec) : SlotReleaser.Sink {
        override fun release(idx: Int, renderNs: Long) {
            codec.releaseOutputBuffer(idx, renderNs)
            stats.onRendered(); gauge.onDone(System.nanoTime())
        }
        override fun discard(idx: Int) {
            codec.releaseOutputBuffer(idx, false)
            stats.onDropped(1); gauge.onDone(System.nanoTime())
        }
        fun releaseNow(idx: Int) {
            codec.releaseOutputBuffer(idx, true)
            stats.onRendered(); gauge.onDone(System.nanoTime())
        }
    }

    /** How long an output may be held for a possible same-slot successor: the compositor needs it this long before the slot. */
    private fun dispatchLeadNs(): Long {
        val g = vsync.grid()
        return if (g.deadlineNs > 0) g.deadlineNs + DISPATCH_MARGIN_NS else g.periodNs
    }

    /**
     * Takes every ready output. [BUFFER_ADAPTIVE] uses [AdaptivePacer] (capture-time based playout delay), or
     * [ConstantPlayoutPacer] when [cpdConfig] is set (T-080);
     * with [bufferFrames] == 0 only the newest is rendered at once and the skipped ones count as dropped
     * (T-015 behavior). Otherwise each frame gets a vsync slot and render timestamp from its pacer and goes to
     * [releaser]: at most one release per slot, at most one replaceable buffer held back across drains until its
     * dispatch deadline (T-057). Returns true once an output-format change has been seen (one-time logging).
     */
    private fun drainOutput(
        codec: DecoderCodec, info: DecoderCodec.OutputInfo, pacer: FramePacer, adaptivePacer: AdaptivePacer,
        cpd: ConstantPlayoutPacer?, sink: CodecSink, releaser: SlotReleaser, gen: Int, firstWaitUs: Long = 0,
    ): Boolean {
        var waitUs = firstWaitUs // only the first dequeue blocks; the rest of a burst is taken without waiting
        val mode = bufferFrames
        pacer.bufferFrames = mode
        val useAdaptive = mode == BUFFER_ADAPTIVE
        val paced = useAdaptive || mode > 0
        stats.setGapThresholdUs(vsync.periodNs * 3 / 2 / 1000)
        var prev = -1
        formatChanged = false
        while (true) {
            val idx = codec.dequeueOutputBuffer(info, waitUs)
            if (idx == DecoderCodec.INFO_OUTPUT_FORMAT_CHANGED) { formatChanged = true; continue }
            if (idx < 0) break
            waitUs = 0
            lastOutputNs = System.nanoTime()
            val isFrame = info.flags and DecoderCodec.BUFFER_FLAG_CODEC_CONFIG == 0
            val readyNs = System.nanoTime()
            if (isFrame) {
                // T-159: health is timed on decoder output, not on onFrameRendered (panels may throttle presentation).
                if (progress.onOutput(gen)) onHealthEvent(HealthEvent.FirstOutput(gen))
                stats.onOutput(info.presentationTimeUs, nowUs())
                readyByPts.put(info.presentationTimeUs, readyNs)
            }
            if (paced) {
                if (!isFrame) { codec.releaseOutputBuffer(idx, false); continue }
                val captureUs = captureByPts.get(info.presentationTimeUs)
                val trace = releaser.trace
                val probe = adaptivePacer.probe
                probe?.clear()
                // T-141: the first output after an idle sleep is released at once (null), independent of the clock.
                val d = firstOutput.schedule {
                    if (!useAdaptive) pacer.schedule(readyNs)
                    else if (cpd != null) cpd.schedule(captureUs, readyNs)
                    else adaptivePacer.schedule(captureUs, readyNs)
                }
                if (d == null) {
                    trace?.record(info.presentationTimeUs, captureUs ?: 0, readyNs, null, 0, false, false, 0, PaceTrace.ACTION_NOW)
                    releaser.flushAll()
                    sink.releaseNow(idx)
                    continue
                }
                stats.onPaceAdd(d.addedNs / 1000)
                if (useAdaptive) stats.onScheduled(d.skipped)
                if (d.lateDrop) counters.onLateDrop(if (d.ownSlotNs != 0L) (d.ownSlotNs - readyNs) / 1000 else null)
                val tag = trace?.record(info.presentationTimeUs, captureUs ?: 0, readyNs, probe, d.slotNs, d.lateDrop, d.collided, d.ownSlotNs) ?: -1L
                releaser.submit(idx, d.slotNs, d.renderNs, d.slotNs - dispatchLeadNs(), readyNs, vsync.periodNs, tag)
                continue
            }
            if (isFrame) firstOutput.take() // unpaced: released at once anyway; the bypass must not linger
            if (prev >= 0) sink.discard(prev)
            prev = idx
        }
        if (prev >= 0) sink.releaseNow(prev)
        return formatChanged
    }

    private fun logOutputFormat(codec: DecoderCodec) {
        val f = codec.outputFormat
        fun key(k: String) = if (f.containsKey(k)) f.getInteger(k).toString() else "unset"
        env.log('I', tag, "${env.elapsedRealtimeMs()} I decoder ev=output_format " +
            "range=${key(MediaFormat.KEY_COLOR_RANGE)} standard=${key(MediaFormat.KEY_COLOR_STANDARD)} " +
            "transfer=${key(MediaFormat.KEY_COLOR_TRANSFER)} " +
            "size=${key(MediaFormat.KEY_WIDTH)}x${key(MediaFormat.KEY_HEIGHT)} " +
            "crop=${key("crop-left")},${key("crop-top")},${key("crop-right")},${key("crop-bottom")}")
    }

    private fun nowUs() = env.elapsedRealtimeNanos() / 1000
}
