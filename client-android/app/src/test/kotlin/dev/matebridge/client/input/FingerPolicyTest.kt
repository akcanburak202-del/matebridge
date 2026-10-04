package dev.matebridge.client.input

import dev.matebridge.client.protocol.Buttons
import dev.matebridge.client.protocol.Pinch
import dev.matebridge.client.protocol.PointerAbs
import dev.matebridge.client.protocol.Scroll
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-223 (decision 0030 §1): Çizim's "gestures only" finger policy. One finger sends nothing (a palm cannot click or
 * drag), two-finger scroll and pinch still reach the Mac, and a policy change mid-contact releases only what the new
 * policy no longer allows (never a stuck button, never an invented release).
 */
class FingerPolicyTest {
    private val presence = FakePresence()
    private val counters = InputCounters()

    private fun tracker() = TouchTracker({ VP }, presence, counters).also { it.widthPt = 1400; it.heightPt = 920 }

    private fun TouchTracker.gesturesOnly() = also { assertTrue(setPolicy(FingerPolicy.GESTURES_ONLY, 0).isEmpty()) }

    private fun ptrs(out: List<Outgoing>) = out.messages().filterIsInstance<PointerAbs>()
    private fun pinches(out: List<Outgoing>) = out.messages().filterIsInstance<Pinch>().map { it.phase }
    private fun scrolls(out: List<Outgoing>) = out.messages().filterIsInstance<Scroll>().map { it.phase }

    private fun down(t: TouchTracker, ms: Long, id: Int, vararg f: Finger) =
        t.onFrame(touchFrame(TouchAction.DOWN, ms, id, *f), ms)

    private fun move(t: TouchTracker, ms: Long, vararg f: Finger) = t.onFrame(touchFrame(TouchAction.MOVE, ms, -1, *f), ms)
    private fun up(t: TouchTracker, ms: Long, id: Int, vararg f: Finger) = t.onFrame(touchFrame(TouchAction.UP, ms, id, *f), ms)

    private fun twoDown(t: TouchTracker): List<Outgoing> =
        down(t, 0, 1, finger(1, 1000f, 900f)) + down(t, 5, 2, finger(1, 1000f, 900f), finger(2, 1200f, 900f))

    private fun spread(t: TouchTracker, ms: Long, half: Float) =
        move(t, ms, finger(1, 1100f - half, 900f), finger(2, 1100f + half, 900f))

    // ---- one finger is silent ----

    @Test fun aSingleTapSendsNothing() {
        val t = tracker().gesturesOnly()
        assertTrue(down(t, 0, 1, finger(1, 300f, 300f)).isEmpty())
        assertTrue(t.tick(100).isEmpty()) // the hold time passes: no press
        assertTrue(up(t, 110, 1, finger(1, 300f, 300f)).isEmpty()) // and no click
        assertTrue(t.isIdle)
        assertFalse(t.isPressed)
    }

    @Test fun aOneFingerDragSendsNothing() {
        val t = tracker().gesturesOnly()
        assertTrue(down(t, 0, 1, finger(1, 300f, 300f)).isEmpty())
        assertTrue(move(t, 10, finger(1, 600f, 600f)).isEmpty()) // far beyond the slop
        assertTrue(t.tick(100).isEmpty())
        assertTrue(move(t, 120, finger(1, 900f, 900f)).isEmpty())
        assertTrue(up(t, 130, 1, finger(1, 900f, 900f)).isEmpty())
        assertTrue(t.isIdle)
    }

    @Test fun aSilentFingerWhoseLiftWasLostIsForgotten() {
        val t = tracker().gesturesOnly()
        down(t, 0, 1, finger(1, 300f, 300f))
        assertFalse(t.isIdle)
        t.tick(TouchTracker.PRESS_STALE_MS - 1)
        assertFalse(t.isIdle)
        assertTrue(t.tick(TouchTracker.PRESS_STALE_MS).isEmpty())
        assertTrue(t.isIdle) // no ghost "first finger" left for the next touch
    }

    @Test fun aMovingSilentFingerIsNotForgottenAndASecondFingerStillStartsAGesture() {
        // Codex re-review: the stale guard counts from the last event of the contact, not from the DOWN.
        val t = tracker().gesturesOnly()
        down(t, 0, 1, finger(1, 1000f, 900f))
        var now = 0L
        while (now < TouchTracker.PRESS_STALE_MS + 2_000) { // well past the stale limit, the finger keeps moving
            now += 1_000
            assertTrue(move(t, now, finger(1, 1000f + (now / 1000) * 3f, 900f)).isEmpty())
            assertTrue(t.tick(now).isEmpty())
            assertFalse("still tracked at $now", t.isIdle)
        }
        val x1 = 1000f + (now / 1000) * 3f
        assertTrue(down(t, now + 100, 2, finger(1, x1, 900f), finger(2, x1 + 200f, 900f)).isEmpty())
        val out = move(t, now + 120, finger(1, x1 - 50f, 900f), finger(2, x1 + 250f, 900f))
        assertEquals(listOf(Pinch.BEGAN, Pinch.CHANGED), pinches(out))
    }

    @Test fun aMovingSilentFingerThenTwoFingerScrollPasses() {
        val t = tracker().gesturesOnly()
        down(t, 0, 1, finger(1, 1000f, 900f))
        var now = 0L
        while (now < TouchTracker.PRESS_STALE_MS + 1_000) { now += 1_000; move(t, now, finger(1, 1000f, 900f + now / 1000)); t.tick(now) }
        val y1 = 900f + now / 1000
        down(t, now + 100, 2, finger(1, 1000f, y1), finger(2, 1200f, y1))
        val out = move(t, now + 120, finger(1, 1000f, y1 + 60f), finger(2, 1200f, y1 + 60f))
        assertEquals(listOf(Scroll.BEGAN, Scroll.CHANGED), scrolls(out))
    }

    @Test fun aFingerThatStopsSendingEventsIsStillForgottenAfterAMove() {
        val t = tracker().gesturesOnly()
        down(t, 0, 1, finger(1, 300f, 300f))
        move(t, 5_000, finger(1, 320f, 300f)) // last event
        t.tick(5_000 + TouchTracker.PRESS_STALE_MS - 1)
        assertFalse(t.isIdle)
        t.tick(5_000 + TouchTracker.PRESS_STALE_MS)
        assertTrue(t.isIdle)
    }

    @Test fun aPressedFingerKeepsItsOwnStaleRuleUnderTheDefaultPolicy() {
        // Unchanged by the fix: ALL still releases a pressed finger PRESS_STALE_MS after its last event, never earlier.
        val t = tracker()
        down(t, 0, 1, finger(1, 300f, 300f))
        move(t, 10, finger(1, 500f, 500f)) // pressed
        assertTrue(t.isPressed)
        assertTrue(t.tick(10 + TouchTracker.PRESS_STALE_MS - 1).isEmpty())
        assertEquals(listOf(0), ptrs(t.tick(10 + TouchTracker.PRESS_STALE_MS)).map { it.buttons })
    }

    // ---- reconciliation with the live pointer list (Codex): a finger the tracker let go of is never a first finger ----

    @Test fun expiredSilentFingerThenPolicyChangeThenSecondFingerClicksNothing() {
        val t = tracker().gesturesOnly()
        down(t, 0, 1, finger(1, 300f, 300f))
        t.tick(TouchTracker.PRESS_STALE_MS) // the silent contact expires; finger 1 is still on the glass
        assertTrue(t.isIdle)
        assertTrue(t.setPolicy(FingerPolicy.ALL, TouchTracker.PRESS_STALE_MS + 10).isEmpty()) // Ctrl+Shift+7 to Oyun
        val now = TouchTracker.PRESS_STALE_MS + 100
        assertTrue(down(t, now, 2, finger(1, 300f, 300f), finger(2, 900f, 300f)).isEmpty())
        assertTrue(t.tick(now + 100).isEmpty()) // no LEFT after the hold time
        assertTrue(move(t, now + 120, finger(1, 300f, 300f), finger(2, 1200f, 600f)).isEmpty()) // and no drag
        assertTrue(t.isLockedOut)
        assertTrue(up(t, now + 200, 2, finger(1, 300f, 300f), finger(2, 1200f, 600f)).isEmpty())
        assertTrue(up(t, now + 210, 1, finger(1, 300f, 300f)).isEmpty())
        assertFalse(t.isLockedOut) // every finger lifted
        down(t, now + 300, 3, finger(3, 100f, 100f)) // a fresh touch presses as usual
        assertEquals(listOf(Buttons.LEFT), ptrs(t.tick(now + 360)).map { it.buttons })
    }

    @Test fun expiredPressInAllWithTheFingerStillDownThenSecondFingerClicksNothing() {
        val t = tracker()
        down(t, 0, 1, finger(1, 300f, 300f))
        move(t, 10, finger(1, 500f, 500f)) // pressed
        assertEquals(listOf(0), ptrs(t.tick(10 + TouchTracker.PRESS_STALE_MS)).map { it.buttons }) // stale: released
        assertTrue(t.isIdle)
        val now = TouchTracker.PRESS_STALE_MS + 100
        assertTrue(down(t, now, 2, finger(1, 500f, 500f), finger(2, 900f, 300f)).isEmpty())
        assertTrue(t.tick(now + 100).isEmpty()) // no LEFT
        assertTrue(t.isLockedOut)
    }

    @Test fun aFirstFingerAloneStillPressesNormally() {
        val t = tracker()
        down(t, 0, 1, finger(1, 300f, 300f))
        assertEquals(listOf(Buttons.LEFT), ptrs(t.tick(50)).map { it.buttons })
        assertFalse(t.isLockedOut)
    }

    // ---- two fingers still work ----

    @Test fun twoFingerPinchPasses() {
        val t = tracker().gesturesOnly()
        assertTrue(twoDown(t).isEmpty())
        assertEquals(listOf(Pinch.BEGAN, Pinch.CHANGED), pinches(spread(t, 20, 150f)))
        assertTrue(t.isPinching)
        assertEquals(listOf(Pinch.ENDED), pinches(up(t, 40, 1, finger(1, 950f, 900f), finger(2, 1250f, 900f))))
        assertTrue(t.isIdle)
    }

    @Test fun twoFingerScrollPasses() {
        val t = tracker().gesturesOnly()
        twoDown(t)
        val out = move(t, 20, finger(1, 1000f, 950f), finger(2, 1200f, 950f))
        assertEquals(listOf(Scroll.BEGAN, Scroll.CHANGED), scrolls(out))
        assertTrue(t.isScrolling)
        assertEquals(listOf(Scroll.ENDED), scrolls(up(t, 40, 1, finger(1, 1000f, 950f), finger(2, 1200f, 950f))))
    }

    @Test fun nothingIsSentForTheFirstFingerWhenTheSecondOneArrives() {
        val t = tracker().gesturesOnly()
        down(t, 0, 1, finger(1, 1000f, 900f))
        t.tick(200) // the first finger rests for a while, silently
        assertTrue(down(t, 210, 2, finger(1, 1000f, 900f), finger(2, 1200f, 900f)).isEmpty())
        assertEquals(listOf(Pinch.BEGAN, Pinch.CHANGED), pinches(spread(t, 230, 150f)))
    }

    // ---- switching mid-contact ----

    @Test fun enteringMidOneFingerDragSendsTheButtonUpAndNothingElse() {
        val t = tracker()
        down(t, 0, 1, finger(1, 300f, 300f))
        move(t, 10, finger(1, 500f, 500f)) // beyond the slop: pressed, a drag
        assertTrue(t.isPressed)
        val out = t.setPolicy(FingerPolicy.GESTURES_ONLY, 20)
        assertEquals(listOf(0), ptrs(out).map { it.buttons }) // exactly the matching up
        assertFalse(t.isPressed)
        assertTrue(move(t, 30, finger(1, 600f, 600f)).isEmpty()) // the finger is still on the glass: silent
        assertTrue(t.tick(200).isEmpty())
        assertTrue(up(t, 210, 1, finger(1, 600f, 600f)).isEmpty()) // and no second up, no click
        assertTrue(t.isIdle)
    }

    @Test fun afterTheDragIsReleasedASecondFingerStillStartsAGesture() {
        val t = tracker()
        down(t, 0, 1, finger(1, 1000f, 900f))
        move(t, 10, finger(1, 1000f, 930f))
        t.setPolicy(FingerPolicy.GESTURES_ONLY, 20)
        assertTrue(down(t, 30, 2, finger(1, 1000f, 930f), finger(2, 1200f, 930f)).isEmpty())
        assertEquals(listOf(Pinch.BEGAN, Pinch.CHANGED), pinches(move(t, 50, finger(1, 950f, 930f), finger(2, 1250f, 930f))))
    }

    @Test fun enteringWhileAFingerIsPendingOwesNothing() {
        val t = tracker()
        down(t, 0, 1, finger(1, 300f, 300f)) // inside the hold time: nothing was sent
        assertTrue(t.setPolicy(FingerPolicy.GESTURES_ONLY, 10).isEmpty())
        assertTrue(t.tick(100).isEmpty())
        assertTrue(up(t, 110, 1, finger(1, 300f, 300f)).isEmpty())
    }

    @Test fun aPinchInProgressAcrossTheSwitchIsNotCancelled() {
        val t = tracker()
        twoDown(t)
        assertEquals(listOf(Pinch.BEGAN, Pinch.CHANGED), pinches(spread(t, 20, 150f)))
        assertTrue(t.setPolicy(FingerPolicy.GESTURES_ONLY, 30).isEmpty()) // nothing cancelled, nothing invented
        assertTrue(t.isPinching)
        assertEquals(listOf(Pinch.CHANGED), pinches(spread(t, 40, 200f)))
        assertEquals(listOf(Pinch.ENDED), pinches(up(t, 60, 1, finger(1, 900f, 900f), finger(2, 1300f, 900f)))) // one clean ENDED
        // and leaving again mid-pinch changes nothing either
        val u = tracker().gesturesOnly()
        twoDown(u); spread(u, 20, 150f)
        assertTrue(u.setPolicy(FingerPolicy.ALL, 30).isEmpty())
        assertTrue(u.isPinching)
    }

    @Test fun aScrollInProgressAcrossTheSwitchIsNotCancelled() {
        val t = tracker()
        twoDown(t)
        move(t, 20, finger(1, 1000f, 950f), finger(2, 1200f, 950f))
        assertTrue(t.isScrolling)
        assertTrue(t.setPolicy(FingerPolicy.GESTURES_ONLY, 30).isEmpty())
        assertTrue(t.isScrolling)
        assertEquals(listOf(Scroll.ENDED), scrolls(up(t, 50, 1, finger(1, 1000f, 950f), finger(2, 1200f, 950f))))
    }

    @Test fun fullyOffStillCancelsEverything() {
        val pinch = tracker().gesturesOnly()
        twoDown(pinch); spread(pinch, 20, 150f)
        assertEquals(listOf(Pinch.CANCELLED), pinches(pinch.setPolicy(FingerPolicy.OFF, 30)))
        assertTrue(pinch.isIdle)
        val scroll = tracker()
        twoDown(scroll); move(scroll, 20, finger(1, 1000f, 950f), finger(2, 1200f, 950f))
        assertEquals(listOf(Scroll.CANCELLED), scrolls(scroll.setPolicy(FingerPolicy.OFF, 30)))
        val drag = tracker()
        down(drag, 0, 1, finger(1, 300f, 300f)); move(drag, 10, finger(1, 500f, 500f))
        assertEquals(listOf(0), ptrs(drag.setPolicy(FingerPolicy.OFF, 20)).map { it.buttons })
        // OFF refuses even the second finger of a gesture
        assertTrue(down(drag, 100, 1, finger(1, 10f, 10f)).isEmpty())
        assertTrue(down(drag, 105, 2, finger(1, 10f, 10f), finger(2, 400f, 10f)).isEmpty())
        assertTrue(drag.isIdle)
    }

    @Test fun leavingWhileASilentFingerIsHeldDoesNotTurnItIntoAPress() {
        val t = tracker().gesturesOnly()
        down(t, 0, 1, finger(1, 300f, 300f))
        assertTrue(t.setPolicy(FingerPolicy.ALL, 500).isEmpty()) // nothing was sent, nothing is owed
        assertTrue(t.tick(600).isEmpty()) // no press from a finger that only rested while Çizim was on
        assertTrue(move(t, 610, finger(1, 700f, 700f)).isEmpty())
        assertTrue(up(t, 620, 1, finger(1, 700f, 700f)).isEmpty())
        // a fresh touch works again at once
        down(t, 700, 2, finger(2, 300f, 300f))
        assertEquals(listOf(Buttons.LEFT), ptrs(t.tick(760)).map { it.buttons })
    }

    @Test fun allToAllAndRepeatedPoliciesAreNoOps() {
        val t = tracker()
        assertTrue(t.setPolicy(FingerPolicy.ALL, 0).isEmpty())
        t.gesturesOnly()
        assertTrue(t.setPolicy(FingerPolicy.GESTURES_ONLY, 5).isEmpty())
        assertEquals(FingerPolicy.GESTURES_ONLY, t.policy)
        assertFalse(t.disabled)
        t.setDisabled(true, 10)
        assertTrue(t.disabled)
        assertEquals(FingerPolicy.OFF, t.policy)
    }

    // ---- through the capture layer: the releases reach the host ----

    private val sink = FakeSink()
    private val cap = InputCapture(sink, { VP }, onEvent = { _, _ -> }) { }

    private fun capTouch(action: TouchAction, now: Long, acting: Int, vararg f: Finger) {
        sink.nowMs = now
        cap.onTouch(touchFrame(action, now, acting, *f), now)
    }

    private fun capPolicy(p: FingerPolicy, now: Long) { sink.nowMs = now; cap.setFingerPolicy(p, now) }

    private fun setUpCap() {
        cap.setActive(true, 0)
        cap.setStreamGeometry(1400, 920)
    }

    @Test fun throughTheCaptureEnteringCizimMidDragLetsTheHostSeeTheUp() {
        setUpCap()
        capTouch(TouchAction.DOWN, 0, 1, finger(1, 300f, 300f))
        capTouch(TouchAction.MOVE, 10, -1, finger(1, 500f, 500f))
        assertTrue(sink.host.touchDown)
        capPolicy(FingerPolicy.GESTURES_ONLY, 20)
        assertFalse(sink.host.touchDown)
        assertTrue(sink.host.clear)
        assertEquals(FingerPolicy.GESTURES_ONLY, cap.fingerPolicy)
        assertFalse(cap.fingersDisabled) // not the "tamamen kapat" switch
        val n = sink.sent.size
        capTouch(TouchAction.MOVE, 30, -1, finger(1, 600f, 600f))
        capTouch(TouchAction.UP, 40, 1, finger(1, 600f, 600f))
        assertEquals(n, sink.sent.size)
        assertTrue(sink.host.violations.isEmpty())
    }

    @Test fun throughTheCaptureAPalmTapSendsNothingButPinchStillReachesTheHost() {
        setUpCap()
        capPolicy(FingerPolicy.GESTURES_ONLY, 0)
        capTouch(TouchAction.DOWN, 10, 1, finger(1, 300f, 300f))
        sink.nowMs = 100; sink.tickHost(); cap.tick(100)
        capTouch(TouchAction.UP, 110, 1, finger(1, 300f, 300f))
        assertTrue(sink.sent.isEmpty())
        capTouch(TouchAction.DOWN, 200, 2, finger(2, 1000f, 900f))
        capTouch(TouchAction.DOWN, 205, 3, finger(2, 1000f, 900f), finger(3, 1200f, 900f))
        capTouch(TouchAction.MOVE, 220, -1, finger(2, 950f, 900f), finger(3, 1250f, 900f))
        assertEquals(listOf(Pinch.BEGAN, Pinch.CHANGED), sink.sent.filterIsInstance<Pinch>().map { it.phase })
    }

    @Test fun throughTheCaptureAPinchAcrossTheSwitchEndsCleanly() {
        setUpCap()
        capTouch(TouchAction.DOWN, 0, 1, finger(1, 1000f, 900f))
        capTouch(TouchAction.DOWN, 5, 2, finger(1, 1000f, 900f), finger(2, 1200f, 900f))
        capTouch(TouchAction.MOVE, 20, -1, finger(1, 950f, 900f), finger(2, 1250f, 900f))
        capPolicy(FingerPolicy.GESTURES_ONLY, 30)
        assertTrue(sink.sent.filterIsInstance<Pinch>().none { it.phase == Pinch.CANCELLED })
        capTouch(TouchAction.UP, 40, 1, finger(1, 950f, 900f), finger(2, 1250f, 900f))
        assertEquals(Pinch.ENDED, sink.sent.filterIsInstance<Pinch>().last().phase)
        assertTrue(sink.host.violations.isEmpty())
    }
}
