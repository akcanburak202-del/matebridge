package dev.matebridge.client.video

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PerfBoostTest {
    private class FakeAction : BoostAction {
        var pulses = 0; var releases = 0
        override fun pulse() { pulses++ }
        override fun release() { releases++ }
    }

    private class FakeScheduler : PulseScheduler {
        var calls = 0; var closed = 0; var periodMs = 0L
        var task: Runnable? = null
        override fun every(periodMs: Long, task: Runnable): AutoCloseable {
            calls++; this.periodMs = periodMs; this.task = task
            return AutoCloseable { closed++; this.task = null }
        }
    }

    private val action = FakeAction()
    private val sched = FakeScheduler()
    private var made = 0
    private val logs = ArrayList<String>()
    private val boost = PerfBoost({ made++; action }, sched) { ev, f -> logs += "$ev $f" }

    @Test fun offCreatesNothing() {
        boost.update(enabled = false, streaming = true, foreground = true, remote = false)
        boost.update(enabled = false, streaming = false, foreground = false, remote = true)
        assertEquals(0, made)
        assertEquals(0, sched.calls)
        assertFalse(boost.running)
        assertTrue(logs.isEmpty())
    }

    @Test fun startsWhenAllConditionsHold() {
        boost.update(true, streaming = true, foreground = true, remote = false)
        assertTrue(boost.running)
        assertEquals(1, made)
        assertEquals(1, sched.calls)
        assertEquals(1000L, sched.periodMs)
        assertEquals(1, action.pulses)
        sched.task!!.run()
        assertEquals(2, action.pulses)
        assertEquals(listOf("perf_boost state=on reason=ok period_ms=1000"), logs)
    }

    @Test fun repeatedUpdatesDoNotRestart() {
        repeat(3) { boost.update(true, true, true, false) }
        assertEquals(1, sched.calls)
        assertEquals(1, logs.size)
    }

    @Test fun eachConditionStopsIt() {
        val cases = listOf(
            Triple("setting", booleanArrayOf(false, true, true, false), "setting"),
            Triple("stream", booleanArrayOf(true, false, true, false), "stream"),
            Triple("background", booleanArrayOf(true, true, false, false), "background"),
            Triple("remote", booleanArrayOf(true, true, true, true), "remote"),
        )
        for ((_, c, reason) in cases) {
            val a = FakeAction(); val s = FakeScheduler(); val l = ArrayList<String>()
            val b = PerfBoost({ a }, s) { ev, f -> l += "$ev $f" }
            b.update(true, true, true, false)
            assertTrue(b.running)
            b.update(c[0], c[1], c[2], c[3])
            assertFalse(reason, b.running)
            assertEquals(1, s.closed)
            assertEquals(1, a.releases)
            assertEquals("perf_boost state=off reason=$reason", l.last())
            // a pulse already queued after stop does nothing
            a.pulses.let { n -> s.task?.run(); assertEquals(n, a.pulses) }
        }
    }

    @Test fun canRestartAfterStop() {
        boost.update(true, true, true, false)
        boost.update(true, true, false, false)
        boost.update(true, true, true, false)
        assertEquals(2, sched.calls)
        assertEquals(2, made)
    }

    @Test fun remoteNeverStarts() {
        boost.update(true, true, true, true)
        assertEquals(0, made)
        assertEquals(0, sched.calls)
    }

    @Test fun pulseErrorsAreSwallowed() {
        val bad = object : BoostAction {
            override fun pulse() = throw IllegalStateException()
            override fun release() = throw IllegalStateException()
        }
        val b = PerfBoost({ bad }, sched) { _, _ -> }
        b.update(true, true, true, false)
        sched.task!!.run()
        b.update(false, true, true, false)
        assertFalse(b.running)
    }

    @Test fun unsupportedActionLogsAndStaysOff() {
        val b = PerfBoost({ throw UnsupportedOperationException() }, sched) { ev, f -> logs += "$ev $f" }
        b.update(true, true, true, false)
        assertFalse(b.running)
        assertEquals(0, sched.calls)
        assertEquals(listOf("perf_boost state=off reason=unsupported"), logs)
    }

    @Test fun shutdownStopsWithoutLog() {
        boost.update(true, true, true, false)
        logs.clear()
        boost.shutdown()
        assertFalse(boost.running)
        assertEquals(1, action.releases)
        assertTrue(logs.isEmpty())
    }

    @Test fun reasonOrder() {
        val r = PerfBoostRules.Reason.values()
        assertEquals(PerfBoostRules.Reason.SETTING, PerfBoostRules.reason(false, false, false, true))
        assertEquals(PerfBoostRules.Reason.REMOTE, PerfBoostRules.reason(true, false, false, true))
        assertEquals(PerfBoostRules.Reason.OK, PerfBoostRules.reason(true, true, true, false))
        assertEquals(5, r.size)
    }
}
