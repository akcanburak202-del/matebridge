package dev.matebridge.client.video

import java.util.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class Avc444v2Test {
    private class P444(val w: Int, val h: Int, val y: IntArray, val cb: IntArray, val cr: IntArray)
    private class P420(val w: Int, val h: Int, val y: IntArray, val cb: IntArray, val cr: IntArray)

    private fun random444(w: Int, h: Int, seed: Long): P444 {
        val r = Random(seed)
        return P444(w, h, IntArray(w * h) { r.nextInt(256) }, IntArray(w * h) { r.nextInt(256) }, IntArray(w * h) { r.nextInt(256) })
    }

    /** Kotlin copy of probes/yuv444-probe AVC444v2.pack (main chroma mode `pick`). */
    private fun pack(p: P444): Pair<P420, P420> {
        val w = p.w; val h = p.h; val cw = w / 2; val ch = h / 2; val q = w / 4
        val main = P420(w, h, p.y.copyOf(), IntArray(cw * ch), IntArray(cw * ch))
        val aux = P420(w, h, IntArray(w * h), IntArray(cw * ch), IntArray(cw * ch))
        for (j in 0 until ch) for (i in 0 until cw) {
            main.cb[j * cw + i] = p.cb[2 * j * w + 2 * i]
            main.cr[j * cw + i] = p.cr[2 * j * w + 2 * i]
        }
        for (y in 0 until h) for (x in 0 until cw) {
            aux.y[y * w + x] = p.cb[y * w + 2 * x + 1]
            aux.y[y * w + cw + x] = p.cr[y * w + 2 * x + 1]
        }
        for (j in 0 until ch) {
            val row = (2 * j + 1) * w
            for (x in 0 until q) {
                aux.cb[j * cw + x] = p.cb[row + 4 * x]
                aux.cr[j * cw + x] = p.cb[row + 4 * x + 2]
                aux.cb[j * cw + q + x] = p.cr[row + 4 * x]
                aux.cr[j * cw + q + x] = p.cr[row + 4 * x + 2]
            }
        }
        return main to aux
    }

    private fun sample(main: P420, aux: P420, h: Avc444v2.Home): Int {
        val cw = main.w / 2
        return when (h.plane) {
            Avc444v2.Plane.AUX_LUMA -> aux.y[h.y * main.w + h.x]
            Avc444v2.Plane.AUX_CB -> aux.cb[h.y * cw + h.x]
            Avc444v2.Plane.AUX_CR -> aux.cr[h.y * cw + h.x]
            Avc444v2.Plane.MAIN_CHROMA -> error("main chroma needs the colour channel")
        }
    }

    @Test
    fun reconstructionIsBitExact() {
        for ((w, h) in listOf(8 to 2, 16 to 8, 28 to 18, 64 to 36)) {
            val src = random444(w, h, (w * 31 + h).toLong())
            val (main, aux) = pack(src)
            val cw = w / 2
            for (py in 0 until h) for (px in 0 until w) {
                val hb = Avc444v2.home(px, py, w, cr = false)
                val hr = Avc444v2.home(px, py, w, cr = true)
                val cb = if (hb.plane == Avc444v2.Plane.MAIN_CHROMA) main.cb[hb.y * cw + hb.x] else sample(main, aux, hb)
                val cr = if (hr.plane == Avc444v2.Plane.MAIN_CHROMA) main.cr[hr.y * cw + hr.x] else sample(main, aux, hr)
                assertEquals("cb $px,$py ${w}x$h", src.cb[py * w + px], cb)
                assertEquals("cr $px,$py ${w}x$h", src.cr[py * w + px], cr)
            }
        }
    }

    @Test
    fun everyAuxiliarySampleIsUsedExactlyOnce() {
        val w = 32; val h = 10
        val used = HashMap<Triple<Avc444v2.Plane, Int, Int>, Int>()
        for (py in 0 until h) for (px in 0 until w) for (cr in listOf(false, true)) {
            val hm = Avc444v2.home(px, py, w, cr)
            if (hm.plane == Avc444v2.Plane.MAIN_CHROMA) continue
            used.merge(Triple(hm.plane, hm.x, hm.y), 1, Int::plus)
        }
        assertTrue(used.values.all { it == 1 })
        // aux luma: all W*H samples, aux Cb + Cr: W/2*H/2 each
        assertEquals(w * h + 2 * (w / 2) * (h / 2), used.size)
    }

    @Test
    fun mainChromaIsTheEvenEvenSample() {
        val hm = Avc444v2.home(6, 4, 16, cr = false)
        assertEquals(Avc444v2.Home(Avc444v2.Plane.MAIN_CHROMA, 3, 2), hm)
    }

    @Test
    fun validSizes() {
        assertTrue(Avc444v2.isValid(2800, 1840))
        assertTrue(Avc444v2.isValid(1848, 1214))
        assertTrue(!Avc444v2.isValid(1850, 1214))
        assertTrue(!Avc444v2.isValid(1848, 1213))
    }

    @Test
    fun bt709FullRangeMatchesProbeShader() {
        val c = YuvConversion.of(matrix = 1, fullRange = true)
        assertEquals(1.5748f, c.crR, 1e-4f)
        assertEquals(-0.1873f, c.cbG, 1e-4f)
        assertEquals(-0.4681f, c.crG, 1e-4f)
        assertEquals(1.8556f, c.cbB, 1e-4f)
        val grey = c.toRgb(0.5f, YuvConversion.CHROMA_MID, YuvConversion.CHROMA_MID)
        for (v in grey) assertEquals(0.5f, v, 1e-5f)
    }

    @Test
    fun limitedRangeMapsBlackAndWhite() {
        val c = YuvConversion.of(matrix = 1, fullRange = false)
        val black = c.toRgb(16f / 255f, YuvConversion.CHROMA_MID, YuvConversion.CHROMA_MID)
        val white = c.toRgb(235f / 255f, YuvConversion.CHROMA_MID, YuvConversion.CHROMA_MID)
        for (v in black) assertEquals(0f, v, 1e-4f)
        for (v in white) assertEquals(1f, v, 1e-4f)
        val red = c.toRgb(63f / 255f, 102f / 255f, 240f / 255f)
        assertTrue(red[0] > 0.95f && red[1] < 0.05f)
    }

    @Test
    fun unknownMatrixIsBt709_andOthersDiffer() {
        assertEquals(YuvConversion.of(1, true), YuvConversion.of(0, true))
        assertEquals(1.402f, YuvConversion.of(6, true).crR, 1e-3f)
        assertEquals(1.4746f, YuvConversion.of(9, true).crR, 1e-3f)
        assertEquals(7, YuvConversion.of(1, false).toArray().size)
    }
}
