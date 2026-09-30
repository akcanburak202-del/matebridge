package dev.matebridge.client.input

import dev.matebridge.client.protocol.Pen
import dev.matebridge.client.protocol.PenSample
import dev.matebridge.client.protocol.PointerAbs
import dev.matebridge.client.protocol.ReleaseAll
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-029 / decision 0007: a pen contact is sent only once it is confirmed (second real sample, or [PenTracker.CONFIRM_MS]
 * passed); a contact that ends first (tip bounce) never reaches the host. The tracker tests come first, the capture-level
 * ones (finger gate, RELEASE_ALL, device removal, routing, the host model) after.
 */
class PenContactConfirmTest {
    private val IR = PenSample.IN_RANGE
    private val CT = PenSample.CONTACT
    private val SS = PenSample.STROKE_START

    private val counters = InputCounters()
    private val t = PenTracker({ VP }, counters)

    private fun flags(out: List<Outgoing>) = penSamples(out.messages()).map { it.flags }
    private fun nx(x: Float) = VP.normX(x)

    // ================= tracker: confirmation =================

    @Test fun aSingleSampleContactThatEndsWithinTheWindowIsDroppedAndProducesNoContactMessage() {
        assertTrue(t.onFrame(penFrame(PenAction.DOWN, pt(0, pressure = 0.005f)), 0).isEmpty())
        assertTrue(t.contactHeld)
        val up = t.onFrame(penFrame(PenAction.UP, pt(8, pressure = 0f)), 8) // ~8 ms later, no MOVE in between
        // Only a hover sample at the lift position: no STROKE_START, no contact, no release of a contact never sent.
        assertEquals(listOf(IR), flags(up))
        assertEquals(1L, counters.bounceDropped)
        assertFalse(t.contactHeld)
        assertEquals(PenTracker.State.HOVER, t.state)
        assertTrue(t.tick(20).isEmpty()) // nothing left behind that a later tick could confirm
        assertTrue(t.tick(40).isEmpty())
    }

    @Test fun downPlusMoveIsAnOrdinaryStrokeWithTheOriginalTimestamps() {
        t.onFrame(penFrame(PenAction.DOWN, pt(100, x = 500f)), 100)
        val out = t.onFrame(penFrame(PenAction.MOVE, pt(103, x = 510f)), 103)
        assertEquals(1, out.size)
        val pen = out[0].msg as Pen
        assertEquals(100_000L, pen.baseTimeUs)
        assertEquals(listOf(0L, 3000L), pen.samples.map { it.dtUs })
        assertEquals(listOf(IR or CT or SS, IR or CT), pen.samples.map { it.flags })
        assertEquals(listOf(nx(500f), nx(510f)), pen.samples.map { it.x })
        assertEquals(PenTracker.State.CONTACT, t.state)
        assertEquals(0L, counters.bounceDropped)
        // and the stroke ends the usual way
        assertEquals(listOf(IR), flags(t.onFrame(penFrame(PenAction.UP, pt(106)), 106)))
    }

    @Test fun aDownCarryingHistoryIsAlreadyConfirmed() {
        val out = t.onFrame(penFrame(PenAction.DOWN, pt(0), pt(3)), 3)
        assertEquals(listOf(IR or CT or SS, IR or CT), flags(out))
        assertFalse(t.contactHeld)
    }

    @Test fun aStationaryContactIsConfirmedByTheTickAfterTheWindowWithItsOriginalTime() {
        t.onFrame(penFrame(PenAction.DOWN, pt(50, x = 700f)), 50)
        assertTrue(t.tick(50 + PenTracker.CONFIRM_MS - 1).isEmpty())
        val out = t.tick(50 + PenTracker.CONFIRM_MS)
        assertEquals(1, out.size)
        val pen = out[0].msg as Pen
        assertEquals(50_000L, pen.baseTimeUs) // the sample keeps its own time, not the tick's
        assertEquals(listOf(IR or CT or SS), pen.samples.map { it.flags })
        assertEquals(nx(700f), pen.samples[0].x)
        assertEquals(PenTracker.State.CONTACT, t.state)
        assertFalse(t.contactHeld)
        assertEquals(0L, counters.bounceDropped)
    }

    @Test fun anUpAtOrAfterTheWindowConfirmsTheContactFirstSoAShortRealContactIsWhole() {
        t.onFrame(penFrame(PenAction.DOWN, pt(0)), 0)
        val up = t.onFrame(penFrame(PenAction.UP, pt(PenTracker.CONFIRM_MS)), PenTracker.CONFIRM_MS)
        assertEquals(listOf(IR or CT or SS, IR), flags(up))
        assertEquals(0L, counters.bounceDropped)
        // one millisecond short of the window it is a bounce
        val t2 = PenTracker({ VP }, counters)
        t2.onFrame(penFrame(PenAction.DOWN, pt(0)), 0)
        assertEquals(listOf(IR), flags(t2.onFrame(penFrame(PenAction.UP, pt(PenTracker.CONFIRM_MS - 1)), PenTracker.CONFIRM_MS - 1)))
        assertEquals(1L, counters.bounceDropped)
    }

    @Test fun theWindowIsMeasuredInEventTimeNotDispatchTime() {
        // The UI thread was busy: both events are dispatched together although the pen was down for only 8 ms.
        t.onFrame(penFrame(PenAction.DOWN, pt(0)), 100)
        assertEquals(listOf(IR), flags(t.onFrame(penFrame(PenAction.UP, pt(8)), 101)))
        assertEquals(1L, counters.bounceDropped)
    }

    @Test fun anUpCarryingHistoryConfirmsTheContactAndTheStrokeGoesOutWhole() {
        // DOWN at 0 ms, then ONE UP event with history at 3 and 6 ms and the lift sample at 8 ms (inside the window).
        assertTrue(t.onFrame(penFrame(PenAction.DOWN, pt(0, x = 100f)), 0).isEmpty())
        val out = t.onFrame(penFrame(PenAction.UP, pt(3, x = 110f), pt(6, x = 120f), pt(8, x = 125f, pressure = 0f)), 8)
        assertEquals(0L, counters.bounceDropped)
        assertEquals(listOf(IR or CT or SS, IR or CT, IR or CT, IR), flags(out))
        val s = penSamples(out.messages())
        assertEquals(listOf(nx(100f), nx(110f), nx(120f), nx(125f)), s.map { it.x })
        // The held DOWN and the UP's samples may travel in separate messages: compare absolute times.
        val abs = out.map { it.msg as Pen }.flatMap { m -> m.samples.map { m.baseTimeUs + it.dtUs } }
        assertEquals("original timestamps, in order", listOf(0L, 3000L, 6000L, 8000L), abs)
        assertEquals(PenTracker.State.HOVER, t.state)
        assertFalse(t.contactHeld)
        assertEquals(NO_DEVICE, t.contactDeviceId)
    }

    @Test fun aBareUpInsideTheWindowIsStillABounce() {
        // The single DOWN sample is the whole contact: UP without history, inside the window.
        t.onFrame(penFrame(PenAction.DOWN, pt(0)), 0)
        assertEquals(listOf(IR), flags(t.onFrame(penFrame(PenAction.UP, pt(9)), 9)))
        assertEquals(1L, counters.bounceDropped)
    }

    @Test fun aHoverEventEndsAHeldContactLikeAnUp() {
        t.onFrame(penFrame(PenAction.DOWN, pt(0)), 0)
        assertEquals(listOf(IR), flags(t.onFrame(penFrame(PenAction.HOVER_ENTER, pt(6)), 6)))
        assertEquals(1L, counters.bounceDropped)
        assertFalse(t.contactHeld)
    }

    // ================= tracker: contacts that never get confirmed =================

    @Test fun aCancelWhileHeldSendsOnlyFlagsZeroWhateverTheAge() {
        t.onFrame(penFrame(PenAction.DOWN, pt(0)), 0)
        val c = t.onFrame(penFrame(PenAction.CANCEL, pt(30)), 30) // older than the window: still never sent
        assertEquals(listOf(0), flags(c))
        assertFalse(c[0].mergeable)
        assertEquals(PenTracker.State.OUT, t.state)
        assertFalse(t.inRange)
        assertEquals(1L, counters.bounceDropped)
        assertFalse(t.contactHeld)
        assertTrue(t.tick(100).isEmpty())
    }

    @Test fun releaseWhileHeldDropsItSilentlyAndOnlyClosesWhatTheHostKnows() {
        // The host believes the pen hovers: it gets its flags = 0, nothing else.
        t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(0)), 0)
        t.onFrame(penFrame(PenAction.DOWN, pt(5)), 5)
        assertEquals(listOf(0), flags(t.release(8)))
        assertFalse(t.contactHeld)
        assertFalse(t.inRange)
        assertTrue(t.tick(200).isEmpty())
        // The host knows nothing of the pen: nothing at all is sent.
        val t2 = PenTracker({ VP }, counters)
        t2.onFrame(penFrame(PenAction.DOWN, pt(0)), 0)
        assertTrue(t2.release(4).isEmpty())
        assertFalse(t2.inRange)
        assertTrue(t2.tick(200).isEmpty())
        assertEquals(0L, counters.bounceDropped) // not a bounce: the lifecycle ended it
    }

    @Test fun resetWhileHeldForgetsItAndTheStrokeMiddleIsHoverOnly() {
        t.onFrame(penFrame(PenAction.DOWN, pt(0)), 0)
        t.reset()
        assertFalse(t.inRange)
        assertFalse(t.contactHeld)
        assertTrue(t.tick(50).isEmpty())
        assertEquals(listOf(IR), flags(t.onFrame(penFrame(PenAction.MOVE, pt(60)), 60)))
    }

    @Test fun aToolChangeWhileHeldDropsTheOldToolsContactWithoutAReleaseForIt() {
        // From out of range: the host has nothing for the pen tool, so only the eraser's hover goes out.
        t.onFrame(penFrame(PenAction.DOWN, pt(0)), 0)
        val out = t.onFrame(penFrame(PenAction.HOVER_ENTER, pt(5), eraser = true), 5)
        assertEquals(listOf(Pen.TOOL_ERASER), out.map { (it.msg as Pen).tool })
        assertEquals(listOf(IR), flags(out))
        // From hover: the host held the pen in range, so that gets its flags = 0 first.
        val t2 = PenTracker({ VP }, counters)
        t2.onFrame(penFrame(PenAction.HOVER_MOVE, pt(0)), 0)
        t2.onFrame(penFrame(PenAction.DOWN, pt(5)), 5)
        val out2 = t2.onFrame(penFrame(PenAction.HOVER_ENTER, pt(7), eraser = true), 7)
        assertEquals(listOf(Pen.TOOL_PEN, Pen.TOOL_ERASER), out2.map { (it.msg as Pen).tool })
        assertEquals(listOf(0, IR), flags(out2))
        assertFalse(t2.contactHeld)
    }

    @Test fun aMoveThatChangesTheToolWhileHeldDropsTheHeldContactAndNeverSendsAContact() {
        t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(0)), 0)
        t.onFrame(penFrame(PenAction.DOWN, pt(5)), 5)
        val out = t.onFrame(penFrame(PenAction.MOVE, pt(8), eraser = true), 8)
        // The host held the pen in range: it gets its flags = 0, then the eraser is only hover (its contact never began).
        assertEquals(listOf(Pen.TOOL_PEN, Pen.TOOL_ERASER), out.map { (it.msg as Pen).tool })
        assertEquals(listOf(0, IR), flags(out))
        assertFalse(t.contactHeld)
        assertEquals(PenTracker.State.HOVER, t.state)
        assertTrue(t.tick(100).none { m -> (m.msg as Pen).samples.any { it.flags and CT != 0 } })
    }

    @Test fun aHoverExitWhileHeldFromOutOfRangeDropsItAndLeavesWithFlagsZero() {
        t.onFrame(penFrame(PenAction.DOWN, pt(0)), 0) // host state OUT
        assertEquals(PenTracker.State.OUT, t.state)
        val out = t.onFrame(penFrame(PenAction.HOVER_EXIT, pt(8)), 8)
        assertEquals(listOf(0), flags(out)) // state is OUT, so the exit is not deferred
        assertFalse(t.inRange)
        assertFalse(t.contactHeld)
        assertEquals(1L, counters.bounceDropped)
    }

    // ================= tracker: state while held =================

    @Test fun whileHeldThePenCountsAsInRangeAndTheContactsDeviceAndPointerAreFollowed() {
        assertFalse(t.inRange)
        t.onFrame(penFrame(PenAction.DOWN, pt(0), device = PEN_DEVICE, pointerId = 3), 0)
        assertTrue(t.inRange) // the finger gate must not open
        assertTrue(t.followsPointer(PEN_DEVICE, 3))
        assertFalse(t.followsPointer(TOUCH_DEVICE, 3))
        assertFalse(t.followsPointer(PEN_DEVICE, 0))
        assertEquals(PEN_DEVICE, t.contactDeviceId)
        assertEquals(3, t.contactPointerId)
        assertEquals("nothing was sent, so the gate clock did not move", NEVER_MS, t.lastSentMs)
        assertEquals(PenTracker.State.OUT, t.state) // the host's belief
        // After a bounce nothing is followed any more.
        t.onFrame(penFrame(PenAction.UP, pt(5), device = PEN_DEVICE, pointerId = 3), 5)
        assertFalse(t.followsPointer(PEN_DEVICE, 3))
        assertEquals(NO_DEVICE, t.contactDeviceId)
    }

    @Test fun aHeldContactIsNotRepeatedByTheLivenessTimer() {
        t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(0)), 0)
        t.onFrame(penFrame(PenAction.DOWN, pt(90)), 90) // the hover repeat would be due at 100 ms
        val out = t.tick(100) // confirms; must be the contact sample, not a hover repeat
        assertEquals(listOf(IR or CT or SS), flags(out))
        assertTrue(t.tick(125).isEmpty())
    }

    // ================= tracker: the deferred hover exit =================

    @Test fun anExitSwallowedByTheDownStaysSwallowedWhenTheBounceEndsWithAnUpBecauseThePenIsStillThere() {
        t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(0)), 0)
        t.onFrame(penFrame(PenAction.HOVER_EXIT, pt(3)), 3)
        t.onFrame(penFrame(PenAction.DOWN, pt(5)), 5)
        assertEquals(1L, counters.exitAbsorbed)
        val up = t.onFrame(penFrame(PenAction.UP, pt(9)), 9)
        assertEquals(listOf(IR), flags(up)) // a hover sample; no flags = 0 ever went out
        assertTrue(t.inRange)
        assertEquals(PenTracker.State.HOVER, t.state)
    }

    @Test fun anExitSwallowedByTheDownIsAnsweredByTheCancelThatEndsTheHeldContact() {
        t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(0)), 0)
        t.onFrame(penFrame(PenAction.HOVER_EXIT, pt(3)), 3)
        t.onFrame(penFrame(PenAction.DOWN, pt(5)), 5)
        assertEquals(listOf(0), flags(t.onFrame(penFrame(PenAction.CANCEL, pt(8)), 8)))
        assertFalse(t.inRange)
    }

    @Test fun aHoverExitWhileHeldIsDeferredAgainAndSentByTheTick() {
        t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(0)), 0)
        t.onFrame(penFrame(PenAction.HOVER_EXIT, pt(3)), 3)
        t.onFrame(penFrame(PenAction.DOWN, pt(5)), 5)
        assertTrue(t.onFrame(penFrame(PenAction.HOVER_EXIT, pt(8)), 8).isEmpty()) // bounce dropped, exit deferred again
        assertEquals(1L, counters.bounceDropped)
        assertEquals(listOf(0), flags(t.tick(8 + PenTracker.EXIT_DEFER_MS)))
        assertFalse(t.inRange)
    }

    // ================= tracker: the recorded bounce =================

    @Test fun theRecordedBounceThenTheRealStrokeProducesOnlyTheSecondStroke() {
        // NOTES 2026-09-30: hover, exit right before DOWN, DOWN with pressure 76/16384, UP 8 ms later with no sample in
        // between, 22 ms in the air, DOWN again 3 pt further with pressure 236/16384, the stroke goes on.
        val sent = ArrayList<Outgoing>()
        fun feed(f: PenFrame, now: Long) { sent += t.onFrame(f, now) }
        feed(penFrame(PenAction.HOVER_MOVE, pt(0, x = 800f)), 0)
        feed(penFrame(PenAction.HOVER_MOVE, pt(3, x = 800f)), 3)
        feed(penFrame(PenAction.HOVER_EXIT, pt(6, x = 800f)), 6)
        feed(penFrame(PenAction.DOWN, pt(7, x = 800f, pressure = 76f / 16384f)), 7)
        feed(penFrame(PenAction.UP, pt(15, x = 800f, pressure = 0f)), 15) // 8 ms after the DOWN
        for (ms in 16L..36L step 3) feed(penFrame(PenAction.HOVER_MOVE, pt(ms, x = 801f)), ms)
        feed(penFrame(PenAction.HOVER_EXIT, pt(37, x = 801f)), 37)
        feed(penFrame(PenAction.DOWN, pt(38, x = 803f, pressure = 236f / 16384f)), 38) // 23 ms after the UP
        feed(penFrame(PenAction.MOVE, pt(41, x = 805f, pressure = 0.02f)), 41)
        feed(penFrame(PenAction.MOVE, pt(44, x = 808f, pressure = 0.03f)), 44)
        feed(penFrame(PenAction.UP, pt(200, x = 900f, pressure = 0f)), 200)
        val samples = penSamples(sent.messages())
        val contact = samples.filter { it.flags and CT != 0 }
        assertEquals("exactly one stroke start, and it is the second stroke", 1, samples.count { it.flags and SS != 0 })
        assertEquals(nx(803f), samples.first { it.flags and SS != 0 }.x)
        assertEquals(nx(803f), contact.first().x) // no contact sample before it
        assertEquals(3, contact.size)
        assertEquals(1L, counters.bounceDropped)
        // the hover before the second stroke is unbroken: no flags = 0 between the strokes
        assertEquals(0, samples.takeWhile { it.flags and CT == 0 }.count { it.flags == 0 })
    }

    // ================= tracker: duplicates and counters =================

    @Test fun theDuplicateFilterAndCountersWorkOnAConfirmedContactAsBefore() {
        t.onFrame(penFrame(PenAction.DOWN, pt(0, x = 100f)), 0)
        val out = t.onFrame(penFrame(PenAction.MOVE, pt(3, x = 110f), pt(3, x = 110f), pt(6, x = 110f)), 6)
        assertEquals(1, out.size)
        val pen = out[0].msg as Pen
        assertEquals(listOf(nx(100f), nx(110f), nx(110f)), pen.samples.map { it.x })
        assertEquals(listOf(0L, 3000L, 6000L), pen.samples.map { it.dtUs })
        assertEquals(listOf(IR or CT or SS, IR or CT, IR or CT), pen.samples.map { it.flags })
        assertEquals(1L, counters.dupExact)
        assertEquals(1L, counters.dupPos)
        assertEquals(3L, counters.maxBatch)
    }

    @Test fun bounceDroppedIsInTheSummaryFields() {
        t.onFrame(penFrame(PenAction.DOWN, pt(0)), 0)
        t.onFrame(penFrame(PenAction.UP, pt(4)), 4)
        assertTrue(counters.any())
        assertTrue(counters.fields(1000).endsWith("bounce_dropped=1"))
        counters.reset()
        assertEquals(0L, counters.bounceDropped)
    }

    // ================= capture level: finger gate, lifecycle, routing, host model =================

    private class Rig {
        val sink = FakeSink()
        val lines = ArrayList<String>()
        val cap = InputCapture(sink, { VP }, onStatsLine = { lines += it }).also { it.setActive(true, 0); it.setStreamGeometry(1400, 920) }
        fun pen(a: PenAction, t: Long, vararg p: PenPoint, pointerId: Int = 0) {
            sink.nowMs = t; cap.onPen(penFrame(a, *p, device = PEN_DEVICE, pointerId = pointerId), t)
        }
        fun touch(a: TouchAction, t: Long, acting: Int, vararg f: Finger) {
            sink.nowMs = t; cap.onTouch(touchFrame(a, t, acting, *f), t)
        }
        fun tick(t: Long) { sink.nowMs = t; sink.tickHost(); cap.tick(t) }
        val host get() = sink.host
        fun contactMessages() = penSamples(sink.sent).count { it.flags and PenSample.CONTACT != 0 }
    }

    @Test fun theHostNeverHearsOfTheBounceAndSeesExactlyOneStroke() {
        val r = Rig()
        r.pen(PenAction.HOVER_ENTER, 0, pt(0))
        r.pen(PenAction.HOVER_EXIT, 10, pt(10))
        r.pen(PenAction.DOWN, 11, pt(11, pressure = 0.005f))
        assertFalse("held: the host has no contact yet", r.host.penContact)
        assertTrue(r.host.penInRange)
        r.pen(PenAction.UP, 19, pt(19, pressure = 0f))
        r.tick(25); r.tick(50)
        assertEquals(0, r.contactMessages())
        assertFalse(r.host.penContact)
        r.pen(PenAction.HOVER_EXIT, 40, pt(40))
        r.pen(PenAction.DOWN, 42, pt(42, x = 1403f))
        r.pen(PenAction.MOVE, 45, pt(45, x = 1406f))
        assertTrue(r.host.penContact)
        r.pen(PenAction.UP, 60, pt(60))
        assertFalse(r.host.penContact)
        assertEquals(1, penSamples(r.sink.sent).count { it.flags and PenSample.STROKE_START != 0 })
        assertTrue(r.host.violations.isEmpty())
        assertEquals(0, r.sink.pressesRejected)
    }

    @Test fun aTickConfirmedContactAfterASwallowedExitIsEndedByACancelAndTheHostIsClean() {
        val r = Rig()
        r.pen(PenAction.HOVER_ENTER, 0, pt(0))
        r.pen(PenAction.HOVER_EXIT, 10, pt(10))
        r.pen(PenAction.DOWN, 12, pt(12)) // swallows the exit, held
        r.tick(25) // 13 ms after the DOWN: the timer confirms it
        assertTrue(r.host.penContact)
        r.pen(PenAction.CANCEL, 30, pt(30))
        assertFalse(r.host.penContact)
        assertFalse(r.host.penInRange)
        assertTrue(r.host.clear)
        assertFalse(r.cap.penInRange)
        assertEquals(1, penSamples(r.sink.sent).count { it.flags and PenSample.STROKE_START != 0 })
        assertTrue(r.host.violations.isEmpty())
    }

    @Test fun aFingerCannotStartWhileAContactIsHeld() {
        val r = Rig()
        r.pen(PenAction.DOWN, 0, pt(0)) // out of range so far: the held contact is all there is
        assertTrue(r.cap.penInRange)
        r.touch(TouchAction.DOWN, 2, 1, finger(1, 300f, 300f))
        r.pen(PenAction.UP, 6, pt(6)) // bounce; the pen hovers now
        r.tick(60); r.tick(100)
        assertTrue(r.sink.sent.none { it is PointerAbs })
        assertEquals(0, r.sink.pressesRejected)
        assertTrue(r.host.violations.isEmpty())
    }

    @Test fun releaseAllWhileHeldSendsNoContactAndNoExtraRelease() {
        val r = Rig()
        r.pen(PenAction.HOVER_ENTER, 0, pt(0))
        r.pen(PenAction.DOWN, 10, pt(10))
        r.sink.nowMs = 14
        r.cap.releaseAll(ReleaseAll.FOCUS_LOST, 14)
        assertEquals(0, r.contactMessages())
        // the hover the host knew about ends with one flags = 0, then RELEASE_ALL; nothing else
        assertEquals(listOf(IR, 0), penSamples(r.sink.sent).map { it.flags })
        assertTrue(r.sink.sent.last() is ReleaseAll)
        assertTrue(r.host.clear && !r.host.penInRange)
        assertFalse(r.cap.penInRange)
        r.cap.resume()
        r.tick(100)
        assertEquals(0, r.contactMessages()) // the dropped DOWN does not come back
        assertTrue(r.host.violations.isEmpty())
    }

    @Test fun deviceRemovalWhileHeldEndsCleanly() {
        val r = Rig()
        r.pen(PenAction.DOWN, 0, pt(0)) // out of range before: the host knows nothing
        r.sink.nowMs = 5
        r.cap.onDeviceRemoved(PEN_DEVICE, 5)
        assertEquals(0, r.contactMessages())
        assertTrue(r.sink.sent.last() is ReleaseAll)
        assertEquals("no PEN message at all: the host knew nothing of the pen", 0, penSamples(r.sink.sent).size)
        assertEquals(1, r.sink.sent.count { it is ReleaseAll })
        assertFalse(r.cap.penInRange)
        assertTrue(r.host.clear && !r.host.hasHeld)
    }

    @Test fun aHeldContactIsRoutedByDeviceAndPointerLikeAnOpenOne() {
        val r = Rig()
        r.pen(PenAction.DOWN, 0, pt(0), pointerId = 2)
        assertTrue(r.cap.followsPen(PEN_DEVICE, 2))
        assertFalse(r.cap.followsPen(TOUCH_DEVICE, 2))
        assertEquals(PEN_DEVICE, r.cap.penContactDevice)
        assertEquals(2, r.cap.penContactPointerId)
        // a release reported with another tool type still belongs to the pen (PROTOCOL.md section 7)
        assertEquals(Route.PEN, ReleaseRouting.routeUp(ToolKind.OTHER, PEN_DEVICE, 2, r.cap))
        // a cancel of the touchscreen does not reach the held pen contact, one of the pen's own device does
        assertFalse(ReleaseRouting.cancelReachesPen(TOUCH_DEVICE, penPointerInEvent = false, followers = r.cap))
        assertTrue(ReleaseRouting.cancelReachesPen(PEN_DEVICE, penPointerInEvent = false, followers = r.cap))
        r.cap.androidUp(ToolKind.OTHER, PEN_DEVICE, 2, 6)
        assertEquals(0, r.contactMessages())
        assertFalse(r.cap.followsPen(PEN_DEVICE, 2))
    }

    @Test fun theSummaryLineCountsTheDroppedBounce() {
        val r = Rig()
        r.tick(0)
        r.pen(PenAction.DOWN, 10, pt(10))
        r.pen(PenAction.UP, 16, pt(16))
        r.tick(1000)
        assertTrue(r.lines.toString(), r.lines[0].contains("bounce_dropped=1"))
    }
}
