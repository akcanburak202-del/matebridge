package dev.matebridge.client.input

import dev.matebridge.client.protocol.Buttons
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.Pen
import dev.matebridge.client.protocol.PenSample
import dev.matebridge.client.protocol.PointerAbs
import dev.matebridge.client.protocol.ReleaseAll
import dev.matebridge.client.protocol.Scroll
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The T-024 review round, one section per fix (names start with "fixN"), against the trackers and against the
 * capture over the real-host reference model. Section 0 covers the RELEASE_ALL / pointer-lock rules.
 */
class InputHardeningTest {
    private val IR = PenSample.IN_RANGE
    private val CT = PenSample.CONTACT
    private val SS = PenSample.STROKE_START

    // ---- tracker-level helpers ----
    private val presence = FakePresence()
    private val counters = InputCounters()
    private fun touchTracker() = TouchTracker({ VP }, presence, counters).also { it.widthPt = 1400; it.heightPt = 920 }
    private fun penTracker() = PenTracker({ VP }, counters)
    private fun ptrs(o: List<Outgoing>) = o.messages().filterIsInstance<PointerAbs>()
    private fun scrolls(o: List<Outgoing>) = o.messages().filterIsInstance<Scroll>()
    private fun flags(o: List<Outgoing>) = penSamples(o.messages()).map { it.flags }

    // ---- capture-level rig: capture over the real-host reference model ----
    private class Rig {
        val sink = FakeSink()
        val cap = InputCapture(sink, { VP }).also { it.setActive(true, 0); it.setStreamGeometry(1400, 920) }
        fun pen(a: PenAction, t: Long, vararg p: PenPoint, eraser: Boolean = false, pointerId: Int = 0) {
            sink.nowMs = t; cap.onPen(penFrame(a, *p, eraser = eraser, pointerId = pointerId), t)
        }
        fun touch(a: TouchAction, t: Long, acting: Int, vararg f: Finger) {
            sink.nowMs = t; cap.onTouch(touchFrame(a, t, acting, *f), t)
        }
        fun tick(t: Long) { sink.nowMs = t; sink.tickHost(); cap.tick(t) }
        fun tickTo(from: Long, to: Long) { var t = from; while (t < to) { t += 25; tick(t) } }
        fun releaseAll(reason: Int, t: Long) { sink.nowMs = t; cap.releaseAll(reason, t) }
        val host get() = sink.host
    }

    // ================= section 0: buttons = 0 before RELEASE_ALL, resume rules =================

    @Test fun buttonsZeroImmediatelyPrecedesReleaseAllForEveryReason() {
        for (reason in listOf(ReleaseAll.BACKGROUND, ReleaseAll.FOCUS_LOST, ReleaseAll.DEVICE_DETACHED, ReleaseAll.USER)) {
            val r = Rig()
            r.touch(TouchAction.DOWN, 0, 1, finger(1, 300f, 400f))
            r.tick(60) // the held-back DOWN goes out: the host now has LEFT reported
            assertTrue("reason=$reason", r.host.touchReportedHeld)
            r.touch(TouchAction.MOVE, 70, -1, finger(1, 320f, 410f))
            r.sink.nowMs = 80
            when (reason) {
                ReleaseAll.DEVICE_DETACHED -> r.cap.onDeviceRemoved(2, 80) // the touch frames carry device 2
                ReleaseAll.USER -> r.cap.setActive(false, 80)
                else -> r.cap.releaseAll(reason, 80)
            }
            val i = r.sink.sent.indexOfLast { it is ReleaseAll }
            assertEquals("reason=$reason", reason, (r.sink.sent[i] as ReleaseAll).reason)
            val before = r.sink.sent[i - 1] as PointerAbs
            assertEquals("reason=$reason buttons", 0, before.buttons)
            assertEquals(PointerAbs.SOURCE_TOUCH, before.source)
            assertEquals("last known position", VP.normX(320f), before.x)
            assertEquals(VP.normY(410f), before.y)
            assertFalse("reason=$reason: the host must not keep LEFT reported", r.host.touchReportedHeld)
            // A fresh press after the release must be accepted by the host (its pointer lock would swallow it otherwise).
            r.cap.resume()
            r.cap.setActive(true, 90)
            r.touch(TouchAction.UP, 95, 1, finger(1, 320f, 410f)) // the old finger lifts, untracked
            r.touch(TouchAction.DOWN, 3000, 2, finger(2, 100f, 100f))
            r.tick(3060)
            assertTrue("reason=$reason: fresh press reported", r.host.touchDown)
            assertEquals("reason=$reason", 0, r.sink.pressesRejected)
        }
    }

    @Test fun aFingerAlreadyDownWhenInputResumesIsNeverReportedAsPressedUntilAFreshDown() {
        val r = Rig()
        r.touch(TouchAction.DOWN, 0, 1, finger(1, 300f, 400f))
        r.tick(60)
        r.releaseAll(ReleaseAll.FOCUS_LOST, 70)
        r.cap.resume()
        val n = r.sink.sent.size
        // Finger 1 is still on the glass: its moves, a long rest and its lift must not produce a press or a release.
        for (i in 1..20) r.touch(TouchAction.MOVE, 100L + i * 20, -1, finger(1, 300f + i, 400f))
        r.tickTo(500, 15_000)
        r.touch(TouchAction.UP, 15_100, 1, finger(1, 320f, 400f))
        assertEquals(n, r.sink.sent.size)
        assertFalse(r.host.touchReportedHeld)
        // A fresh DOWN is a press.
        r.touch(TouchAction.DOWN, 16_000, 2, finger(2, 100f, 100f))
        r.tick(16_060)
        assertEquals(Buttons.LEFT, (r.sink.sent.last() as PointerAbs).buttons)
        assertEquals(0, r.sink.pressesRejected)
    }

    @Test fun aSecondFingerLandingWhileTheFirstIsStaleStartsASinglePressNotAScroll() {
        val r = Rig()
        r.touch(TouchAction.DOWN, 0, 1, finger(1, 300f, 400f))
        r.tick(60)
        r.releaseAll(ReleaseAll.FOCUS_LOST, 70)
        r.cap.resume()
        val n = r.sink.sent.size
        r.touch(TouchAction.DOWN, 100, 2, finger(1, 300f, 400f), finger(2, 900f, 400f))
        r.tick(200)
        assertTrue(r.sink.sent.drop(n).none { it is Scroll })
        assertTrue(r.host.touchDown) // finger 2 is a fresh press
    }

    // ================= fix 1: releases do not depend on the tool type at release time =================

    @Test fun fix1_routingFollowsTheTrackerNotTheReportedToolType() {
        assertEquals(Route.TOUCH, ReleaseRouting.routeUp(ToolKind.OTHER, followedByPen = false, followedByTouch = true))
        assertEquals(Route.PEN, ReleaseRouting.routeUp(ToolKind.OTHER, followedByPen = true, followedByTouch = false))
        assertEquals(Route.TOUCH, ReleaseRouting.routeUp(ToolKind.PEN, followedByPen = false, followedByTouch = true))
        assertEquals(Route.PEN, ReleaseRouting.routeUp(ToolKind.PEN, followedByPen = false, followedByTouch = false))
        assertEquals(Route.TOUCH, ReleaseRouting.routeUp(ToolKind.FINGER, followedByPen = false, followedByTouch = false))
        assertEquals(Route.NONE, ReleaseRouting.routeUp(ToolKind.OTHER, followedByPen = false, followedByTouch = false))
        assertTrue(ReleaseRouting.cancelReachesPen(penPointerInEvent = true, followedPenPointerInEvent = false))
        assertTrue(ReleaseRouting.cancelReachesPen(penPointerInEvent = false, followedPenPointerInEvent = true))
        assertFalse(ReleaseRouting.cancelReachesPen(penPointerInEvent = false, followedPenPointerInEvent = false))
    }

    @Test fun fix1_aPressedFingerIsReleasedEvenIfTheReleaseNoLongerListsItAsAFinger() {
        val t = touchTracker()
        t.onFrame(touchFrame(TouchAction.DOWN, 0, 4, finger(4, 300f, 400f)), 0)
        t.tick(50)
        assertTrue(t.follows(4))
        assertFalse(t.follows(5))
        // The platform reports the lift as PALM/UNKNOWN: the finger list of the frame is empty.
        val out = t.onFrame(touchFrame(TouchAction.UP, 60, 4), 60)
        assertEquals(listOf(0), ptrs(out).map { it.buttons })
        assertEquals(VP.normX(300f), ptrs(out)[0].x) // last known position
        assertTrue(t.isIdle)
    }

    @Test fun fix1_aPendingFingerAndAScrollAlsoEndWhenTheReleaseIsMisclassified() {
        val a = touchTracker()
        a.onFrame(touchFrame(TouchAction.DOWN, 0, 4, finger(4, 300f, 400f)), 0)
        assertTrue(a.follows(4))
        assertEquals(listOf(Buttons.LEFT, 0), ptrs(a.onFrame(touchFrame(TouchAction.UP, 20, 4), 20)).map { it.buttons })
        val b = touchTracker()
        b.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 1000f, 900f)), 0)
        b.onFrame(touchFrame(TouchAction.DOWN, 5, 2, finger(1, 1000f, 900f), finger(2, 1200f, 900f)), 5)
        assertTrue(b.follows(1) && b.follows(2))
        val end = b.onFrame(touchFrame(TouchAction.UP, 40, 2, finger(1, 1000f, 900f)), 40)
        assertEquals(listOf(Scroll.ENDED), scrolls(end).map { it.phase })
    }

    @Test fun fix1_captureExposesTheFollowedPointersAndAMisclassifiedReleaseReachesTheHost() {
        val r = Rig()
        r.touch(TouchAction.DOWN, 0, 5, finger(5, 300f, 400f))
        r.tick(60)
        assertTrue(r.cap.followsFingerPointer(5))
        assertFalse(r.cap.followsFingerPointer(6))
        r.touch(TouchAction.UP, 80, 5) // no finger listed any more
        assertFalse(r.host.touchDown)
        assertFalse(r.cap.followsFingerPointer(5))
        r.pen(PenAction.DOWN, 200, pt(200), pointerId = 3)
        assertTrue(r.cap.followsPenPointer(3))
        assertEquals(3, r.cap.penContactPointerId)
        assertFalse(r.cap.followsPenPointer(0))
        assertTrue(r.host.penContact)
    }

    @Test fun fix1_aPenReleaseWithADifferentToolTypeStillEndsTheActiveTool() {
        val t = penTracker()
        t.onFrame(penFrame(PenAction.DOWN, pt(0), pointerId = 2), 0)
        // UP reported with the eraser tool type although the pen went down: same tool, no leave/enter dance.
        val up = t.onFrame(penFrame(PenAction.UP, pt(5), eraser = true, pointerId = 2), 5)
        assertEquals(listOf(Pen.TOOL_PEN), up.map { (it.msg as Pen).tool })
        assertEquals(listOf(IR), flags(up))
        val t2 = penTracker()
        t2.onFrame(penFrame(PenAction.DOWN, pt(0), pointerId = 2), 0)
        val cancel = t2.onFrame(penFrame(PenAction.CANCEL, pt(5), eraser = true, pointerId = 2), 5)
        assertEquals(listOf(Pen.TOOL_PEN), cancel.map { (it.msg as Pen).tool })
        assertEquals(listOf(0), flags(cancel))
    }

    // ================= fix 2: releaseAll is exception-safe =================

    private fun stroke(r: Rig) {
        r.pen(PenAction.HOVER_ENTER, 0, pt(0))
        r.pen(PenAction.DOWN, 5, pt(5))
        r.pen(PenAction.MOVE, 10, pt(10))
    }

    @Test fun fix2_releaseAllResetsTheModelAndClosesTheConnectionWhenTheSinkThrows() {
        val r = Rig()
        stroke(r)
        r.sink.throwOnSend = true
        var thrown = false
        try { r.releaseAll(ReleaseAll.BACKGROUND, 40) } catch (e: IllegalStateException) { thrown = true }
        assertTrue("the fault still reaches the caller for logging", thrown)
        assertFalse("the model must not keep believing in the stroke", r.cap.penInContact)
        assertFalse(r.cap.penInRange)
        assertEquals("the connection is closed so the host releases on disconnect", 1, r.sink.closeCalls)
        assertTrue(r.host.clear)
    }

    @Test fun fix2_aThrowingLogHookCannotSkipTheResetOrTheConnectionClose() {
        val sink = FakeSink()
        val cap = InputCapture(sink, { VP }, onEvent = { ev, _ -> if (ev == "release_all") throw IllegalStateException("log failed") })
        cap.setActive(true, 0)
        sink.nowMs = 5
        cap.onPen(penFrame(PenAction.DOWN, pt(5)), 5)
        assertTrue(cap.penInContact)
        var thrown = false
        try { cap.releaseAll(ReleaseAll.BACKGROUND, 40) } catch (e: IllegalStateException) { thrown = true }
        assertTrue(thrown)
        assertFalse("the model is forgotten whatever happened", cap.penInContact)
        assertEquals("RELEASE_ALL never went out, so the connection is dropped", 1, sink.closeCalls)
        assertTrue(sink.host.clear)
    }

    @Test fun fix2_releaseAllClosesTheConnectionWhenReleaseAllWasRefused() {
        val r = Rig()
        stroke(r)
        r.sink.accept = false // the queue refuses everything
        r.releaseAll(ReleaseAll.FOCUS_LOST, 40)
        assertEquals(1, r.sink.closeCalls)
        assertFalse(r.cap.penInContact)
    }

    @Test fun fix2_aQueuedReleaseAllDoesNotCloseTheConnection() {
        val r = Rig()
        stroke(r)
        r.releaseAll(ReleaseAll.FOCUS_LOST, 40)
        assertEquals(0, r.sink.closeCalls)
    }

    @Test fun fix2_aFailingCloseHookNeverEscapesReleaseAll() {
        var closes = 0
        val cap = InputCapture(
            object : InputSink {
                override fun send(msg: Message) = false
                override fun congested() = false
                override fun closeConnection() { closes++; throw IllegalStateException("close failed") }
            },
            { VP },
        )
        cap.setActive(true, 0)
        cap.releaseAll(ReleaseAll.BACKGROUND, 10) // must not throw
        assertEquals(1, closes)
    }

    // ================= fix 3: bound the touch side like the pen side =================

    private fun scrollRig(): Rig {
        val r = Rig()
        r.touch(TouchAction.DOWN, 0, 1, finger(1, 1000f, 900f))
        r.touch(TouchAction.DOWN, 5, 2, finger(1, 1000f, 900f), finger(2, 1200f, 900f))
        assertTrue(r.host.scrollOpen)
        return r
    }

    @Test fun fix3_aScrollWhoseFingersDoNotMoveEndsAfterFiveSecondsAndTheKeepaliveStops() {
        val r = scrollRig()
        r.tickTo(5, 4_900)
        assertTrue("still open before 5 s", r.host.scrollOpen)
        assertTrue(r.cap.scrollOpen)
        r.tickTo(4_900, 5_100)
        assertFalse(r.host.scrollOpen)
        assertFalse(r.cap.scrollOpen)
        assertEquals(1, r.sink.sent.count { it is Scroll && it.phase == Scroll.ENDED })
        val n = r.sink.sent.size
        r.tickTo(5_100, 30_000)
        assertEquals("no keepalive once the gesture is closed", n, r.sink.sent.size)
        assertEquals("the keepalive fed the host watchdog until the end", 0, r.sink.watchdogFires)
    }

    @Test fun fix3_theSameFingersMovingAgainStartANewGestureWithBegan() {
        val r = scrollRig()
        r.tickTo(5, 5_200)
        assertFalse(r.host.scrollOpen)
        val n = r.sink.sent.size
        r.touch(TouchAction.MOVE, 6_000, -1, finger(1, 1000f, 960f), finger(2, 1200f, 960f))
        val fresh = r.sink.sent.drop(n).filterIsInstance<Scroll>()
        assertEquals(listOf(Scroll.BEGAN, Scroll.CHANGED), fresh.map { it.phase })
        assertEquals(30f, fresh[1].dy, 0.001f) // 60 px = 30 pt: the movement that restarted it is not lost
        assertTrue(r.host.scrollOpen)
        r.touch(TouchAction.UP, 6_100, 1, finger(1, 1000f, 960f), finger(2, 1200f, 960f))
        assertFalse(r.host.scrollOpen)
        assertEquals(0, r.sink.watchdogFires)
    }

    @Test fun fix3_liftingAFingerOfAParkedScrollSendsNothingAndAFreshGestureStartsAfterBothLift() {
        val r = scrollRig()
        r.tickTo(5, 5_200)
        val n = r.sink.sent.size
        r.touch(TouchAction.UP, 5_500, 1, finger(1, 1000f, 900f), finger(2, 1200f, 900f))
        r.touch(TouchAction.UP, 5_600, 2, finger(2, 1200f, 900f))
        assertEquals(n, r.sink.sent.size)
        r.touch(TouchAction.DOWN, 6_000, 3, finger(3, 500f, 500f))
        r.tick(6_060)
        assertTrue(r.host.touchDown)
    }

    @Test fun fix3_aPressedFingerWithoutAnyEventForTenSecondsIsReleasedAndForgotten() {
        val r = Rig()
        r.touch(TouchAction.DOWN, 0, 1, finger(1, 300f, 400f))
        r.tick(60)
        assertTrue(r.host.touchDown)
        r.tickTo(60, 10_000)
        assertTrue("still pressed before 10 s", r.host.touchDown)
        r.tickTo(10_000, 10_200)
        assertFalse(r.host.touchDown)
        assertFalse(r.cap.fingerPressed)
        assertEquals(0, (r.sink.sent.last() as PointerAbs).buttons)
        assertFalse(r.host.touchReportedHeld) // reported released, so the pointer lock is clear
        val n = r.sink.sent.size
        r.touch(TouchAction.MOVE, 11_000, -1, finger(1, 310f, 400f))
        r.touch(TouchAction.UP, 11_100, 1, finger(1, 310f, 400f))
        assertEquals("the forgotten finger produces nothing", n, r.sink.sent.size)
        r.touch(TouchAction.DOWN, 12_000, 2, finger(2, 100f, 100f))
        r.tick(12_060)
        assertTrue("a fresh DOWN is a fresh press", r.host.touchDown)
        assertEquals(0, r.sink.pressesRejected)
    }

    @Test fun fix3_movementKeepsAPressedFingerAlive() {
        val r = Rig()
        r.touch(TouchAction.DOWN, 0, 1, finger(1, 300f, 400f))
        r.tick(60)
        var t = 60L
        var x = 300f
        while (t < 60_000) {
            t += 5_000
            x += 3f
            r.tickTo(t - 5_000, t - 1)
            r.touch(TouchAction.MOVE, t, -1, finger(1, x, 400f))
        }
        assertTrue(r.host.touchDown)
        assertTrue(r.cap.fingerPressed)
    }

    // ================= fix 4: the finger gate uses the host's clock =================

    @Test fun fix4_theGateRunsFromTheLastPenMessageSentNotFromTheLastAndroidEvent() {
        val t = touchTracker()
        presence.inRange = false
        presence.lastSentMs = 1_000
        t.onFrame(touchFrame(TouchAction.DOWN, 1_900, 1, finger(1, 10f, 10f)), 1_900)
        assertTrue(t.isIdle)
        t.onFrame(touchFrame(TouchAction.DOWN, 2_000, 2, finger(2, 10f, 10f)), 2_000)
        assertFalse(t.isIdle)
    }

    @Test fun fix4_penTrackerReportsTheTimeOfItsLastEmittedMessageIncludingRepeatsAndTheSyntheticLeave() {
        val t = penTracker()
        t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(1000)), 1000)
        assertEquals(1000L, t.lastSentMs)
        t.tick(1100) // liveness repeat
        assertEquals(1100L, t.lastSentMs)
        assertEquals(1000L, t.lastEventMs) // the real Android event time is kept for the stale guards
        var now = 1100L
        while (t.inRange && now < 10_000) { now += 25; t.tick(now) } // the 2 s stale guard sends flags = 0
        assertFalse("the stale guard closed the hover", t.inRange)
        assertTrue(now >= 3000L)
        assertEquals(now, t.lastSentMs)
    }

    @Test fun fix4_afterAFastLiftTheClientRefusesAFingerThatTheHostWouldIgnore() {
        val r = Rig()
        r.pen(PenAction.DOWN, 0, pt(0))
        r.pen(PenAction.UP, 20, pt(20)) // fast lift: Android sends no hover events afterwards
        r.tickTo(20, 2_100)
        val leaveIdx = r.sink.sent.indexOfLast { m -> m is Pen && m.samples.all { it.flags == 0 } }
        assertTrue("the stale guard closed the hover", leaveIdx >= 0)
        val leaveAt = r.sink.sentAt[leaveIdx]
        assertTrue(leaveAt in 2_000..2_100)
        // A finger lands 100 ms after the synthetic leave: the host gate (1 s from that message) would ignore it.
        r.touch(TouchAction.DOWN, leaveAt + 100, 1, finger(1, 500f, 500f))
        r.tickTo(leaveAt + 100, leaveAt + 300)
        r.touch(TouchAction.UP, leaveAt + 320, 1, finger(1, 500f, 500f))
        assertTrue(r.sink.sent.none { it is PointerAbs })
        assertEquals(0, r.sink.pressesRejected)
        // Once the host gate has expired the same touch is a press.
        r.touch(TouchAction.DOWN, leaveAt + 1_100, 2, finger(2, 500f, 500f))
        r.tick(leaveAt + 1_160)
        assertTrue(r.host.touchDown)
        assertEquals(0, r.sink.pressesRejected)
    }

    @Test fun fix4_aPenMessageSentDuringTheHoldOffDropsTheHeldBackPressInsteadOfSendingAnIgnoredOne() {
        val r = Rig()
        r.touch(TouchAction.DOWN, 1_000, 1, finger(1, 300f, 400f)) // gate open, DOWN is held back
        r.pen(PenAction.CANCEL, 1_010, pt(1_010)) // a stray cancel emits flags = 0: the host gate is now closed
        r.tick(1_060)
        assertTrue(r.sink.sent.none { it is PointerAbs })
        assertEquals(0, r.sink.pressesRejected)
        assertFalse(r.cap.fingerPressed)
    }

    @Test fun fix4_aTapWhoseGateClosedDuringTheHoldOffIsDropped() {
        val t = touchTracker()
        t.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 300f, 400f)), 0)
        presence.lastSentMs = 10 // a PEN message went out meanwhile
        val out = t.onFrame(touchFrame(TouchAction.UP, 20, 1, finger(1, 300f, 400f)), 20)
        assertTrue(out.isEmpty())
        assertTrue(t.isIdle)
    }

    // ================= fix 5: the pen entering range closes an open scroll, and the gate blocks a new one =================

    @Test fun fix5_penEnteringRangeCancelsAnOpenScrollAndTheFingersStayIgnored() {
        val r = scrollRig()
        r.pen(PenAction.HOVER_ENTER, 100, pt(100))
        assertEquals(Scroll.CANCELLED, r.sink.sent.filterIsInstance<Scroll>().last().phase)
        assertFalse(r.host.scrollOpen)
        assertFalse(r.cap.scrollOpen)
        val n = r.sink.sent.size
        r.touch(TouchAction.MOVE, 120, -1, finger(1, 1000f, 950f), finger(2, 1200f, 950f))
        r.touch(TouchAction.MOVE, 140, -1, finger(1, 1000f, 990f), finger(2, 1200f, 990f))
        // a palm finger landing next must not restart anything, gate or lockout
        r.touch(TouchAction.DOWN, 160, 3, finger(1, 1000f, 990f), finger(2, 1200f, 990f), finger(3, 50f, 50f))
        r.tick(300)
        assertTrue("nothing but the pen's own messages", r.sink.sent.drop(n).none { it is Scroll || it is PointerAbs })
        assertEquals(0, r.sink.watchdogFires)
    }

    @Test fun fix5_theGateBlocksANewScrollFromStartingAsWellAsANewPress() {
        val t = touchTracker()
        t.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 1000f, 900f)), 0)
        presence.inRange = true
        presence.lastSentMs = 0
        val out = t.onFrame(touchFrame(TouchAction.DOWN, 5, 2, finger(1, 1000f, 900f), finger(2, 1200f, 900f)), 5)
        assertTrue(out.isEmpty())
        assertTrue(scrolls(t.tick(500)).isEmpty())
    }

    @Test fun fix5_aParkedScrollDoesNotRestartWhileThePenIsNear() {
        val t = touchTracker()
        t.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 1000f, 900f)), 0)
        t.onFrame(touchFrame(TouchAction.DOWN, 5, 2, finger(1, 1000f, 900f), finger(2, 1200f, 900f)), 5)
        var now = 5L
        while (now < 5_100) { now += 25; t.tick(now) } // idle end: parked
        presence.inRange = true
        val out = t.onFrame(touchFrame(TouchAction.MOVE, 6_000, -1, finger(1, 1000f, 960f), finger(2, 1200f, 960f)), 6_000)
        assertTrue(out.isEmpty())
        assertTrue(t.isIdle)
    }

    @Test fun fix5_penRangeBeginAlsoClosesAParkedScrollWithoutAMessage() {
        val t = touchTracker()
        t.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 1000f, 900f)), 0)
        t.onFrame(touchFrame(TouchAction.DOWN, 5, 2, finger(1, 1000f, 900f), finger(2, 1200f, 900f)), 5)
        var now = 5L
        while (now < 5_100) { now += 25; t.tick(now) }
        assertTrue(t.onPenRangeBegan(5_200).isEmpty()) // ENDED already went out at the idle end
        assertTrue(t.isIdle)
    }

    // ================= fix 6: no new press until every finger has lifted after a scroll =================

    @Test fun fix6_afterAScrollEndsANewFingerDoesNotTurnIntoAClickWhileTheOtherStaysDown() {
        val t = touchTracker()
        t.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 1000f, 900f)), 0)
        t.onFrame(touchFrame(TouchAction.DOWN, 5, 2, finger(1, 1000f, 900f), finger(2, 1200f, 900f)), 5)
        val end = t.onFrame(touchFrame(TouchAction.UP, 40, 1, finger(1, 1000f, 900f), finger(2, 1200f, 900f)), 40)
        assertEquals(listOf(Scroll.ENDED), scrolls(end).map { it.phase })
        assertTrue(t.isLockedOut)
        // Finger 2 is still down; finger 3 lands: neither a pending press nor a click 40 ms later.
        val third = t.onFrame(touchFrame(TouchAction.DOWN, 80, 3, finger(2, 1200f, 900f), finger(3, 300f, 300f)), 80)
        assertTrue(third.isEmpty())
        assertTrue(t.tick(200).isEmpty())
        assertTrue(t.onFrame(touchFrame(TouchAction.UP, 220, 3, finger(2, 1200f, 900f), finger(3, 300f, 300f)), 220).isEmpty())
        // Only when the last finger lifts is touch accepted again.
        assertTrue(t.onFrame(touchFrame(TouchAction.UP, 260, 2, finger(2, 1200f, 900f)), 260).isEmpty())
        assertFalse(t.isLockedOut)
        t.onFrame(touchFrame(TouchAction.DOWN, 400, 4, finger(4, 100f, 100f)), 400)
        assertEquals(listOf(Buttons.LEFT), ptrs(t.tick(460)).map { it.buttons })
    }

    @Test fun fix6_aFreshTouchWithNoOtherFingerDownClearsTheLockout() {
        val t = touchTracker()
        t.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 1000f, 900f)), 0)
        t.onFrame(touchFrame(TouchAction.DOWN, 5, 2, finger(1, 1000f, 900f), finger(2, 1200f, 900f)), 5)
        t.onFrame(touchFrame(TouchAction.UP, 40, 1, finger(1, 1000f, 900f), finger(2, 1200f, 900f)), 40)
        assertTrue(t.isLockedOut)
        // The leftover finger vanished without us seeing its UP: a DOWN with nobody else down is a new touch.
        t.onFrame(touchFrame(TouchAction.DOWN, 100, 3, finger(3, 300f, 300f)), 100)
        assertFalse(t.isLockedOut)
        assertFalse(t.isIdle)
    }

    @Test fun fix6_theLockoutAlsoHoldsAfterAForcedScrollEnd() {
        val r = scrollRig()
        r.releaseAll(ReleaseAll.FOCUS_LOST, 50)
        r.cap.resume()
        val n = r.sink.sent.size
        // Both old fingers are still down; a new one lands.
        r.touch(TouchAction.DOWN, 100, 3, finger(1, 1000f, 900f), finger(2, 1200f, 900f), finger(3, 300f, 300f))
        r.tick(300)
        assertEquals(n, r.sink.sent.size)
    }

    // ================= fix 7: history is read for every pen action =================

    @Test fun fix7_aDownCarryingHistoryKeepsEverySampleAndStrokeStartOnlyOnTheFirst() {
        val t = penTracker()
        val out = t.onFrame(penFrame(PenAction.DOWN, pt(0, x = 100f), pt(3, x = 110f), pt(6, x = 120f)), 6)
        assertEquals(1, out.size)
        val s = (out[0].msg as Pen).samples
        assertEquals(listOf(IR or CT or SS, IR or CT, IR or CT), s.map { it.flags })
        assertEquals(listOf(VP.normX(100f), VP.normX(110f), VP.normX(120f)), s.map { it.x })
        assertEquals(listOf(0L, 3000L, 6000L), s.map { it.dtUs })
        assertEquals(PenTracker.State.CONTACT, t.state)
    }

    @Test fun fix7_aDownWhileAlreadyInContactStillEndsTheOldContactBeforeTheHistoryStartsTheNewStroke() {
        val t = penTracker()
        t.onFrame(penFrame(PenAction.DOWN, pt(0)), 0)
        val out = t.onFrame(penFrame(PenAction.DOWN, pt(10), pt(13)), 13)
        assertEquals(listOf(IR, IR or CT or SS, IR or CT), flags(out))
    }

    @Test fun fix7_anUpCarryingHistoryKeepsTheContactSamplesThenLifts() {
        val t = penTracker()
        t.onFrame(penFrame(PenAction.DOWN, pt(0)), 0)
        val out = t.onFrame(penFrame(PenAction.UP, pt(3), pt(6), pt(9)), 9)
        assertEquals(listOf(IR or CT, IR or CT, IR), flags(out))
    }

    @Test fun fix7_aHoverExitCarryingHistoryKeepsTheHoverSamplesThenLeavesAfterTheDeferral() {
        val t = penTracker()
        t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(0)), 0)
        val out = t.onFrame(penFrame(PenAction.HOVER_EXIT, pt(3, x = 10f), pt(6, x = 20f), pt(9, x = 30f)), 9)
        assertEquals(listOf(IR, IR), flags(out)) // the two batched positions
        assertEquals(listOf(VP.normX(10f), VP.normX(20f)), penSamples(out.messages()).map { it.x })
        val leave = penSamples(t.tick(9 + PenTracker.EXIT_DEFER_MS).messages())
        assertEquals(listOf(0), leave.map { it.flags })
        assertEquals(VP.normX(30f), leave[0].x) // the exit itself is at the last position
    }

    @Test fun fix7_aHoverExitWithHistoryWhileOutOnlyLeaves() {
        val t = penTracker()
        val out = t.onFrame(penFrame(PenAction.HOVER_EXIT, pt(3), pt(6)), 6)
        assertEquals(listOf(0), flags(out))
    }

    // ================= stats fields =================

    @Test fun theSummaryCarriesTheNewGuardCounters() {
        val c = InputCounters()
        c.pressStale = 2
        c.scrollIdleEnds = 3
        assertTrue(c.any())
        val f = c.fields(1000)
        assertTrue(f, f.contains("press_stale=2") && f.contains("scroll_idle_end=3"))
    }
}
