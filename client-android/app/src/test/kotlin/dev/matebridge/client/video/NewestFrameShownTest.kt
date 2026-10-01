package dev.matebridge.client.video

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-065 invariant, pacer + SlotReleaser end to end: a decoded frame is only ever dropped when a NEWER frame
 * replaces it; the newest frame is always released (within a bounded time).
 */
private const val ms = 1_000_000L

class NewestFrameShownTest {
    private class Lcg(var seed: Long = 777L) {
        fun next(): Double { seed = seed * 6364136223846793005L + 1442695040888963407L; return ((seed ushr 33) % 10_000) / 10_000.0 }
    }

    private class Sim(var panelHz: Int, val streamFps: Int, val arrivalNs: Long) {
        val clk = VsyncClock(panelHz.toFloat()).also { it.onVsync(0); it.deadlineOverrideNs = VsyncClock.DEADLINE_DISPLAY; it.setDisplayTiming(0, 13_330_000L) }
        val pacer = AdaptivePacer(clk, 1_000_000_000L / streamFps).also {
            it.intervalProvider = { p -> FrameInterval.resolve(1_000_000_000L / streamFps, p, arrivalNs) }
        }
        var current = -1 // frame being submitted
        val releasedAt = HashMap<Int, Long>() // frame -> render timestamp
        val selfDiscarded = ArrayList<Int>() // dropped by its own submit (no newer frame involved)
        val replaced = ArrayList<Int>()
        val rel = SlotReleaser(object : SlotReleaser.Sink {
            override fun release(idx: Int, renderNs: Long) { releasedAt[idx] = renderNs }
            override fun discard(idx: Int) { if (idx == current) selfDiscarded.add(idx) else replaced.add(idx) }
        }, PresentCounters())
        var now = 0L

        fun advanceTo(t: Long) {
            val period = clk.grid().periodNs
            var v = clk.grid().lastNs
            while (v + period <= t) { v += period; clk.onVsync(v) }
            rel.flushDue(t)
            now = t
        }

        fun frame(k: Int, captureNs: Long, readyNs: Long) {
            advanceTo(readyNs)
            current = k
            val d = pacer.schedule(captureNs / 1000, readyNs)!!
            rel.submit(k, d.slotNs, d.renderNs, d.slotNs - (clk.grid().deadlineNs + 1 * ms), readyNs, clk.periodNs)
            current = -1
        }

        fun finish() { advanceTo(now + 200 * ms) }
    }

    private fun run(
        panelHz: Int, streamFps: Int, gapMinMs: Int, gapMaxMs: Int, n: Int = 300, switchTo: Int? = null,
    ): Sim {
        val s = Sim(panelHz, streamFps, 1_000_000_000L / panelHz)
        val rnd = Lcg()
        val hostTick = 1_000_000_000L / 120
        var cap = 1_000_000_000L
        for (k in 0 until n) {
            cap += (gapMinMs + (rnd.next() * (gapMaxMs - gapMinMs)).toInt()) * ms
            cap = (cap / hostTick) * hostTick
            if (switchTo != null && k == n / 2) { s.panelHz = switchTo; s.clk.setNominalHz(switchTo.toFloat()) }
            s.frame(k, cap, cap + 15 * ms + (rnd.next() * 2 * ms).toLong())
        }
        s.finish()
        return s
    }

    /** No frame dropped by its own submit; the newest frame was released; every frame released or replaced. */
    private fun check(label: String, s: Sim, n: Int) {
        assertTrue("$label: frames dropped without a newer one: ${s.selfDiscarded}", s.selfDiscarded.isEmpty())
        assertTrue("$label: newest frame never released", s.releasedAt.containsKey(n - 1))
        for (k in 0 until n) assertTrue("$label: frame $k vanished", s.releasedAt.containsKey(k) || k in s.replaced)
    }

    @Test fun sparseFramesAreNeverDroppedAcrossPanelAndStreamRates() {
        for (panel in listOf(60, 120)) for (fps in listOf(60, 120)) {
            for ((lo, hi) in listOf(100 to 600, 20 to 60, 1100 to 3000)) {
                check("panel=$panel fps=$fps gaps=$lo..$hi", run(panel, fps, lo, hi), 300)
            }
        }
    }

    @Test fun sparseFramesOnAPanelSwitchAreNeverDropped() {
        for ((from, to) in listOf(60 to 120, 120 to 60)) {
            for ((lo, hi) in listOf(100 to 600, 20 to 60)) {
                check("switch $from->$to gaps=$lo..$hi", run(from, 120, lo, hi, switchTo = to), 300)
            }
        }
    }

    @Test fun framesFarApartAreAllReleasedNothingToReplaceThem() {
        val s = run(60, 120, 100, 600)
        assertEquals(300, s.releasedAt.size)
        assertTrue(s.replaced.isEmpty())
    }

    @Test fun singleFrameAfterALongGapIsReleasedWithinTwoPeriods() {
        for (panel in listOf(60, 120)) {
            val s = Sim(panel, 120, 1_000_000_000L / panel)
            var cap = 1_000_000_000L
            val tick = 1_000_000_000L / 120
            for (k in 0 until 20) { cap += tick; s.frame(k, cap, cap + 15 * ms) }
            cap += 700 * ms; cap = (cap / tick) * tick
            val readyNs = cap + 15 * ms
            s.frame(99, cap, readyNs)
            s.finish()
            val period = s.clk.periodNs
            val render = s.releasedAt[99]
            assertTrue("panel=$panel single frame released", render != null)
            assertTrue("panel=$panel released within 2 periods: ${(render!! - readyNs) / 1000} us", render - readyNs <= 2 * period)
        }
    }

    @Test fun phaseLockReacquiresAfterASparseGap() {
        val clk = VsyncClock(60f).also { it.onVsync(0); it.deadlineOverrideNs = VsyncClock.DEADLINE_DISPLAY; it.setDisplayTiming(0, 13_330_000L) }
        val p = AdaptivePacer(clk, 16_666_666L)
        var cap = 1_000_000_000L
        var now = cap + 15 * ms
        var v = 0L
        fun vs(t: Long) { while (v + clk.periodNs <= t) { v += clk.periodNs; clk.onVsync(v) } }
        for (k in 0 until 40) { vs(now); p.schedule(cap / 1000, now); cap += 16_666_666L; now += 16_666_666L }
        assertTrue(p.phaseLock)
        val before = p.rephases
        cap += 250 * ms; now += 250 * ms
        vs(now)
        val d = p.schedule(cap / 1000, now)!!
        assertTrue(!d.lateDrop)
        assertEquals(before, p.rephases)
    }
}
