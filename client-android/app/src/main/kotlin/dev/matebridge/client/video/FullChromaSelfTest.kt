package dev.matebridge.client.video

import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** Tightly packed copy of an `Image` plane (row and pixel strides removed). Pure Kotlin (T-254 `PlaneCopy`). */
object PlaneCopy {
    fun tight(buf: ByteBuffer, rowStride: Int, pixelStride: Int, w: Int, h: Int): ByteArray {
        val out = ByteArray(w * h)
        val src = buf.duplicate()
        for (r in 0 until h) {
            val rowStart = r * rowStride
            if (pixelStride == 1) {
                src.position(rowStart)
                src.get(out, r * w, w)
            } else {
                for (x in 0 until w) out[r * w + x] = src.get(rowStart + x * pixelStride)
            }
        }
        return out
    }
}

/** How the native raw comparison line decides (the T-254 `t2` gate). */
object RawVerdict {
    /** True/false from `exact=1|0` of a `rawCompare` line; null when the line carries no verdict (`ok=0`). */
    fun exact(line: String): Boolean? {
        if (!line.contains("ok=1")) return null
        return Regex("""\bexact=(\d)""").find(line)?.groupValues?.get(1)?.let { it == "1" }
    }
}

/**
 * The full colour capability self-test (decision 0034, T-259; T-254 `t2` logic). Runs once per APK build on a background
 * thread; the result goes to [FullChromaCapability]. It checks, on this tablet:
 *  1. `GL_EXT_YUV_target` and the EGL image import are there (the native `rawInit`);
 *  2. a decoder's output image read raw by the GPU is bit-identical to a CPU read of the same image (Y, Cb, Cr);
 *  3. a SECOND HEVC decoder can be opened next to the first (the auxiliary stream needs one).
 * The clip is one embedded intra frame ([FullChromaSelfTestClip]); the picture itself is irrelevant.
 *
 * A definitive "no" is [Outcome.Fail]; anything that stopped the test from deciding (a busy decoder, a timeout, an
 * unexpected exception) is [Outcome.Inconclusive] and is retried at the next start ([FullChromaCapability.recordInconclusive]).
 */
object FullChromaSelfTest {
    sealed interface Outcome {
        data object Pass : Outcome
        data class Fail(val reason: String) : Outcome
        data class Inconclusive(val reason: String) : Outcome
    }

    private const val DECODE_TIMEOUT_MS = 4_000L

    private val SINGLE_FLIGHT = Any()

    /**
     * Records [run]'s outcome in [capability]; returns it. Call off the UI thread. Single flight, process-wide (the native
     * raw context is global): a second caller (e.g. a recreated activity) waits, then sees the stored result and does not
     * run again.
     */
    fun runAndRecord(capability: FullChromaCapability, log: (String) -> Unit): Outcome = synchronized(SINGLE_FLIGHT) {
        val st = capability.status()
        when (st.state) {
            FullChromaCapability.State.PASSED -> return Outcome.Pass
            FullChromaCapability.State.FAILED -> return Outcome.Fail(st.reason)
            FullChromaCapability.State.UNKNOWN -> {}
        }
        runAndRecordLocked(capability, log)
    }

    private fun runAndRecordLocked(capability: FullChromaCapability, log: (String) -> Unit): Outcome {
        val outcome = try { run(log) } catch (t: Throwable) { Outcome.Inconclusive("exception_${t.javaClass.simpleName}") }
        when (outcome) {
            Outcome.Pass -> capability.recordPass()
            is Outcome.Fail -> capability.recordFail(outcome.reason)
            is Outcome.Inconclusive -> capability.recordInconclusive(outcome.reason)
        }
        return outcome
    }

    fun run(log: (String) -> Unit): Outcome {
        if (!FullChromaNative.available) return Outcome.Fail("native_library")
        val clip = AnnexBSplitter.split(FullChromaSelfTestClip.data)
        val config = clip.firstOrNull { it.isCodecConfig } ?: return Outcome.Inconclusive("clip_no_config")
        val frame = clip.firstOrNull { it.isKeyframe } ?: return Outcome.Inconclusive("clip_no_keyframe")
        val w = FullChromaSelfTestClip.WIDTH
        val h = FullChromaSelfTestClip.HEIGHT

        val rawErr = FullChromaNative.rawInit()
        if (rawErr.isNotEmpty()) {
            log("raw_init=$rawErr")
            // Only a missing extension is a definitive "no"; an EGL/context failure may be transient.
            return if (rawErr.contains("not exposed")) Outcome.Fail("raw_init_" + rawErr.take(40))
            else Outcome.Inconclusive("raw_init_" + rawErr.take(40))
        }
        var first: Decoder? = null
        var second: Decoder? = null
        // ImageReader listeners need a Looper: this runs on a plain thread, so give them their own (a null handler throws).
        val ht = HandlerThread("mb-fc-selftest-img").also { it.start() }
        val handler = Handler(ht.looper)
        try {
            first = Decoder.open(w, h, config.data.value, ImageFormat.YUV_420_888,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_CPU_READ_OFTEN, handler)
                ?: return Outcome.Inconclusive("decoder_open")
            // The second decoder is opened while the first one is alive (the auxiliary stream's situation).
            second = Decoder.open(w, h, config.data.value, ImageFormat.PRIVATE, HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE, handler)
            if (second == null) {
                log("second_decoder=open_failed")
                return Outcome.Inconclusive("second_decoder_open") // contention is indistinguishable from a limit: retried
            }
            val img = first.decodeOne(frame.data.value) ?: return Outcome.Inconclusive("no_output")
            val secondImg = second.decodeOne(frame.data.value)
            secondImg?.close()
            val line = try { compare(img, w, h) } finally { img.close() }
            log("raw_compare $line second_output=${if (secondImg != null) 1 else 0}")
            return when (RawVerdict.exact(line)) {
                true -> if (secondImg != null) Outcome.Pass else Outcome.Inconclusive("second_decoder_no_output")
                false -> Outcome.Fail("raw_samples_differ")
                null -> {
                    val err = line.substringAfter("err=", "unknown").take(40)
                    if (err.startsWith("no_")) Outcome.Inconclusive("raw_compare_$err") else Outcome.Fail("raw_compare_$err")
                }
            }
        } finally {
            first?.close()
            second?.close()
            FullChromaNative.rawShutdown()
            ht.quitSafely()
        }
    }

    private fun compare(img: Image, w: Int, h: Int): String {
        val p = img.planes
        val y = PlaneCopy.tight(p[0].buffer, p[0].rowStride, p[0].pixelStride, w, h)
        val u = PlaneCopy.tight(p[1].buffer, p[1].rowStride, p[1].pixelStride, w / 2, h / 2)
        val v = PlaneCopy.tight(p[2].buffer, p[2].rowStride, p[2].pixelStride, w / 2, h / 2)
        val hw = img.hardwareBuffer ?: return "ok=0 err=no_hardware_buffer"
        return try { FullChromaNative.rawCompare(hw, w, h, y, u, v) } finally { hw.close() }
    }

    /** One synchronous HEVC decoder into its own ImageReader. */
    private class Decoder private constructor(
        private val codec: MediaCodec,
        private val reader: ImageReader,
        private val images: LinkedBlockingQueue<Image>,
    ) {
        companion object {
            fun open(w: Int, h: Int, parameterSets: ByteArray, imageFormat: Int, usage: Long, handler: Handler): Decoder? {
                var codec: MediaCodec? = null
                var reader: ImageReader? = null
                try {
                    val images = LinkedBlockingQueue<Image>()
                    val r = ImageReader.newInstance(w, h, imageFormat, 4, usage)
                    reader = r
                    r.setOnImageAvailableListener({ rd ->
                        try { rd.acquireNextImage()?.let { images.add(it) } } catch (_: IllegalStateException) {}
                    }, handler)
                    val c = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_HEVC)
                    codec = c
                    val f = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, w, h)
                    f.setByteBuffer("csd-0", ByteBuffer.wrap(parameterSets))
                    c.configure(f, r.surface, null, 0)
                    c.start()
                    return Decoder(c, r, images)
                } catch (_: Throwable) {
                    try { codec?.release() } catch (_: Throwable) {}
                    try { reader?.close() } catch (_: Throwable) {}
                    return null
                }
            }
        }

        /** Decodes the access unit [au] (+ end of stream, to flush the output) and returns the output image, or null. */
        fun decodeOne(au: ByteArray): Image? {
            val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(DECODE_TIMEOUT_MS)
            var queued = 0 // 0 = AU, 1 = EOS, 2 = done
            val info = MediaCodec.BufferInfo()
            while (System.nanoTime() < deadline) {
                if (queued < 2) {
                    val idx = codec.dequeueInputBuffer(2_000)
                    if (idx >= 0) {
                        if (queued == 0) {
                            val b = codec.getInputBuffer(idx)!!
                            b.clear(); b.put(au)
                            codec.queueInputBuffer(idx, 0, au.size, 0, 0)
                        } else {
                            codec.queueInputBuffer(idx, 0, 0, 1_000, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        }
                        queued++
                    }
                }
                val out = codec.dequeueOutputBuffer(info, 2_000)
                if (out >= 0) {
                    val frame = info.size > 0
                    codec.releaseOutputBuffer(out, frame) // render to the reader
                    if (frame) return images.poll(1_000, TimeUnit.MILLISECONDS)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return images.poll(200, TimeUnit.MILLISECONDS)
                }
            }
            return images.poll()
        }

        fun close() {
            try { codec.stop() } catch (_: Throwable) {}
            try { codec.release() } catch (_: Throwable) {}
            while (true) (images.poll() ?: break).close()
            try { reader.close() } catch (_: Throwable) {}
        }
    }
}
