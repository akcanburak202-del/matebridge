package dev.matebridge.client.video

import dev.matebridge.client.stream.DisplayRateDebouncer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-141: the vsync loop sleeps without frames, wakes on the next one, and the first frame after a sleep is not held. */
class VsyncIdleTest {
    private val ms = 1_000_000L
    private val idle = VsyncIdleGate.DEFAULT_IDLE_AFTER_NS

    @Test fun keepsRunningWhileFramesFlowAndSleepsAfterTheThreshold() {
        val g = VsyncIdleGate()
        g.start(0)
        // 10 fps (100 ms gaps) for 2 s at 120 Hz: never asleep.
        var t = 0L
        var nextFrame = 0L
        var last = 0L
        while (t < 2_000 * ms) {
            if (t >= nextFrame) { g.onActivity(t); last = t; nextFrame += 100 * ms }
            assertTrue("asleep at $t", g.onVsync(t))
            t += 8_333_333L
        }
        // Awake until the threshold after the last frame, asleep at the first vsync past it.
        assertTrue(g.onVsync(last + idle - 1))
        assertFalse(g.onVsync(last + idle))
        assertTrue(g.isAsleep)
    }

    @Test fun firstActivityWhileAsleepRequestsExactlyOneWake() {
        val g = VsyncIdleGate()
        g.start(0)
        assertFalse(g.onVsync(idle))
        assertTrue(g.onActivity(idle + 10 * ms))
        assertFalse("one wake per sleep", g.onActivity(idle + 11 * ms))
        val w = g.wake(idle + 12 * ms)
        assertNotNull(w)
        assertEquals(12 * ms, w!!.sleptNs)
        assertFalse(g.isAsleep)
        assertNull("not asleep any more", g.wake(idle + 13 * ms))
        assertFalse("awake: no wake request", g.onActivity(idle + 14 * ms))
        // Next sleep: a wake can be requested again.
        assertFalse(g.onVsync(idle + 14 * ms + idle))
        assertTrue(g.onActivity(idle + 14 * ms + idle + 1))
    }

    @Test fun activityNextToFallingAsleepIsNeverLost() {
        val g = VsyncIdleGate()
        g.start(0)
        // A frame written before the vsync's check: the loop stays awake.
        g.onActivity(idle)
        assertTrue(g.onVsync(idle))
        assertFalse(g.isAsleep)
        // A frame written after the loop fell asleep sees the flag and requests a wake.
        assertFalse(g.onVsync(2 * idle))
        assertTrue(g.onActivity(2 * idle + 1))
    }

    @Test fun framesFromAnotherThreadAlwaysGetTheLoopRunningAgain() {
        // Reader thread: bursts of frames with pauses; loop thread: vsyncs, sleeps, and wakes only when asked (as the
        // activity does with its posted runnable). Every burst must find the loop awake or get a wake request.
        val g = VsyncIdleGate(idleAfterNs = 200_000L) // 0.2 ms: many sleeps and races
        g.start(System.nanoTime())
        val wakeAsked = java.util.concurrent.atomic.AtomicBoolean(false)
        val done = java.util.concurrent.atomic.AtomicBoolean(false)
        val reader = Thread {
            repeat(300) {
                val until = System.nanoTime() + 300_000L
                while (System.nanoTime() < until) Thread.onSpinWait()
                repeat(20) { if (g.onActivity(System.nanoTime())) wakeAsked.set(true) }
            }
            done.set(true) // right after the last burst
        }
        reader.start()
        while (true) {
            val finished = done.get() // read first: everything the reader did is visible below
            if (g.isAsleep) {
                if (wakeAsked.getAndSet(false)) { g.wake(System.nanoTime()); continue }
                if (finished) {
                    // Asleep with no wake pending after the last frame: legit only if the loop fell asleep at least the
                    // threshold after that frame. A lost wake would leave it asleep with a fresh, unseen frame.
                    assertTrue(g.sinceActivityNs(System.nanoTime()) >= 200_000L)
                    break
                }
            } else {
                g.onVsync(System.nanoTime())
            }
        }
        reader.join()
    }

    @Test fun stopClearsSleepSoNoWakeIsRequested() {
        val g = VsyncIdleGate()
        g.start(0)
        assertFalse(g.onVsync(idle))
        g.stop()
        assertFalse(g.onActivity(idle + 1))
        assertNull(g.wake(idle + 2))
    }

    @Test fun rateReportsWaitForFreshVsyncsAfterAWakeButNotAtStart() {
        val g = VsyncIdleGate()
        g.start(0)
        assertTrue("start: report at once (as before)", g.rateReady)
        assertFalse(g.onVsync(idle))
        assertFalse("asleep", g.rateReady)
        g.onActivity(idle + ms)
        g.wake(idle + ms)
        var t = idle + ms
        repeat(VsyncIdleGate.RATE_VSYNCS_AFTER_WAKE) {
            assertFalse(g.rateReady)
            t += 8 * ms
            g.onVsync(t)
        }
        assertTrue(g.rateReady)
    }

    @Test fun idleLineOncePerLongSleepAndOffOnlyAfterOn() {
        val g = VsyncIdleGate()
        g.start(0)
        assertFalse(g.idleLogDue(0))
        assertFalse(g.onVsync(idle))
        assertFalse("short sleep: no line yet", g.idleLogDue(idle + 500 * ms))
        // Woken before a second: no on, so no off either.
        g.onActivity(idle + 600 * ms)
        assertFalse(g.wake(idle + 600 * ms)!!.idleLogged)
        // Long sleep.
        val s = idle + 600 * ms + idle
        assertFalse(g.onVsync(s))
        assertTrue(g.idleLogDue(s + VsyncIdleGate.DEFAULT_LOG_AFTER_NS))
        assertFalse("once", g.idleLogDue(s + 2 * VsyncIdleGate.DEFAULT_LOG_AFTER_NS))
        g.onActivity(s + 5_000 * ms)
        val w = g.wake(s + 5_000 * ms)!!
        assertTrue(w.idleLogged)
        assertEquals(5_000 * ms, w.sleptNs)
    }

    @Test fun decoderWaitsGrowOnlyWhenIdle() {
        assertEquals(4 * ms, IdleWait.waitNs(0, 4 * ms))
        assertEquals(4 * ms, IdleWait.waitNs(idle - 1, 4 * ms))
        assertEquals(IdleWait.IDLE_WAIT_NS, IdleWait.waitNs(idle, 4 * ms))
        assertEquals(IdleWait.IDLE_WAIT_NS, IdleWait.waitNs(60_000 * ms, 5 * ms))
    }

    /**
     * Activity loop as MainActivity runs it: on sleep the clock is reset (phase forgotten, period kept). The first frame
     * after the sleep must be presented at once (no grid), and once the woken loop has a fresh vsync the next frame gets a
     * slot on the new grid, never one in the past.
     */
    @Test fun firstFrameAfterSleepIsPresentedAtOnceThenPacedOnTheFreshGrid() {
        val period = 8_333_333L
        val clk = VsyncClock(120f).also { it.setDisplayTiming(0, 13_330_000L) }
        val gate = VsyncIdleGate()
        val adaptive = AdaptivePacer(clk, period)
        val fixed = FramePacer(clk, 1, period)
        var vs = 0L
        gate.start(0)
        // Streaming: 60 frames, one per period, with vsyncs.
        for (k in 0 until 60) {
            vs += period
            clk.onVsync(vs)
            gate.onActivity(vs)
            assertTrue(gate.onVsync(vs))
            assertNotNull(adaptive.schedule(vs / 1000 - 20_000, vs + 2 * ms))
        }
        val periodBefore = clk.periodNs
        // No frames: the loop keeps ticking until the threshold, then sleeps and the clock forgets its phase.
        while (true) {
            vs += period
            clk.onVsync(vs)
            if (!gate.onVsync(vs)) { clk.reset(); break }
        }
        assertFalse(clk.hasSample)
        assertEquals("panel rate kept while idle", periodBefore, clk.periodNs)
        // 5 s later a frame arrives (the clock's old phase would have drifted): presented at once.
        val arrive = vs + 5_000 * ms + 3_141_592L
        assertTrue(gate.onActivity(arrive))
        assertNull("adaptive: no grid, present now", adaptive.schedule(arrive / 1000 - 20_000, arrive + 10 * ms))
        assertNull("fixed buffer: no grid, present now", fixed.schedule(arrive + 10 * ms))
        // The woken loop's first vsync re-anchors the grid; the next frame lands on a future slot of it.
        assertNotNull(gate.wake(arrive + 1 * ms))
        val firstVsync = arrive + 4 * ms
        clk.onVsync(firstVsync)
        val ready = firstVsync + 9 * ms
        val d = adaptive.schedule(ready / 1000 - 20_000, ready)!!
        assertTrue("slot ${d.slotNs} not before ready $ready", d.slotNs >= ready)
        assertEquals("slot on the fresh grid", 0L, Math.floorMod(d.slotNs - firstVsync, clk.periodNs))
        val f = fixed.schedule(ready)!!
        assertTrue(f.slotNs >= ready)
        assertEquals(0L, Math.floorMod(f.slotNs - firstVsync, clk.periodNs))
    }

    /**
     * Review P2, surface path: the woken loop delivers a vsync BEFORE the first frame is decoded (the activity posts the
     * wake before feeding the decoder, or pointer input woke it earlier). The clock has a sample again, yet the first
     * output after the sleep must still go out at once; the next one is paced normally.
     */
    @Test fun firstOutputAfterSleepIsImmediateEvenWhenTheClockRestartedFirst() {
        val period = 8_333_333L
        val clk = VsyncClock(120f).also { it.setDisplayTiming(0, 13_330_000L) }
        val gate = VsyncIdleGate()
        val bypass = FirstOutputBypass()
        val adaptive = AdaptivePacer(clk, period)
        val fixed = FramePacer(clk, 1, period)
        val cpd = ConstantPlayoutPacer(clk, CpdConfig(), period)
        var vs = 0L
        gate.start(0)
        for (k in 0 until 30) { vs += period; clk.onVsync(vs); gate.onActivity(vs); assertTrue(gate.onVsync(vs)) }
        while (true) { vs += period; clk.onVsync(vs); if (!gate.onVsync(vs)) { bypass.arm(); clk.reset(); break } }

        for (case in 0 until 3) {
            if (case > 0) bypass.arm() // next sleep
            // Input (or the frame's own posted wake) restarts the loop, and a vsync comes before the decoded output.
            val t = vs + (case + 1) * 2_000 * ms
            gate.onActivity(t)
            gate.wake(t)
            clk.onVsync(t + 3 * ms)
            assertTrue("the clock restarted first", clk.hasSample)
            val ready = t + 12 * ms
            // Without the bypass this output would be paced (the clock-only approach would hold it).
            val unbypassed = when (case) {
                0 -> AdaptivePacer(clk, period).schedule(ready / 1000 - 20_000, ready)
                1 -> FramePacer(clk, 1, period).schedule(ready)
                else -> ConstantPlayoutPacer(clk, CpdConfig(), period).schedule(ready / 1000 - 20_000, ready)
            }
            assertNotNull("case $case: paced without the bypass", unbypassed)
            val first = bypass.schedule {
                when (case) {
                    0 -> adaptive.schedule(ready / 1000 - 20_000, ready)
                    1 -> fixed.schedule(ready)
                    else -> cpd.schedule(ready / 1000 - 20_000, ready)
                }
            }
            assertNull("case $case: first output after the sleep released at once", first)
            assertFalse(bypass.isArmed)
            // The next output is paced on the fresh grid.
            val ready2 = ready + period
            val second = bypass.schedule { fixed.schedule(ready2) }
            assertNotNull(second)
            assertTrue(second!!.slotNs >= ready2)
            clk.reset()
        }
    }

    @Test fun bypassIsTakenOnceAndDisarmedByAStreamStart() {
        val b = FirstOutputBypass()
        val paced = FramePacer.Decision(1, false, 0)
        assertNotNull("not armed: normal scheduling", b.schedule { paced })
        b.arm()
        assertTrue(b.take())
        assertFalse(b.take())
        b.arm()
        b.disarm()
        assertNotNull(b.schedule { paced })
        // Taken from another thread exactly once.
        b.arm()
        val hits = java.util.concurrent.atomic.AtomicInteger()
        val ts = List(4) { Thread { repeat(1000) { if (b.take()) hits.incrementAndGet() } } }
        ts.forEach { it.start() }; ts.forEach { it.join() }
        assertEquals(1, hits.get())
    }

    /**
     * Review P2, GL path model (GlPresenter, one GL thread): on sleep the bypass is armed; the first frame-available
     * after it presents at once whether the loop is still asleep or already running, then later frames wait for vsync.
     */
    @Test fun glFirstFrameAfterSleepIsDrawnOnArrival() {
        val gate = VsyncIdleGate()
        val first = FirstOutputBypass()
        var loopRunning = true
        var drawnOnArrival = 0
        fun onFrameAvailable(t: Long) {
            val wakeAsked = gate.onActivity(t)
            if (first.take() || wakeAsked) { gate.wake(t); drawnOnArrival++; loopRunning = true }
        }
        gate.start(0)
        assertFalse(gate.onVsync(idle))
        loopRunning = false; first.arm()
        onFrameAvailable(idle + 50 * ms)
        assertEquals(1, drawnOnArrival)
        assertTrue(loopRunning)
        onFrameAvailable(idle + 58 * ms) // the loop runs: this one waits for its vsync
        assertEquals(1, drawnOnArrival)
        // Asleep again, and the loop got going before the frame (not by a frame): still drawn on arrival.
        assertFalse(gate.onVsync(idle + 58 * ms + idle))
        loopRunning = false; first.arm()
        gate.wake(idle + 58 * ms + idle + ms); loopRunning = true
        onFrameAvailable(idle + 58 * ms + idle + 5 * ms)
        assertEquals(2, drawnOnArrival)
    }

    @Test fun debouncerPauseKeepsReportedValueAndRestartsAPendingFall() {
        val d = DisplayRateDebouncer()
        assertEquals(120, d.observe(120, 0))
        assertNull(d.observe(60, 1_000)) // fall candidate starts
        d.onPause() // loop sleeps 10 s
        assertEquals(120, d.current)
        assertNull("no stale fall right after the pause", d.observe(60, 11_000))
        assertNull(d.observe(60, 11_400))
        assertEquals(60, d.observe(60, 11_500))
        // A rise after a pause still goes out at once.
        d.onPause()
        assertEquals(120, d.observe(120, 20_000))
        assertNull("same value: nothing", d.observe(120, 21_000))
    }
}
