package dev.matebridge.client.video

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer

/**
 * T-158: the video decoder as [VideoRenderer] uses it. Exactly the `MediaCodec` calls the renderer makes, so a JVM test
 * can drive the real renderer threads with a fake; production uses [MediaCodecDecoder] (1:1 wrapper). The interface and
 * its nested types use no Android classes: the output surface is an opaque handle and the input format a
 * [DecoderFormat].
 */
interface DecoderCodec {
    /** `MediaCodec.createDecoderByType`; throws like it does. */
    fun interface Factory {
        fun create(mime: String): DecoderCodec
    }

    /** The two `MediaCodec.BufferInfo` fields the renderer reads; filled by [dequeueOutputBuffer]. */
    class OutputInfo {
        var presentationTimeUs = 0L
        var flags = 0
    }

    /** Read-only view of a codec format (`MediaFormat` getters, same exceptions). */
    interface FormatView {
        fun containsKey(key: String): Boolean
        fun getInteger(key: String): Int
        fun getFloat(key: String): Float
    }

    companion object {
        const val INFO_TRY_AGAIN_LATER = MediaCodec.INFO_TRY_AGAIN_LATER
        const val INFO_OUTPUT_FORMAT_CHANGED = MediaCodec.INFO_OUTPUT_FORMAT_CHANGED
        const val BUFFER_FLAG_CODEC_CONFIG = MediaCodec.BUFFER_FLAG_CODEC_CONFIG
    }

    /** Component name (diagnostics). */
    val name: String

    /** Whether `FEATURE_LowLatency` is supported for [mime]; null when the platform has no such feature (API < 30). */
    fun lowLatencySupport(mime: String): Boolean?

    /** `configure(format, surface, null, 0)`; [surface] is the output `Surface`, opaque here. */
    fun configure(format: DecoderFormat, surface: Any)
    fun start()
    fun dequeueInputBuffer(timeoutUs: Long): Int
    fun getInputBuffer(index: Int): ByteBuffer?
    fun queueInputBuffer(index: Int, offset: Int, size: Int, presentationTimeUs: Long, flags: Int)
    fun dequeueOutputBuffer(info: OutputInfo, timeoutUs: Long): Int
    fun releaseOutputBuffer(index: Int, renderTimestampNs: Long)
    fun releaseOutputBuffer(index: Int, render: Boolean)

    /** Called on the main thread with (presentation time us, system nano time) of each rendered frame. */
    fun setOnFrameRenderedListener(listener: (presentationTimeUs: Long, nanoTime: Long) -> Unit)
    val inputFormat: FormatView
    val outputFormat: FormatView
    fun stop()
    fun release()
}

/** Decoder input format without Android classes: mime, size and integer keys in insertion order. */
class DecoderFormat(val mime: String, val width: Int, val height: Int) {
    private val ints = LinkedHashMap<String, Int>()

    fun setInteger(key: String, value: Int) { ints[key] = value }

    /** Integer keys in the order they were set (a key set twice keeps its first position, like a map). */
    val integers: Map<String, Int> get() = ints
}

/** Production [DecoderCodec]: forwards every call to one `MediaCodec`. */
class MediaCodecDecoder private constructor(private val codec: MediaCodec) : DecoderCodec {
    companion object {
        val FACTORY = DecoderCodec.Factory { mime -> MediaCodecDecoder(MediaCodec.createDecoderByType(mime)) }
    }

    /** Output thread only (one per codec), like the renderer's former `BufferInfo`. */
    private val bufferInfo = MediaCodec.BufferInfo()

    override val name: String get() = codec.name

    override fun lowLatencySupport(mime: String): Boolean? {
        if (Build.VERSION.SDK_INT < 30) return null
        return try {
            codec.codecInfo.getCapabilitiesForType(mime)
                .isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)
        } catch (e: Exception) { false }
    }

    override fun configure(format: DecoderFormat, surface: Any) {
        val f = MediaFormat.createVideoFormat(format.mime, format.width, format.height)
        for ((k, v) in format.integers) f.setInteger(k, v)
        codec.configure(f, surface as Surface, null, 0)
    }

    override fun start() = codec.start()
    override fun dequeueInputBuffer(timeoutUs: Long) = codec.dequeueInputBuffer(timeoutUs)
    override fun getInputBuffer(index: Int): ByteBuffer? = codec.getInputBuffer(index)
    override fun queueInputBuffer(index: Int, offset: Int, size: Int, presentationTimeUs: Long, flags: Int) =
        codec.queueInputBuffer(index, offset, size, presentationTimeUs, flags)

    override fun dequeueOutputBuffer(info: DecoderCodec.OutputInfo, timeoutUs: Long): Int {
        val idx = codec.dequeueOutputBuffer(bufferInfo, timeoutUs)
        info.presentationTimeUs = bufferInfo.presentationTimeUs
        info.flags = bufferInfo.flags
        return idx
    }

    override fun releaseOutputBuffer(index: Int, renderTimestampNs: Long) = codec.releaseOutputBuffer(index, renderTimestampNs)
    override fun releaseOutputBuffer(index: Int, render: Boolean) = codec.releaseOutputBuffer(index, render)

    override fun setOnFrameRenderedListener(listener: (presentationTimeUs: Long, nanoTime: Long) -> Unit) {
        codec.setOnFrameRenderedListener(
            { _, pts, nanoTime -> listener(pts, nanoTime) },
            android.os.Handler(android.os.Looper.getMainLooper()),
        )
    }

    override val inputFormat: DecoderCodec.FormatView get() = FormatAdapter(codec.inputFormat)
    override val outputFormat: DecoderCodec.FormatView get() = FormatAdapter(codec.outputFormat)
    override fun stop() = codec.stop()
    override fun release() = codec.release()

    private class FormatAdapter(private val f: MediaFormat) : DecoderCodec.FormatView {
        override fun containsKey(key: String) = f.containsKey(key)
        override fun getInteger(key: String) = f.getInteger(key)
        override fun getFloat(key: String) = f.getFloat(key)
    }
}

/**
 * T-158: the platform calls of the decoder threads besides the codec (clock, logcat, thread id/priority), so the
 * renderer lifecycle runs on the JVM. Production: [AndroidDecoderEnv].
 */
interface DecoderEnv {
    /** `SystemClock.elapsedRealtime()`. */
    fun elapsedRealtimeMs(): Long
    /** `SystemClock.elapsedRealtimeNanos()`. */
    fun elapsedRealtimeNanos(): Long
    /** One logcat line; [level] is 'I', 'W' or 'E'. */
    fun log(level: Char, tag: String, line: String)
    /** `Process.myTid()`. */
    fun myTid(): Int
    /** `Process.setThreadPriority(THREAD_PRIORITY_DISPLAY)` for the calling thread; may throw. */
    fun setDisplayPriority()
}

object AndroidDecoderEnv : DecoderEnv {
    override fun elapsedRealtimeMs() = SystemClock.elapsedRealtime()
    override fun elapsedRealtimeNanos() = SystemClock.elapsedRealtimeNanos()
    override fun log(level: Char, tag: String, line: String) {
        when (level) {
            'E' -> Log.e(tag, line)
            'W' -> Log.w(tag, line)
            else -> Log.i(tag, line)
        }
    }
    override fun myTid() = android.os.Process.myTid()
    override fun setDisplayPriority() = android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_DISPLAY)
}
