package dev.matebridge.client.input

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class Hold120Test {
    private class FakeActuator : Hold120Actuator {
        var starts = 0
        var stops = 0
        var cancel: (() -> Unit)? = null
        override fun start(onCancelled: () -> Unit) { starts++; cancel = onCancelled }
        override fun stop() { stops++ }
    }

    private class FakeTimer : Hold120Timer {
        class Task(val ms: Long, val r: Runnable) { var closed = false }
        val tasks = ArrayList<Task>()
        override fun postDelayed(ms: Long, task: Runnable): AutoCloseable {
            val t = Task(ms, task); tasks += t
            return AutoCloseable { t.closed = true }
        }
        fun fireLast() { tasks.last().let { if (!it.closed) it.r.run() } }
    }

    private var now = 0L
    private val timer = FakeTimer()
    private val logs = ArrayList<String>()
    private val made = ArrayList<FakeActuator>()
    private var provide = true
    private val c = Hold120Controller(
        newActuator = { if (provide) FakeActuator().also { made += it } else null },
        timer = timer, nowMs = { now }, log = { e, f -> logs += "$e $f" },
    )

    private fun ok(enabled: Boolean = true, bound: Boolean = true, streaming: Boolean = true, fg: Boolean = true, remote: Boolean = false, game: Boolean = true, fps: Int = 120) =
        c.update(enabled, bound, streaming, fg, remote, game, fps)

    @Test fun offByDefaultCreatesNothing() {
        ok(enabled = false)
        assertTrue(made.isEmpty()); assertTrue(timer.tasks.isEmpty()); assertTrue(logs.isEmpty()); assertFalse(c.holding)
    }

    @Test fun allConditionsHoldTheTouch() {
        ok()
        assertEquals(1, made.size); assertEquals(1, made[0].starts); assertTrue(c.holding)
        assertEquals(listOf("hold120 state=on reason=ok"), logs)
        ok() // unchanged: no second start, no new log line
        assertEquals(1, made.size); assertEquals(1, logs.size)
    }

    @Test fun everyConditionDroppingReleasesWithUpAndReason() {
        val cases = listOf<Pair<String, () -> Unit>>(
            "setting" to { ok(enabled = false) },
            "remote" to { ok(remote = true) },
            "service" to { ok(bound = false) },
            "background" to { ok(fg = false) },
            "stream" to { ok(streaming = false) },
            "mode" to { ok(game = false) },
            "mode" to { ok(fps = 60) },
        )
        for ((reason, drop) in cases) {
            made.clear(); logs.clear()
            ok()
            val a = made.single()
            drop()
            assertEquals("$reason: UP sent once", 1, a.stops)
            assertFalse(c.holding)
            assertEquals(listOf("hold120 state=on reason=ok", "hold120 state=off reason=$reason"), logs)
        }
    }

    @Test fun conditionsReturningRestartAtOnce() {
        ok(); ok(game = false); ok()
        assertEquals(2, made.size); assertTrue(c.holding)
    }

    @Test fun notBoundOrNoActuatorStartsNothing() {
        ok(bound = false)
        assertTrue(made.isEmpty())
        provide = false
        ok()
        assertFalse(c.holding); assertTrue(logs.isEmpty())
    }

    @Test fun cancelledRetriesAfterBackoffAndOnlyWhileConditionsHold() {
        ok()
        made[0].cancel!!.invoke()
        assertEquals(1, made[0].stops); assertFalse(c.holding); assertTrue(c.retryPending)
        assertEquals(1000L, timer.tasks.last().ms)
        assertEquals("hold120 state=off reason=cancelled", logs.last())
        timer.fireLast()
        assertEquals(2, made.size); assertTrue(c.holding)
        // quick second cancellation backs off
        made[1].cancel!!.invoke()
        assertEquals(2000L, timer.tasks.last().ms)
        timer.fireLast()
        made[2].cancel!!.invoke()
        assertEquals(4000L, timer.tasks.last().ms)
    }

    @Test fun backoffCapsAndStableHoldResetsIt() {
        ok()
        repeat(6) { i ->
            made.last().cancel!!.invoke()
            if (i == 5) assertEquals(8000L, timer.tasks.last().ms)
            timer.fireLast()
        }
        now += Hold120Rules.STABLE_MS + 1
        made.last().cancel!!.invoke()
        assertEquals(1000L, timer.tasks.last().ms)
    }

    @Test fun conditionDroppingDuringRetryCancelsIt() {
        ok()
        made[0].cancel!!.invoke()
        ok(game = false)
        assertTrue(timer.tasks.last().closed); assertFalse(c.retryPending)
        assertEquals(1, made.size)
    }

    @Test fun staleCancelAfterReleaseIsIgnored() {
        ok()
        val cancel = made[0].cancel!!
        ok(enabled = false)
        cancel()
        assertTrue(timer.tasks.isEmpty()); assertEquals(1, made[0].stops)
    }

    @Test fun shutdownReleasesWithoutLogAndCancelsRetry() {
        ok(); logs.clear()
        c.shutdown()
        assertEquals(1, made[0].stops); assertTrue(logs.isEmpty()); assertFalse(c.holding)
        ok(); made.last().cancel!!.invoke(); c.shutdown()
        assertTrue(timer.tasks.last().closed)
    }

    @Test fun rulesOrderAndKnobParse() {
        assertEquals(Hold120Rules.Reason.SETTING, Hold120Rules.reason(false, false, false, false, true, false, 0))
        assertEquals(Hold120Rules.Reason.REMOTE, Hold120Rules.reason(true, false, false, false, true, false, 0))
        assertEquals(Hold120Target.OVERLAY, Hold120Target.parse(null))
        assertEquals(Hold120Target.OVERLAY, Hold120Target.parse("x"))
        assertEquals(Hold120Target.SURFACE, Hold120Target.parse(" Surface "))
    }
}
