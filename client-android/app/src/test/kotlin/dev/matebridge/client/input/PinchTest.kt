package dev.matebridge.client.input

import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.Pinch
import dev.matebridge.client.protocol.PointerAbs
import dev.matebridge.client.protocol.PointerRel
import dev.matebridge.client.protocol.ReleaseAll
import dev.matebridge.client.protocol.Scroll
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-037: two-finger pinch on the touchscreen and the touchpad, classification, gate ownership, merging and release paths. */
class PinchTest {
    private val presence = FakePresence()
    private val counters = InputCounters()

    // ---------------- classifier ----------------

    private val K = TwoFingerClassifier.Kind.PINCH
    private val S = TwoFingerClassifier.Kind.SCROLL

    @Test fun classifierPinchWhenDistanceChangesAndTheCentroidStays() {
        assertEquals(K, TwoFingerClassifier.classify(200f, 216f, 3f, 16f, 140f))
        assertEquals(K, TwoFingerClassifier.classify(200f, 180f, 3f, 16f, 140f))
    }

    @Test fun classifierScrollWhenTheCentroidMovesFirst() {
        assertEquals(S, TwoFingerClassifier.classify(200f, 204f, 20f, 16f, 140f))
        assertEquals(S, TwoFingerClassifier.classify(200f, 200f, 17f, 16f, 140f))
    }

    @Test fun classifierWaitsBelowBothThresholds() {
        assertNull(TwoFingerClassifier.classify(200f, 210f, 10f, 16f, 140f)) // 5 percent, 10 px
        assertNull(TwoFingerClassifier.classify(200f, 200f, 0f, 16f, 140f))
    }

    @Test fun classifierSameFrameCrossingIsDecidedByWhichMovedMore() {
        assertEquals(K, TwoFingerClassifier.classify(200f, 300f, 30f, 16f, 140f)) // 100 px spread, 30 px slide
        assertEquals(S, TwoFingerClassifier.classify(200f, 230f, 60f, 16f, 140f)) // 30 px spread, 60 px slide
    }

    @Test fun classifierBaselineDistanceHasAFloor() {
        // Fingers 10 px apart: 5 px of jitter is 50 percent of the distance but only 3.5 percent of the floor.
        assertNull(TwoFingerClassifier.classify(10f, 15f, 0f, 16f, 140f))
    }

    @Test fun scaleIsRelativeAndClamped() {
        assertEquals(0.05f, TwoFingerClassifier.scale(200f, 210f), 1e-6f)
        assertEquals(-0.25f, TwoFingerClassifier.scale(200f, 150f), 1e-6f)
        assertEquals(1f, TwoFingerClassifier.scale(100f, 300f), 0f)
        assertEquals(-0.5f, TwoFingerClassifier.scale(100f, 10f), 0f)
        assertEquals(0f, TwoFingerClassifier.scale(0f, 10f), 0f)
    }

    // ---------------- touchscreen ----------------

    private fun tracker() = TouchTracker({ VP }, presence, counters).also { it.widthPt = 1400; it.heightPt = 920 }

    private fun pinches(out: List<Outgoing>) = out.messages().filterIsInstance<Pinch>()
    private fun scrolls(out: List<Outgoing>) = out.messages().filterIsInstance<Scroll>()

    /** Two fingers down at (1000, 900) and (1200, 900): distance 200. */
    private fun twoDown(t: TouchTracker) {
        t.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 1000f, 900f)), 0)
        t.onFrame(touchFrame(TouchAction.DOWN, 5, 2, finger(1, 1000f, 900f), finger(2, 1200f, 900f)), 5)
    }

    /** Fingers at x = 1100 -/+ [half] on the row y = 900: distance 2 * half, centre (1100, 900). */
    private fun spread(t: TouchTracker, ms: Long, half: Float) =
        t.onFrame(touchFrame(TouchAction.MOVE, ms, -1, finger(1, 1100f - half, 900f), finger(2, 1100f + half, 900f)), ms)

    @Test fun spreadingStartsAPinchWithBeganThenTheScaleSinceTheBaseline() {
        val t = tracker()
        twoDown(t)
        val out = spread(t, 20, 150f) // 200 -> 300 px
        val p = pinches(out)
        assertEquals(listOf(Pinch.BEGAN, Pinch.CHANGED), p.map { it.phase })
        assertTrue(scrolls(out).isEmpty())
        assertEquals(0f, p[0].scale, 0f)
        assertEquals(0.5f, p[1].scale, 1e-5f)
        assertTrue(p.all { it.source == Pinch.SOURCE_TOUCH })
        assertTrue(p.all { it.x == VP.normX(1100f) && it.y == VP.normY(900f) })
        assertFalse(out[0].mergeable)
        assertTrue(out[1].mergeable)
        assertTrue(t.isPinching)
        // Next step is relative to the previous distance: 300 -> 400.
        val next = pinches(spread(t, 30, 200f))
        assertEquals(1, next.size)
        assertEquals(1f / 3f, next[0].scale, 1e-5f)
    }

    @Test fun pinchCenterFollowsTheFingers() {
        val t = tracker()
        twoDown(t)
        spread(t, 20, 150f)
        val out = t.onFrame(touchFrame(TouchAction.MOVE, 30, -1, finger(1, 1000f, 950f), finger(2, 1400f, 950f)), 30)
        val p = pinches(out)
        assertEquals(1, p.size)
        assertEquals(VP.normX(1200f), p[0].x)
        assertEquals(VP.normY(950f), p[0].y)
    }

    @Test fun belowSixPercentNothingIsDecidedAndNothingIsSent() {
        val t = tracker()
        twoDown(t)
        assertTrue(spread(t, 10, 105f).isEmpty()) // 200 -> 210: 5 percent
        assertFalse(t.isPinching)
        assertFalse(t.isScrolling)
        val out = spread(t, 20, 108f) // 216: 8 percent, measured from the baseline
        val p = pinches(out)
        assertEquals(listOf(Pinch.BEGAN, Pinch.CHANGED), p.map { it.phase })
        assertEquals(0.08f, p[1].scale, 1e-5f)
    }

    @Test fun aCommonSlideFirstIsAScrollAndStaysOneEvenWhenTheFingersSpreadLater() {
        val t = tracker()
        twoDown(t)
        val out = t.slide(10)
        assertEquals(listOf(Scroll.BEGAN, Scroll.CHANGED), scrolls(out).map { it.phase })
        assertTrue(pinches(out).isEmpty())
        // Fingers now spread by 100 px: still a scroll, no pinch message, the centroid did not move so no delta.
        val later = t.onFrame(touchFrame(TouchAction.MOVE, 30, -1, finger(1, 950f, 930f), finger(2, 1250f, 930f)), 30)
        assertTrue(pinches(later).isEmpty())
        assertTrue(t.isScrolling)
    }

    @Test fun aPinchStaysAPinchWhenTheFingersSlideLater() {
        val t = tracker()
        twoDown(t)
        spread(t, 20, 150f)
        val out = t.onFrame(touchFrame(TouchAction.MOVE, 30, -1, finger(1, 950f, 1100f), finger(2, 1250f, 1100f)), 30)
        assertTrue(scrolls(out).isEmpty()) // same distance: no scale, no scroll
        assertTrue(t.isPinching)
    }

    @Test fun oneLargeStepIsClamped() {
        val t = tracker()
        twoDown(t)
        val p = pinches(spread(t, 20, 400f)) // 200 -> 800 px: +300 percent
        assertEquals(Pinch.MAX_SCALE, p[1].scale, 0f)
        val q = pinches(spread(t, 30, 40f)) // 800 -> 80: -90 percent
        assertEquals(Pinch.MIN_SCALE, q[0].scale, 0f)
    }

    @Test fun liftingEitherFingerEndsThePinchAndTheOtherIsIgnored() {
        val t = tracker()
        twoDown(t)
        spread(t, 20, 150f)
        val end = t.onFrame(touchFrame(TouchAction.UP, 40, 1, finger(1, 950f, 900f), finger(2, 1250f, 900f)), 40)
        assertEquals(listOf(Pinch.ENDED), pinches(end).map { it.phase })
        assertEquals(0f, pinches(end)[0].scale, 0f)
        assertFalse(end[0].mergeable)
        assertTrue(t.isLockedOut)
        assertTrue(t.onFrame(touchFrame(TouchAction.MOVE, 60, -1, finger(2, 1300f, 900f)), 60).isEmpty())
        assertTrue(t.tick(500).isEmpty())
        assertTrue(t.onFrame(touchFrame(TouchAction.UP, 80, 2, finger(2, 1300f, 900f)), 80).isEmpty())
        assertFalse(t.isPinching)
    }

    @Test fun anUndecidedGestureSendsNothingWhenTheFingersLiftOrAreCancelled() {
        val t = tracker()
        twoDown(t)
        assertTrue(t.follows(TOUCH_DEVICE, 1) && t.follows(TOUCH_DEVICE, 2))
        assertTrue(t.onFrame(touchFrame(TouchAction.UP, 40, 1, finger(1, 1000f, 900f), finger(2, 1200f, 900f)), 40).isEmpty())
        assertTrue(t.isLockedOut)
        val u = tracker()
        twoDown(u)
        assertTrue(u.onFrame(touchFrame(TouchAction.CANCEL, 40, -1), 40).isEmpty())
        assertTrue(u.release(50).isEmpty())
        assertTrue(u.isIdle)
    }

    @Test fun restingFingersKeepAPinchAliveAndThenEndItAfterFiveSeconds() {
        val t = tracker()
        twoDown(t)
        spread(t, 20, 150f)
        assertTrue(t.tick(100).isEmpty())
        val ka = pinches(t.tick(20 + TouchTracker.SCROLL_KEEPALIVE_MS))
        assertEquals(1, ka.size)
        assertEquals(Pinch.CHANGED, ka[0].phase)
        assertEquals(0f, ka[0].scale, 0f)
        assertEquals(VP.normX(1100f), ka[0].x)
        var now = 20L
        val all = ArrayList<Pinch>()
        while (now < 5_100) { now += 25; all += pinches(t.tick(now)) }
        assertEquals(1, all.count { it.phase == Pinch.ENDED })
        assertFalse(t.isPinching)
        assertEquals(1L, counters.scrollIdleEnds)
        // The same fingers moving again restart a pinch of the same kind, relative to where they rested.
        val again = pinches(spread(t, 6_000, 180f)) // 300 -> 360
        assertEquals(listOf(Pinch.BEGAN, Pinch.CHANGED), again.map { it.phase })
        assertEquals(0.2f, again[1].scale, 1e-5f)
    }

    @Test fun penInRangeOrRecentlyActiveRefusesANewPinch() {
        val t = tracker()
        twoDown(t)
        presence.inRange = true
        presence.lastSentMs = 0
        assertTrue(spread(t, 20, 150f).isEmpty())
        assertTrue(t.isIdle)
        assertEquals(1L, counters.palmRejects)
        // Not in range any more, but inside the 1.2 s hold: refused as well (the second finger DOWN is refused).
        val u = tracker()
        presence.inRange = false
        presence.lastSentMs = 1_000
        u.onFrame(touchFrame(TouchAction.DOWN, 1_100, 1, finger(1, 1000f, 900f)), 1_100)
        u.onFrame(touchFrame(TouchAction.DOWN, 1_105, 2, finger(1, 1000f, 900f), finger(2, 1200f, 900f)), 1_105)
        assertTrue(spread(u, 1_120, 150f).isEmpty())
        // Two fingers that were down before the pen appeared and decide while the pen is in range.
        val v = tracker()
        presence.lastSentMs = NEVER_MS
        twoDown(v)
        presence.inRange = true
        assertTrue(spread(v, 30, 150f).isEmpty())
        assertTrue(v.isIdle)
        assertTrue(v.isLockedOut)
    }

    @Test fun penEnteringRangeCancelsAnOpenPinch() {
        val t = tracker()
        twoDown(t)
        spread(t, 20, 150f)
        val out = t.onPenRangeBegan(50)
        assertEquals(listOf(Pinch.CANCELLED), pinches(out).map { it.phase })
        assertTrue(t.isIdle)
        assertTrue(t.onFrame(touchFrame(TouchAction.MOVE, 70, -1, finger(1, 900f, 900f), finger(2, 1300f, 900f)), 70).isEmpty())
    }

    @Test fun disablingFingersAndReleaseCancelAnOpenPinch() {
        val a = tracker()
        twoDown(a); spread(a, 20, 150f)
        assertEquals(listOf(Pinch.CANCELLED), pinches(a.setPolicy(FingerPolicy.OFF, 50)).map { it.phase })
        val b = tracker()
        twoDown(b); spread(b, 20, 150f)
        assertEquals(listOf(Pinch.CANCELLED), pinches(b.release(50)).map { it.phase })
        assertTrue(b.release(60).isEmpty())
    }

    @Test fun aDisabledTrackerRefusesTheSecondFingerSoNoPinchStarts() {
        val t = tracker()
        t.setPolicy(FingerPolicy.OFF, 0)
        twoDown(t)
        assertTrue(spread(t, 20, 150f).isEmpty())
    }

    // ---------------- touchpad ----------------

    private val rel = RelPointerTracker(counters).also { it.widthPt = 1000 }

    private fun f(id: Int, x: Float, y: Float) = Finger(id, x, y)

    private fun pad(action: PadAction, ms: Long, acting: Int, vararg fingers: Finger): List<Message> =
        rel.onPad(PadFrame(action, acting, fingers.toList(), ms * 1000, PAD, 0, 0, 1000f), ms).messages()

    private fun padTwoDown() {
        pad(PadAction.DOWN, 0, 0, f(0, 100f, 100f))
        pad(PadAction.DOWN, 5, 1, f(0, 100f, 100f), f(1, 400f, 100f)) // distance 300, slop 20, floor 50
    }

    @Test fun padSpreadIsAPinchFromTheTouchpadWithCenterZero() {
        padTwoDown()
        val m = pad(PadAction.MOVE, 20, -1, f(0, 80f, 100f), f(1, 420f, 100f)) // 300 -> 340
        val p = m.filterIsInstance<Pinch>()
        assertEquals(listOf(Pinch.BEGAN, Pinch.CHANGED), p.map { it.phase })
        assertTrue(p.all { it.source == Pinch.SOURCE_TOUCHPAD && it.x == 0 && it.y == 0 })
        assertEquals(0f, p[0].scale, 0f)
        assertEquals(340f / 300f - 1f, p[1].scale, 1e-5f)
        assertTrue(m.none { it is Scroll || it is PointerRel })
        assertTrue(rel.isPinching)
        assertTrue(rel.holdsState)
        val next = pad(PadAction.MOVE, 30, -1, f(0, 60f, 100f), f(1, 440f, 100f)).filterIsInstance<Pinch>()
        assertEquals(380f / 340f - 1f, next.single().scale, 1e-5f)
    }

    @Test fun padCommonSlideStillScrollsAndNeverBecomesAPinch() {
        padTwoDown()
        val m = pad(PadAction.MOVE, 20, -1, f(0, 100f, 140f), f(1, 400f, 140f))
        assertEquals(listOf(Scroll.BEGAN, Scroll.CHANGED), m.filterIsInstance<Scroll>().map { it.phase })
        val later = pad(PadAction.MOVE, 30, -1, f(0, 60f, 140f), f(1, 440f, 140f))
        assertTrue(later.none { it is Pinch })
        assertTrue(rel.isScrolling)
    }

    @Test fun padPinchEndsWhenAFingerLiftsWhenBothLiftTogetherAndOnRelease() {
        padTwoDown()
        pad(PadAction.MOVE, 20, -1, f(0, 80f, 100f), f(1, 420f, 100f))
        val end = pad(PadAction.UP, 40, 1, f(0, 80f, 100f), f(1, 420f, 100f))
        assertEquals(listOf(Pinch.ENDED), end.filterIsInstance<Pinch>().map { it.phase })
        assertFalse(rel.isPinching)
        pad(PadAction.UP, 50, 0, f(0, 80f, 100f))
        // release()
        rel.reset()
        padTwoDownFresh()
        pad(PadAction.MOVE, 20, -1, f(0, 80f, 100f), f(1, 420f, 100f))
        val rl = rel.release(60).messages().filterIsInstance<Pinch>()
        assertEquals(listOf(Pinch.ENDED), rl.map { it.phase })
        assertFalse(rel.holdsState)
    }

    private fun padTwoDownFresh() {
        // After a reset the pointers already on the pad are ignored until they lift: lift and touch again.
        pad(PadAction.UP, 1, 0, f(0, 100f, 100f))
        pad(PadAction.UP, 2, 1, f(1, 400f, 100f))
        padTwoDown()
    }

    @Test fun padPinchKeepaliveAndIdleEnd() {
        padTwoDown()
        pad(PadAction.MOVE, 20, -1, f(0, 80f, 100f), f(1, 420f, 100f))
        val ka = rel.tick(20 + PadTuning.SCROLL_KEEPALIVE_MS).messages().filterIsInstance<Pinch>()
        assertEquals(listOf(Pinch.CHANGED), ka.map { it.phase })
        assertEquals(0f, ka[0].scale, 0f)
        val end = rel.tick(20 + PadTuning.SCROLL_IDLE_END_MS).messages().filterIsInstance<Pinch>()
        assertEquals(listOf(Pinch.ENDED), end.map { it.phase })
        assertTrue(rel.tick(20 + PadTuning.SCROLL_IDLE_END_MS + 500).isEmpty())
        val again = pad(PadAction.MOVE, 6_000, -1, f(0, 60f, 100f), f(1, 440f, 100f)).filterIsInstance<Pinch>()
        assertEquals(listOf(Pinch.BEGAN, Pinch.CHANGED), again.map { it.phase })
    }

    // ---------------- capture level: gate, release paths ----------------

    private val sink = FakeSink()
    private val cap = InputCapture(sink, { VP }).also {
        it.setActive(true, 0)
        it.setStreamGeometry(1400, 920)
    }

    private fun touch(action: TouchAction, ms: Long, acting: Int, vararg fs: Finger) {
        sink.nowMs = ms
        cap.onTouch(TouchFrame(action, acting, fs.toList(), ms * 1000, TOUCH_DEVICE), ms)
    }

    private fun capPad(action: PadAction, ms: Long, acting: Int, vararg fs: Finger) {
        sink.nowMs = ms
        cap.onPad(PadFrame(action, acting, fs.toList(), ms * 1000, PAD, 0, 0, 1000f), ms)
    }

    private fun phases() = sink.sent.mapNotNull {
        when (it) {
            is Pinch -> "P" + it.phase
            is Scroll -> if (it.phase != Scroll.NONE) "S" + it.phase else null
            else -> null
        }
    }

    private fun touchPinch() {
        touch(TouchAction.DOWN, 0, 1, finger(1, 1000f, 900f))
        touch(TouchAction.DOWN, 5, 2, finger(1, 1000f, 900f), finger(2, 1200f, 900f))
        touch(TouchAction.MOVE, 20, -1, finger(1, 950f, 900f), finger(2, 1250f, 900f))
    }

    private fun padPair(base: Long) {
        capPad(PadAction.DOWN, base, 0, f(0, 100f, 100f))
        capPad(PadAction.DOWN, base + 5, 1, f(0, 100f, 100f), f(1, 400f, 100f))
    }

    @Test fun aPadScrollOrPinchIsDroppedWhileTheTouchscreenOwnsAPinch() {
        touchPinch()
        assertEquals(listOf("P1", "P2"), phases())
        sink.clearSent()
        padPair(100)
        capPad(PadAction.MOVE, 130, -1, f(0, 100f, 140f), f(1, 400f, 140f)) // a pad scroll
        assertTrue(phases().isEmpty())
        // The owner continues and ends; ownership is free afterwards.
        touch(TouchAction.MOVE, 200, -1, finger(1, 900f, 900f), finger(2, 1300f, 900f))
        touch(TouchAction.UP, 210, 1, finger(2, 1300f, 900f))
        assertEquals(listOf("P2", "P3"), phases())
    }

    @Test fun aTouchPinchIsDroppedWhileThePadOwnsAScrollAndTheOtherWayRound() {
        padPair(0)
        capPad(PadAction.MOVE, 30, -1, f(0, 100f, 140f), f(1, 400f, 140f))
        assertEquals(listOf("S1", "S2"), phases())
        sink.clearSent()
        touchPinch()
        assertTrue(phases().isEmpty())
        touch(TouchAction.UP, 40, 1, finger(2, 1250f, 900f))
        assertTrue("the suppressed ENDED is dropped too", phases().isEmpty())
        // Pad scroll ends: free. A pad pinch then owns, and a touch scroll cannot start.
        capPad(PadAction.UP, 60, 1, f(0, 100f, 140f), f(1, 400f, 140f))
        assertEquals(listOf("S3"), phases())
    }

    @Test fun aSecondOpenGestureOfAnotherKindFromTheSameSourceCannotCoexist() {
        // The touchscreen ends its pinch (finger lift) and, after every finger lifted, may start a scroll.
        touchPinch()
        touch(TouchAction.UP, 40, 1, finger(1, 950f, 900f), finger(2, 1250f, 900f))
        touch(TouchAction.UP, 50, 2, finger(2, 1250f, 900f))
        touch(TouchAction.DOWN, 100, 3, finger(3, 1000f, 900f))
        touch(TouchAction.DOWN, 105, 4, finger(3, 1000f, 900f), finger(4, 1200f, 900f))
        touch(TouchAction.MOVE, 120, -1, finger(3, 1000f, 940f), finger(4, 1200f, 940f))
        assertEquals(listOf("P1", "P2", "P3", "S1", "S2"), phases())
    }

    @Test fun releaseAllCancelsAnOpenPinchBeforeReleaseAll() {
        touchPinch()
        sink.clearSent()
        cap.releaseAll(ReleaseAll.FOCUS_LOST, 50)
        assertEquals(listOf("P4"), phases())
        assertTrue(sink.sent.last() is ReleaseAll)
        assertFalse(cap.pinchOpen)
    }

    @Test fun deviceRemovalClosesAnOpenPinch() {
        touchPinch()
        sink.clearSent()
        cap.onDeviceRemoved(TOUCH_DEVICE, 50)
        assertEquals(listOf("P4"), phases())
        assertTrue(sink.sent.last() is ReleaseAll)
    }

    @Test fun captureLossEndsAnOpenPadPinch() {
        padPair(0)
        capPad(PadAction.MOVE, 30, -1, f(0, 80f, 100f), f(1, 420f, 100f))
        assertEquals(listOf("P1", "P2"), phases())
        sink.clearSent()
        cap.onPointerCaptureLost(50)
        assertEquals(listOf("P3"), phases())
    }

    @Test fun thePenComingIntoRangeCancelsTheTouchPinchAndASessionResetFreesTheOwnership() {
        touchPinch()
        sink.clearSent()
        sink.nowMs = 60
        cap.onPen(penFrame(PenAction.HOVER_ENTER, pt(60)), 60)
        assertEquals(listOf("P4"), phases())
        // A new connection: nothing is held, ownership is forgotten, a new pad pinch passes.
        cap.onPen(penFrame(PenAction.HOVER_EXIT, pt(70)), 70)
        cap.tick(200)
        cap.onSessionReset()
        sink.clearSent()
        padPair(3_000)
        capPad(PadAction.MOVE, 3_030, -1, f(0, 80f, 100f), f(1, 420f, 100f))
        assertEquals(listOf("P1", "P2"), phases())
    }

    @Test fun aTouchPinchProducesOnlyEncodablePinchMessages() {
        touchPinch() // FakeSink encodes every message
        assertTrue(sink.sent.filterIsInstance<Pinch>().all { it.source == Pinch.SOURCE_TOUCH })
        assertTrue(sink.sent.none { it is PointerAbs })
    }

    // ---------------- outbox ----------------

    private val outSink = FakeSink()
    private val outCounters = InputCounters()
    private val outbox = InputOutbox(outSink, outCounters) {}

    private fun pinch(phase: Int, scale: Float = 0f, x: Int = 0, source: Int = Pinch.SOURCE_TOUCH) =
        Outgoing(Pinch(0, scale, x, x, phase, source), phase == Pinch.CHANGED)

    @Test fun congestedPinchChangedMergeByProductWithTheNewestCenter() {
        outSink.congestedNow = true
        outbox.send(pinch(Pinch.CHANGED, 0.1f, x = 10))
        outbox.send(pinch(Pinch.CHANGED, 0.2f, x = 20))
        assertTrue(outSink.sent.isEmpty())
        assertEquals(1L, outCounters.merged)
        outSink.congestedNow = false
        outbox.tick()
        val m = outSink.sent.single() as Pinch
        assertEquals(1.1f * 1.2f - 1f, m.scale, 1e-5f)
        assertEquals(20, m.x)
        assertEquals(1L, outCounters.pinchMsgs)
    }

    @Test fun pinchBeganEndedAndCancelledAreNeverMergedOrReordered() {
        outSink.congestedNow = true
        outbox.send(pinch(Pinch.BEGAN))
        outbox.send(pinch(Pinch.CHANGED, 0.1f))
        outbox.send(pinch(Pinch.CHANGED, 0.1f))
        outbox.send(pinch(Pinch.ENDED))
        outbox.send(pinch(Pinch.BEGAN))
        outbox.send(pinch(Pinch.CHANGED, -0.2f))
        outbox.send(pinch(Pinch.CANCELLED))
        assertEquals(listOf(Pinch.BEGAN, Pinch.CHANGED, Pinch.ENDED, Pinch.BEGAN, Pinch.CHANGED, Pinch.CANCELLED), outSink.sent.filterIsInstance<Pinch>().map { it.phase })
        assertEquals(1.1f * 1.1f - 1f, (outSink.sent[1] as Pinch).scale, 1e-5f)
        assertFalse(outbox.hasHeld)
    }

    @Test fun aProductOutsideTheWireRangeOrAnotherSourceIsNotMerged() {
        outSink.congestedNow = true
        outbox.send(pinch(Pinch.CHANGED, 0.8f))
        outbox.send(pinch(Pinch.CHANGED, 0.8f)) // 2.24 - 1 > 1.0
        assertEquals(1, outSink.sent.size)
        assertEquals(0.8f, (outSink.sent[0] as Pinch).scale, 0f)
        outbox.flush()
        assertEquals(2, outSink.sent.size)
        outSink.clearSent()
        outbox.send(pinch(Pinch.CHANGED, 0.1f, source = Pinch.SOURCE_TOUCH))
        outbox.send(pinch(Pinch.CHANGED, 0.1f, source = Pinch.SOURCE_TOUCHPAD))
        assertEquals(1, outSink.sent.size)
    }

    @Test fun aPinchIsNotMergedWithAScroll() {
        assertNull(InputOutbox.merge(Pinch(0, 0.1f, 0, 0, Pinch.CHANGED, 0), Scroll(0, 1f, 1f, Scroll.CHANGED)))
    }

    private companion object {
        const val PAD = 7
    }
}
