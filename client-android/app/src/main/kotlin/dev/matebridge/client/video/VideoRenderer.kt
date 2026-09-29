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
 * first waits for the previous thread to exit, so two codecs never run at once. UI-thread blocking
 * is bounded (see [JOIN_MS]).
 *
 * Decoder errors restart the codec on the same surface (queue reset, last CODEC_CONFIG replayed,
 * KEYFRAME_REQUEST(DECODE_ERROR)), at most 3 times per 10 s; after that [onGiveUp] is called.
 * [onKeyframeRequest] and [onGiveUp] are called from arbitrary threads.
 */
class VideoRenderer(
    private val config: StreamConfig,
    private val onKeyframeRequest: (Int) -> Unit,
    private val onGiveUp: (String) -> Unit = {},
) : VideoFrameSink {
    companion object {
        const val JOIN_MS = 300L
    }

    private val tag = "MB/decoder"
    val stats = VideoStats()
    private val queue = FrameQueue(stats)

    private class Attachment(val surface: Surface, val previous: Thread?) {
        @Volatile var active = true
        lateinit var thread: Thread
    }

    private var current: Attachment? = null // UI thread only

    /** Codec description for on-screen diagnostics. */
    @Volatile var codecInfo: String = "-"
        private set

    override fun onFrame(frame: VideoFrame) {
        queue.offer(frame)?.let(onKeyframeRequest)
    }

    fun attachSurface(surface: Surface) {
        val old = detachInternal()
        onKeyframeRequest(queue.reset())
        val att = Attachment(surface, old)
        att.thread = Thread({ decodeLoop(att) }, "mb-decoder")
        current = att
        att.thread.start()
    }

    fun detachSurface() {
        detachInternal()
    }

    /** Signals the current thread to stop and waits briefly. Returns the thread if still alive. */
    private fun detachInternal(): Thread? {
        val att = current ?: return null
        att.active = false
        att.thread.join(JOIN_MS)
        if (att.thread.isAlive) {
            Log.w(tag, "${SystemClock.elapsedRealtime()} W decoder ev=detach_slow")
            return att.thread // the next attachment's thread waits for it
        }
        current = null
        return null
    }

    private fun mime() = if (config.codec == StreamConfig.CODEC_H264) MediaFormat.MIMETYPE_VIDEO_AVC
    else MediaFormat.MIMETYPE_VIDEO_HEVC

    private fun createCodec(surface: Surface): MediaCodec {
        val mime = mime()
        val format = MediaFormat.createVideoFormat(mime, config.widthPx, config.heightPx)
        format.setInteger(MediaFormat.KEY_PRIORITY, 0) // real-time
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, config.widthPx * config.heightPx * 3 / 2)
        if (config.fps > 0) format.setInteger(MediaFormat.KEY_FRAME_RATE, config.fps)
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
        Log.i(tag, "${SystemClock.elapsedRealtime()} I decoder ev=codec_start name=${codec.name} mime=$mime " +
            "size=${config.widthPx}x${config.heightPx} low_latency=$lowLatency")
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
        try {
            codec = createCodec(att.surface)
            val info = MediaCodec.BufferInfo()
            var held: VideoFrame? = null
            var loggedFormat = false
            while (att.active) {
                if (drainOutput(codec, info) && !loggedFormat) {
                    loggedFormat = true
                    logOutputFormat(codec)
                }
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
                stats.onInput(frame.frameSeq, nowUs())
                codec.queueInputBuffer(idx, 0, frame.data.size, frame.frameSeq, flags)
            }
        } catch (e: Exception) {
            error = e.javaClass.simpleName
        } finally {
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            Log.i(tag, "${SystemClock.elapsedRealtime()} I decoder ev=codec_stop")
        }
        return error
    }

    private var formatChanged = false

    /**
     * Releases every ready output; only the newest is rendered, skipped ones count as dropped.
     * Returns true once an output-format change has been seen (for one-time logging).
     */
    private fun drainOutput(codec: MediaCodec, info: MediaCodec.BufferInfo): Boolean {
        var prev = -1
        formatChanged = false
        while (true) {
            val idx = codec.dequeueOutputBuffer(info, 0)
            if (idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) { formatChanged = true; continue }
            if (idx < 0) break
            if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                stats.onOutput(info.presentationTimeUs, nowUs())
            }
            if (prev >= 0) {
                codec.releaseOutputBuffer(prev, false)
                stats.onDropped(1)
            }
            prev = idx
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
            "transfer=${key(MediaFormat.KEY_COLOR_TRANSFER)}")
    }

    private fun nowUs() = SystemClock.elapsedRealtimeNanos() / 1000
}
