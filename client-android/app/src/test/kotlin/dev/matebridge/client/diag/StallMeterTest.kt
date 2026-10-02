package dev.matebridge.client.diag

import dev.matebridge.client.diag.StallMeter.Companion.NONE
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StallMeterTest {
    private val ms = 1_000_000L // ns
    private val t0 = 10_000 * ms
    private val rt0 = 50_000 * ms // realtime runs ahead of uptime by 40 s (earlier suspends)

    /** Fake clock: uptime [now] and realtime = uptime + [offset]. */
    private inner class Clock(var now: Long = t0, var offset: Long = rt0 - t0)

    private fun started(c: Clock = Clock()) = StallMeter().also { it.start(c.now, c.now + c.offset) }

    /** Wakes [lateNs] after the next deadline. */
    private fun StallMeter.tick(c: Clock, lateNs: Long = 0): Boolean {
        c.now = nextDeadlineNs() + lateNs
        return onTick(c.now, c.now + c.offset)
    }

    private fun StallMeter.window() = StallMeter.Window().also { takeWindow(it) }

    @Test fun onTimeTicksFollowThePeriod() {
        val c = Clock()
        val m = started(c)
        assertEquals(t0 + 5 * ms, m.nextDeadlineNs())
        for (i in 0 until 200) assertFalse(m.tick(c, lateNs = 100_000))
        assertEquals(t0 + 201 * 5 * ms, m.nextDeadlineNs()) // a small lateness does not shift the schedule
        val w = m.window()
        assertEquals(200, w.ticks)
        assertEquals(100, w.lateMaxUs)
        assertEquals(0, w.stalls)
        assertEquals(0, w.suspendUs)
    }

    @Test fun lateTickDoesNotCatchUpMissedTicks() {
        val c = Clock()
        val m = started(c)
        m.tick(c, lateNs = 40 * ms)
        assertEquals(c.now + 5 * ms, m.nextDeadlineNs())
    }

    @Test fun stallsAboveThirtyMsAreCountedAndAboveFiftyLogged() {
        val c = Clock()
        val m = started(c)
        assertFalse(m.tick(c, lateNs = 30 * ms)) // exactly 30: not a stall
        assertFalse(m.tick(c, lateNs = 40 * ms)) // stall, not logged
        assertTrue(m.tick(c, lateNs = 120 * ms))
        assertEquals(120_000, m.stall.durUs)
        assertEquals(0, m.stall.suspendUs)
        assertEquals(c.now, m.stall.atNs)
        assertEquals(0, m.stall.suppressed)
        val w = m.window()
        assertEquals(3, w.ticks)
        assertEquals(2, w.stalls)
        assertEquals(120_000, w.lateMaxUs)
    }

    @Test fun suspendShowsAsRealtimeGrowth() {
        val c = Clock()
        val m = started(c)
        m.tick(c)
        c.offset += 700 * ms // the device slept 700 ms: realtime ran, uptime did not
        assertTrue(m.tick(c, lateNs = 60 * ms))
        assertEquals(700_000, m.stall.suspendUs)
        m.tick(c)
        assertEquals(700_000, m.window().suspendUs)
        m.tick(c)
        assertEquals(0, m.window().suspendUs) // the next window starts from the new offset
    }

    @Test fun stallLinesAreRateLimitedToFivePerSecond() {
        val c = Clock()
        val m = started(c)
        repeat(5) { assertTrue(m.tick(c, lateNs = 60 * ms)) }
        assertFalse(m.tick(c, lateNs = 60 * ms))
        assertFalse(m.tick(c, lateNs = 60 * ms))
        // 7 ticks of 65 ms = 455 ms; 150 on-time ticks (750 ms) end the one-second limit window
        repeat(150) { assertFalse(m.tick(c)) }
        assertTrue(m.tick(c, lateNs = 60 * ms))
        assertEquals(2, m.stall.suppressed)
        assertTrue(m.tick(c, lateNs = 60 * ms))
        assertEquals(0, m.stall.suppressed)
    }

    @Test fun maxLateCoversTheGapWindow() {
        val c = Clock()
        val m = started(c)
        repeat(20) { m.tick(c) } // on time up to t0 + 100 ms
        m.tick(c, lateNs = 150 * ms) // stopped from t0+105 to t0+255
        val stallEnd = c.now
        repeat(10) { m.tick(c, lateNs = 200_000) }
        // A gap that ended right after the stall: the stalled tick overlaps.
        assertEquals(150_000, m.maxLateUs(stallEnd - 160 * ms, stallEnd + 1 * ms, c.now))
        // A window that overlaps only the stall's stopped interval (not its wake-up).
        assertEquals(150_000, m.maxLateUs(t0 + 150 * ms, t0 + 170 * ms, c.now))
        // A gap after the stall: only on-time ticks.
        assertEquals(200, m.maxLateUs(stallEnd + 10 * ms, c.now, c.now))
        // A gap before the stall: on-time ticks only (the late wake-up is outside it).
        assertEquals(0, m.maxLateUs(t0 + 50 * ms, t0 + 100 * ms, c.now))
    }

    @Test fun overdueTickCountsBeforeItRuns() {
        val c = Clock()
        val m = started(c)
        repeat(10) { m.tick(c) }
        val deadline = m.nextDeadlineNs()
        // The process resumed 90 ms after the deadline; a reader asks before the tick thread got to run.
        val now = deadline + 90 * ms
        assertEquals(90_000, m.maxLateUs(now - 95 * ms, now, now))
    }

    @Test fun noneWhenNotRunningOrUncovered() {
        val m = StallMeter()
        assertEquals(NONE, m.maxLateUs(0, 10 * ms, 10 * ms))
        val c = Clock()
        val s = started(c)
        // Before the first tick and not overdue yet: nothing covers the window.
        assertEquals(NONE, s.maxLateUs(t0 - 50 * ms, t0, t0 + 1 * ms))
        s.tick(c)
        s.stop()
        assertEquals(NONE, s.maxLateUs(t0, c.now, c.now))
        assertFalse(s.onTick(c.now + 100 * ms, c.now + c.offset + 100 * ms)) // ignored after stop
    }

    @Test fun ringKeepsOnlyTheNewestTicks() {
        val c = Clock()
        val m = StallMeter(ringSize = 8).also { it.start(c.now, c.now + c.offset) }
        m.tick(c, lateNs = 100 * ms) // will be overwritten
        repeat(8) { m.tick(c) }
        assertEquals(0, m.maxLateUs(t0, c.now, c.now))
    }

    @Test fun emptyWindowPrintsDashes() {
        val w = started().window()
        assertEquals(0, w.ticks)
        assertEquals("ticks=0 tick_late_max_ms=- stalls=0 suspend_ms=- cpu_freq_khz=-", w.logFields(-1))
    }

    @Test fun logFieldsFormat() {
        val c = Clock()
        val m = started(c)
        m.tick(c, lateNs = 1_234_567)
        m.tick(c, lateNs = 45 * ms)
        assertEquals(
            "ticks=2 tick_late_max_ms=45.0 stalls=1 suspend_ms=0.0 cpu_freq_khz=2016000",
            m.window().logFields(2_016_000),
        )
    }

    @Test fun restartClearsState() {
        val c = Clock()
        val m = started(c)
        m.tick(c, lateNs = 80 * ms)
        m.start(c.now, c.now + c.offset)
        assertEquals(c.now + 5 * ms, m.nextDeadlineNs())
        assertEquals(0, m.window().ticks)
        m.tick(c)
        assertEquals(0, m.maxLateUs(c.now - 100 * ms, c.now + 1, c.now + 1))
    }

    @Test fun ms1Formats() {
        assertEquals("-", StallMeter.ms1(NONE))
        assertEquals("0.0", StallMeter.ms1(0))
        assertEquals("12.3", StallMeter.ms1(12_345))
        assertEquals("-1.5", StallMeter.ms1(-1_500))
    }

    @Test fun maxKhzPicksTheLargestReadableCore() {
        assertEquals(2_400_000, StallMeter.maxKhz(listOf("1800000\n", null, "2400000\n", "garbage")))
        assertEquals(-1, StallMeter.maxKhz(listOf(null, "")))
        assertEquals(-1, StallMeter.maxKhz(emptyList()))
    }
}
