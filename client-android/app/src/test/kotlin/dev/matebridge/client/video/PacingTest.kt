package dev.matebridge.client.video

import dev.matebridge.client.stream.DisplayModeInfo
import dev.matebridge.client.stream.DisplayModePicker
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
        st.onShown(200_000); st.onShown(217_000)
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

    @Test fun noSamplesMeansImmediate() {
        assertNull(FramePacer(VsyncClock(60f), 1, period60).schedule(1_000))
    }

    @Test fun periodIgnoresOutOfRangeAndSkippedCallbacks() {
        val v = VsyncClock(60f)
        var t = 0L
        repeat(10) { v.onVsync(t); t += 8_333_333L } // 120 Hz samples while nominal is 60: ignored
        assertEquals(period60, v.periodNs)
        val v2 = VsyncClock(60f)
        v2.onVsync(0); v2.onVsync(period60); v2.onVsync(period60 * 4) // 2 callbacks skipped
        assertTrue(Math.abs(v2.periodNs - period60) < 100_000)
        v.setNominalHz(120f)
        assertEquals(8_333_333L, v.periodNs)
    }

    @Test fun slotsLieOnTheMidPeriodGrid() {
        val v = clock(60f)
        assertEquals(period60 / 2, v.slotAtOrAfter(5 * ms, 0.5))
        assertEquals(period60 / 2 + period60, v.slotAtOrAfter(period60 / 2 + 1, 0.5))
    }

    @Test fun bufferDelaysByContentFramesAndKeepsCadence() {
        val pacer = FramePacer(clock(60f), 1, period60)
        val a = pacer.schedule(1 * ms)!!
        assertFalse(a.collided)
        assertTrue(a.renderNs >= 1 * ms + period60)
        val b = pacer.schedule(1 * ms)!! // same instant: one cadence step later, not the same slot
        assertEquals(a.renderNs + period60, b.renderNs)
    }

    @Test fun cadenceIsTwoVsyncsAt120HzFor60FpsContent() {
        val v = clock(120f)
        val pacer = FramePacer(v, 1, period60)
        val a = pacer.schedule(0)!!
        val b = pacer.schedule(0)!!
        assertEquals(2 * v.periodNs, b.renderNs - a.renderNs)
    }

    @Test fun backlogIsBoundedAndNewestSharesTheSlot() {
        val pacer = FramePacer(clock(60f), 1, period60)
        pacer.schedule(0)
        val second = pacer.schedule(0)!!
        assertFalse(second.collided)
        val third = pacer.schedule(0)!! // would be 2 frames beyond the base
        assertTrue(third.collided)
        assertEquals(second.renderNs, third.renderNs)
    }

    @Test fun recoversAfterAGap() {
        val pacer = FramePacer(clock(60f), 2, period60)
        pacer.schedule(0)
        val late = pacer.schedule(1_000 * ms)!!
        assertFalse(late.collided)
        assertTrue(late.renderNs >= 1_000 * ms + 2 * period60)
    }

    @Test fun bufferIsClampedToTwo() {
        val v = clock(60f)
        val a = FramePacer(v, 5, period60).schedule(0)!!
        val b = FramePacer(v, 2, period60).schedule(0)!!
        assertEquals(b.renderNs, a.renderNs)
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
        val text = StatsFormat.overlay(snap, 1000, 30_000, StatsFormat.pacingLine(120f, 1))
        assertTrue(text.contains("Mod 120 Hz | Tampon 1"))
        assertTrue(text.contains("Ağ 16.7/24.1/40.2 ms >16.7:5"))
        assertTrue(text.contains("Gösterim"))
        assertEquals("net_p50_us=16700 net_p95_us=24100 net_p99_us=40200 net_over=5", StatsFormat.gapFields("net", g))
    }
}
