package dev.matebridge.client.video

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import dev.matebridge.client.protocol.KeyframeRequest
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.VideoFrame

/** Anything that produces VIDEO_FRAMEs pushes them here (session in T-015, file player in debug). */
fun interface VideoFrameSink {
    fun onFrame(frame: VideoFrame)
}

/**
 * MediaCodec decoder bound to a Surface. One decoder thread per attachment; all MediaCodec calls
 * happen on it. Frames go through [FrameQueue] (bounded, newest wins, keyframe gated).
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
) : VideoFrameSink {
    companion object {
        const val JOIN_MS = 300L
        const val BUFFER_ADAPTIVE = -1
        private const val PTS_MAP_MAX = 64
        /** Blocking wait of the output thread per dequeue; bounds shutdown latency only. */
        private const val OUTPUT_WAIT_US = 5_000L
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

    /** KEY_OPERATING_RATE policy, see [OperatingRate]; read at each codec start. */
    @Volatile var operatingRate: Int = OperatingRate.STREAM_FPS

    // frameSeq (codec pts) -> host capture time (us) / time the decoded frame became ready (ns, System.nanoTime).
    private val captureByPts = BoundedMap()
    private val readyByPts = BoundedMap()

    private class BoundedMap {
        private val m = object : LinkedHashMap<Long, Long>() {
            override fun removeEldestEntry(e: MutableMap.MutableEntry<Long, Long>) = size > PTS_MAP_MAX
        }
        @Synchronized fun put(k: Long, v: Long) { m[k] = v }
        @Synchronized fun get(k: Long): Long? = m[k]
        @Synchronized fun clear() = m.clear()
    }

    /** Stats-window feedback for the adaptive pacer (skip percentage of the window just ended). */
    /** Slack D of the adaptive pacer for the latest frame, in microseconds (0 when not adaptive/unknown). */
    fun paceDUs(): Long = (adaptive?.lastDNs ?: 0L) / 1000

    fun onSkipWindow(skipPct: Double?) { adaptive?.onSkipWindow(skipPct) }
    private val queue = FrameQueue(stats)

    private class Attachment(val surface: Surface, val previous: Thread?) {
        @Volatile var active = true
        lateinit var thread: Thread
    }

    private var current: Attachment? = null // UI thread only
    private var lingering: Thread? = null // last retired decoder thread; the next one waits for it (UI thread only)

    /** Codec description for on-screen diagnostics. */
    @Volatile var codecInfo: String = "-"
        private set

    /** True while a surface is attached. The session must not feed frames while false. */
    @Volatile var attached = false
        private set

    fun isWaitingKeyframe() = queue.isWaitingKeyframe()

    override fun onFrame(frame: VideoFrame) {
        queue.offer(frame)?.let(onKeyframeRequest)
    }

    fun attachSurface(surface: Surface) {
        retire(wait = false)
        attached = true
        onKeyframeRequest(queue.reset())
        start(surface)
    }

    fun detachSurface() {
        attached = false
        retire(wait = true)
    }

    /**
     * New STREAM_CONFIG: drops queued frames and stored parameter sets. If a surface is attached the
     * codec is restarted on it without blocking the caller (the new thread waits for the old one).
     */
    fun reconfigure(newConfig: StreamConfig) {
        config = newConfig
        val surface = current?.surface
        retire(wait = false)
        val reason = queue.reset(KeyframeRequest.STARTUP, keepConfig = false)
        if (surface != null) {
            onKeyframeRequest(reason)
            start(surface)
        }
    }

    private fun start(surface: Surface) {
        val att = Attachment(surface, lingering)
        att.thread = Thread({ decodeLoop(att) }, "mb-decoder")
        current = att
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
            if (att.thread.isAlive) Log.w(tag, "${SystemClock.elapsedRealtime()} W decoder ev=detach_slow")
        }
    }

    private fun mime(config: StreamConfig) = if (config.codec == StreamConfig.CODEC_H264) MediaFormat.MIMETYPE_VIDEO_AVC
    else MediaFormat.MIMETYPE_VIDEO_HEVC

    private fun createCodec(surface: Surface): MediaCodec {
        val config = this.config
        val mime = mime(config)
        val format = MediaFormat.createVideoFormat(mime, config.widthPx, config.heightPx)
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
            Log.w(tag, "${SystemClock.elapsedRealtime()} W decoder ev=color_unsupported primaries=${config.colorPrimaries}")
        }

        val codec = MediaCodec.createDecoderByType(mime)
        var lowLatency = "n/a"
        if (Build.VERSION.SDK_INT >= 30) {
            val supported = try {
                codec.codecInfo.getCapabilitiesForType(mime)
                    .isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)
            } catch (e: Exception) { false }
            if (supported) format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            lowLatency = if (supported) "on" else "unsupported"
        }
        try {
            codec.configure(format, surface, null, 0)
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
        Log.i(tag, "${SystemClock.elapsedRealtime()} I decoder ev=codec_start name=${codec.name} mime=$mime " +
            "size=${config.widthPx}x${config.heightPx} low_latency=$lowLatency requested_rate=${rate ?: "none"} accepted $accepted")
        return codec
    }

    private fun decodeLoop(att: Attachment) {
        try { att.previous?.join() } catch (_: InterruptedException) { return }
        val policy = RestartPolicy()
        while (att.active) {
            val failure = runCodec(att)
            if (!att.active) break
            Log.e(tag, "${SystemClock.elapsedRealtime()} E decoder ev=decode_error err=$failure")
            if (!policy.allow(SystemClock.elapsedRealtime())) {
                Log.e(tag, "${SystemClock.elapsedRealtime()} E decoder ev=give_up")
                att.active = false
                onGiveUp("decoder failed repeatedly: $failure")
                break
            }
            onKeyframeRequest(queue.reset(KeyframeRequest.DECODE_ERROR))
        }
    }

    /** Runs one codec instance until detach or error. Returns the error name, or null on detach. */
    private fun runCodec(att: Attachment): String? {
        var codec: MediaCodec? = null
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
            adaptive = adaptivePacer
            captureByPts.clear(); readyByPts.clear()
            if (codecReportsShown) {
                codec.setOnFrameRenderedListener(
                    { _, pts, nanoTime ->
                        val period = vsync.periodNs
                        val fi = if (frameIntervalNs > 0) frameIntervalNs else period
                        val cadence = Math.round(fi.toDouble() / period).coerceAtLeast(1) * period
                        stats.onShownPaced(readyByPts.get(pts), nanoTime, period, cadence)
                    },
                    android.os.Handler(android.os.Looper.getMainLooper()),
                )
            }
            // Outputs are drained on their own thread with a blocking dequeue, so a decoded frame is handled the
            // moment it is ready instead of after the input side's 4 ms poll/dequeue waits (T-052).
            val c = codec
            val t = Thread({
                val outInfo = MediaCodec.BufferInfo()
                var loggedFormat = false
                try {
                    while (att.active && outRunning.get()) {
                        if (drainOutput(c, outInfo, pacer, adaptivePacer, OUTPUT_WAIT_US) && !loggedFormat) {
                            loggedFormat = true
                            logOutputFormat(c)
                        }
                    }
                } catch (e: Exception) {
                    if (outRunning.get()) outError.set(e.javaClass.simpleName)
                }
            }, "mb-decoder-out")
            outThread = t
            t.start()
            while (att.active && outError.get() == null) {
                val frame = held ?: queue.poll(4)
                held = null
                if (frame == null) continue
                val idx = codec.dequeueInputBuffer(4_000)
                if (idx < 0) { held = frame; continue }
                val buf = codec.getInputBuffer(idx)!!
                if (buf.capacity() < frame.data.size) {
                    Log.e(tag, "${SystemClock.elapsedRealtime()} E decoder ev=frame_too_large size=${frame.data.size} cap=${buf.capacity()}")
                    codec.queueInputBuffer(idx, 0, 0, 0, 0) // hand the empty buffer back
                    stats.onDropped(1)
                    onKeyframeRequest(queue.onDecoderError())
                    continue
                }
                buf.clear()
                buf.put(frame.data.value)
                val flags = if (frame.isCodecConfig) MediaCodec.BUFFER_FLAG_CODEC_CONFIG else 0
                stats.onInput(frame.frameSeq, nowUs(), if (frame.isCodecConfig) null else frame.captureTimeUs)
                if (!frame.isCodecConfig) captureByPts.put(frame.frameSeq, frame.captureTimeUs)
                codec.queueInputBuffer(idx, 0, frame.data.size, frame.frameSeq, flags)
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
            Log.i(tag, "${SystemClock.elapsedRealtime()} I decoder ev=codec_stop")
        }
        return error
    }

    private var formatChanged = false

    /**
     * Releases every ready output. [BUFFER_ADAPTIVE] uses [AdaptivePacer] (capture-time based playout delay);
     * with [bufferFrames] == 0 only the newest is rendered at once and the
     * skipped ones count as dropped (T-015 behavior). Otherwise each frame gets a vsync-aligned render
     * timestamp from [pacer]; a frame that would exceed the bounded backlog shares the previous slot, so
     * the older one is not rendered when both are ready in the same drain (counted as dropped, not rendered).
     * Returns true once an output-format change has been seen (for one-time logging).
     */
    private fun drainOutput(
        codec: MediaCodec, info: MediaCodec.BufferInfo, pacer: FramePacer, adaptivePacer: AdaptivePacer,
        firstWaitUs: Long = 0,
    ): Boolean {
        var waitUs = firstWaitUs // only the first dequeue blocks; the rest of a burst is taken without waiting
        val mode = bufferFrames
        pacer.bufferFrames = mode
        val useAdaptive = mode == BUFFER_ADAPTIVE
        val paced = useAdaptive || mode > 0
        stats.setGapThresholdUs(vsync.periodNs * 3 / 2 / 1000)
        var prev = -1
        var pendingIdx = -1 // paced: newest buffer not yet released (waits for a possible same-slot successor)
        var pendingNs = 0L
        formatChanged = false
        while (true) {
            val idx = codec.dequeueOutputBuffer(info, waitUs)
            if (idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) { formatChanged = true; continue }
            if (idx < 0) break
            waitUs = 0
            val isFrame = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0
            val readyNs = System.nanoTime()
            if (isFrame) {
                stats.onOutput(info.presentationTimeUs, nowUs())
                readyByPts.put(info.presentationTimeUs, readyNs)
            }
            if (paced) {
                if (!isFrame) { codec.releaseOutputBuffer(idx, false); continue }
                val d = if (useAdaptive) adaptivePacer.schedule(captureByPts.get(info.presentationTimeUs), readyNs)
                else pacer.schedule(readyNs)
                if (d == null) {
                    if (pendingIdx >= 0) { codec.releaseOutputBuffer(pendingIdx, pendingNs); stats.onRendered(); pendingIdx = -1 }
                    codec.releaseOutputBuffer(idx, true)
                    stats.onRendered()
                    continue
                }
                stats.onPaceAdd(d.addedNs / 1000)
                if (useAdaptive) stats.onScheduled(d.skipped)
                if (pendingIdx >= 0) {
                    if (d.collided) {
                        // Same slot as the waiting older buffer: it would be superseded, so do not render it.
                        codec.releaseOutputBuffer(pendingIdx, false)
                        stats.onDropped(1)
                    } else {
                        codec.releaseOutputBuffer(pendingIdx, pendingNs)
                        stats.onRendered()
                    }
                } else if (d.collided) {
                    stats.onDropped(1) // supersedes a frame released in an earlier drain
                }
                pendingIdx = idx
                pendingNs = d.renderNs
                continue
            }
            if (prev >= 0) {
                codec.releaseOutputBuffer(prev, false)
                stats.onDropped(1)
            }
            prev = idx
        }
        if (pendingIdx >= 0) {
            codec.releaseOutputBuffer(pendingIdx, pendingNs)
            stats.onRendered()
        }
        if (prev >= 0) {
            codec.releaseOutputBuffer(prev, true)
            stats.onRendered()
        }
        return formatChanged
    }

    private fun logOutputFormat(codec: MediaCodec) {
        val f = codec.outputFormat
        fun key(k: String) = if (f.containsKey(k)) f.getInteger(k).toString() else "unset"
        Log.i(tag, "${SystemClock.elapsedRealtime()} I decoder ev=output_format " +
            "range=${key(MediaFormat.KEY_COLOR_RANGE)} standard=${key(MediaFormat.KEY_COLOR_STANDARD)} " +
            "transfer=${key(MediaFormat.KEY_COLOR_TRANSFER)} " +
            "size=${key(MediaFormat.KEY_WIDTH)}x${key(MediaFormat.KEY_HEIGHT)} " +
            "crop=${key("crop-left")},${key("crop-top")},${key("crop-right")},${key("crop-bottom")}")
    }

    private fun nowUs() = SystemClock.elapsedRealtimeNanos() / 1000
}
