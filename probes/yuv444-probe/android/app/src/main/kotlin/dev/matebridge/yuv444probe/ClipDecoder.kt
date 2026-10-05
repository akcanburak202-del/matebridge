package dev.matebridge.yuv444probe

import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import java.nio.ByteBuffer
import java.util.ArrayDeque
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.LockSupport

/** A loaded clip: the file bytes, its access units and its csd-0. */
class LoadedClip(val name: ClipName, val data: ByteArray) {
    val units: List<AnnexB.Unit> = AnnexB.accessUnits(data)
    val csd: ByteArray? = AnnexB.codecConfig(data)
    val maxUnit: Int = units.maxOfOrNull { it.length } ?: 0
}

/** Where a decoder's output goes. */
enum class Output {
    /** Straight to a Surface (today's SurfaceView path). */
    SURFACE,
    /** ImageReader PRIVATE + GPU_SAMPLED_IMAGE (what the GL merge consumes). */
    IMAGE_PRIVATE,
    /** ImageReader YUV_420_888, CPU readable and GPU sampled (the t2 reference). */
    IMAGE_YUV,
    /** No surface; buffers released unrendered. */
    BUFFER,
}

/**
 * One MediaCodec HEVC decoder in asynchronous mode on its own HandlerThread. Input is fed by [trySubmit] (one access
 * unit per call, looping the clip from its IDR; a unit is never skipped, so reference chains stay intact). The
 * presentation timestamp is `seq * step`, so a frame's sequence number is recoverable from the output buffer and from
 * `Image.getTimestamp()`.
 */
class ClipDecoder(
    private val tag: String,
    private val clip: LoadedClip,
    private val codecName: String,
    private val output: Output,
    private val surface: Surface?,
    private val fps: Int,
    private val maxImages: Int,
    /** Called on the decoder thread for each output buffer (sequence number, `System.nanoTime()`). */
    private val onOutput: (Long, Long) -> Unit,
    /** Image outputs: called on the decoder thread; the receiver owns and must close the Image. */
    private val onImage: ((Image, Long) -> Unit)?,
    private val log: (String) -> Unit,
) {
    private val thread = HandlerThread("y444-$tag").also { it.start() }
    private val handler = Handler(thread.looper)
    private var codec: MediaCodec? = null
    private var reader: ImageReader? = null
    private val free = ArrayDeque<Int>()
    private var nextUnit = 0
    private var loggedFormat = false

    /** Access units submitted so far (written by the feeder thread only). */
    @Volatile var seq = 0L
        private set
    @Volatile var error: String? = null
        private set

    val stepUs: Long = 1_000_000L / fps
    val width: Int get() = clip.name.width
    val height: Int get() = clip.name.height

    private fun <T> onThread(block: () -> T): T {
        var result: Result<T>? = null
        val done = CountDownLatch(1)
        handler.post {
            result = runCatching(block)
            done.countDown()
        }
        if (!done.await(5, TimeUnit.SECONDS)) throw IllegalStateException("decoder $tag thread timeout")
        return result!!.getOrThrow()
    }

    /** Creates, configures and starts the codec; null on success or the failure text. */
    fun start(): String? = onThread {
        try {
            val fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, clip.name.width, clip.name.height)
            fmt.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, clip.maxUnit + 4096)
            fmt.setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            clip.csd?.let { fmt.setByteBuffer("csd-0", ByteBuffer.wrap(it)) }
            val c = MediaCodec.createByCodecName(codecName)
            codec = c
            c.setCallback(callback, handler)
            val target: Surface? = when (output) {
                Output.SURFACE -> surface
                Output.BUFFER -> null
                Output.IMAGE_PRIVATE, Output.IMAGE_YUV -> {
                    val (format, usage) = if (output == Output.IMAGE_PRIVATE) {
                        ImageFormat.PRIVATE to HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE
                    } else {
                        ImageFormat.YUV_420_888 to (HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_CPU_READ_OFTEN)
                    }
                    val r = ImageReader.newInstance(clip.name.width, clip.name.height, format, maxImages, usage)
                    r.setOnImageAvailableListener({ onImageAvailable(it) }, handler)
                    reader = r
                    r.surface
                }
            }
            c.configure(fmt, target, null, 0)
            c.start()
            null
        } catch (e: MediaCodec.CodecException) {
            "start:${e.errorCode}:${e.diagnosticInfo}"
        } catch (t: Throwable) {
            "start:${t.javaClass.simpleName}:${t.message}"
        }
    }

    /** Queues the next access unit if an input buffer is free; false when none is (nothing is consumed). */
    fun trySubmit(): Boolean {
        val c = codec ?: return false
        val idx = synchronized(free) { if (free.isEmpty()) -1 else free.removeFirst() }
        if (idx < 0) return false
        return try {
            val u = clip.units[nextUnit]
            val buf = c.getInputBuffer(idx) ?: return false
            buf.clear()
            buf.put(clip.data, u.offset, u.length)
            c.queueInputBuffer(idx, 0, u.length, seq * stepUs, 0)
            seq++
            nextUnit = (nextUnit + 1) % clip.units.size
            true
        } catch (_: IllegalStateException) {
            false
        }
    }

    fun stop() {
        try { codec?.stop() } catch (_: Throwable) {}
        try { codec?.release() } catch (_: Throwable) {}
        try { reader?.close() } catch (_: Throwable) {}
        thread.quitSafely()
        thread.join(1000)
    }

    private fun onImageAvailable(r: ImageReader) {
        val arrival = System.nanoTime()
        try {
            val img = r.acquireNextImage() ?: return
            val sink = onImage
            if (sink != null) sink(img, arrival) else img.close()
        } catch (e: IllegalStateException) {
            if (error == null) error = "image:${e.message}"
        }
    }

    private val callback = object : MediaCodec.Callback() {
        override fun onInputBufferAvailable(c: MediaCodec, idx: Int) {
            synchronized(free) { free.add(idx) }
        }

        override fun onOutputBufferAvailable(c: MediaCodec, idx: Int, info: MediaCodec.BufferInfo) {
            try {
                val now = System.nanoTime()
                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                    onOutput(info.presentationTimeUs / stepUs, now)
                }
                c.releaseOutputBuffer(idx, output != Output.BUFFER)
            } catch (_: IllegalStateException) {
            }
        }

        override fun onError(c: MediaCodec, e: MediaCodec.CodecException) {
            if (error == null) error = "codec:${e.errorCode}:${e.diagnosticInfo}"
        }

        override fun onOutputFormatChanged(c: MediaCodec, format: MediaFormat) {
            if (!loggedFormat) {
                loggedFormat = true
                log("Y444PROBE info out_format $tag $output $format")
            }
        }
    }
}

/**
 * Paces the decoders at [fps]: tick i is due at `t0 + i * period`; each decoder gets the access units it owes (normally
 * one). A tick that still owes a unit after the loop (no free input buffer) counts as missed; the unit goes in on a
 * later tick, never dropped.
 */
class Feeder(
    private val fps: Int,
    private val decoders: List<ClipDecoder>,
    val t0Ns: Long,
    private val maxTicks: Int,
) : Thread("y444-feeder") {
    @Volatile private var stopFlag = false
    val missed = IntArray(decoders.size)
    @Volatile var ticks = 0
        private set
    val periodNs: Long = 1_000_000_000L / fps

    fun halt() {
        stopFlag = true
    }

    override fun run() {
        var i = 0
        while (!stopFlag && i < maxTicks) {
            val due = t0Ns + i * periodNs
            while (!stopFlag) {
                val left = due - System.nanoTime()
                if (left <= 0) break
                LockSupport.parkNanos(left)
            }
            for ((d, dec) in decoders.withIndex()) {
                while (dec.seq <= i && dec.trySubmit()) { /* catch up on owed units */ }
                if (dec.seq <= i) missed[d]++
            }
            i++
            ticks = i
        }
    }
}
