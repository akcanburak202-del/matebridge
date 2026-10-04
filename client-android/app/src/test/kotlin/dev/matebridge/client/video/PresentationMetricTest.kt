package dev.matebridge.client.video

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-220: one presentation metric for every pacer. `skip_pct` is the share of released frames held longer than their
 * content cadence ([HoldMeter]); before, it came from the adaptive pacer's own decisions in that mode and from the
 * frame-rendered callback with buffer 0, so the two did not compare. Deterministic, no sleeps.
 */
class PresentationMetricTest {
    private val ms = 1_000_000L
    private val p60 = 1_000_000_000L / 60
    private val p120 = 1_000_000_000L / 120

    /** Decodes and releases 60 fps frames 0..[holds].size with the given holds (in 120 Hz vsyncs) into [st]. */
    private fun play(st: VideoStats, holds: IntArray, startSlot: Long = 1_000_000_000L): VideoStats {
        var slot = startSlot
        for (k in 0..holds.size) {
            val cap = 500_000L + k * p60 / 1000
            st.onInput(k.toLong(), cap, cap)
            st.onOutput(k.toLong(), cap + 20_000, cap + 20_000)
            st.onReleased(k.toLong(), cap, cap + 21_000, slot, p120)
            if (k < holds.size) slot += holds[k] * p120
        }
        return st
    }

    @Test fun threeVsyncHoldAtCadenceTwoIsLong() {
        // 60 fps on 120 Hz: holds 2 2 3 1 2 2 (+ the last, unconfirmed). One long (3), one short (1).
        val s = play(VideoStats(), intArrayOf(2, 2, 3, 1, 2, 2, 2)).snapshot(reset = true)
        assertEquals(6L, s.holdJudged) // the last release is confirmed only by a later one
        assertEquals(1L, s.holdLong)
        assertEquals(1L, s.holdShort)
        assertEquals(100.0 / 6, s.skipPct!!, 1e-9)
    }

    @Test fun holdMeterRules() {
        val m = HoldMeter()
        fun dec(vararg caps: Long) = caps.forEach(m::onDecoded)
        val c = LongArray(12) { 1_000_000L + it * p60 / 1000 }
        dec(*c)
        val base = 5_000_000_000L
        // Same vsync twice: the newer release replaces the older (never shown). Frame 1 replaced by 2 on one slot.
        assertEquals(HoldMeter.NONE, m.onPresented(c[0], base, p120))
        assertEquals(HoldMeter.NONE, m.onPresented(c[1], base + 2 * p120, p120))
        assertEquals(HoldMeter.NONE, m.onPresented(c[2], base + 2 * p120 + 1_000, p120)) // replaces 1
        // Confirms 0 -> 2: frame 0 was held 2 vsyncs = the cadence, exact. The metric is the hold; frame 1, which never
        // showed, is a discarded frame (counted as such), not a hold.
        assertEquals(HoldMeter.EXACT, m.onPresented(c[3], base + 4 * p120, p120))
        // 2 -> 3 with 3 vsyncs is long; 3 -> 4 with 1 short.
        assertEquals(HoldMeter.EXACT, m.onPresented(c[4], base + 7 * p120, p120)) // confirms 2 -> 3 (2 vsyncs)
        assertEquals(HoldMeter.LONG, m.onPresented(c[5], base + 8 * p120, p120)) // confirms 3 -> 4 (3 vsyncs)
        assertEquals(HoldMeter.SHORT, m.onPresented(c[6], base + 10 * p120, p120)) // confirms 4 -> 5 (1 vsync)
        // A decoded frame never shown (7 discarded) makes 6's hold long: 6 -> 8 over 4 vsyncs.
        assertEquals(HoldMeter.EXACT, m.onPresented(c[8], base + 14 * p120, p120)) // confirms 5 -> 6 (2)
        assertEquals(HoldMeter.LONG, m.onPresented(c[9], base + 16 * p120, p120)) // confirms 6 -> 8 (4)
    }

    @Test fun sourceGapsOtherCadencesAndPanelChangesAreNotJudged() {
        val m = HoldMeter()
        val base = 5_000_000_000L
        // Captures 0, 1, then an irregular 25 ms gap (a frame the host skipped), then regular ones.
        val caps = longArrayOf(0, 16_667, 41_667, 58_334, 75_001, 91_668, 108_335).map { it + 1_000_000L }
        caps.forEach(m::onDecoded)
        m.onPresented(caps[0], base, p120)
        m.onPresented(caps[2], base + 5 * p120, p120) // 1 discarded
        assertEquals("0 -> 2 spans the irregular capture", HoldMeter.NONE, m.onPresented(caps[3], base + 7 * p120, p120))
        assertEquals("2 -> 3 regular", HoldMeter.EXACT, m.onPresented(caps[4], base + 9 * p120, p120))
        assertEquals("3 -> 4 regular", HoldMeter.EXACT, m.onPresented(caps[5], base + 9 * p120 + p60, p60))
        assertEquals("4 -> 5 on another panel rate", HoldMeter.NONE, m.onPresented(caps[6], base + 9 * p120 + 2 * p60, p60))
        val p = p120 * 3 / 2 // 80 Hz: 60 fps is no integer cadence
        val n = HoldMeter()
        val c2 = LongArray(6) { 1_000_000L + it * p60 / 1000 }
        c2.forEach(n::onDecoded)
        for (k in 0 until 6) assertEquals(HoldMeter.NONE, n.onPresented(c2[k], base + k * 2 * p, p))
    }

    @Test fun latchSlotIsTheRequestedVsyncUnlessHandedOverLate() {
        val g = VsyncClock.Grid(1_000_000_000L, p120, 0, 6 * ms)
        val lead = 6 * ms
        val slot = 1_000_000_000L + 4 * p120
        // On time: the requested slot (render time + lead).
        assertEquals(slot, HoldMeter.latchSlot(g, slot - lead, lead, slot - 10 * ms))
        // Handed over after the deadline of its slot: the next vsync a buffer queued now can make.
        assertEquals(slot + p120, HoldMeter.latchSlot(g, slot - lead, lead, slot - 4 * ms))
        // Released at once (buffer 0): the earliest vsync after release + deadline.
        assertEquals(slot, HoldMeter.latchSlot(g, 0, lead, slot - 7 * ms))
        assertEquals(0L, HoldMeter.latchSlot(VsyncClock.Grid(-1, p120, 0, 0), 0, lead, slot))
    }

    @Test fun releaseThatStallsPastTheDeadlineCountsForTheNextVsync() {
        // T-220 review: the clock is read once the release call returned. A call that starts 1 ms before its slot's
        // deadline and returns 2 ms later is attributed to the next vsync (a missed deadline is never hidden).
        val clk = VsyncClock(120f).also { it.onVsync(0); it.setDisplayTiming(0, 13_330_000L) }
        val g = clk.grid()
        val slot = g.lastNs + 4 * g.periodNs
        val render = slot - clk.leadNs()
        var now = slot - g.deadlineNs - ms
        var got = LongArray(2)
        fun release(stallNs: Long) = HoldMeter.releasedSlot(clk, render, { now }, { now += stallNs }) { s, p -> got = longArrayOf(s, p) }
        release(0)
        assertEquals("on time", slot, got[0])
        now = slot - g.deadlineNs - ms
        release(2 * ms)
        assertEquals("stalled past the deadline inside the call", slot + g.periodNs, got[0])
        assertEquals(g.periodNs, got[1])
        // Buffer 0 (released at once): the earliest vsync after the call returned.
        now = slot - g.deadlineNs - ms
        HoldMeter.releasedSlot(clk, 0, { now }, { now += 2 * ms }) { s, _ -> got[0] = s }
        assertEquals(slot + g.periodNs, got[0])
        // The panel rate changes during the call: slot and period come from the grid after it (one snapshot).
        HoldMeter.releasedSlot(clk, render, { now }, { clk.setNominalHz(60f) }) { s, p -> got = longArrayOf(s, p) }
        assertEquals(clk.grid().periodNs, got[1])
        assertTrue("period ${got[1]}", got[1] > 16_000_000L)
    }

    @Test fun traceRecordsTheReleaseTimeVsyncAndPeriod() {
        val t = PaceTrace(capacity = 8)
        val id = t.record(1, 1_000, 2_000, null, 5_000_000, false, false, 0)
        t.onRelease(id, 5_000_000, 4_000_000, 0)
        t.onLatch(id, 13_333_333, 8_333_333)
        val id2 = t.record(2, 17_000, 18_000, null, 0, false, false, 0) // not released
        t.onDiscard(id2, 19_000, PaceTrace.ACTION_REPLACE)
        val lines = StringBuilder().also { t.writeCsv(it) }.toString().trim().split("\n")
        val h = lines[0].split(",")
        assertEquals(listOf("latch_slot_ns", "latch_period_ns", "cb_ns", "cb_period_ns"), h.takeLast(4))
        assertEquals(PaceTrace.CSV_COLS, h.size)
        assertEquals(listOf("13333333", "8333333", "0", "0"), lines[1].split(",").takeLast(4))
        assertEquals(listOf("0", "0", "0", "0"), lines[2].split(",").takeLast(4))
        assertEquals(PaceTrace.CSV_COLS, lines[2].split(",").size)
    }

    @Test fun onceSlotsAreReportedSchedulerAndCallbackNoLongerCount() {
        // Legacy callers (no slot reported) keep the old definition; the renderer reports slots, so the metric is one.
        val legacy = VideoStats()
        legacy.onScheduled(true); legacy.onScheduled(false)
        assertEquals(50.0, legacy.snapshot(reset = true).skipPct!!, 0.0)

        val st = play(VideoStats(), intArrayOf(2, 2, 2, 2))
        st.onScheduled(true); st.onScheduled(true) // the pacer's own verdict: not the metric any more
        st.onShownPaced(0, 0, p120, 2 * p120); st.onShownPaced(0, 10 * p120, p120, 2 * p120) // callback diagnostic
        val s = st.snapshot(reset = true)
        assertEquals(0.0, s.skipPct!!, 0.0)
        assertEquals(100.0, s.schedSkipPct!!, 0.0)
        assertEquals(100.0, s.cbSkipPct!!, 0.0)
        assertNull("nothing judged in an empty window", st.snapshot(reset = true).skipPct)
    }

    @Test fun logWindowSumsTheHoldsAndThePresentLineHasThem() {
        val st = play(VideoStats(), intArrayOf(2, 3, 1, 2, 2))
        val one = st.snapshot(reset = true)
        val log = st.logSnapshot(reset = true)
        assertEquals(one, log)
        val w = st.holdWindow(reset = true)
        assertEquals(VideoStats.HoldCounts(4, 1, 1, latchJudged = 4, latchLong = 1), w) // no callbacks: the latch model counts
        assertEquals("hold_n=4 hold_short_pct=25.0 hold_long_pct=25.0 hold_src=latch latch_skip_pct=25.0", w.logFields())
        assertEquals("hold_n=0 hold_short_pct=- hold_long_pct=- hold_src=latch latch_skip_pct=-", st.holdWindow().logFields())
    }

    @Test fun simSelfTestVector() {
        // The vector of `tools/pacing/sim.py --holds-selftest` (same rules in Python): 60 fps on 120 Hz, 100 frames, every
        // 10th decoded but never shown, frame 50 handed over 4 ms after its slot's deadline. 88 judged: 10 long holds of 4
        // vsyncs, one long 3, one short 1.
        val p = 8_333_333L
        val grid = VsyncClock.Grid(1_000_000_000L, p, 0, 6 * ms)
        val lead = 6 * ms
        val st = VideoStats()
        for (k in 0 until 100) {
            val cap = k * 16_667L
            st.onInput(k.toLong(), cap, cap)
            st.onOutput(k.toLong(), cap + 20_000, cap + 20_000)
            if (k % 10 == 5) { st.onDiscarded(); continue }
            val slot = 1_000_000_000L + k * 2 * p
            val release = if (k == 50) slot - 6 * ms + 4 * ms else slot - 10 * ms
            st.onReleased(k.toLong(), cap, release / 1000, HoldMeter.latchSlot(grid, slot - lead, lead, release), p)
        }
        val s = st.snapshot(reset = true)
        assertEquals(88L, s.holdJudged)
        assertEquals(11L, s.holdLong)
        assertEquals(1L, s.holdShort)
        assertEquals(1250.0 / 100, s.skipPct!!, 1e-9)
    }

    @Test fun codecStartBreaksTheSequence() {
        val st = play(VideoStats(), intArrayOf(2, 2))
        st.snapshot(reset = true)
        st.resetFrames() // a new codec: frame_seq and the content run start over
        play(st, intArrayOf(2, 2), startSlot = 9_000_000_000L)
        assertEquals("only the new stream's intervals", 1L, st.snapshot(reset = true).holdJudged)
    }

    // --- the same stream through both pacers -------------------------------------------------------------------------

    /** Reference: holds of consecutive shown frames (the last one unconfirmed), against cadence [n]. */
    private fun reference(shown: List<LongArray>, periodNs: Long, n: Long): Triple<Int, Int, Int> {
        var judged = 0; var short = 0; var long = 0
        for (i in 1 until shown.size - 1) {
            val h = Math.round((shown[i][1] - shown[i - 1][1]).toDouble() / periodNs)
            judged++
            if (h < n) short++ else if (h > n) long++
        }
        return Triple(judged, short, long)
    }

    /** 60 fps on 120 Hz with device-like two-bucket arrivals (NOTES 2026-10-04: 12.5 / 20.8 ms callback buckets). */
    private fun run(adaptive: Boolean): PresentRig {
        val rig = PresentRig(120, p60, adaptive)
        val rnd = Lcg(2026L)
        val start = 1_000_000_000L
        for (k in 0 until 3600) {
            val cap = start + k * p60
            val j = (if (rnd.next() < 0.5) -4 * ms else 4 * ms) + (rnd.next() * ms).toLong()
            rig.frame(k, cap, cap + 21 * ms + j)
        }
        rig.finish(start + 3600 * p60 + 100 * ms)
        return rig
    }

    @Test fun sameStreamIsReportedWithOneMetricForBufferZeroAndAdaptive() {
        val zero = run(adaptive = false)
        val adaptive = run(adaptive = true)
        for ((name, rig) in listOf("buffer 0" to zero, "adaptive" to adaptive)) {
            val s = rig.stats.snapshot(reset = true)
            val (judged, short, long) = reference(rig.shown(), p120, 2)
            println("T-220 $name: judged ${s.holdJudged} short ${s.holdShort} long ${s.holdLong} skip_pct ${s.skipPct} " +
                "(reference $judged/$short/$long), scheduler skip_pct ${s.schedSkipPct}, released ${rig.released.size}")
            assertEquals(name, judged.toLong(), s.holdJudged)
            assertEquals(name, short.toLong(), s.holdShort)
            assertEquals(name, long.toLong(), s.holdLong)
            assertEquals(name, long * 100.0 / judged, s.skipPct!!, 1e-9)
            assertTrue("$name: every interval of the continuous stream judged", s.holdJudged >= 3500)
        }
        val z = zero.stats.logSnapshot(); val a = adaptive.stats.logSnapshot()
        // The device symptom with buffer 0 (holds of 1 and 3 vsyncs), none with the 2:1 lock: same yardstick.
        assertTrue("buffer 0 short ${z.holdShort} long ${z.holdLong}", z.holdShort * 100 >= 5 * z.holdJudged && z.holdLong * 100 >= 5 * z.holdJudged)
        assertTrue("adaptive long ${a.holdLong} short ${a.holdShort}", (a.holdLong + a.holdShort) * 100 <= a.holdJudged)
    }

    @Test fun lockedFrameMissingItsSlotAtCadenceTwoIsALongHoldAndASkip() {
        // AdaptivePacer's missed-slot branch at n = 2: the frame goes to the next vsync, the previous one is held 3.
        val rig = PresentRig(120, p60, adaptive = true)
        val start = 1_000_000_000L
        var late: FramePacer.Decision? = null
        for (k in 0 until 200) {
            val cap = start + k * p60
            val d = rig.frame(k, cap, cap + 21 * ms + if (k == 150) 9 * ms else 0)!!
            if (k == 150) late = d
        }
        rig.finish(start + 200 * p60 + 100 * ms)
        val s = rig.stats.snapshot(reset = true)
        println("T-220 missed slot: judged ${s.holdJudged} short ${s.holdShort} long ${s.holdLong}, decision skipped ${late!!.skipped}")
        assertTrue(rig.pacer.phaseLock)
        assertEquals(1L, s.holdLong)
        assertEquals(1L, s.holdShort)
        assertTrue("3-vsync hold at cadence 2 counts as a scheduler skip too", late.skipped)
    }
}
