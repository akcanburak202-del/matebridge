package dev.matebridge.client.video

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.VideoFrame

/** Anything that produces VIDEO_FRAMEs pushes them here (session in T-015, file player in debug). */
fun interface VideoFrameSink {
    fun onFrame(frame: VideoFrame)
}

/**
 * MediaCodec decoder bound to a Surface. One decoder thread per attached surface; all MediaCodec
 * calls happen on it. Frames go through [FrameQueue] (bounded, newest wins, keyframe gated).
 *
 * Lifecycle: [attachSurface] when the SurfaceView surface exists, [detachSurface] when it is
 * destroyed or the activity stops. Re-attaching resets the queue and asks for a keyframe.
 * [onKeyframeRequest] is called from arbitrary threads with a KeyframeRequest.* reason.
 */
class VideoRenderer(
    private val config: StreamConfig,
    private val onKeyframeRequest: (Int) -> Unit,
) : VideoFrameSink {
    private val tag = "MB/decoder"
    val stats = VideoStats()
    private val queue = FrameQueue(stats)

    @Volatile private var thread: Thread? = null
    @Volatile private var running = false

    /** Set once the codec has been configured; for on-screen diagnostics. */
    @Volatile var codecInfo: String = "-"
        private set

    override fun onFrame(frame: VideoFrame) {
        queue.offer(frame)?.let(onKeyframeRequest)
    }

    fun attachSurface(surface: Surface) {
        detachSurface()
        onKeyframeRequest(queue.reset())
        running = true
        thread = Thread({ decodeLoop(surface) }, "mb-decoder").also { it.start() }
    }

    fun detachSurface() {
        val t = thread ?: return
        running = false
        t.join(2000)
        thread = null
    }

    private fun mime() = if (config.codec == StreamConfig.CODEC_H264) MediaFormat.MIMETYPE_VIDEO_AVC
    else MediaFormat.MIMETYPE_VIDEO_HEVC

    private fun createCodec(surface: Surface): MediaCodec {
        val mime = mime()
        val format = MediaFormat.createVideoFormat(mime, config.widthPx, config.heightPx)
        format.setInteger(MediaFormat.KEY_PRIORITY, 0) // real-time
        if (config.fps > 0) format.setInteger(MediaFormat.KEY_FRAME_RATE, config.fps)
        ColorMapping.standard(config.matrix)?.let { format.setInteger(MediaFormat.KEY_COLOR_STANDARD, it) }
        ColorMapping.transfer(config.transfer)?.let { format.setInteger(MediaFormat.KEY_COLOR_TRANSFER, it) }
        format.setInteger(MediaFormat.KEY_COLOR_RANGE, ColorMapping.range(config.fullRange))

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
        codec.configure(format, surface, null, 0)
        codec.start()
        codecInfo = "${codec.name} ${config.widthPx}x${config.heightPx} lowLatency=$lowLatency"
        Log.i(tag, "${SystemClock.elapsedRealtime()} I decoder ev=codec_start name=${codec.name} mime=$mime " +
            "size=${config.widthPx}x${config.heightPx} low_latency=$lowLatency")
        return codec
    }

    private fun decodeLoop(surface: Surface) {
        var codec: MediaCodec? = null
        var held: VideoFrame? = null
        val info = MediaCodec.BufferInfo()
        try {
            codec = createCodec(surface)
            while (running) {
                drainOutput(codec, info)
                val frame = held ?: queue.poll(4)
                held = null
                if (frame == null) continue
                val idx = codec.dequeueInputBuffer(4_000)
                if (idx < 0) { held = frame; continue }
                val buf = codec.getInputBuffer(idx)!!
                buf.clear()
                buf.put(frame.data.value)
                val flags = if (frame.isCodecConfig) MediaCodec.BUFFER_FLAG_CODEC_CONFIG else 0
                stats.onInput(frame.frameSeq, nowUs())
                codec.queueInputBuffer(idx, 0, frame.data.size, frame.frameSeq, flags)
            }
        } catch (e: Exception) {
            Log.e(tag, "${SystemClock.elapsedRealtime()} E decoder ev=decode_error err=${e.javaClass.simpleName}")
            if (running) {
                running = false
                onKeyframeRequest(queue.onDecoderError())
            }
        } finally {
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            Log.i(tag, "${SystemClock.elapsedRealtime()} I decoder ev=codec_stop")
        }
    }

    /** Releases every ready output; only the newest one is rendered (older are skipped). */
    private fun drainOutput(codec: MediaCodec, info: MediaCodec.BufferInfo) {
        var prev = -1
        while (true) {
            val idx = codec.dequeueOutputBuffer(info, 0)
            if (idx < 0) break // includes INFO_* codes; nothing to do for them
            if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                stats.onOutput(info.presentationTimeUs, nowUs())
            }
            if (prev >= 0) codec.releaseOutputBuffer(prev, false)
            prev = idx
        }
        if (prev >= 0) {
            codec.releaseOutputBuffer(prev, true)
            stats.onRendered()
        }
    }

    private fun nowUs() = SystemClock.elapsedRealtimeNanos() / 1000
}
