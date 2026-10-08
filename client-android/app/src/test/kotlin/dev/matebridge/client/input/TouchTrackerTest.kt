package dev.matebridge.client.input

import dev.matebridge.client.protocol.Buttons
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.PointerAbs
import dev.matebridge.client.protocol.Scroll
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TouchTrackerTest {
    private val presence = FakePresence()
    private val counters = InputCounters()

    private fun tracker(widthPt: Int = 1400, heightPt: Int = 920) = TouchTracker({ VP }, presence, counters).also {
        it.widthPt = widthPt
        it.heightPt = heightPt
    }

    private fun ptrs(out: List<Outgoing>) = out.messages().filterIsInstance<PointerAbs>()
    private fun scrolls(out: List<Outgoing>) = out.messages().filterIsInstance<Scroll>()
    private fun buttons(out: List<Outgoing>) = ptrs(out).map { it.buttons }

    @Test fun tapSendsDownThenUpAtTheTouchDownPosition() {
        val t = tracker()
        assertTrue(t.onFrame(touchFrame(TouchAction.DOWN, 0, 7, finger(7, 500f, 600f)), 0).isEmpty()) // held back
        val out = t.onFrame(touchFrame(TouchAction.UP, 20, 7, finger(7, 503f, 604f)), 20)
        val p = ptrs(out)
        assertEquals(listOf(Buttons.LEFT, 0), p.map { it.buttons })
        assertTrue(p.all { it.source == PointerAbs.SOURCE_TOUCH })
        assertTrue(p.all { it.x == VP.normX(500f) && it.y == VP.normY(600f) }) // a click, not a nudge
        assertTrue(t.isIdle)
    }

    @Test fun downIsSentOnTickAfterTheHoldOff() {
        val t = tracker()
        t.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 100f, 100f)), 0)
        assertTrue(t.tick(TouchTracker.HOLD_MS - 1).isEmpty())
        assertEquals(listOf(Buttons.LEFT), buttons(t.tick(TouchTracker.HOLD_MS)))
        val move = t.onFrame(touchFrame(TouchAction.MOVE, 60, -1, finger(1, 130f, 100f)), 60)
        assertEquals(listOf(Buttons.LEFT), buttons(move))
        assertEquals(VP.normX(130f), ptrs(move)[0].x)
        val up = t.onFrame(touchFrame(TouchAction.UP, 80, 1, finger(1, 130f, 100f)), 80)
        assertEquals(listOf(0), buttons(up))
        assertEquals(VP.normX(130f), ptrs(up)[0].x)
    }

    @Test fun movingBeyondTheSlopStartsTheDragAtOnce() {
        val t = tracker()
        t.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 100f, 100f)), 0)
        assertTrue(t.onFrame(touchFrame(TouchAction.MOVE, 5, -1, finger(1, 105f, 100f)), 5).isEmpty())
        val out = t.onFrame(touchFrame(TouchAction.MOVE, 10, -1, finger(1, 140f, 100f)), 10)
        assertEquals(listOf(Buttons.LEFT, Buttons.LEFT), buttons(out))
        assertEquals(VP.normX(100f), ptrs(out)[0].x) // DOWN where the finger landed
        assertEquals(VP.normX(140f), ptrs(out)[1].x) // then the drag
    }

    @Test fun twoFingersStartAScrollWithoutAnyClick() {
        val t = tracker()
        val all = ArrayList<Message>()
        all += t.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 1000f, 900f)), 0).messages()
        all += t.onFrame(touchFrame(TouchAction.DOWN, 12, 2, finger(1, 1000f, 900f), finger(2, 1200f, 900f)), 12).messages()
        assertTrue(all.none { it is PointerAbs })
        assertTrue("nothing is sent before the first movement is classified", all.isEmpty())
        all += t.slide(20).messages()
        val sc = all.filterIsInstance<Scroll>()
        assertEquals(listOf(Scroll.BEGAN, Scroll.CHANGED), sc.map { it.phase })
        assertEquals(0f, sc[0].dx, 0f)
        assertEquals(15f, sc[1].dy, 0.001f) // the movement that decided is not lost
        assertTrue(t.tick(500).none { it.msg is PointerAbs }) // the first finger never becomes a press
    }

    @Test fun secondFingerAfterAPressReleasesItThenScrolls() {
        val t = tracker()
        t.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 1000f, 900f)), 0)
        t.tick(50) // DOWN sent
        val out = t.onFrame(touchFrame(TouchAction.DOWN, 100, 2, finger(1, 1000f, 900f), finger(2, 1200f, 900f)), 100)
        val msgs = out.messages()
        assertEquals(1, msgs.size)
        assertEquals(0, (msgs[0] as PointerAbs).buttons) // UP first
        assertEquals(Scroll.BEGAN, (t.slide(120).messages()[0] as Scroll).phase)
    }

    @Test fun scrollDeltasAreCentroidMotionInMacPoints() {
        val t = tracker(widthPt = 1400, heightPt = 920) // 2800x1840 px -> 1400x920 pt: 0.5 pt per px
        t.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 1000f, 900f)), 0)
        t.onFrame(touchFrame(TouchAction.DOWN, 5, 2, finger(1, 1000f, 900f), finger(2, 1200f, 900f)), 5)
        val out = t.onFrame(touchFrame(TouchAction.MOVE, 20, -1, finger(1, 1100f, 1000f), finger(2, 1300f, 1000f)), 20)
        val s = scrolls(out)
        assertEquals(listOf(Scroll.BEGAN, Scroll.CHANGED), s.map { it.phase })
        assertEquals(50f, s[1].dx, 0.001f)
        assertEquals(50f, s[1].dy, 0.001f)
        assertTrue(out[1].mergeable)
        // No movement, no message.
        assertTrue(t.onFrame(touchFrame(TouchAction.MOVE, 30, -1, finger(1, 1100f, 1000f), finger(2, 1300f, 1000f)), 30).isEmpty())
    }

    @Test fun scrollEndsWhenEitherFingerLiftsAndTheOtherIsIgnoredUntilItLifts() {
        val t = tracker()
        t.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 1000f, 900f)), 0)
        t.onFrame(touchFrame(TouchAction.DOWN, 5, 2, finger(1, 1000f, 900f), finger(2, 1200f, 900f)), 5)
        t.slide(10)
        val end = t.onFrame(touchFrame(TouchAction.UP, 40, 1, finger(1, 1000f, 900f), finger(2, 1200f, 900f)), 40)
        assertEquals(listOf(Scroll.ENDED), scrolls(end).map { it.phase })
        assertFalse(end[0].mergeable)
        // The remaining finger neither scrolls nor clicks.
        assertTrue(t.onFrame(touchFrame(TouchAction.MOVE, 60, -1, finger(2, 1250f, 900f)), 60).isEmpty())
        assertTrue(t.tick(500).isEmpty())
        assertTrue(t.onFrame(touchFrame(TouchAction.UP, 80, 2, finger(2, 1250f, 900f)), 80).isEmpty())
    }

    @Test fun restingFingersKeepTheHostScrollWatchdogAlive() {
        val t = tracker()
        t.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 1000f, 900f)), 0)
        t.onFrame(touchFrame(TouchAction.DOWN, 5, 2, finger(1, 1000f, 900f), finger(2, 1200f, 900f)), 5)
        assertTrue(t.tick(100).isEmpty()) // undecided: nothing open, nothing to keep alive
        t.slide(10)
        assertTrue(t.tick(100).isEmpty())
        val ka = scrolls(t.tick(10 + TouchTracker.SCROLL_KEEPALIVE_MS))
        assertEquals(1, ka.size)
        assertEquals(Scroll.CHANGED, ka[0].phase)
        assertEquals(0f, ka[0].dx, 0f)
        assertTrue(t.tick(10 + TouchTracker.SCROLL_KEEPALIVE_MS + 50).isEmpty())
        assertEquals(1, scrolls(t.tick(10 + 2 * TouchTracker.SCROLL_KEEPALIVE_MS)).size)
    }

    @Test fun scrollNeedsTheStreamGeometry() {
        val t = tracker(widthPt = 0, heightPt = 0)
        t.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 1000f, 900f)), 0)
        val out = t.onFrame(touchFrame(TouchAction.DOWN, 5, 2, finger(1, 1000f, 900f), finger(2, 1200f, 900f)), 5)
        assertTrue(out.isEmpty())
    }

    @Test fun thirdFingerIsIgnored() {
        val t = tracker()
        t.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 1000f, 900f)), 0)
        t.onFrame(touchFrame(TouchAction.DOWN, 5, 2, finger(1, 1000f, 900f), finger(2, 1200f, 900f)), 5)
        val out = t.onFrame(touchFrame(TouchAction.DOWN, 9, 3, finger(1, 1000f, 900f), finger(2, 1200f, 900f), finger(3, 50f, 50f)), 9)
        assertTrue(out.isEmpty())
        t.onFrame(touchFrame(TouchAction.MOVE, 20, -1, finger(1, 1000f, 930f), finger(2, 1200f, 930f), finger(3, 50f, 50f)), 20)
        assertEquals(listOf(Scroll.ENDED), scrolls(t.onFrame(touchFrame(TouchAction.UP, 30, 2, finger(1, 1000f, 900f), finger(2, 1200f, 900f), finger(3, 50f, 50f)), 30)).map { it.phase })
    }

    @Test fun actionCancelReleasesAPressedFingerAndCancelsAScroll() {
        // pressed finger
        val a = tracker()
        a.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 300f, 400f)), 0)
        a.tick(50)
        val upOnCancel = a.onFrame(touchFrame(TouchAction.CANCEL, 60, -1, finger(1, 300f, 400f)), 60)
        assertEquals(listOf(0), buttons(upOnCancel))
        assertTrue(a.isIdle)
        // scroll in progress
        val b = tracker()
        b.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 1000f, 900f)), 0)
        b.onFrame(touchFrame(TouchAction.DOWN, 5, 2, finger(1, 1000f, 900f), finger(2, 1200f, 900f)), 5)
        b.slide(10)
        val c = b.onFrame(touchFrame(TouchAction.CANCEL, 60, -1, finger(1, 1000f, 900f), finger(2, 1200f, 900f)), 60)
        assertEquals(listOf(Scroll.CANCELLED), scrolls(c).map { it.phase })
        assertTrue(b.isIdle)
        // a finger that was only pending sends nothing at all
        val d = tracker()
        d.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 300f, 400f)), 0)
        assertTrue(d.onFrame(touchFrame(TouchAction.CANCEL, 5, -1, finger(1, 300f, 400f)), 5).isEmpty())
        assertTrue(d.tick(500).isEmpty())
    }

    @Test fun newPressIsRefusedWhileThePenIsInRangeAndForOneSecondAfter() {
        val t = tracker()
        presence.inRange = true
        presence.lastSentMs = 0
        assertTrue(t.onFrame(touchFrame(TouchAction.DOWN, 100, 1, finger(1, 10f, 10f)), 100).isEmpty())
        assertTrue(t.tick(500).isEmpty())
        assertTrue(t.isIdle)
        assertEquals(1L, counters.palmRejects)
        // The pen left at t=200: still refused for 1 s...
        presence.inRange = false
        presence.lastSentMs = 200
        t.onFrame(touchFrame(TouchAction.DOWN, 1100, 2, finger(2, 10f, 10f)), 1100)
        assertTrue(t.isIdle)
        assertEquals(2L, counters.palmRejects)
        // ...and accepted once the client's gate (host's 1 s plus a 200 ms margin) has passed.
        t.onFrame(touchFrame(TouchAction.DOWN, 1300, 3, finger(3, 10f, 10f)), 1300)
        assertTrue(t.isIdle) // 1100 ms after the pen message: past the host's second, still inside the margin
        t.onFrame(touchFrame(TouchAction.DOWN, 1400, 4, finger(4, 10f, 10f)), 1400)
        assertFalse(t.isIdle)
    }

    @Test fun releasesAreNeverRefusedByTheGate() {
        val t = tracker()
        t.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 300f, 400f)), 0)
        t.tick(50)
        presence.inRange = true // pen arrives (the capture layer would call onPenRangeBegan; here it does not)
        presence.lastSentMs = 60
        val up = t.onFrame(touchFrame(TouchAction.UP, 80, 1, finger(1, 300f, 400f)), 80)
        assertEquals(listOf(0), buttons(up))
    }

    @Test fun penEnteringRangeReleasesAPendingOrPressedFingerAndIgnoresItAfterwards() {
        // pressed
        val t = tracker()
        t.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 300f, 400f)), 0)
        t.tick(50)
        assertEquals(listOf(0), buttons(t.onPenRangeBegan(60)))
        assertTrue(t.onFrame(touchFrame(TouchAction.MOVE, 70, -1, finger(1, 320f, 400f)), 70).isEmpty())
        assertTrue(t.onFrame(touchFrame(TouchAction.UP, 90, 1, finger(1, 320f, 400f)), 90).isEmpty())
        // pending: nothing was sent, nothing to release
        val p = tracker()
        p.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 300f, 400f)), 0)
        assertTrue(p.onPenRangeBegan(10).isEmpty())
        assertTrue(p.tick(500).isEmpty())
        assertEquals(2L, counters.palmRejects)
    }

    @Test fun disabledSettingRefusesPressesAndReleasesHeldFingers() {
        val t = tracker()
        t.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 300f, 400f)), 0)
        t.tick(50)
        assertEquals(listOf(0), buttons(t.setPolicy(FingerPolicy.OFF, 60)))
        assertTrue(t.onFrame(touchFrame(TouchAction.DOWN, 100, 2, finger(2, 10f, 10f)), 100).isEmpty())
        assertTrue(t.tick(500).isEmpty())
        assertTrue(t.isIdle)
        assertTrue(t.setPolicy(FingerPolicy.ALL, 600).isEmpty())
        t.onFrame(touchFrame(TouchAction.DOWN, 700, 3, finger(3, 10f, 10f)), 700)
        assertFalse(t.isIdle)
    }

    @Test fun releaseEndsWhateverIsHeld() {
        val t = tracker()
        t.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 300f, 400f)), 0)
        t.tick(50)
        assertEquals(listOf(0), buttons(t.release(70)))
        assertTrue(t.release(80).isEmpty())
    }

    @Test fun coordinatesGoThroughTheViewport() {
        val t = tracker()
        t.onFrame(touchFrame(TouchAction.DOWN, 0, 1, finger(1, 0f, 1840f)), 0)
        val out = t.onFrame(touchFrame(TouchAction.UP, 10, 1, finger(1, 0f, 1840f)), 10)
        assertEquals(0, ptrs(out)[0].x)
        assertEquals(65535, ptrs(out)[0].y)
    }
}
