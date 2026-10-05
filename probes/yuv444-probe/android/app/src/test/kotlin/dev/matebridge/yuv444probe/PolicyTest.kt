package dev.matebridge.yuv444probe

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PolicyTest {
    private val ms = 1_000_000L

    @Test fun presentAndDirectModesParse() {
        assertEquals(PresentMode.QUEUE, PresentMode.parse(null))
        assertEquals(PresentMode.DEPTH1, PresentMode.parse(" Depth1 "))
        assertEquals(PresentMode.PTS, PresentMode.parse("pts"))
        assertNull(PresentMode.parse("bogus"))
        assertEquals(DirectMode.IMMEDIATE, DirectMode.parse(null))
        assertEquals(DirectMode.PTS, DirectMode.parse("PTS"))
        assertNull(DirectMode.parse("x"))
    }

    @Test fun argsDefaultsAndClamps() {
        val a = Args(emptyMap())
        assertEquals(PresentMode.QUEUE, a.present)
        assertEquals(DirectMode.IMMEDIATE, a.directMode)
        assertEquals(6 * ms, a.leadNs)
        assertEquals(0L, a.vsyncOffsetNs)
        val b = Args(mapOf("present" to "pts", "lead_ms" to "2.5", "vsync_off_ms" to "-2", "swap" to "0"))
        assertEquals(PresentMode.PTS, b.present)
        assertEquals(2_500_000L, b.leadNs)
        assertEquals(-2 * ms, b.vsyncOffsetNs)
        assertEquals(0, b.swap)
        assertEquals(30 * ms, Args(mapOf("lead_ms" to "999")).leadNs)
    }

    @Test fun depth1GateOpensOnlyWhenLatched() {
        assertFalse(Depth1Gate.open(1, 1, 0))
        assertFalse(Depth1Gate.open(2, 1, 50 * ms))
        assertTrue(Depth1Gate.open(0, 1, 0))
        assertTrue(Depth1Gate.open(-1, 1, 0))  // timestamps unavailable
        assertTrue(Depth1Gate.open(1, 1, Depth1Gate.STALL_NS))  // never wedge
    }

    @Test fun vsyncGridNextAtOrAfter() {
        val g = VsyncGrid(1000, 100)
        assertEquals(1000, g.nextAtOrAfter(1000))
        assertEquals(1100, g.nextAtOrAfter(1001))
        assertEquals(1100, g.nextAtOrAfter(1100))
        assertEquals(900, g.nextAtOrAfter(850))  // before the reference
    }

    @Test fun vsyncEstimatorMedianPeriod() {
        val p = 16_666_667L
        val s = LongArray(8) { 5_000_000_000L + it * p }
        s[3] += 2 * ms  // one jittered sample must not move the median
        val g = VsyncEstimator.estimate(s, 1 * ms)!!
        assertEquals(p, g.periodNs)
        assertEquals(s.max() + 1 * ms, g.refNs)
        assertNull(VsyncEstimator.estimate(longArrayOf(1, 2, 3), 0))
        assertNull(VsyncEstimator.estimate(longArrayOf(0, 100 * ms, 200 * ms, 300 * ms), 0))
    }

    @Test fun slotAllocatorTargetsNextSlotMinusLead() {
        val g = VsyncGrid(0, 16 * ms)
        val a = SlotAllocator(6 * ms)
        // now = 3 ms: earliest slot >= 9 ms is 16 ms, target 10 ms
        assertEquals(10 * ms, a.targetNs(3 * ms, g))
        // next frame 16.7 ms later: slot 32 ms, target 26 ms
        assertEquals(26 * ms, a.targetNs(19 * ms, g))
        assertEquals(0, a.bumps)
    }

    @Test fun slotAllocatorBumpsSameSlotAndFoldsPastBound() {
        val g = VsyncGrid(0, 16 * ms)
        val a = SlotAllocator(6 * ms, maxAheadSlots = 1)
        assertEquals(10 * ms, a.targetNs(3 * ms, g))            // slot 16
        assertEquals(26 * ms, a.targetNs(4 * ms, g))            // same slot -> bumped to 32 (1 slot ahead, allowed)
        assertEquals(1, a.bumps)
        assertEquals(26 * ms, a.targetNs(5 * ms, g))            // would be 48: 2 ahead > 1 -> fold onto 32
        assertEquals(1, a.folds)
    }

    @Test fun displayEstimateKeepsPtsReleaseOnItsSlot() {
        val g = VsyncGrid(0, 16 * ms)
        // released exactly (and 0.4 ms late) at slot - lead: shown on that slot
        assertEquals(32 * ms, DisplayEstimate.presentNs(g, 26 * ms, 6 * ms))
        assertEquals(32 * ms, DisplayEstimate.presentNs(g, 26 * ms + 400_000, 6 * ms))
        // immediate release 1 ms after a slot-lead point misses it: next slot
        assertEquals(48 * ms, DisplayEstimate.presentNs(g, 28 * ms, 6 * ms))
    }

    @Test fun verdictFollowsTheCardRule() {
        assertEquals(LatencyVerdict.PROCEED, LatencyVerdict.decide(2.0, 5.0))
        assertEquals(LatencyVerdict.PROCEED, LatencyVerdict.decide(-3.0, 0.0))
        assertEquals(LatencyVerdict.DISCUSS, LatencyVerdict.decide(5.1, 4.0))
        assertEquals(LatencyVerdict.DISCUSS, LatencyVerdict.decide(2.0, 10.0))
        assertEquals(LatencyVerdict.STOP, LatencyVerdict.decide(2.0, 10.1))
        assertEquals(LatencyVerdict.STOP, LatencyVerdict.decide(12.0, 1.0))
    }

    @Test fun latLineFormatsAndParses() {
        val r = PresentStats.analyze(
            longArrayOf(0, 20 * ms, 30 * ms, 0, 16 * ms, 36 * ms, 47 * ms, 0), 16 * ms,
        )
        val line = LatLine.format("gl", "depth1", "measured", "2800x1840", 60, 60, listOf(60.0), r, 2, 0, "x=1")
        assertTrue(line.startsWith("Y444PROBE lat mode=depth1 path=gl display=measured"))
        assertTrue(line.endsWith("x=1"))
        val (p50, p95) = LatLine.p50p95(line)!!
        assertEquals(30.0, p50, 1e-9)
        assertEquals(31.0, p95, 1e-9)
        assertNull(LatLine.p50p95("arrival_to_display_ms=- "))  // empty distribution
    }
}
