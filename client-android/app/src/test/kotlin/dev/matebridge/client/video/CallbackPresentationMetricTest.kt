package dev.matebridge.client.video

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-225: `skip_pct` is measured on the codec's frame-rendered callback times, not on the vsync each frame was handed to
 * the codec for. On the tablet the latch model counted ~20% of the frames the adaptive pacer holds until just before
 * the compositor deadline as late (the release call returns within 1 ms of the cut); the callbacks showed ~3% at most.
 * Deterministic, no sleeps.
 */
class CallbackPresentationMetricTest {
    private val ms = 1_000_000L
    private val p60 = 1_000_000_000L / 60
    private val p120 = 1_000_000_000L / 120
    private val cbOffset = PresentRig.CB_OFFSET_NS

    /**
     * 60 fps frames 0..holds.size decoded into [st]. Frame k is released for vsync `releaseSlots[k]` (latch model) and its
     * callback reports vsync `shownSlots[k]` (null = the callback never comes); both in 120 Hz vsyncs from [base].
     */
    private fun play(
        st: VideoStats, releaseHolds: IntArray, shownHolds: IntArray, base: Long = 1_000_000_000L, missing: Set<Int> = emptySet(),
    ): VideoStats {
        var rel = base; var shown = base
        for (k in 0..shownHolds.size) {
            val cap = 500_000L + k * p60 / 1000
            st.onInput(k.toLong(), cap, cap)
            st.onOutput(k.toLong(), cap + 20_000, cap + 20_000)
            st.awaitCallback(k.toLong())
            st.onReleased(k.toLong(), cap, cap + 21_000, rel, p120)
            if (k !in missing) st.onRenderCallback(k.toLong(), cap, cap + 52_000, shown + cbOffset, p120)
            if (k < shownHolds.size) { rel += releaseHolds[k] * p120; shown += shownHolds[k] * p120 }
        }
        return st
    }

    @Test fun releasesPastTheOldCutWithRegularCallbacksAreNoSkip() {
        // Every release is attributed 3 vsyncs apart in alternation with 1 (the latch model's miscount), the callbacks
        // come regularly two vsyncs apart.
        val rel = IntArray(40) { if (it % 2 == 0) 3 else 1 }
        val s = play(VideoStats(), rel, IntArray(40) { 2 }).snapshot(reset = true)
        assertEquals(0.0, s.skipPct!!, 0.0)
        assertEquals(0L, s.holdLong)
        assertEquals(0L, s.holdShort)
        assertTrue("latch model: ${s.latchSkipPct}", s.latchSkipPct!! > 40.0)
    }

    @Test fun threeVsyncCallbackGapAtCadenceTwoIsLongAndTheNextOneShort() {
        // Shown holds 2 2 3 1 2 2 (+ the last, unconfirmed): one long (3), one short (1).
        val s = play(VideoStats(), IntArray(7) { 2 }, intArrayOf(2, 2, 3, 1, 2, 2, 2)).snapshot(reset = true)
        assertEquals(6L, s.holdJudged)
        assertEquals(1L, s.holdLong)
        assertEquals(1L, s.holdShort)
        assertEquals(100.0 / 6, s.skipPct!!, 1e-9)
        assertEquals("the release-time model saw regular releases", 0.0, s.latchSkipPct!!, 0.0)
    }

    @Test fun releasedFrameWithoutCallbackMakesItsPredecessorLong() {
        // Frame 5 was released but SurfaceFlinger dropped it: no callback. Frame 4 stays on screen 4 vsyncs (2 content
        // frames), judged against cadence 2: one long hold, and no short one.
        val st = VideoStats()
        val s = play(st, IntArray(12) { 2 }, IntArray(12) { 2 }, missing = setOf(5)).snapshot(reset = true)
        assertEquals(1L, s.holdLong)
        assertEquals(0L, s.holdShort)
        assertTrue(s.skipPct!! > 0.0)
        assertEquals("the missing callback is counted", 1L, s.renderCbMissing)
    }

    @Test fun bufferZeroAndAdaptiveGetTheSameMetricFromTheSameCallbacks() {
        // The same callback stream (regular, two vsyncs, with one late frame) behind two different release patterns:
        // buffer 0 (released at once, attributed to the earliest vsync) and the adaptive pacer's held releases.
        val shown = IntArray(60) { if (it == 30) 3 else if (it == 31) 1 else 2 }
        val atOnce = play(VideoStats(), IntArray(60) { if (it % 3 == 0) 1 else 2 }, shown).snapshot(reset = true)
        val held = play(VideoStats(), IntArray(60) { if (it % 2 == 0) 3 else 1 }, shown).snapshot(reset = true)
        assertEquals(atOnce.holdJudged, held.holdJudged)
        assertEquals(atOnce.holdShort, held.holdShort)
        assertEquals(atOnce.holdLong, held.holdLong)
        assertEquals(atOnce.skipPct, held.skipPct)
        assertEquals(1L, held.holdLong)
        assertEquals(1L, held.holdShort)
        assertTrue("latch models differ", atOnce.latchSkipPct != held.latchSkipPct)
    }

    @Test fun noCallbacksFallBackToTheLatchModel() {
        val st = VideoStats()
        var slot = 1_000_000_000L
        for (k in 0..20) {
            val cap = 500_000L + k * p60 / 1000
            st.onInput(k.toLong(), cap, cap); st.onOutput(k.toLong(), cap + 20_000, cap + 20_000)
            st.onReleased(k.toLong(), cap, cap + 21_000, slot, p120)
            slot += (if (k == 10) 3 else if (k == 11) 1 else 2) * p120
        }
        val s = st.snapshot(reset = true)
        assertEquals(1L, s.holdLong)
        assertEquals(s.latchSkipPct, s.skipPct)
        assertEquals("latch", st.holdWindow().logFields().substringAfter("hold_src=").substringBefore(' '))
    }

    @Test fun callbackWindowIsLoggedWithItsSourceAndTheLatchDiagnostic() {
        val st = play(VideoStats(), IntArray(8) { if (it % 2 == 0) 3 else 1 }, intArrayOf(2, 2, 3, 1, 2, 2, 2, 2))
        val w = st.holdWindow(reset = true)
        assertTrue(w.fromCallbacks)
        assertEquals(7L, w.judged)
        assertEquals("hold_n=7 hold_short_pct=14.3 hold_long_pct=14.3 hold_src=cb latch_skip_pct=57.1", w.logFields())
    }

    @Test fun logWindowSumsCallbackHoldsAndLatchOnesApart() {
        val st = play(VideoStats(), IntArray(8) { if (it % 2 == 0) 3 else 1 }, intArrayOf(2, 2, 3, 1, 2, 2, 2, 2))
        val one = st.snapshot(reset = true)
        val log = st.logSnapshot(reset = true)
        assertEquals(one, log)
        assertEquals(1L, log.holdLong)
        assertEquals(100.0 / 7, log.skipPct!!, 1e-9)
        assertEquals(400.0 / 7, log.latchSkipPct!!, 1e-9)
    }

    @Test fun unknownFrameOrDroppedStampBreaksTheSequence() {
        val st = VideoStats()
        fun frame(k: Int, shown: Long, cap: Long? = 500_000L + k * p60 / 1000) {
            val c = 500_000L + k * p60 / 1000
            st.onInput(k.toLong(), c, c); st.onOutput(k.toLong(), c + 20_000, c + 20_000)
            st.onRenderCallback(k.toLong(), cap, c + 52_000, shown, p120)
        }
        val base = 1_000_000_000L
        frame(0, base); frame(1, base + 2 * p120); frame(2, base + 4 * p120)
        frame(3, base + 6 * p120, cap = null) // capture unknown (e.g. after a reset): no interval spans it
        frame(4, base + 12 * p120); frame(5, base + 14 * p120)
        frame(6, Long.MAX_VALUE) // no usable time
        frame(7, base + 40 * p120)
        val s = st.snapshot(reset = true)
        assertEquals("only 0 -> 1 -> 2 (judged at 2) is judged; 4 -> 5 is confirmed by nothing", 1L, s.holdJudged)
        assertEquals(0L, s.holdLong)
    }

    // --- the pacer's feedback ---------------------------------------------------------------------------------------

    /**
     * 60 s of 60 fps on a 120 Hz panel through the adaptive pacer, one skip window per second fed from [source] (the
     * snapshot's metric). Returns the pacer and the last window's numbers.
     */
    private fun feedback(
        releaseJitterNs: Long, late: (Long) -> Int = { 0 }, source: (VideoStats.Snapshot) -> Double?,
    ): Triple<AdaptivePacer, Double?, Double?> {
        val rig = PresentRig(120, p60, adaptive = true, callbacks = true, releaseJitterNs = releaseJitterNs, lateByVsyncs = late)
        val rnd = Lcg(225L)
        val start = 1_000_000_000L
        var lastCb: Double? = null; var lastLatch: Double? = null
        var maxCb = 0.0; var maxLatch = 0.0
        for (k in 0 until 3600) {
            val cap = start + k * p60
            val j = (if (rnd.next() < 0.5) -4 * ms else 4 * ms) + (rnd.next() * ms).toLong()
            rig.frame(k, cap, cap + 21 * ms + j)
            if (k % 60 == 59) {
                val s = rig.stats.snapshot(reset = true)
                rig.pacer.onSkipWindow(source(s))
                lastCb = s.skipPct; lastLatch = s.latchSkipPct
                s.skipPct?.let { maxCb = maxOf(maxCb, it) }; s.latchSkipPct?.let { maxLatch = maxOf(maxLatch, it) }
            }
        }
        println("T-225 feedback: release jitter ${releaseJitterNs / 1000} us: level ${rig.pacer.level}, max callback skip_pct $maxCb, max latch $maxLatch")
        return Triple(rig.pacer, maxCb, maxLatch)
    }

    @Test fun perfectCallbackHoldsKeepTheLevelAtZeroWhateverTheReleaseCallReturnsAt() {
        for (jitterUs in longArrayOf(0, 1_000, 1_500, 2_500)) {
            val (pacer, maxCb, maxLatch) = feedback(jitterUs * 1000) { it.skipPct }
            assertEquals("jitter $jitterUs us", 0, pacer.level)
            assertEquals("jitter $jitterUs us: callbacks regular", 0.0, maxCb!!, 0.0)
            if (jitterUs >= 1_500) assertTrue("jitter $jitterUs us: the latch model miscounts ($maxLatch)", maxLatch!! > 3.0)
        }
    }

    @Test fun theLatchModelWouldHaveRaisedTheLevel() {
        // The T-220 behaviour, kept reproducible: the pacer fed the latch percentage climbs although nothing was skipped.
        val (pacer, maxCb, _) = feedback(2_500_000L) { it.latchSkipPct }
        assertTrue("callbacks showed (almost) no skip: $maxCb", maxCb!! < AdaptivePacer.SKIP_HIGH_PCT)
        assertTrue("level ${pacer.level}", pacer.level >= 1)
    }

    @Test fun realSkipsStillRaiseTheLevel() {
        // Every 8th frame is shown one vsync late: a 3-vsync hold (long) and a 1-vsync hold (short) per 8 frames.
        val (pacer, maxCb, _) = feedback(0L, late = { cap -> if (((cap - 1_000_000L) / (p60 / 1000)) % 8 == 5L) 1 else 0 }) { it.skipPct }
        assertTrue("callback skip_pct max $maxCb", maxCb!! > 5.0)
        assertTrue("level ${pacer.level}", pacer.level >= 1)
    }

    // --- PresentMeter (the callback gap diagnostic, `cb_skip_pct`) ---------------------------------------------------

    @Test fun presentMeterSeesAThreeVsyncGapAtCadenceTwo() {
        val m = PresentMeter()
        val p = p120
        var t = 0L
        m.onShown(0, t, p, 2 * p)
        for (i in 1..10) { t += if (i == 5) 3 * p else 2 * p; m.onShown(t - 4 * p, t, p, 2 * p) }
        val s = m.snapshot()
        assertEquals(10, s.intervals)
        assertEquals("the 3-vsync gap, not the 2-vsync ones", 1, s.skipped)
        val one = PresentMeter()
        one.onShown(0, 0, p, p); one.onShown(0, p, p, p); one.onShown(0, 3 * p, p, p) // cadence 1: a 2-vsync gap is a skip
        assertEquals(1, one.snapshot().skipped)
    }

    // --- pace trace ---------------------------------------------------------------------------------------------------

    @Test fun traceCarriesTheCallbackTimeInItsLastColumn() {
        val t = PaceTrace(capacity = 16)
        val id = t.record(7, 1_000, 2_000, null, 5_000_000, false, false, 0)
        t.onRelease(id, 5_000_000, 4_000_000, 0)
        t.record(8, 17_000, 18_000, null, 6_000_000, false, false, 0)
        t.onCallback(7, 123_456_789L, 8_333_333L)
        t.onCallback(99, 5L) // not a row of this trace: ignored
        val lines = StringBuilder().also { t.writeCsv(it) }.toString().trim().split("\n")
        assertEquals(listOf("cb_ns", "cb_period_ns"), lines[0].split(",").dropLast(1).takeLast(2))
        assertEquals(listOf("123456789", "8333333"), lines[1].split(",").dropLast(1).takeLast(2))
        assertEquals(listOf("0", "0"), lines[2].split(",").dropLast(1).takeLast(2))
        assertEquals(PaceTrace.CSV_COLS, lines[1].split(",").size)
        // A reused row starts without the old callback.
        val small = PaceTrace(capacity = 2)
        small.record(1, 0, 0, null, 0, false, false, 0); small.onCallback(1, 77)
        small.record(2, 0, 0, null, 0, false, false, 0); small.record(3, 0, 0, null, 0, false, false, 0)
        val rows = StringBuilder().also { small.writeCsv(it) }.toString().trim().split("\n").drop(1).map { it.split(",") }
        assertEquals(listOf("2", "3"), rows.map { it[0] })
        assertEquals(listOf("0", "0"), rows.map { it.last() })
        small.onCallback(1, 5L) // frame 1 left the ring: ignored
        assertEquals(listOf("0", "0"), StringBuilder().also { small.writeCsv(it) }.toString().trim().split("\n").drop(1).map { it.split(",").last() })
    }
}
