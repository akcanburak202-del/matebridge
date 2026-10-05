package dev.matebridge.client.video

import java.util.Random
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChromaReuseTest {
    private class P444(val w: Int, val h: Int, val y: IntArray, val cb: IntArray, val cr: IntArray)

    private fun random444(w: Int, h: Int, seed: Long): P444 {
        val r = Random(seed)
        return P444(w, h, IntArray(w * h) { r.nextInt(256) }, IntArray(w * h) { r.nextInt(256) }, IntArray(w * h) { r.nextInt(256) })
    }

    /** Kotlin copy of the host packer (main chroma mode `pick`), as in Avc444v2Test. */
    private fun pack(p: P444): Pair<Planes420, Planes420> {
        val w = p.w; val h = p.h; val cw = w / 2; val ch = h / 2; val q = w / 4
        val main = Planes420(w, h, p.y.copyOf(), IntArray(cw * ch), IntArray(cw * ch))
        val aux = Planes420(w, h, IntArray(w * h), IntArray(cw * ch), IntArray(cw * ch))
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

    private fun copy(m: Planes420, dy: (Int) -> Int = { 0 }) =
        Planes420(m.w, m.h, IntArray(m.y.size) { (m.y[it] + dy(it)).coerceIn(0, 255) }, m.cb.copyOf(), m.cr.copyOf())

    // ---- the block rule ----

    @Test fun ruleAcceptsDifferencesUpToTheTolerance() {
        val y = intArrayOf(100, 102, 98, 100)
        val ref = intArrayOf(100, 100, 100, 100)
        assertTrue(ChromaReuse.blockUnchanged(y, ref, 128, 128, 126, 130))
        assertFalse(ChromaReuse.blockUnchanged(intArrayOf(100, 103, 100, 100), ref, 128, 128, 128, 128)) // luma beyond
        assertFalse(ChromaReuse.blockUnchanged(y, ref, 128, 128, 125, 128)) // Cb beyond
        assertFalse(ChromaReuse.blockUnchanged(y, ref, 128, 131, 128, 128)) // Cr beyond
    }

    @Test fun negativeToleranceDisablesReuse() {
        val y = intArrayOf(10, 10, 10, 10)
        assertFalse(ChromaReuse.blockUnchanged(y, y, 128, 128, 128, 128, tolerance = -1))
        assertTrue(ChromaReuse.blockUnchanged(y, y, 128, 128, 128, 128, tolerance = 0))
    }

    @Test fun toleranceZeroNeedsAnExactMatch() {
        val y = intArrayOf(10, 10, 10, 10)
        assertFalse(ChromaReuse.blockUnchanged(y, intArrayOf(10, 10, 10, 11), 128, 128, 128, 128, tolerance = 0))
        assertFalse(ChromaReuse.blockUnchanged(y, y, 129, 128, 128, 128, tolerance = 0))
    }

    // ---- the state model ----

    @Test fun pairedFrameRestoresTheSourceExactly() {
        val src = random444(16, 8, 1)
        val (main, aux) = pack(src)
        val m = ChromaReuseModel(16, 8)
        m.drawPaired(main, aux)
        assertArrayEquals(src.y, m.y)
        assertArrayEquals(src.cb, m.cb)
        assertArrayEquals(src.cr, m.cr)
        assertTrue(m.valid)
    }

    @Test fun mainOnlyFrameWithoutStateIsThePlainUpsample() {
        val src = random444(16, 8, 2)
        val (main, _) = pack(src)
        val m = ChromaReuseModel(16, 8)
        assertFalse(m.valid)
        assertEquals(0, m.drawMainOnly(main))
        for (py in 0 until 8) for (px in 0 until 16) {
            assertEquals(main.cb[(py / 2) * 8 + px / 2], m.cb[py * 16 + px])
            assertEquals(main.cr[(py / 2) * 8 + px / 2], m.cr[py * 16 + px])
            assertEquals(main.y[py * 16 + px], m.y[py * 16 + px])
        }
    }

    @Test fun staticScreenKeepsFullColourWhenTheAuxiliaryFrameIsLate() {
        val src = random444(32, 16, 3)
        val (main, aux) = pack(src)
        val m = ChromaReuseModel(32, 16)
        m.drawPaired(main, aux)
        // Next frames: the same picture with T-253-style sharpening wobble of up to +-2 in luma, no auxiliary frame.
        val r = Random(9)
        repeat(10) {
            val noisy = copy(main) { r.nextInt(5) - 2 }
            assertEquals(16 / 2 * (32 / 2), m.drawMainOnly(noisy))
            assertArrayEquals(src.cb, m.cb) // odd-pixel chroma (only in the auxiliary view) survived
            assertArrayEquals(src.cr, m.cr)
            assertArrayEquals(noisy.y, m.y) // luma is always the current frame's
        }
    }

    @Test fun onlyChangedBlocksFallBackToTheMainChroma() {
        val src = random444(16, 8, 4)
        val (main, aux) = pack(src)
        val m = ChromaReuseModel(16, 8)
        m.drawPaired(main, aux)
        val moved = copy(main)
        val bx = 3; val by = 1 // block (3, 1) = pixels x 6..7, y 2..3
        val at = 2 * by * 16 + 2 * bx
        moved.y[at] = if (main.y[at] > 100) main.y[at] - 50 else main.y[at] + 50
        val reused = m.drawMainOnly(moved)
        assertEquals(8 * 4 - 1, reused)
        for (py in 0 until 8) for (px in 0 until 16) {
            val inChanged = px / 2 == bx && py / 2 == by
            val i = py * 16 + px
            if (inChanged) {
                assertEquals(main.cb[(py / 2) * 8 + px / 2], m.cb[i])
                assertEquals(main.cr[(py / 2) * 8 + px / 2], m.cr[i])
                assertEquals(moved.y[i], m.yRef[i])
            } else {
                assertEquals(src.cb[i], m.cb[i])
                assertEquals(src.cr[i], m.cr[i])
            }
        }
    }

    @Test fun referenceLumaDoesNotDrift() {
        val src = random444(16, 8, 5)
        val (main, aux) = pack(src)
        val flat = Planes420(16, 8, IntArray(16 * 8) { 100 }, main.cb, main.cr)
        val m = ChromaReuseModel(16, 8)
        m.drawPaired(flat, aux)
        // A slow ramp of +1 per frame: every step is within the tolerance of the PREVIOUS frame, but at +3 the block
        // differs from the kept reference by more than 2, so the colour is dropped then (no creeping reuse).
        val blocks = 8 * 4
        assertEquals(blocks, m.drawMainOnly(Planes420(16, 8, IntArray(16 * 8) { 101 }, main.cb, main.cr)))
        assertEquals(blocks, m.drawMainOnly(Planes420(16, 8, IntArray(16 * 8) { 102 }, main.cb, main.cr)))
        assertEquals(0, m.drawMainOnly(Planes420(16, 8, IntArray(16 * 8) { 103 }, main.cb, main.cr)))
        assertArrayEquals(IntArray(16 * 8) { 103 }, m.yRef) // the reference moved with the colour reset
    }

    @Test fun reuseCanBeSwitchedOff() {
        val src = random444(16, 8, 6)
        val (main, aux) = pack(src)
        val m = ChromaReuseModel(16, 8, tolerance = -1)
        m.drawPaired(main, aux)
        assertEquals(0, m.drawMainOnly(main))
        val plain = ChromaReuseModel(16, 8)
        plain.drawPaired(main, aux)
        assertEquals(0, plain.drawMainOnly(main, reuse = false))
        assertArrayEquals(m.cb, plain.cb)
    }

    @Test fun aLaterPairedFrameReplacesTheWholeState() {
        val a = random444(16, 8, 7)
        val b = random444(16, 8, 8)
        val m = ChromaReuseModel(16, 8)
        val (ma, aa) = pack(a)
        val (mb, ab) = pack(b)
        m.drawPaired(ma, aa)
        m.drawMainOnly(ma)
        m.drawPaired(mb, ab)
        assertArrayEquals(b.cb, m.cb)
        assertArrayEquals(b.cr, m.cr)
        assertArrayEquals(b.y, m.yRef)
    }

    // ---- late upgrade decision ----

    @Test fun lateUpgradeOnlyForAMainOnlyFrame() {
        val u = LateUpgrade()
        assertNull(u.candidate())
        u.onMainDrawn(1000, paired = true)
        assertNull(u.candidate())
        u.onMainDrawn(2000, paired = false)
        assertEquals(2000L, u.candidate())
        u.onUpgraded()
        assertNull(u.candidate()) // once per frame
    }

    @Test fun aNewMainFrameReplacesTheCandidate() {
        val u = LateUpgrade()
        u.onMainDrawn(2000, paired = false)
        u.onMainDrawn(3000, paired = false)
        assertEquals(3000L, u.candidate())
        u.onMainDrawn(4000, paired = true)
        assertNull(u.candidate())
    }

    @Test fun framesWithoutACaptureTimeAreNeverUpgraded() {
        val u = LateUpgrade()
        u.onMainDrawn(LateUpgrade.NONE, paired = false)
        assertNull(u.candidate())
        u.onMainDrawn(5, paired = false)
        u.clear()
        assertNull(u.candidate())
    }

    @Test fun pairingFindDoesNotJudgeOrEvict() {
        val evicted = ArrayList<String>()
        val p = AuxPairing<String>(2) { evicted.add(it) }
        p.add(100, "a")
        p.add(200, "b")
        assertEquals("a", p.find(100))
        assertNull(p.find(300))
        assertEquals(0, p.paired + p.late)
        assertTrue(evicted.isEmpty())
        // The late auxiliary frame of a frame that was shown main-only is found after it was judged late.
        assertNull(p.pair(300))
        assertEquals(1L, p.late)
    }

    @Test fun pairingFindSeesAnAuxiliaryFrameThatArrivedAfterTheJudgement() {
        val p = AuxPairing<String>(2) { }
        assertNull(p.pair(500)) // main 500 shown main-only: late
        p.add(500, "x")         // its auxiliary frame arrives
        assertEquals("x", p.find(500))
    }

    // ---- stats fields ----

    @Test fun statsFieldsCarryReuseAndUpgrades() {
        val snap = PackedPresenter.Snapshot(
            drawn = 60, mainOnly = 20, paired = 40, displaced = 0, drawErrors = 0, glMsP50 = 1.5, glMsP95 = 2.0,
            outstandingMax = 1, reuseSame = 900, reuseTotal = 1000, lateUpgrades = 7,
        )
        val f = FullChromaStatsFormat.fields(1, snap)
        assertTrue(f, f.endsWith("reuse_pct=90.0 late_upgrades=7"))
        assertEquals(90.0, snap.reusePct!!, 1e-9)
        val none = FullChromaStatsFormat.fields(1, PackedPresenter.Snapshot(0, 0, 0, 0, 0, null, null, 0))
        assertTrue(none, none.endsWith("reuse_pct=- late_upgrades=0"))
        assertFalse(FullChromaStatsFormat.fields(0, null).contains("reuse_pct"))
    }
}
