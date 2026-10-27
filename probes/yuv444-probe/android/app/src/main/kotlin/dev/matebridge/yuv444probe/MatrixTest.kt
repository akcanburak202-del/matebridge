package dev.matebridge.yuv444probe

import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.math.abs

/**
 * T-384: why does the GL_EXT_YUV_target raw read not match on the MediaTek tablet, and does any decoder / ImageReader /
 * MediaFormat combination match? One intra frame is decoded per combination; the reference planes come from the software
 * decoder (HEVC decoding is bit exact, so any correct decoder yields the same planes). Each combination logs one
 * `Y444PROBE t5` line: CPU planes vs reference, GPU raw read vs reference, sample values, and the driver-converted
 * (samplerExternalOES) output vs the colour conversion of the reference.
 */
class MatrixTest(private val dir: File, private val args: Args, private val log: (String) -> Unit) {
    private class Planes(val w: Int, val h: Int, val y: ByteArray, val cb: ByteArray, val cr: ByteArray)

    private class Variant(val label: String, val format: Int, val usage: Long, val viaBuilder: Boolean)

    private val variants = listOf(
        Variant("yuv_gpu_cpu", ImageFormat.YUV_420_888, HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_CPU_READ_OFTEN, false),
        Variant("yuv_gpu_only", ImageFormat.YUV_420_888, HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE, false),
        Variant("private_gpu", ImageFormat.PRIVATE, HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE, false),
        Variant("hwb_ycbcr_gpu_cpu", HardwareBuffer.YCBCR_420_888, HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_CPU_READ_OFTEN, true),
        Variant("hwb_ycbcr_gpu_only", HardwareBuffer.YCBCR_420_888, HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE, true),
    )

    fun run() {
        val clipName = args.str("clip") ?: "clip256.h265"
        val f = File(dir, clipName)
        if (!f.exists()) { log("Y444PROBE t5 info missing clip ${f.path}"); return }
        val data = f.readBytes()
        val units = AnnexB.accessUnits(data)
        val csd = AnnexB.codecConfig(data)
        val w = args.int("w", 256)
        val h = args.int("h", 144)
        // The first access unit of the probe's own clips holds VPS/SPS/PPS + IDR; the self-test clip is the same shape.
        val au = data.copyOfRange(units[0].offset, units[0].offset + units[0].length)
        log("Y444PROBE t5 info clip=$clipName ${w}x$h units=${units.size} au0=${au.size} csd=${csd?.size} device=${Build.MODEL} sdk=${Build.VERSION.SDK_INT}")

        val list = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
            .filter { !it.isEncoder && it.supportedTypes.any { t -> t.equals("video/hevc", true) } }
        for (i in list) {
            val caps = i.getCapabilitiesForType("video/hevc")
            log("Y444PROBE t5 info hevc_decoder ${i.name} hw=${i.isHardwareAccelerated} sw=${i.isSoftwareOnly} vendor=${i.isVendor} " +
                "colorFormats=${caps.colorFormats.joinToString(",") { "0x" + Integer.toHexString(it) }}")
        }
        val names = (listOf("c2.mtk.hevc.decoder", "c2.mtk.hevc.decoder.lowlatency", "c2.android.hevc.decoder") +
            list.map { it.name }).distinct().filter { n -> list.any { it.name == n } || n.startsWith("c2.mtk") }
        val ht = HandlerThread("t5-img").also { it.start() }
        val handler = Handler(ht.looper)
        try {
            for (n in names) {
                try {
                    val c = MediaCodec.createByCodecName(n)
                    val vp = if (Build.VERSION.SDK_INT >= 31) c.supportedVendorParameters else emptyList()
                    log("Y444PROBE t5 info vendor_params $n count=${vp.size} ${vp.joinToString(",")}")
                    c.release()
                } catch (t: Throwable) {
                    log("Y444PROBE t5 info vendor_params $n unsupported ${t.javaClass.simpleName}:${t.message?.take(60)?.replace(' ', '_')}")
                }
            }
            val ref = decode("c2.android.hevc.decoder", w, h, csd, au, variants[0], null, handler)
            val refImg = ref.first
            if (refImg == null) { log("Y444PROBE t5 reference_failed ${ref.second}"); return }
            val refPlanes = try { cpuPlanes(refImg, w, h) } finally { refImg.close() }
            log("Y444PROBE t5 info reference ok y0=${hex(refPlanes.y, 0, 8)}")
            val err = Native.rawInit()
            if (err.isNotEmpty()) { log("Y444PROBE t5 gl_init_failed $err"); return }
            try {
                val tweaks = listOf<Pair<String, (MediaFormat) -> Unit>>(
                    "default" to { _ -> },
                    "flexible" to { f -> f.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible) },
                )
                for (n in names) for (v in variants) for ((tn, tw) in tweaks) {
                    val tag = "codec=$n reader=${v.label} fmt=$tn"
                    try {
                        val (img, why) = decode(n, w, h, csd, au, v, tw, handler)
                        if (img == null) { log("Y444PROBE t5 $tag unsupported $why"); continue }
                        try { log("Y444PROBE t5 $tag " + evaluate(img, w, h, refPlanes)) } finally { img.close() }
                    } catch (t: Throwable) {
                        log("Y444PROBE t5 $tag unsupported exception=${t.javaClass.simpleName}:${t.message?.take(80)?.replace(' ', '_')}")
                    }
                }
            } finally {
                Native.rawShutdown()
            }
        } finally {
            ht.quitSafely()
        }
        log("Y444PROBE t5 done")
    }

    private fun hex(b: ByteArray, off: Int, n: Int) = (off until minOf(off + n, b.size)).joinToString(".") { (b[it].toInt() and 0xFF).toString() }

    private fun cpuPlanes(img: Image, w: Int, h: Int): Planes {
        val p = img.planes
        return Planes(w, h,
            PlaneCopy.tight(p[0].buffer, p[0].rowStride, p[0].pixelStride, w, h),
            PlaneCopy.tight(p[1].buffer, p[1].rowStride, p[1].pixelStride, w / 2, h / 2),
            PlaneCopy.tight(p[2].buffer, p[2].rowStride, p[2].pixelStride, w / 2, h / 2))
    }

    private class Diff {
        var mis = 0L; var total = 0L; var max = 0
        fun add(a: Int, b: Int) { total++; val d = abs(a - b); if (d != 0) { mis++; if (d > max) max = d } }
    }

    private fun u(b: ByteArray, i: Int) = b[i].toInt() and 0xFF

    private fun evaluate(img: Image, w: Int, h: Int, ref: Planes): String {
        val sb = StringBuilder()
        sb.append("img_fmt=${img.format} ")
        val hw = img.hardwareBuffer
        var cpu: Planes? = null
        try {
            cpu = cpuPlanes(img, w, h)
            val p = img.planes
            val dy = Diff(); val dcb = Diff(); val dcr = Diff()
            for (i in ref.y.indices) dy.add(u(cpu.y, i), u(ref.y, i))
            for (i in ref.cb.indices) { dcb.add(u(cpu.cb, i), u(ref.cb, i)); dcr.add(u(cpu.cr, i), u(ref.cr, i)) }
            sb.append("cpu_strides=${p[0].rowStride}/${p[0].pixelStride},${p[1].rowStride}/${p[1].pixelStride},${p[2].rowStride}/${p[2].pixelStride} ")
            sb.append("cpu_y_mis=${dy.mis}/${dy.total} cpu_y_max=${dy.max} cpu_cb_mis=${dcb.mis}/${dcb.total} cpu_cb_max=${dcb.max} cpu_cr_mis=${dcr.mis}/${dcr.total} cpu_cr_max=${dcr.max} ")
        } catch (t: Throwable) {
            sb.append("cpu=unavailable(${t.javaClass.simpleName}) ")
        }
        if (hw == null) { sb.append("gpu=no_hardware_buffer"); return sb.toString() }
        try {
            val full = Native.gpuRender(hw, w, h, 0, 0)
            val fullInfo = Native.gpuInfo()
            if (full.isEmpty()) { sb.append("gpu=failed $fullInfo"); return sb.toString() }
            val half = Native.gpuRender(hw, w, h, 0, 1)
            val cw = w / 2; val ch = h / 2
            val mm = IntArray(2)
            for (flip in 0..1) for (r in 0 until h step 7) {
                val br = if (flip == 1) h - 1 - r else r
                for (x in 0 until w) if (u(full, (r * w + x) * 4) != u(ref.y, br * w + x)) mm[flip]++
            }
            val flip = if (mm[1] < mm[0]) 1 else 0
            val dy = Diff(); val dcb = Diff(); val dcr = Diff()
            for (r in 0 until h) {
                val br = if (flip == 1) h - 1 - r else r
                for (x in 0 until w) dy.add(u(full, (r * w + x) * 4), u(ref.y, br * w + x))
            }
            for (r in 0 until ch) {
                val br = if (flip == 1) ch - 1 - r else r
                for (x in 0 until cw) {
                    dcb.add(u(half, (r * cw + x) * 4 + 1), u(ref.cb, br * cw + x))
                    dcr.add(u(half, (r * cw + x) * 4 + 2), u(ref.cr, br * cw + x))
                }
            }
            sb.append("$fullInfo flip=$flip gpu_y_mis=${dy.mis}/${dy.total} gpu_y_max=${dy.max} gpu_cb_mis=${dcb.mis}/${dcb.total} gpu_cb_max=${dcb.max} gpu_cr_mis=${dcr.mis}/${dcr.total} gpu_cr_max=${dcr.max} ")
            val exact = dy.mis == 0L && dcb.mis == 0L && dcr.mis == 0L
            sb.append("GPU_EXACT=${if (exact) 1 else 0} ")
            fun gpuRow(rows: ByteArray, rw: Int, rowCount: Int, row: Int, n: Int, plane: Int) =
                (0 until n).joinToString(".") { u(rows, (rowOf(row, rowCount, flip) * rw + it) * 4 + plane).toString() }
            val my = h / 2; val mc = ch / 2
            sb.append("s_y0_ref=${hex(ref.y, 0, 8)} s_y0_cpu=${cpu?.let { hex(it.y, 0, 8) }} s_y0_gpu=${gpuRow(full, w, h, 0, 8, 0)} ")
            sb.append("s_ymid_ref=${hex(ref.y, my * w, 8)} s_ymid_cpu=${cpu?.let { hex(it.y, my * w, 8) }} s_ymid_gpu=${gpuRow(full, w, h, my, 8, 0)} ")
            sb.append("s_cb0_ref=${hex(ref.cb, 0, 4)} s_cb0_cpu=${cpu?.let { hex(it.cb, 0, 4) }} s_cb0_gpu=${gpuRow(half, cw, ch, 0, 4, 1)} ")
            sb.append("s_cr0_ref=${hex(ref.cr, 0, 4)} s_cr0_cpu=${cpu?.let { hex(it.cr, 0, 4) }} s_cr0_gpu=${gpuRow(half, cw, ch, 0, 4, 2)} ")
            sb.append("s_cbmid_ref=${hex(ref.cb, mc * cw, 4)} s_cbmid_cpu=${cpu?.let { hex(it.cb, mc * cw, 4) }} s_cbmid_gpu=${gpuRow(half, cw, ch, mc, 4, 1)} ")
            sb.append("s_crmid_ref=${hex(ref.cr, mc * cw, 4)} s_crmid_cpu=${cpu?.let { hex(it.cr, mc * cw, 4) }} s_crmid_gpu=${gpuRow(half, cw, ch, mc, 4, 2)} ")
            sb.append("kind=${classify(full, half, w, h, flip, ref)} ")
            val oes = Native.gpuRender(hw, w, h, 1, 0)
            if (oes.isEmpty()) sb.append("oes=unavailable ${Native.gpuInfo()}") else sb.append(oesVsExpected(oes, w, h, flip, ref))
        } finally {
            hw.close()
        }
        return sb.toString()
    }

    private fun rowOf(r: Int, rows: Int, flip: Int) = if (flip == 1) rows - 1 - r else r

    /** Coarse failure type for the GPU raw read. */
    private fun classify(full: ByteArray, half: ByteArray, w: Int, h: Int, flip: Int, ref: Planes): String {
        var allZero = true; var allSame = true; val first = u(full, 0)
        var chromaSwap = 0; var n = 0
        val cw = w / 2; val ch = h / 2
        for (r in 0 until ch step 3) for (x in 0 until cw step 3) {
            val gcb = u(half, (r * cw + x) * 4 + 1); val gcr = u(half, (r * cw + x) * 4 + 2)
            val br = rowOf(r, ch, flip)
            n++
            if (gcb == u(ref.cr, br * cw + x) && gcr == u(ref.cb, br * cw + x)) chromaSwap++
        }
        for (i in 0 until w * h step 13) { val v = u(full, i * 4); if (v != 0) allZero = false; if (v != first) allSame = false }
        var shift = "none"
        for (k in -8..8) {
            if (k == 0) continue
            var ok = 0; var tot = 0
            for (r in 8 until h - 8 step 5) for (x in 0 until w step 7) {
                tot++
                if (u(full, (rowOf(r, h, flip) * w + x) * 4) == u(ref.y, (rowOf(r, h, flip) + k).coerceIn(0, h - 1) * w + x)) ok++
            }
            if (ok * 10 > tot * 8) { shift = "rows$k"; break }
        }
        if (shift == "none") for (k in -8..8) {
            if (k == 0) continue
            var ok = 0; var tot = 0
            for (r in 0 until h step 5) for (x in 8 until w - 8 step 7) {
                tot++
                if (u(full, (rowOf(r, h, flip) * w + x) * 4) == u(ref.y, rowOf(r, h, flip) * w + (x + k))) ok++
            }
            if (ok * 10 > tot * 8) { shift = "cols$k"; break }
        }
        return when {
            allZero -> "all_zero"
            allSame -> "constant_$first"
            chromaSwap * 10 > n * 8 -> "cb_cr_swapped"
            shift != "none" -> "shifted_$shift"
            else -> "scrambled_or_converted"
        }
    }

    private fun clamp(v: Double) = v.coerceIn(0.0, 255.0).toInt()

    private data class Std(val name: String, val kr: Double, val kb: Double, val limited: Boolean)

    /** Compares the driver-converted RGB with the conversion of the reference under four standard matrices. */
    private fun oesVsExpected(oes: ByteArray, w: Int, h: Int, flip: Int, ref: Planes): String {
        val stds = listOf(Std("601lim", 0.299, 0.114, true), Std("709lim", 0.2126, 0.0722, true),
            Std("601full", 0.299, 0.114, false), Std("709full", 0.2126, 0.0722, false))
        var best = ""; var bestScore = Long.MAX_VALUE; var bestMax = 0; var bestBad = 0L
        val cw = w / 2
        for (s in stds) {
            val kg = 1 - s.kr - s.kb
            var maxd = 0; var bad = 0L; var sum = 0L
            for (r in 0 until h) {
                val br = rowOf(r, h, flip)
                for (x in 0 until w) {
                    val yv = u(ref.y, br * w + x).toDouble()
                    val cbv = u(ref.cb, (br / 2) * cw + x / 2) - 128.0
                    val crv = u(ref.cr, (br / 2) * cw + x / 2) - 128.0
                    val yy = if (s.limited) (yv - 16) * 255.0 / 219.0 else yv
                    val cs = if (s.limited) 255.0 / 224.0 else 1.0
                    val rr = yy + 2 * (1 - s.kr) * crv * cs
                    val bb = yy + 2 * (1 - s.kb) * cbv * cs
                    val gg = (yy - s.kr * rr - s.kb * bb) / kg
                    val o = (r * w + x) * 4
                    val d = maxOf(abs(u(oes, o) - clamp(rr)), abs(u(oes, o + 1) - clamp(gg)), abs(u(oes, o + 2) - clamp(bb)))
                    sum += d; if (d > maxd) maxd = d; if (d > 8) bad++
                }
            }
            if (sum < bestScore) { bestScore = sum; best = s.name; bestMax = maxd; bestBad = bad }
        }
        val mid = ((h / 2) * w) * 4
        return "oes_best=$best oes_max=$bestMax oes_bad8=$bestBad/${w * h} oes_px0=${u(oes, 0)}.${u(oes, 1)}.${u(oes, 2)} " +
            "oes_pxmid=${u(oes, mid)}.${u(oes, mid + 1)}.${u(oes, mid + 2)} ref_px0_y_cb_cr=${u(ref.y, 0)}.${u(ref.cb, 0)}.${u(ref.cr, 0)}"
    }

    /** Decodes the first access unit; returns the output image, or null with the reason. The reader stays open (leaks until exit). */
    private fun decode(codecName: String, w: Int, h: Int, csd: ByteArray?, au: ByteArray, v: Variant,
                       tweak: ((MediaFormat) -> Unit)?, handler: Handler): Pair<Image?, String> {
        var codec: MediaCodec? = null
        val images = LinkedBlockingQueue<Image>()
        try {
            val r = if (v.viaBuilder) {
                ImageReader.Builder(w, h).setImageFormat(v.format).setUsage(v.usage).setMaxImages(4).build()
            } else ImageReader.newInstance(w, h, v.format, 4, v.usage)
            r.setOnImageAvailableListener({ rd ->
                try { rd.acquireNextImage()?.let { images.add(it) } } catch (_: IllegalStateException) {}
            }, handler)
            val c = MediaCodec.createByCodecName(codecName)
            codec = c
            val f = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, w, h)
            csd?.let { f.setByteBuffer("csd-0", ByteBuffer.wrap(it)) }
            tweak?.invoke(f)
            c.configure(f, r.surface, null, 0)
            c.start()
            val deadline = System.nanoTime() + 4_000_000_000L
            var queued = 0
            val info = MediaCodec.BufferInfo()
            var got = false
            while (System.nanoTime() < deadline && !got) {
                if (queued < 2) {
                    val idx = c.dequeueInputBuffer(2_000)
                    if (idx >= 0) {
                        if (queued == 0) {
                            val b = c.getInputBuffer(idx)!!; b.clear(); b.put(au)
                            c.queueInputBuffer(idx, 0, au.size, 0, 0)
                        } else c.queueInputBuffer(idx, 0, 0, 1_000, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        queued++
                    }
                }
                val out = c.dequeueOutputBuffer(info, 2_000)
                if (out >= 0) {
                    val frame = info.size > 0
                    c.releaseOutputBuffer(out, frame)
                    if (frame) got = true
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                } else if (out == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    log("Y444PROBE t5 info $codecName ${v.label} out_format=${c.outputFormat.toString().replace(' ', '_')}")
                }
            }
            val img = images.poll(1_000, TimeUnit.MILLISECONDS)
            return if (img != null) img to "ok" else null to (if (got) "no_image" else "no_output")
        } catch (t: Throwable) {
            return null to "${t.javaClass.simpleName}:${t.message?.take(80)?.replace(' ', '_')}"
        } finally {
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
        }
    }
}
