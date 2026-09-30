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
        val p = pacer ?: AdaptivePacer(clk, fiNs)
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
        repeat(AdaptivePacer.HIGH_WINDOWS) { pacer.onSkipWindow(10.0) }
        assertTrue(pacer.extraNs > 0)
        // Panel goes to 60 Hz: after the clock re-seeds, the pacer drops its stale feedback.
        repeat(VsyncClock.RESEED_AFTER_MULTIPLE + 1) { t += p60; v.onVsync(t) }
        assertEquals(p60, v.periodNs)
        assertNotNull(pacer.schedule(60 * p120 / 1000, 1_000_000_000L + 60 * p120 + 20 * ms))
        assertEquals(0L, pacer.extraNs)
    }

    @Test fun feedbackRaisesAndDecaysSlack() {
        val pacer = AdaptivePacer(clock(p120))
        pacer.schedule(0, 100)
        // Two high windows are not enough (needs HIGH_WINDOWS in a row).
        repeat(AdaptivePacer.HIGH_WINDOWS - 1) { pacer.onSkipWindow(5.0) }
        assertEquals(0, pacer.level)
        pacer.onSkipWindow(1.5) // in between: resets the run
        repeat(AdaptivePacer.HIGH_WINDOWS - 1) { pacer.onSkipWindow(5.0) }
        assertEquals(0, pacer.level)
        pacer.onSkipWindow(5.0)
        assertEquals(1, pacer.level)
        // Hold: no further change during HOLD_WINDOWS even when skips stay high.
        repeat(AdaptivePacer.HOLD_WINDOWS - 1) { pacer.onSkipWindow(50.0) }
        assertEquals(1, pacer.level)
        repeat(AdaptivePacer.HIGH_WINDOWS + 1) { pacer.onSkipWindow(50.0) }
        assertEquals(2, pacer.level)
        repeat(100) { pacer.onSkipWindow(50.0) }
        assertEquals(AdaptivePacer.MAX_LEVEL, pacer.level) // capped
        pacer.onSkipWindow(null)
        assertEquals(AdaptivePacer.MAX_LEVEL, pacer.level)
        // Back down only after a long quiet stretch, one level at a time.
        repeat(AdaptivePacer.LOW_WINDOWS) { pacer.onSkipWindow(0.0) }
        assertEquals(1, pacer.level)
        repeat(AdaptivePacer.HOLD_WINDOWS - 1) { pacer.onSkipWindow(0.0) }
        assertEquals(1, pacer.level) // held
        pacer.onSkipWindow(0.0)
        assertEquals(0, pacer.level)
    }

    @Test fun decodeJitter3msAt120HzSettlesAtOneVsyncWithoutFlapping() {
        val pacer = AdaptivePacer(clock(p120), p120)
        var seed = 99L
        fun rnd(): Double { seed = seed * 6364136223846793005L + 1442695040888963407L; return ((seed ushr 33) % 10_000) / 10_000.0 }
        var changes = 0; var lastLevel = 0; var skips = 0; var scheduled = 0; var added = 0.0
        var windowSkips = 0; var windowN = 0
        val frames = 120 * 60 // one minute
        for (k in 0 until frames) {
            val cap = 1_000_000_000L + k * p120
            val ready = cap + 9 * ms + (rnd() * 3 * ms).toLong() // decode ~9-12 ms, 3 ms jitter
            val d = pacer.schedule(cap / 1000, ready)!!
            scheduled++; windowN++
            added += d.addedNs
            if (d.skipped) { skips++; windowSkips++ }
            if (windowN == 120) {
                pacer.onSkipWindow(windowSkips * 100.0 / windowN)
                windowN = 0; windowSkips = 0
                if (pacer.level != lastLevel) { changes++; lastLevel = pacer.level }
            }
        }
        assertEquals("level changes", 0, changes)
        assertTrue("skips ${skips * 100.0 / scheduled}", skips * 100.0 / scheduled < 1.0)
        // D stays within one vsync: measured jitter (3 ms) plus the margin.
        assertTrue("D ${pacer.lastDNs / ms.toDouble()}", pacer.lastDNs <= p120)
        assertTrue("added ${added / scheduled / ms}", added / scheduled <= p120)
    }

    @Test fun fasterContentThanPanelDropsInsteadOfQueueing() {
        // 120 fps stream on a 60 Hz panel (Huawei drops the panel rate when nobody touches it).
        val clk = clock(p60)
        val pacer = AdaptivePacer(clk, p120)
        var seed = 7L
        fun rnd(): Double { seed = seed * 6364136223846793005L + 1442695040888963407L; return ((seed ushr 33) % 10_000) / 10_000.0 }
        var collisions = 0; var skips = 0; var maxD = 0L; var latencySum = 0.0; var maxLatency = 0L; val n = 120 * 30
        var prevSlot = Long.MIN_VALUE
        for (k in 0 until n) {
            val cap = 1_000_000_000L + k * p120
            val ready = cap + 9 * ms + (rnd() * 3 * ms).toLong()
            val d = pacer.schedule(cap / 1000, ready)!!
            if (d.collided) collisions++
            if (d.skipped) skips++
            maxD = maxOf(maxD, pacer.lastDNs)
            val slot = d.renderNs + p60 / 2
            val lat = slot - ready
            latencySum += lat; maxLatency = maxOf(maxLatency, lat)
            // Slots never run backwards and never queue more than one period ahead of the earliest vsync.
            assertTrue(prevSlot == Long.MIN_VALUE || slot >= prevSlot)
            prevSlot = slot
            assertTrue("added ${d.addedNs}", d.addedNs <= p60 + AdaptivePacer.MARGIN_NS + 3 * ms)
        }
        val dropPct = collisions * 100.0 / n
        assertTrue("drops $dropPct", dropPct in 40.0..60.0)
        assertTrue("D ${maxD / ms.toDouble()}", maxD <= p60 + AdaptivePacer.MARGIN_NS)
        assertTrue("latency ${latencySum / n / ms}", latencySum / n <= 2 * p60)
        assertTrue("max latency ${maxLatency / ms}", maxLatency <= 3 * p60)
        assertEquals("intentional drops are not skips", 0, skips)
    }

    @Test fun panelSwitch120To60AndBackResetsSlack() {
        val v = VsyncClock(120f).also { it.onVsync(0) }
        val pacer = AdaptivePacer(v, p120)
        var k = 0
        fun run(frames: Int) { repeat(frames) { val cap = 1_000_000_000L + k * p120; pacer.schedule(cap / 1000, cap + 9 * ms + (k % 3) * ms); k++ } }
        run(200)
        repeat(AdaptivePacer.HIGH_WINDOWS) { pacer.onSkipWindow(20.0) }
        assertEquals(1, pacer.level)
        // Panel drops to 60 Hz (display listener reseeds the clock at once): level and stale jitter data are dropped.
        v.setNominalHz(60f)
        run(1)
        assertEquals(0, pacer.level)
        run(120)
        assertTrue("D at 60 Hz ${pacer.lastDNs / ms.toDouble()}", pacer.lastDNs <= p60 + AdaptivePacer.MARGIN_NS)
        // ...and back to 120 Hz: base D again (jitter ~2 ms + margin), not a leftover of the 60 Hz regime.
        v.setNominalHz(120f)
        run(200)
        assertEquals(0, pacer.level)
        assertTrue("D at 120 Hz ${pacer.lastDNs / ms.toDouble()}", pacer.lastDNs <= p120)
    }

    @Test fun idleSourceGapIsNotASkip() {
        val pacer = AdaptivePacer(clock(p120), p120)
        pacer.schedule(0, 1_000_000_000L + 20 * ms)
        // Host sends nothing for 100 ms (static screen): the next frame is on time for its own capture time.
        val cap = 100 * ms
        val d = pacer.schedule(cap / 1000, 1_000_000_000L + cap + 20 * ms)!!
        assertEquals(false, d.skipped)
    }

    @Test fun lateFrameIsASkip() {
        val pacer = AdaptivePacer(clock(p120), p120)
        for (k in 0 until 40) pacer.schedule(k * p120 / 1000, 1_000_000_000L + k * p120 + 20 * ms)
        // One frame 3 vsyncs late, arriving after its slot and the next one.
        val k = 40
        val d = pacer.schedule(k * p120 / 1000, 1_000_000_000L + k * p120 + 20 * ms + 3 * p120)!!
        assertTrue(d.skipped)
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
