package dev.matebridge.client.video

import dev.matebridge.client.stream.DisplayModeInfo
import dev.matebridge.client.stream.DisplayModePicker
import dev.matebridge.client.stream.FrameRatePolicy
import dev.matebridge.client.stream.StatsFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class IntervalHistogramTest {
    @Test fun percentilesAndThreshold() {
        val h = IntervalHistogram(16_700)
        for (i in 1..100) h.record(i * 1000L) // 1..100 ms
        val s = h.summary()
        assertEquals(100, s.count)
        assertEquals(50_000L, s.p50Us)
        assertEquals(95_000L, s.p95Us)
        assertEquals(99_000L, s.p99Us)
        assertEquals(84, s.overThreshold) // 17..100 ms
    }

    @Test fun markRecordsGapsAndResetKeepsLastEvent() {
        val h = IntervalHistogram()
        h.mark(1_000); h.mark(18_000); h.mark(30_000)
        assertEquals(2, h.summary(reset = true).count)
        h.mark(40_000)
        val s = h.summary()
        assertEquals(1, s.count)
        assertEquals(10_000L, s.p50Us)
    }

    @Test fun breakSequenceSkipsTheGap() {
        val h = IntervalHistogram()
        h.mark(0); h.breakSequence(); h.mark(5_000_000)
        assertEquals(0, h.summary().count)
    }

    @Test fun emptyWindow() {
        assertEquals(IntervalSummary.EMPTY, IntervalHistogram().summary())
    }

    @Test fun boundedSamplesKeepExactOverCount() {
        val h = IntervalHistogram(10)
        repeat(IntervalHistogram.MAX_SAMPLES + 100) { h.record(20) }
        val s = h.summary()
        assertEquals(IntervalHistogram.MAX_SAMPLES + 100, s.count)
        assertEquals(IntervalHistogram.MAX_SAMPLES + 100, s.overThreshold)
    }

    @Test fun statsWiresGaps() {
        val st = VideoStats()
        st.onReceived(10, nowUs = 0); st.onReceived(10, nowUs = 20_000); st.onReceived(5, nowUs = 25_000, isConfig = true)
        st.onOutput(1, 100_000); st.onOutput(2, 110_000)
        st.onShownPaced(null, 200_000_000L, 16_666_667L, 16_666_667L); st.onShownPaced(null, 217_000_000L, 16_666_667L, 16_666_667L)
        val s = st.snapshot(reset = true)
        assertEquals(1, s.network.count)
        assertEquals(1, s.network.overThreshold)
        assertEquals(10_000L, s.ready.p50Us)
        assertEquals(17_000L, s.shown.p50Us)
        assertEquals(0, st.snapshot().network.count)
    }
}

class PacerTest {
    private val ms = 1_000_000L
    private val period60 = 1_000_000_000L / 60

    private fun clock(hz: Float, startNs: Long = 0): VsyncClock = VsyncClock(hz).also { it.onVsync(startNs) }

    private fun feed(v: VsyncClock, fromNs: Long, deltaNs: Long, n: Int): Long {
        var t = fromNs
        repeat(n) { t += deltaNs; v.onVsync(t) }
        return t
    }

    @Test fun noSamplesMeansImmediate() {
        assertNull(AdaptivePacer(VsyncClock(60f), period60).schedule(0L, 1_000))
    }

    @Test fun reseedsFrom60To120AndBack() {
        val v = VsyncClock(60f)
        v.onVsync(0)
        var t = feed(v, 0, period60, 10)
        assertTrue(Math.abs(v.periodNs - period60) < 50_000)
        t = feed(v, t, 8_333_333L, VsyncClock.RESEED_AFTER + 1) // display switched to 120 Hz
        assertTrue("period ${v.periodNs}", Math.abs(v.periodNs - 8_333_333L) < 200_000)
        feed(v, t, period60, VsyncClock.RESEED_AFTER_MULTIPLE + 1) // and back to 60 Hz
        assertTrue("period ${v.periodNs}", Math.abs(v.periodNs - period60) < 200_000)
    }

    @Test fun reseedsFrom120To60() {
        val v = VsyncClock(120f)
        v.onVsync(0)
        feed(v, 0, period60, VsyncClock.RESEED_AFTER_MULTIPLE + 1) // gaps look like skipped callbacks, but persist
        assertTrue("period ${v.periodNs}", Math.abs(v.periodNs - period60) < 200_000)
    }

    @Test fun oneSkippedCallbackDoesNotReseed() {
        val v = VsyncClock(60f)
        v.onVsync(0)
        val t = feed(v, 0, period60, 5)
        v.onVsync(t + period60 * 3) // 2 callbacks skipped
        feed(v, t + period60 * 3, period60, 5)
        assertTrue(Math.abs(v.periodNs - period60) < 100_000)
    }

    @Test fun resetForgetsPhase() {
        val v = clock(60f)
        v.reset()
        assertFalse(v.hasSample)
    }

    @Test fun slotsLieOnTheMidPeriodGrid() {
        val v = clock(60f)
        assertEquals(period60 / 2, v.slotAtOrAfter(5 * ms, 0.5))
        assertEquals(period60 / 2 + period60, v.slotAtOrAfter(period60 / 2 + 1, 0.5))
    }

    @Test fun gapThresholdIsFollowedAndReported() {
        val h = IntervalHistogram()
        h.thresholdUs = 25_000
        h.record(20_000); h.record(30_000)
        val s = h.summary()
        assertEquals(1, s.overThreshold)
        assertEquals(25_000L, s.thresholdUs)
        assertTrue(StatsFormat.gaps("X", s).contains(">25.0:1"))
    }

    @Test fun paceAddIsAveragedPerWindow() {
        val st = VideoStats()
        st.onPaceAdd(10_000); st.onPaceAdd(20_000)
        assertEquals(15_000L, st.snapshot(reset = true).paceAddAvgUs)
        assertNull(st.snapshot().paceAddAvgUs)
    }
}

class DisplayModeTest {
    private val modes = listOf(
        DisplayModeInfo(1, 2800, 1840, 60f), DisplayModeInfo(2, 2800, 1840, 120f),
        DisplayModeInfo(3, 2800, 1840, 144f), DisplayModeInfo(4, 1400, 920, 120f),
    )

    @Test fun picksClosestAtCurrentResolution() {
        assertEquals(2, DisplayModePicker.pick(modes, modes[0], 120f)?.id)
        assertEquals(3, DisplayModePicker.pick(modes, modes[0], 144f)?.id)
        assertEquals(1, DisplayModePicker.pick(modes, modes[0], 50f)?.id)
    }

    @Test fun tieGoesToHigherRate() {
        assertEquals(2, DisplayModePicker.pick(modes, modes[0], 90f)?.id) // 60 and 120 are both 30 away
    }

    @Test fun zeroTargetLeavesModeAlone() {
        assertNull(DisplayModePicker.pick(modes, modes[0], 0f))
    }

    @Test fun overlayShowsModeBufferAndPercentiles() {
        val g = IntervalSummary(60, 16_700, 24_100, 40_200, 5)
        val snap = VideoStats.Snapshot(60, 59, 58, 2, 4_500, 1_250_000, 30_000, g, g, g)
        val text = StatsFormat.overlay(snap, 1000, 30_000, StatsFormat.pacingLine(120f))
        assertTrue(text.contains("Mod 120 Hz | Uyarlı"))
        assertTrue(text.contains("Ağ 16.7/24.1/40.2 ms >16.7:5"))
        assertTrue(text.contains("Gösterim"))
        assertEquals("net_p50_us=16700 net_p95_us=24100 net_p99_us=40200 net_over=5", StatsFormat.gapFields("net", g))
    }
}

class FrameRatePolicyTest {
    @Test fun modeTargetFollowsStreamFpsByDefault() {
        assertEquals(120, FrameRatePolicy.modeTargetHz(FrameRatePolicy.HZ_FOLLOW_STREAM, 120))
        assertEquals(60, FrameRatePolicy.modeTargetHz(FrameRatePolicy.HZ_FOLLOW_STREAM, 60))
        assertEquals(0, FrameRatePolicy.modeTargetHz(FrameRatePolicy.HZ_FOLLOW_STREAM, 0))
    }

    @Test fun modeTargetExplicitExtraWins() {
        assertEquals(0, FrameRatePolicy.modeTargetHz(0, 120))
        assertEquals(144, FrameRatePolicy.modeTargetHz(144, 60))
    }

    @Test fun surfaceRateFollowsStreamUnlessOverridden() {
        assertEquals(120, FrameRatePolicy.surfaceRate(-1, 120))
        assertEquals(60, FrameRatePolicy.surfaceRate(-1, 60))
        assertEquals(0, FrameRatePolicy.surfaceRate(0, 120))
        assertEquals(90, FrameRatePolicy.surfaceRate(90, 60))
    }

    @Test fun requestPicksModeForStreamFps() {
        val modes = listOf(DisplayModeInfo(1, 2800, 1840, 60f), DisplayModeInfo(2, 2800, 1840, 120f))
        assertEquals(1, DisplayModePicker.pick(modes, modes[1], FrameRatePolicy.modeTargetHz(-1, 60).toFloat())?.id)
        assertEquals(2, DisplayModePicker.pick(modes, modes[0], FrameRatePolicy.modeTargetHz(-1, 120).toFloat())?.id)
    }
}
