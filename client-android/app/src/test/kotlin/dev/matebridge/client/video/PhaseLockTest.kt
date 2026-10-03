package dev.matebridge.client.video

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-060: phase-locked slot assignment when the content interval equals the panel period. */
class PhaseLockTest {
    private val ms = 1_000_000L

    private class Run(val slots: List<Long>, val collided: Int, val gaps: Int, val dropped: Int, val pacer: AdaptivePacer, val period: Long)

    private class Lcg(var seed: Long = 12345L) {
        fun next(): Double { seed = seed * 6364136223846793005L + 1442695040888963407L; return ((seed ushr 33) % 10_000) / 10_000.0 }
    }

    /**
     * Frames captured every [fiNs] (host clock); ready = capture + base + jitter in 0..[jitterNs]. [boundaryNs]: the
     * base is chosen so the jitter-free ready time falls that long after a vsync (0 = exactly on the boundary, so
     * +-1 ms of jitter straddles two slots under per-frame rounding).
     */
    private fun run(
        clk: VsyncClock, pacer: AdaptivePacer, frames: Int, fiNs: Long, jitterNs: Long = 2 * ms,
        boundaryNs: Long = 0, startCapNs: Long = 1_000_000_000L, lateAt: Int = -1, lateNs: Long = 0, skip: Int = 60,
        rnd: Lcg = Lcg(),
    ): Run {
        val period = clk.grid().periodNs
        val base = 20 * ms + ((boundaryNs - (startCapNs + 20 * ms)) % period + period) % period
        val slots = ArrayList<Long>()
        var collided = 0; var gaps = 0; var dropped = 0
        var prev = Long.MIN_VALUE
        for (k in 0 until frames) {
            val cap = startCapNs + k * fiNs
            var ready = cap + base + (rnd.next() * jitterNs).toLong()
            if (k == lateAt) ready += lateNs
            val d = pacer.schedule(cap / 1000, ready) ?: continue
            if (k < skip) { prev = d.slotNs; continue }
            if (d.lateDrop) dropped++
            if (d.collided) collided++
            else {
                if (prev != Long.MIN_VALUE && d.slotNs - prev > period * 3 / 2) gaps++
                slots.add(d.slotNs)
            }
            if (d.slotNs > prev) prev = d.slotNs
        }
        return Run(slots, collided, gaps, dropped, pacer, period)
    }

    private fun clock(periodNs: Long) = VsyncClock(1e9f / periodNs).also { it.onVsync(0) }

    private fun exactSlots(r: Run) {
        for (i in 1 until r.slots.size) assertEquals("slot $i", r.period, r.slots[i] - r.slots[i - 1])
    }

    @Test fun sixtyOnSixtyAtTheSlotBoundaryStaysOneFramePerSlot() {
        for (boundary in longArrayOf(0, 1 * ms, 16 * ms, 8 * ms)) {
            val clk = clock(1_000_000_000L / 60)
            val period = clk.grid().periodNs
            val r = run(clk, AdaptivePacer(clk, period), 1500, period, boundaryNs = boundary)
            assertTrue(r.pacer.phaseLock)
            assertEquals("boundary $boundary collided", 0, r.collided)
            assertEquals("boundary $boundary gaps", 0, r.gaps)
            assertEquals(0L, r.pacer.rephases)
            exactSlots(r)
        }
    }

    @Test fun oneTwentyOnOneTwentyAtTheSlotBoundaryStaysOneFramePerSlot() {
        for (boundary in longArrayOf(0, 1 * ms, 7 * ms)) {
            val clk = clock(1_000_000_000L / 120)
            val period = clk.grid().periodNs
            val r = run(clk, AdaptivePacer(clk, period), 3000, period, jitterNs = 2 * ms, boundaryNs = boundary)
            assertTrue(r.pacer.phaseLock)
            assertEquals("boundary $boundary collided", 0, r.collided)
            assertEquals("boundary $boundary gaps", 0, r.gaps)
            assertEquals(0L, r.pacer.rephases)
            exactSlots(r)
        }
    }

    @Test fun lockedDIsBoundedByOnePeriod() {
        val clk = clock(1_000_000_000L / 60)
        val period = clk.grid().periodNs
        val pacer = AdaptivePacer(clk, period)
        run(clk, pacer, 400, period, jitterNs = 30 * ms)
        assertTrue(pacer.lastDNs <= period)
    }

    @Test fun slowClockDriftRephasesRarely() {
        val clk = clock(1_000_000_000L / 60)
        val period = clk.grid().periodNs
        // Host 59.95 Hz against a 60.00 Hz panel: one frame interval is 0.083 percent longer.
        val fi = (period * 60.0 / 59.95).toLong()
        val r = run(clk, AdaptivePacer(clk, period), 3000, fi, boundaryNs = period / 2) // 50 s: drift about 2.5 periods
        assertTrue("rephases ${r.pacer.rephases}", r.pacer.rephases in 1L..4L)
        assertTrue("gaps ${r.gaps} collided ${r.collided}", r.gaps + r.collided <= 4)
        assertTrue(r.pacer.phaseLock)
    }

    @Test fun oneLateFrameDoesNotMoveTheLock() {
        val clk = clock(1_000_000_000L / 60)
        val period = clk.grid().periodNs
        val pacer = AdaptivePacer(clk, period)
        val r = run(clk, pacer, 600, period, lateAt = 300, lateNs = 12 * ms, boundaryNs = period / 2)
        assertEquals(0L, pacer.rephases)
        assertTrue("dropped ${r.dropped} collided ${r.collided}", r.collided <= 1) // a drop is also a collision
        assertTrue("gaps ${r.gaps}", r.gaps <= 1)
        val first = r.slots.first()
        assertTrue(r.slots.all { (it - first) % period == 0L })
    }

    @Test fun lateFrameWhileTheVsyncAnchorAdvancesKeepsTheLock() {
        val clk = clock(1_000_000_000L / 60)
        val period = clk.grid().periodNs
        val pacer = AdaptivePacer(clk, period)
        val start = 1_000_000_000L
        val base = 20 * ms + ((period / 2 - (start + 20 * ms)) % period + period) % period
        var prevSlot = Long.MIN_VALUE
        var vsyncT = 0L
        fun feedVsyncUpTo(t: Long) { while (vsyncT + period <= t) { vsyncT += period; clk.onVsync(vsyncT) } }
        val slots = HashMap<Int, Long>()
        for (k in 0 until 400) {
            val cap = start + k * period
            var ready = cap + base
            if (k == 200) ready += 45 * ms // 2.7 periods late
            feedVsyncUpTo(ready)
            val d = pacer.schedule(cap / 1000, ready)!!
            if (k == 200) assertTrue("late frame dropped", d.lateDrop)
            else if (!d.collided) slots[k] = d.slotNs // frames queued behind the late one are dropped too
            if (k in 100..199) prevSlot = d.slotNs
        }
        assertEquals(0L, pacer.rephases)
        // Before and after the late frame the slots stay on one lattice: frame k sits k - 150 periods from frame 150.
        val ref = slots[150]!!
        for (k in intArrayOf(120, 199, 300, 399)) {
            val diff = slots[k]!! - ref - (k - 150) * period
            assertTrue("k=$k off by $diff", Math.abs(diff) <= 1000)
        }
    }

    @Test fun sustainedMissedSlotsRephaseOnce() {
        val clk = clock(1_000_000_000L / 60)
        val period = clk.grid().periodNs
        val pacer = AdaptivePacer(clk, period)
        run(clk, pacer, 300, period, boundaryNs = period / 2)
        assertEquals(0L, pacer.rephases)
        // The whole pipeline becomes 13 ms slower for good.
        val r = run(clk, pacer, 600, period, boundaryNs = period / 2 + 13 * ms, startCapNs = 1_000_000_000L + 300 * period, skip = 0)
        assertTrue("rephases ${pacer.rephases}", pacer.rephases in 0L..3L)
        assertTrue("gaps ${r.gaps} collided ${r.collided}", r.gaps + r.collided <= 8)
    }

    @Test fun panelSwitchBetween120And60Relocks() {
        val clk = clock(1_000_000_000L / 120)
        val p120 = clk.grid().periodNs
        val p60 = 1_000_000_000L / 60
        val pacer = AdaptivePacer(clk, p120)
        // Thinned host: the content interval is max(stream, period), like FrameInterval.resolve.
        pacer.intervalProvider = { period -> maxOf(p120, period) }
        val a = run(clk, pacer, 600, p120)
        assertTrue(pacer.phaseLock)
        assertEquals(0, a.collided)
        clk.setNominalHz(60f); clk.onVsync(2_000_000_000L)
        val b = run(clk, pacer, 600, p60, startCapNs = 1_500_000_000L + 10_000_000_000L)
        assertTrue(pacer.phaseLock)
        assertTrue("collided ${b.collided} gaps ${b.gaps}", b.collided + b.gaps <= 2)
        assertEquals(0L, pacer.rephases) // the panel-rate epoch reset the state
        clk.setNominalHz(120f); clk.onVsync(3_000_000_000L)
        val c = run(clk, pacer, 600, p120, startCapNs = 30_000_000_000L)
        assertTrue(pacer.phaseLock)
        assertTrue("collided ${c.collided} gaps ${c.gaps}", c.collided + c.gaps <= 2)
    }

    @Test fun surplusStreamOnASlowPanelIsNotLocked() {
        val clk = clock(1_000_000_000L / 60)
        val period = clk.grid().periodNs
        val pacer = AdaptivePacer(clk, period / 2)
        run(clk, pacer, 300, period / 2)
        assertFalse(pacer.phaseLock)
        assertEquals(0L, pacer.rephases)
    }

    @Test fun streamAtTwicePeriodIsLockedOnlyWithTheIntegerLock() {
        // T-208: two periods is an integer cadence (IntegerCadenceLockTest); before, and with the A/B switch off, no lock.
        val clk = clock(1_000_000_000L / 120)
        val period = clk.grid().periodNs
        val pacer = AdaptivePacer(clk, period * 2).also { it.integerLock = false }
        run(clk, pacer, 300, period * 2)
        assertFalse(pacer.phaseLock)
        val clk2 = clock(1_000_000_000L / 120)
        val locked = AdaptivePacer(clk2, period * 2)
        val r = run(clk2, locked, 300, period * 2)
        assertTrue(locked.phaseLock)
        for (i in 1 until r.slots.size) assertEquals("slot $i", 2 * period, r.slots[i] - r.slots[i - 1])
    }

    @Test fun streamAtThreePeriodsIsNotLocked() {
        val clk = clock(1_000_000_000L / 120)
        val period = clk.grid().periodNs
        val pacer = AdaptivePacer(clk, period * 3)
        run(clk, pacer, 300, period * 3)
        assertFalse(pacer.phaseLock)
    }
}
