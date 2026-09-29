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

    private fun feed(v: VsyncClock, fromNs: Long, deltaNs: Long, n: Int): Long {
        var t = fromNs
        repeat(n) { t += deltaNs; v.onVsync(t) }
        return t
    }

    @Test fun noSamplesMeansImmediate() {
        assertNull(FramePacer(VsyncClock(60f), 1, period60).schedule(1_000))
    }

    @Test fun reseedsFrom60To120AndBack() {
        val v = VsyncClock(60f)
        v.onVsync(0)
        var t = feed(v, 0, period60, 10)
        assertTrue(Math.abs(v.periodNs - period60) < 50_000)
        t = feed(v, t, 8_333_333L, VsyncClock.RESEED_AFTER + 1) // display switched to 120 Hz
        assertTrue("period ${v.periodNs}", Math.abs(v.periodNs - 8_333_333L) < 200_000)
        feed(v, t, period60, VsyncClock.RESEED_AFTER + 1) // and back to 60 Hz
        assertTrue("period ${v.periodNs}", Math.abs(v.periodNs - period60) < 200_000)
    }

    @Test fun reseedsFrom120To60() {
        val v = VsyncClock(120f)
        v.onVsync(0)
        feed(v, 0, period60, VsyncClock.RESEED_AFTER + 1) // gaps look like skipped callbacks, but persist
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

    @Test fun bufferOnePresentsOneVsyncAfterTheEarliest() {
        val pacer = FramePacer(clock(60f), 1, period60)
        val d = pacer.schedule(1 * ms)!!
        assertFalse(d.collided)
        assertEquals(period60, d.addedNs) // earliest vsync is period60, V is one period later
        assertEquals(2 * period60 - period60 / 2, d.renderNs)
    }

    @Test fun addedLatencyStaysWithinOneVsyncPlusHalfAFrame() {
        for (hz in listOf(60f, 120f)) {
            val v = clock(hz)
            val pacer = FramePacer(v, 1, period60)
            var t = 0L
            var seed = 12345L
            repeat(500) {
                seed = (seed * 1103515245 + 12345) and 0x7fffffff
                t += period60 + (seed % (12 * ms)) - 6 * ms // 60 fps with +-6 ms arrival jitter
                val d = pacer.schedule(t)!!
                assertTrue("hz=$hz added=${d.addedNs}", d.addedNs <= v.periodNs + period60 / 2)
            }
        }
    }

    @Test fun cadenceKeepsTwoVsyncsAt120HzWhenDebtIsSmall() {
        val v = clock(120f)
        val pacer = FramePacer(v, 1, period60)
        val a = pacer.schedule(0)!!
        val b = pacer.schedule(4 * ms)!!
        assertFalse(b.collided)
        assertEquals(2 * v.periodNs, b.renderNs - a.renderNs)
    }

    @Test fun burstCollidesOnTheSameSlotAndRecovers() {
        val pacer = FramePacer(clock(60f), 1, period60)
        val a = pacer.schedule(0)!!
        val b = pacer.schedule(0)!! // debt of a full frame: re-anchored onto a's slot
        assertTrue(b.collided)
        assertEquals(a.renderNs, b.renderNs)
        val late = pacer.schedule(1_000 * ms)!!
        assertFalse(late.collided)
    }

    @Test fun cadenceDebtDoesNotAccumulate() {
        val v = clock(60f)
        val pacer = FramePacer(v, 1, period60)
        var t = 0L
        var maxAdded = 0L
        repeat(300) { // source 2% faster than the display cadence
            t += period60 * 98 / 100
            val d = pacer.schedule(t)!!
            maxAdded = maxOf(maxAdded, d.addedNs)
        }
        assertTrue("added=$maxAdded", maxAdded <= v.periodNs + period60 / 2)
    }

    @Test fun bufferIsClampedToTwo() {
        val v = clock(60f)
        val a = FramePacer(v, 5, period60).schedule(0)!!
        val b = FramePacer(v, 2, period60).schedule(0)!!
        assertEquals(b.renderNs, a.renderNs)
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
        val text = StatsFormat.overlay(snap, 1000, 30_000, StatsFormat.pacingLine(120f, 1))
        assertTrue(text.contains("Mod 120 Hz | Tampon 1"))
        assertTrue(text.contains("Ağ 16.7/24.1/40.2 ms >16.7:5"))
        assertTrue(text.contains("Gösterim"))
        assertEquals("net_p50_us=16700 net_p95_us=24100 net_p99_us=40200 net_over=5", StatsFormat.gapFields("net", g))
    }
}
