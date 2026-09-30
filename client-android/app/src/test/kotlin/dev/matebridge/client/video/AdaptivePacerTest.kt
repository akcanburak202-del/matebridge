package dev.matebridge.client.video

import dev.matebridge.client.stream.StatsFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AdaptivePacerTest {
    private val ms = 1_000_000L

    /** Result of a simulated run. */
    private class Sim(val skipPct: Double, val avgAddedNs: Double, val avgLatencyNs: Double, val collisions: Int, val frames: Int)

    private fun clock(periodNs: Long): VsyncClock {
        val hz = 1e9f / periodNs
        return VsyncClock(hz).also { it.onVsync(0) }
    }

    /**
     * Frames are captured every [fiNs]; each becomes ready at capture + [baseNs] + jitter in 0..[jitterNs]
     * (deterministic LCG) plus a rare stall. Display slot per frame comes from [pacer]. A skip is a slot gap of
     * more than 1.5 cadences between consecutive frames, measured like the on-screen result.
     */
    private fun simulate(
        pacer: AdaptivePacer?, periodNs: Long, fiNs: Long, jitterNs: Long, frames: Int = 1200,
        baseNs: Long = 20 * ms, stallEvery: Int = 0, feedback: Boolean = false,
    ): Sim {
        var seed = 12345L
        fun rnd(): Double { seed = (seed * 6364136223846793005L + 1442695040888963407L); return ((seed ushr 33) % 10_000) / 10_000.0 }
        val clk = clock(periodNs)
        val p = pacer ?: AdaptivePacer(clk)
        val pace = if (pacer == null) p else pacer
        var prevSlot = Long.MIN_VALUE
        var skipped = 0; var intervals = 0; var collisions = 0
        var added = 0.0; var latency = 0.0; var n = 0
        val cadence = Math.round(fiNs.toDouble() / periodNs).coerceAtLeast(1) * periodNs
        var windowSkips = 0; var windowIntervals = 0
        val readySlots = ArrayList<Long>()
        for (k in 0 until frames) {
            val cap = 1_000_000_000L + k * fiNs // host capture time (ns, host clock)
            val jitter = (rnd() * jitterNs).toLong() + (if (stallEvery > 0 && k % stallEvery == stallEvery - 1) 6 * ms else 0)
            val ready = cap + baseNs + jitter
            // The Choreographer follows the panel; keep the grid alive by feeding vsyncs up to now.
            val d = pace.schedule(cap / 1000, ready) ?: continue
            val slot = d.renderNs + periodNs / 2
            if (d.collided) collisions++
            added += d.addedNs; latency += slot - ready; n++
            if (prevSlot != Long.MIN_VALUE && slot != prevSlot) {
                intervals++; windowIntervals++
                if ((slot - prevSlot) * 2 > cadence * 3) { skipped++; windowSkips++ }
            }
            if (slot != prevSlot) prevSlot = slot
            readySlots.add(slot)
            if (feedback && windowIntervals >= 120) {
                pace.onSkipWindow(windowSkips * 100.0 / windowIntervals)
                windowSkips = 0; windowIntervals = 0
            }
        }
        return Sim(skipped * 100.0 / intervals.coerceAtLeast(1), added / n, latency / n, collisions, n)
    }

    /** Baseline: the old behavior, render at the next vsync after ready (fixed-offset grid mapping). */
    private fun naiveSkipPct(periodNs: Long, fiNs: Long, jitterNs: Long): Double {
        var seed = 12345L
        fun rnd(): Double { seed = (seed * 6364136223846793005L + 1442695040888963407L); return ((seed ushr 33) % 10_000) / 10_000.0 }
        var prev = Long.MIN_VALUE; var skipped = 0; var intervals = 0
        val cadence = Math.round(fiNs.toDouble() / periodNs).coerceAtLeast(1) * periodNs
        for (k in 0 until 1200) {
            val ready = 1_000_000_000L + k * fiNs + 20 * ms + (rnd() * jitterNs).toLong()
            val slot = (ready + periodNs - 1) / periodNs * periodNs
            if (prev != Long.MIN_VALUE && slot != prev) { intervals++; if ((slot - prev) * 2 > cadence * 3) skipped++ }
            if (slot > prev) prev = slot
        }
        return skipped * 100.0 / intervals
    }

    private val p120 = 1_000_000_000L / 120
    private val p60 = 1_000_000_000L / 60

    @Test fun noSamplesOrNoCaptureTimeMeansImmediate() {
        assertNull(AdaptivePacer(VsyncClock(60f)).schedule(1, 1_000_000))
        assertNull(AdaptivePacer(clock(p60)).schedule(null, 1_000_000))
    }

    @Test fun naiveMappingSkipsALotAt120Hz() {
        // Sanity check of the simulation: this is the ~21 percent behavior seen on the tablet.
        val pct = naiveSkipPct(p120, p120, 6 * ms)
        assertTrue("naive skip $pct", pct > 10.0)
    }

    @Test fun adaptive120At120HzNoSkipsAndLowLatency() {
        val r = simulate(null, p120, p120, 6 * ms, feedback = true)
        assertTrue("skip ${r.skipPct}", r.skipPct < 2.0)
        assertTrue("added ${r.avgAddedNs / ms}", r.avgAddedNs <= p120)
        assertEquals(0, r.collisions)
    }

    @Test fun adaptive60At60Hz() {
        val r = simulate(null, p60, p60, 6 * ms, feedback = true)
        assertTrue("skip ${r.skipPct}", r.skipPct < 2.0)
        assertTrue("added ${r.avgAddedNs / ms}", r.avgAddedNs <= p60)
    }

    @Test fun adaptive60FpsContentOn120Hz() {
        val r = simulate(null, p120, p60, 6 * ms, feedback = true)
        assertTrue("skip ${r.skipPct}", r.skipPct < 2.0)
        assertTrue("added ${r.avgAddedNs / ms}", r.avgAddedNs <= p120 * 2)
    }

    @Test fun rareStallsAreBoundedAndFeedbackHelps() {
        val r = simulate(null, p120, p120, 3 * ms, stallEvery = 40, feedback = true)
        // A 6 ms stall every 40 frames = 2.5 percent of frames are late; the loop must keep skips under 5 percent.
        assertTrue("skip ${r.skipPct}", r.skipPct < 5.0)
        assertTrue("added ${r.avgAddedNs / ms}", r.avgAddedNs <= 2 * p120)
    }

    @Test fun latencyDoesNotGrowOverTime() {
        // Clock drift and jitter must not accumulate a backlog: latency stays within D + 2 periods.
        val pacer = AdaptivePacer(clock(p120))
        val r = simulate(pacer, p120, p120, 5 * ms, frames = 6000)
        assertTrue("latency ${r.avgLatencyNs / ms}", r.avgLatencyNs < 12 * ms + 4 * p120)
    }

    @Test fun backlogBeyondLimitTakesThePreviousSlot() {
        val v = clock(p120)
        val pacer = AdaptivePacer(v)
        // Frames captured 8.33 ms apart but all ready at the same instant: a burst far exceeds the lag limit.
        var collided = 0
        for (k in 0 until 30) {
            val d = pacer.schedule(k * p120 / 1000, 1_000_000_000L)!!
            if (d.collided) collided++
        }
        assertTrue(collided > 0)
    }

    @Test fun panelRateChangeResetsState() {
        val v = VsyncClock(120f)
        var t = 0L
        v.onVsync(t)
        val pacer = AdaptivePacer(v)
        repeat(50) { k -> pacer.schedule(k * p120 / 1000, 1_000_000_000L + k * p120 + 20 * ms); t += p120; v.onVsync(t) }
        pacer.onSkipWindow(10.0)
        assertTrue(pacer.extraNs > 0)
        // Panel goes to 60 Hz: after the clock re-seeds, the pacer drops its stale feedback.
        repeat(VsyncClock.RESEED_AFTER + 1) { t += p60; v.onVsync(t) }
        assertEquals(p60, v.periodNs)
        assertNotNull(pacer.schedule(60 * p120 / 1000, 1_000_000_000L + 60 * p120 + 20 * ms))
        assertEquals(0L, pacer.extraNs)
    }

    @Test fun feedbackRaisesAndDecaysSlack() {
        val pacer = AdaptivePacer(clock(p120))
        pacer.schedule(0, 100)
        pacer.onSkipWindow(5.0)
        assertEquals(p120 / 4, pacer.extraNs)
        pacer.onSkipWindow(5.0)
        assertEquals(p120 / 2, pacer.extraNs)
        repeat(AdaptivePacer.QUIET_WINDOWS) { pacer.onSkipWindow(0.0) }
        assertEquals(p120 / 2 - p120 / 8, pacer.extraNs)
        pacer.onSkipWindow(null)
        assertEquals(p120 / 2 - p120 / 8, pacer.extraNs)
        repeat(20) { pacer.onSkipWindow(50.0) }
        assertTrue(pacer.extraNs in 2 * p120 - 8..2 * p120) // capped
    }
}

class PresentMeterTest {
    private val p = 8_333_333L

    @Test fun regularIntervalsHaveNoSkips() {
        val m = PresentMeter()
        for (k in 0 until 100) m.onShown(k * p - p, k * p, p, p)
        val s = m.snapshot()
        assertEquals(99, s.intervals)
        assertEquals(0.0, s.skipPct!!, 0.0)
    }

    @Test fun skipCountedOnlyWhenFrameWasReady() {
        val m = PresentMeter()
        m.onShown(0, 0, p, p)
        m.onShown(p / 2, 2 * p, p, p) // ready before the skipped vsync: skip
        m.onShown(10 * p, 4 * p, p, p) // gap 2p but the frame became ready much later: idle source, no skip
        val s = m.snapshot(reset = true)
        assertEquals(2, s.intervals)
        assertEquals(1, s.skipped)
        assertNull(m.snapshot().skipPct)
    }

    @Test fun cadenceOfTwoPeriodsIsNotASkip() {
        val m = PresentMeter()
        for (k in 0 until 10) m.onShown(k * 2 * p - p, k * 2 * p, p, 2 * p)
        assertEquals(0, m.snapshot().skipped)
    }

    @Test fun breakSequenceIgnoresTheGap() {
        val m = PresentMeter()
        m.onShown(0, 0, p, p); m.breakSequence(); m.onShown(0, 100 * p, p, p)
        assertEquals(0, m.snapshot().intervals)
    }

    @Test fun statsExposeSkipPctAndOverlay() {
        val st = VideoStats()
        st.onShownPaced(0, 0, p, p); st.onShownPaced(0, 2 * p, p, p); st.onShownPaced(2 * p, 3 * p, p, p)
        val snap = st.snapshot(reset = true)
        assertEquals(50.0, snap.skipPct!!, 0.0)
        assertNull(st.snapshot().skipPct)
        val line = StatsFormat.pacingLine(120f, -1, 4_000, 1.5)
        assertTrue(line, line.contains("Uyarlı") && line.contains("%1.5"))
    }
}

class OperatingRateTest {
    @Test fun policies() {
        assertEquals(120, OperatingRate.resolve(OperatingRate.STREAM_FPS, 120))
        assertEquals(Short.MAX_VALUE.toInt(), OperatingRate.resolve(OperatingRate.MAX, 120))
        assertNull(OperatingRate.resolve(OperatingRate.OFF, 120))
        assertEquals(90, OperatingRate.resolve(90, 120))
        assertNull(OperatingRate.resolve(OperatingRate.STREAM_FPS, 0))
    }

    @Test fun decodeLatencyPercentilesInStats() {
        val st = VideoStats()
        for (i in 1..100) { st.onInput(i.toLong(), 0); st.onOutput(i.toLong(), i * 1000L) }
        val s = st.snapshot(reset = true)
        assertEquals(100, s.decode.count)
        assertEquals(50_000L, s.decode.p50Us)
        assertEquals(95_000L, s.decode.p95Us)
        assertEquals(0, st.snapshot().decode.count)
    }
}
