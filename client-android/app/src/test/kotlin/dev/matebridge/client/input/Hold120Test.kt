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
        var canDispatch: (() -> Boolean)? = null
        var preparing = false
        var aborts = 0
        override fun start(onCancelled: () -> Unit, canDispatch: () -> Boolean) { starts++; cancel = onCancelled; this.canDispatch = canDispatch }
        override fun abortIfPreparing(): Boolean { if (preparing) { aborts++; preparing = false; return true }; return false }
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

    // ---- P1-1: geometry ----

    @Test fun segmentsMoveChainAndStayInsideTheOverlay() {
        for (n in 0..7) {
            val g = HoldPathGeometry.segment(n)
            assertTrue("moves", g.x0 != g.x1 || g.y0 != g.y1)
            assertTrue(HoldPathGeometry.inside(g.x0, g.y0)); assertTrue(HoldPathGeometry.inside(g.x1, g.y1))
            val nx = HoldPathGeometry.segment(n + 1)
            assertEquals(g.x1, nx.x0, 0f); assertEquals(g.y1, nx.y0, 0f) // a continuation starts where the last ended
            val f = HoldPathGeometry.finalSegment(n)
            assertEquals(g.x1, f.x0, 0f); assertEquals(g.y1, f.y0, 0f)
            assertTrue("final moves", f.x0 != f.x1)
            assertTrue(HoldPathGeometry.inside(f.x1, f.y1))
        }
    }

    // ---- P1-2: real contact ----

    @Test fun noStartWhileTouchingThenStartsAfterQuietPeriod() {
        c.onTouch(true)
        ok()
        assertTrue(made.isEmpty()); assertFalse(c.holding)
        assertTrue(timer.tasks.isEmpty()) // waits for the contact to end
        now += 500
        c.onTouch(false)
        assertEquals(1000L, timer.tasks.last().ms)
        now += 1000
        timer.fireLast()
        assertTrue(c.holding); assertEquals(1, made.size)
    }

    @Test fun retryDeferredUntilContactsLiftAndQuiet() {
        ok()
        c.onTouch(true) // the real touch cancels the held one
        made[0].cancel!!.invoke()
        assertFalse(c.holding); assertFalse(c.retryPending)
        now += 3000
        c.onTouch(false)
        assertTrue(c.retryPending)
        assertEquals(1000L, timer.tasks.last().ms)
        c.onTouch(true) // touches again before the timer fires
        now += 1000
        timer.fireLast()
        assertFalse(c.holding)
        c.onTouch(false)
        now += 1000
        timer.fireLast()
        assertTrue(c.holding)
    }

    @Test fun touchNeverReleasesAHeldTouch() {
        ok()
        c.onTouch(true)
        ok()
        assertEquals(0, made[0].stops); assertTrue(c.holding)
    }

    @Test fun touchReasonToken() {
        assertEquals(Hold120Rules.Reason.TOUCH, Hold120Rules.reason(true, true, true, true, false, true, 120, touchQuiet = false))
        assertEquals("touch", Hold120Rules.Reason.TOUCH.logName)
    }

    // ---- round 2 ----

    @Test fun timingContractBoundsTheUpLagAndOverlayOutlivesIt() {
        assertTrue(HoldPathGeometry.CHUNK_MS <= 500L)
        assertEquals(HoldPathGeometry.CHUNK_MS + HoldPathGeometry.FINAL_MS, HoldPathGeometry.maxUpLagMs())
        assertTrue(HoldPathGeometry.removalTimeoutMs() >= HoldPathGeometry.maxUpLagMs() + 300L)
    }

    @Test fun mouseUpDoesNotClearAFingerThatIsDown() {
        val t = ContactTracker()
        assertTrue(t.onEvent(ContactTracker.SRC_TOUCH, 0, 1)) // finger down
        assertTrue(t.onEvent(ContactTracker.SRC_MOUSE, 0, 1)) // mouse click
        assertTrue(t.onEvent(ContactTracker.SRC_MOUSE, 1, 1)) // mouse up: finger still down
        assertEquals(1, t.contacts)
        assertFalse(t.onEvent(ContactTracker.SRC_TOUCH, 1, 1))
    }

    @Test fun multiPointerCountsAndStylusIsSeparate() {
        val t = ContactTracker()
        t.onEvent(ContactTracker.SRC_TOUCH, 0, 1)
        t.onEvent(ContactTracker.SRC_TOUCH, 5, 2)
        assertEquals(2, t.contacts)
        assertTrue(t.onEvent(ContactTracker.SRC_TOUCH, 6, 2)) // one lifts
        assertEquals(1, t.contacts)
        t.onEvent(ContactTracker.SRC_STYLUS, 0, 1)
        assertEquals(2, t.contacts)
        t.onEvent(ContactTracker.SRC_STYLUS, 3, 1) // cancel
        assertEquals(1, t.contacts)
        assertTrue(t.onEvent(ContactTracker.SRC_TOUCH, 2, 1)) // a move changes nothing
        assertFalse(t.onEvent(ContactTracker.SRC_TOUCH, 3, 1))
    }

    // ---- round 3 ----

    @Test fun readinessGatesTheFirstDispatch() {
        val w = OverlayReadiness.Verdict.WAIT
        assertEquals(w, OverlayReadiness.decide(false, false, null, 0))
        assertEquals(w, OverlayReadiness.decide(true, true, 0, 10)) // laid out but not settled
        assertEquals(w, OverlayReadiness.decide(true, true, 99, 200))
        assertEquals(OverlayReadiness.Verdict.GO, OverlayReadiness.decide(true, true, 100, 300))
        assertEquals(OverlayReadiness.Verdict.FAIL, OverlayReadiness.decide(false, false, null, 1000))
        assertEquals(OverlayReadiness.Verdict.FAIL, OverlayReadiness.decide(true, true, 50, 1000))
    }

    @Test fun secondStopWhileDrainingIsANoOp() {
        val g = DrainGate()
        g.onStart()
        assertEquals(DrainGate.Action.DRAIN, g.onStop(true))
        assertEquals(DrainGate.Action.NOOP, g.onStop(true)) // the service's release + the controller's stop
        assertEquals(DrainGate.Action.NOOP, g.onStop(false))
        g.onDrained()
        assertEquals(DrainGate.Action.REMOVE_NOW, g.onStop(true)) // nothing active any more
    }

    @Test fun stopBeforeAnyStrokeRemovesTheOverlayAtOnce() {
        val g = DrainGate()
        g.onStart()
        assertEquals(DrainGate.Action.REMOVE_NOW, g.onStop(false))
        assertFalse(g.draining)
    }

    private val rect = intArrayOf(48, 48, 72, 72)
    private fun fx(vararg v: Float) = v

    @Test fun streamStartingInsideTheOverlayIsDroppedThroughItsUp() {
        val f = OverlayDropFilter()
        val t = ContactTracker.SRC_TOUCH
        assertTrue(f.drop(1, t, 0, fx(60f), fx(60f), 1, rect))
        assertTrue(f.drop(1, t, 2, fx(500f), fx(500f), 1, rect))
        assertTrue(f.drop(1, t, 1, fx(500f), fx(500f), 1, null)) // overlay gone: still dropped to its UP
        assertEquals(0, f.activeStreams)
        assertFalse(f.drop(1, t, 0, fx(500f), fx(500f), 1, rect))
    }

    @Test fun otherDevicesUpPassesWhileAStreamIsDropped() {
        val f = OverlayDropFilter()
        val pen = ContactTracker.SRC_STYLUS
        assertFalse(f.drop(2, pen, 0, fx(900f), fx(900f), 1, rect)) // pen down outside: forwarded
        assertTrue(f.drop(1, ContactTracker.SRC_TOUCH, 0, fx(60f), fx(60f), 1, rect)) // finger down in the rect: dropped
        assertFalse(f.drop(2, pen, 1, fx(900f), fx(900f), 1, rect)) // the pen UP must pass
        assertTrue(f.drop(1, ContactTracker.SRC_TOUCH, 1, fx(60f), fx(60f), 1, rect))
    }

    @Test fun mixedPointersAndMouseAndNoOverlayPass() {
        val f = OverlayDropFilter()
        assertFalse(f.drop(1, ContactTracker.SRC_TOUCH, 0, fx(60f, 900f), fx(60f, 900f), 2, rect))
        assertFalse(f.drop(1, ContactTracker.SRC_MOUSE, 0, fx(60f), fx(60f), 1, rect))
        assertFalse(f.drop(1, ContactTracker.SRC_TOUCH, 0, fx(60f), fx(60f), 1, null))
        assertEquals(0, f.activeStreams)
    }

    // ---- round 4 ----

    @Test fun touchDuringPreparationAbortsAndRestartsAfterLiftAndQuiet() {
        ok()
        made[0].preparing = true // overlay added, nothing dispatched yet
        c.onTouch(true)
        assertEquals(1, made[0].aborts); assertEquals(0, made[0].stops)
        assertFalse(c.holding); assertEquals("hold120 state=off reason=touch", logs.last())
        assertTrue(timer.tasks.isEmpty())
        now += 300
        c.onTouch(false)
        assertEquals(1000L, timer.tasks.last().ms)
        now += 1000
        timer.fireLast()
        assertTrue(c.holding); assertEquals(2, made.size)
    }

    @Test fun runningHoldIsNotReleasedByTouch() {
        ok()
        c.onTouch(true)
        assertTrue(c.holding); assertEquals(0, made[0].aborts)
    }

    @Test fun guardMatchesTheQuietPredicate() {
        ok()
        assertTrue(made[0].canDispatch!!.invoke())
        c.onTouch(true)
        assertFalse(made[0].canDispatch!!.invoke())
        c.onTouch(false)
        assertFalse(made[0].canDispatch!!.invoke())
        now += 1000
        assertTrue(made[0].canDispatch!!.invoke())
    }
}
