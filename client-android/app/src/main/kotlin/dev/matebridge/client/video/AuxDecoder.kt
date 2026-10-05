package dev.matebridge.client.video

import android.media.MediaFormat
import dev.matebridge.client.protocol.KeyframeRequest
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.VideoFrame
import java.util.concurrent.ConcurrentHashMap

/**
 * The auxiliary stream's decoder (decision 0034): a second `MediaCodec` (same HEVC mime and size as the main one) whose
 * output goes to the auxiliary ImageReader's surface, rendered at once (no pacing: the GL thread pairs by capture time).
 * Frames come through the bounded [AuxFrameQueue]. Its failures never reach the main stream's `video_health`: a decode
 * error rebuilds this decoder (backoff, [RestartPolicy]) and asks the host for `KEYFRAME_REQUEST(view = 1)`; past the
 * restart limit it gives up ([onGaveUp]) and the picture continues main-only.
 *
 * Threads: `mb-aux-dec` (input, all codec calls except output) and `mb-aux-out` (dequeue/release). [start] and [stop] are
 * called from the UI thread; [stop] waits (bounded) for the threads, so the codec is released before its surface goes.
 */
class AuxDecoder(
    private val config: StreamConfig,
    /** The auxiliary ImageReader's surface (opaque, like the main renderer's output). */
    private val surface: Any,
    private val queue: AuxFrameQueue,
    /** `KEYFRAME_REQUEST(reason, view = 1)`; any thread. */
    private val onKeyframeRequest: (Int) -> Unit,
    private val codecFactory: DecoderCodec.Factory = MediaCodecDecoder.FACTORY,
    private val env: DecoderEnv = AndroidDecoderEnv,
    private val onGaveUp: (String) -> Unit = {},
    private val restartDelaysMs: LongArray = RestartPolicy.DELAYS_MS,
) {
    companion object {
        private const val TAG = "MB/decoder"
        private const val JOIN_MS = 500L
        private const val OUTPUT_WAIT_US = 5_000L
        private const val INPUT_WAIT_NS = 4_000_000L
        private const val CAPTURE_MAP_MAX = 64
    }

    @Volatile private var active = false
    private var thread: Thread? = null
    private val captureBySeq = ConcurrentHashMap<Long, Long>()

    @Volatile var decoded = 0L
        private set
    @Volatile var restarts = 0L
        private set
    @Volatile var gaveUp = false
        private set

    /** `capture_time_us` of the auxiliary frame with [seq] (the ImageReader image timestamp / 1000), or null. */
    fun captureOf(seq: Long): Long? = captureBySeq[seq]

    /** A VIDEO_FRAME of the auxiliary view. Any thread. */
    fun onFrame(frame: VideoFrame) {
        if (!active) return
        queue.offer(frame)?.let(onKeyframeRequest)
    }

    fun start() {
        if (active) return
        active = true
        gaveUp = false
        onKeyframeRequest(queue.reset(KeyframeRequest.STARTUP))
        thread = Thread({ run() }, "mb-aux-dec").also { it.start() }
    }

    fun stop() {
        active = false
        queue.wake()
        val t = thread ?: return
        thread = null
        try { t.join(JOIN_MS) } catch (_: InterruptedException) {}
        if (t.isAlive) env.log('W', TAG, "${env.elapsedRealtimeMs()} W decoder ev=aux_stop_slow join_ms=$JOIN_MS")
    }

    private fun run() {
        val policy = RestartPolicy(delaysMs = restartDelaysMs)
        while (active) {
            val failure = runCodec()
            if (!active) break
            env.log('E', TAG, "${env.elapsedRealtimeMs()} E decoder ev=aux_decode_error err=$failure")
            if (!policy.allow(env.elapsedRealtimeMs())) {
                gaveUp = true
                active = false // no more ingest, no more aux keyframe requests
                env.log('E', TAG, "${env.elapsedRealtimeMs()} E decoder ev=aux_give_up")
                onGaveUp("aux decoder failed repeatedly: $failure")
                return
            }
            try { Thread.sleep(policy.delayMs()) } catch (_: InterruptedException) { return }
            restarts++
            if (active) onKeyframeRequest(queue.reset(KeyframeRequest.DECODE_ERROR))
        }
    }

    private fun format(codec: DecoderCodec): DecoderFormat {
        val mime = if (config.codec == StreamConfig.CODEC_H264) MediaFormat.MIMETYPE_VIDEO_AVC else MediaFormat.MIMETYPE_VIDEO_HEVC
        val f = DecoderFormat(mime, config.widthPx, config.heightPx)
        f.setInteger(MediaFormat.KEY_PRIORITY, 0)
        f.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, config.widthPx * config.heightPx * 3 / 2)
        if (config.fps > 0) f.setInteger(MediaFormat.KEY_FRAME_RATE, config.fps)
        if (codec.lowLatencySupport(mime) == true) f.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        // No colour keys: the planes of this view are DATA (raw samples), never converted.
        return f
    }

    /** One codec instance until stop or error; returns the error name or null on stop. */
    private fun runCodec(): String? {
        var codec: DecoderCodec? = null
        var outThread: Thread? = null
        var error: String? = null
        val outError = java.util.concurrent.atomic.AtomicReference<String?>(null)
        val running = java.util.concurrent.atomic.AtomicBoolean(true)
        try {
            val mime = if (config.codec == StreamConfig.CODEC_H264) MediaFormat.MIMETYPE_VIDEO_AVC else MediaFormat.MIMETYPE_VIDEO_HEVC
            val c = codecFactory.create(mime)
            codec = c
            c.configure(format(c), surface)
            c.start()
            env.log('I', TAG, "${env.elapsedRealtimeMs()} I decoder ev=aux_codec_start name=${c.name} size=${config.widthPx}x${config.heightPx}")
            val t = Thread({
                val info = DecoderCodec.OutputInfo()
                try {
                    while (running.get()) {
                        val idx = c.dequeueOutputBuffer(info, OUTPUT_WAIT_US)
                        if (idx < 0) continue // try again / format changed
                        val isFrame = info.flags and DecoderCodec.BUFFER_FLAG_CODEC_CONFIG == 0
                        c.releaseOutputBuffer(idx, isFrame) // render to the ImageReader at once
                        if (isFrame) decoded++
                    }
                } catch (e: Exception) {
                    if (running.get()) outError.set(e.javaClass.simpleName)
                }
            }, "mb-aux-out")
            outThread = t
            t.start()
            var held: VideoFrame? = null
            while (active && outError.get() == null) {
                val frame = held ?: queue.awaitNext(INPUT_WAIT_NS)
                held = null
                if (frame == null) continue
                val idx = c.dequeueInputBuffer(4_000)
                if (idx < 0) { held = frame; continue }
                val buf = c.getInputBuffer(idx)!!
                if (buf.capacity() < frame.data.size) {
                    c.queueInputBuffer(idx, 0, 0, 0, 0)
                    onKeyframeRequest(queue.reset(KeyframeRequest.DECODE_ERROR))
                    continue
                }
                buf.clear()
                buf.put(frame.data.value)
                if (!frame.isCodecConfig) {
                    captureBySeq[frame.frameSeq] = frame.captureTimeUs
                    if (captureBySeq.size > CAPTURE_MAP_MAX) {
                        for (k in captureBySeq.keys.sorted().take(captureBySeq.size - CAPTURE_MAP_MAX / 2)) captureBySeq.remove(k)
                    }
                }
                val flags = if (frame.isCodecConfig) DecoderCodec.BUFFER_FLAG_CODEC_CONFIG else 0
                c.queueInputBuffer(idx, 0, frame.data.size, frame.frameSeq, flags)
            }
            if (active) error = outError.get()
        } catch (e: Exception) {
            error = e.javaClass.simpleName
        } finally {
            running.set(false)
            try { outThread?.join(JOIN_MS) } catch (_: InterruptedException) {}
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            captureBySeq.clear()
            env.log('I', TAG, "${env.elapsedRealtimeMs()} I decoder ev=aux_codec_stop")
        }
        return error
    }
}
