package dev.matebridge.client.input

import dev.matebridge.client.protocol.Buttons
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.PointerRel
import dev.matebridge.client.protocol.Scroll
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Touchpad and mouse recognition (T-034). Pad extent 1000 raw units and a 1000 pt stream: one raw unit is
 * 1.2 pt before acceleration (PadTuning.SCREEN_SPAN), the slop is 20 raw units.
 */
class RelPointerTrackerTest {
    private val counters = InputCounters()
    private val t = RelPointerTracker(counters).also { it.widthPt = 1000 }

    private fun f(id: Int, x: Float, y: Float) = Finger(id, x, y)

    private fun pad(
        action: PadAction, ms: Long, acting: Int, vararg fingers: Finger, buttons: Int = 0, pressed: Int = 0,
    ): List<Message> =
        t.onPad(PadFrame(action, acting, fingers.toList(), ms * 1000, PAD, buttons, pressed, 1000f), ms).messages()

    private fun rels(m: List<Message>) = m.filterIsInstance<PointerRel>()
    private fun scrolls(m: List<Message>) = m.filterIsInstance<Scroll>()

    @Test fun singleFingerMovesCursorWithScaleAndAcceleration() {
        pad(PadAction.DOWN, 0, 0, f(0, 100f, 100f))
        // 50 raw in 8 ms is very fast: full gain. 50 * 1.2 = 60 pt base, times GAIN_MAX.
        val fast = rels(pad(PadAction.MOVE, 8, 0, f(0, 150f, 100f)))
        assertEquals(1, fast.size)
        assertEquals(60f * PadTuning.GAIN_MAX, fast[0].dx, 0.01f)
        assertEquals(0f, fast[0].dy, 0f)
        assertEquals(0, fast[0].buttons)
        // 2 raw in 50 ms is slow: minimum gain.
        val slow = rels(pad(PadAction.MOVE, 58, 0, f(0, 152f, 100f)))
        assertEquals(2.4f * PadTuning.GAIN_MIN, slow[0].dx, 0.01f)
    }

    @Test fun motionStartsOnlyAfterSlopSoTapsDoNotNudgeTheCursor() {
        pad(PadAction.DOWN, 0, 0, f(0, 100f, 100f))
        assertTrue(pad(PadAction.MOVE, 10, 0, f(0, 105f, 103f)).isEmpty())
        assertTrue(pad(PadAction.MOVE, 20, 0, f(0, 110f, 106f)).isEmpty())
        // Beyond the slop the held-back motion arrives in one piece.
        val m = rels(pad(PadAction.MOVE, 30, 0, f(0, 125f, 106f)))
        assertEquals(1, m.size)
        assertTrue(m[0].dx > 0f)
        assertTrue(m[0].dy > 0f)
    }

    @Test fun singleFingerTapIsLeftClick() {
        pad(PadAction.DOWN, 0, 0, f(0, 100f, 100f))
        pad(PadAction.MOVE, 40, 0, f(0, 104f, 100f))
        val up = rels(pad(PadAction.UP, 100, 0, f(0, 104f, 100f)))
        assertEquals(listOf(Buttons.LEFT, 0), up.map { it.buttons })
        assertTrue(up.all { it.dx == 0f && it.dy == 0f })
        assertEquals(1L, counters.taps)
        assertEquals(0, t.reported)
    }

    @Test fun slowTouchIsNotATap() {
        pad(PadAction.DOWN, 0, 0, f(0, 100f, 100f))
        assertTrue(pad(PadAction.UP, PadTuning.TAP_MS + 1, 0, f(0, 100f, 100f)).isEmpty())
        assertEquals(0L, counters.taps)
    }

    @Test fun movedTouchIsNotATap() {
        pad(PadAction.DOWN, 0, 0, f(0, 100f, 100f))
        pad(PadAction.MOVE, 50, 0, f(0, 160f, 100f))
        val up = pad(PadAction.UP, 100, 0, f(0, 160f, 100f))
        assertTrue(up.isEmpty())
        assertEquals(0L, counters.taps)
    }

    @Test fun twoFingerTapIsRightClick() {
        pad(PadAction.DOWN, 0, 0, f(0, 100f, 100f))
        pad(PadAction.DOWN, 30, 1, f(0, 100f, 100f), f(1, 200f, 100f))
        assertTrue(pad(PadAction.UP, 110, 1, f(0, 100f, 100f), f(1, 200f, 100f)).isEmpty())
        val last = rels(pad(PadAction.UP, 120, 0, f(0, 100f, 100f)))
        assertEquals(listOf(Buttons.RIGHT, 0), last.map { it.buttons })
        assertEquals(1L, counters.taps)
    }

    @Test fun physicalClickIsLeftAndDragsWithFingerMotion() {
        pad(PadAction.DOWN, 0, 0, f(0, 100f, 100f))
        val press = rels(pad(PadAction.BUTTON, 50, -1, f(0, 100f, 100f), buttons = Buttons.LEFT, pressed = Buttons.LEFT))
        assertEquals(listOf(Buttons.LEFT), press.map { it.buttons })
        val drag = rels(pad(PadAction.MOVE, 60, 0, f(0, 110f, 100f), buttons = Buttons.LEFT))
        assertEquals(1, drag.size)
        assertEquals(Buttons.LEFT, drag[0].buttons)
        assertTrue(drag[0].dx > 0f)
        val rel = rels(pad(PadAction.BUTTON, 70, -1, f(0, 110f, 100f), buttons = 0))
        assertEquals(listOf(0), rel.map { it.buttons })
        // Finger lifts soon after: no tap on top of a physical click.
        assertTrue(pad(PadAction.UP, 90, 0, f(0, 110f, 100f)).isEmpty())
        assertEquals(0L, counters.taps)
    }

    @Test fun physicalClickWithTwoFingersIsRightAndStaysRightUntilRelease() {
        pad(PadAction.DOWN, 0, 0, f(0, 100f, 100f))
        pad(PadAction.DOWN, 10, 1, f(0, 100f, 100f), f(1, 300f, 100f))
        val press = rels(pad(PadAction.BUTTON, 50, -1, f(0, 100f, 100f), f(1, 300f, 100f), buttons = Buttons.LEFT, pressed = Buttons.LEFT))
        assertEquals(listOf(Buttons.RIGHT), press.map { it.buttons })
        // One finger leaves, the click is still held: still RIGHT.
        pad(PadAction.UP, 60, 1, f(0, 100f, 100f), f(1, 300f, 100f), buttons = Buttons.LEFT)
        val drag = rels(pad(PadAction.MOVE, 70, 0, f(0, 120f, 100f), buttons = Buttons.LEFT))
        assertEquals(Buttons.RIGHT, drag.single().buttons)
        val rel = rels(pad(PadAction.BUTTON, 80, -1, f(0, 120f, 100f), buttons = 0))
        assertEquals(listOf(0), rel.map { it.buttons })
    }

    @Test fun twoFingersScrollBeganChangedEnded() {
        pad(PadAction.DOWN, 0, 0, f(0, 100f, 100f))
        pad(PadAction.DOWN, 5, 1, f(0, 100f, 100f), f(1, 300f, 100f))
        // Within the slop: nothing yet.
        assertTrue(pad(PadAction.MOVE, 20, -1, f(0, 100f, 110f), f(1, 300f, 110f)).isEmpty())
        // Beyond it: BEGAN, then the accumulated movement (30 raw down = 36 pt, +y down).
        val s1 = scrolls(pad(PadAction.MOVE, 30, -1, f(0, 100f, 130f), f(1, 300f, 130f)))
        assertEquals(listOf(Scroll.BEGAN, Scroll.CHANGED), s1.map { it.phase })
        assertEquals(36f, s1[1].dy, 0.01f)
        assertEquals(0f, s1[1].dx, 0.01f)
        val s2 = scrolls(pad(PadAction.MOVE, 40, -1, f(0, 100f, 140f), f(1, 300f, 140f)))
        assertEquals(listOf(Scroll.CHANGED), s2.map { it.phase })
        assertEquals(12f, s2[0].dy, 0.01f)
        assertTrue(t.isScrolling)
        val end = scrolls(pad(PadAction.UP, 50, 1, f(0, 100f, 140f), f(1, 300f, 140f)))
        assertEquals(listOf(Scroll.ENDED), end.map { it.phase })
        assertFalse(t.isScrolling)
        // The finger that stays does not move the cursor and never taps.
        assertTrue(pad(PadAction.MOVE, 60, -1, f(0, 100f, 300f)).isEmpty())
        assertTrue(pad(PadAction.UP, 70, 0, f(0, 100f, 300f)).isEmpty())
        assertEquals(0L, counters.taps)
        assertTrue(counters.tpScroll >= 4)
    }

    @Test fun scrollKeepaliveAndIdleEndThenNewBegan() {
        pad(PadAction.DOWN, 0, 0, f(0, 100f, 100f))
        pad(PadAction.DOWN, 5, 1, f(0, 100f, 100f), f(1, 300f, 100f))
        pad(PadAction.MOVE, 30, -1, f(0, 100f, 140f), f(1, 300f, 140f))
        assertTrue(t.tick(100).isEmpty())
        val ka = t.tick(30 + PadTuning.SCROLL_KEEPALIVE_MS).single()
        assertTrue(ka.mergeable)
        val kaMsg = ka.msg as Scroll
        assertEquals(Scroll.CHANGED, kaMsg.phase)
        assertEquals(0f, kaMsg.dx, 0f)
        assertEquals(0f, kaMsg.dy, 0f)
        var now = 30 + PadTuning.SCROLL_KEEPALIVE_MS
        var ended = false
        while (!ended && now < 10_000) {
            now += 25
            for (o in t.tick(now)) if ((o.msg as Scroll).phase == Scroll.ENDED) ended = true
        }
        assertTrue(ended)
        assertTrue(now - 30 >= PadTuning.SCROLL_IDLE_END_MS)
        assertFalse(t.isScrolling)
        // The same two fingers move again: a new BEGAN.
        val again = scrolls(pad(PadAction.MOVE, now + 10, -1, f(0, 100f, 150f), f(1, 300f, 150f)))
        assertEquals(listOf(Scroll.BEGAN, Scroll.CHANGED), again.map { it.phase })
    }

    @Test fun fingerCountChangeDoesNotJumpTheCursor() {
        pad(PadAction.DOWN, 0, 0, f(0, 100f, 100f))
        pad(PadAction.MOVE, 8, 0, f(0, 140f, 100f)) // armed
        // A second finger lands far away: no message, in particular no jump towards it.
        assertTrue(pad(PadAction.DOWN, 16, 1, f(0, 140f, 100f), f(1, 800f, 800f)).isEmpty())
        // It lifts again at once (no scroll started): the first finger is locked until everything lifts.
        assertTrue(pad(PadAction.UP, 24, 1, f(0, 140f, 100f), f(1, 800f, 800f)).isEmpty())
        assertTrue(pad(PadAction.MOVE, 32, 0, f(0, 400f, 400f)).isEmpty())
        assertTrue(pad(PadAction.UP, 40, 0, f(0, 400f, 400f)).isEmpty())
        // A fresh touch works again.
        pad(PadAction.DOWN, 500, 0, f(0, 100f, 100f))
        assertEquals(1, rels(pad(PadAction.MOVE, 508, 0, f(0, 150f, 100f))).size)
    }

    @Test fun threeFingersEndScrollAndLock() {
        pad(PadAction.DOWN, 0, 0, f(0, 100f, 100f))
        pad(PadAction.DOWN, 5, 1, f(0, 100f, 100f), f(1, 300f, 100f))
        pad(PadAction.MOVE, 30, -1, f(0, 100f, 140f), f(1, 300f, 140f))
        val out = pad(PadAction.DOWN, 40, 2, f(0, 100f, 140f), f(1, 300f, 140f), f(2, 500f, 140f))
        assertEquals(listOf(Scroll.ENDED), scrolls(out).map { it.phase })
        assertTrue(pad(PadAction.MOVE, 50, -1, f(0, 100f, 240f), f(1, 300f, 240f), f(2, 500f, 240f)).isEmpty())
    }

    @Test fun releaseClosesButtonAndHeldButtonIsNotReportedAgain() {
        pad(PadAction.DOWN, 0, 0, f(0, 100f, 100f))
        pad(PadAction.BUTTON, 10, -1, f(0, 100f, 100f), buttons = Buttons.LEFT, pressed = Buttons.LEFT)
        val out = t.release(20)
        assertEquals(listOf(0), rels(out.messages()).map { it.buttons })
        assertEquals(0, t.reported)
        // The pad still reports the old press and finger after capture comes back: nothing is sent.
        assertTrue(pad(PadAction.MOVE, 100, 0, f(0, 140f, 100f), buttons = Buttons.LEFT).isEmpty())
        assertTrue(pad(PadAction.UP, 110, 0, f(0, 140f, 100f), buttons = Buttons.LEFT).isEmpty())
        assertTrue(pad(PadAction.BUTTON, 120, -1, buttons = 0).isEmpty())
        // A new press is reported again.
        pad(PadAction.DOWN, 200, 0, f(0, 100f, 100f))
        val press = rels(pad(PadAction.BUTTON, 210, -1, f(0, 100f, 100f), buttons = Buttons.LEFT, pressed = Buttons.LEFT))
        assertEquals(listOf(Buttons.LEFT), press.map { it.buttons })
    }

    @Test fun releaseEndsOpenScrollWithEnded() {
        pad(PadAction.DOWN, 0, 0, f(0, 100f, 100f))
        pad(PadAction.DOWN, 5, 1, f(0, 100f, 100f), f(1, 300f, 100f))
        pad(PadAction.MOVE, 30, -1, f(0, 100f, 140f), f(1, 300f, 140f))
        val out = t.release(40).messages()
        assertEquals(listOf(Scroll.ENDED), scrolls(out).map { it.phase })
        assertTrue(rels(out).isEmpty()) // nothing was reported pressed
        assertFalse(t.isScrolling)
        // Fingers that are still on the pad are not a new gesture.
        assertTrue(pad(PadAction.MOVE, 50, -1, f(0, 100f, 240f), f(1, 300f, 240f)).isEmpty())
    }

    @Test fun cancelReleasesLikeCaptureLoss() {
        pad(PadAction.DOWN, 0, 0, f(0, 100f, 100f))
        pad(PadAction.DOWN, 5, 1, f(0, 100f, 100f), f(1, 300f, 100f))
        pad(PadAction.MOVE, 30, -1, f(0, 100f, 140f), f(1, 300f, 140f))
        assertEquals(listOf(Scroll.ENDED), scrolls(pad(PadAction.CANCEL, 40, -1)).map { it.phase })
    }

    @Test fun mouseMotionButtonsAndWheel() {
        fun mouse(ms: Long, dx: Float, dy: Float, buttons: Int, pressed: Int = 0, v: Float = 0f, h: Float = 0f) =
            t.onMouse(MouseFrame(ms * 1000, dx, dy, buttons, pressed, v, h, MOUSE), ms).messages()
        // BACK was already held when we first looked (no press seen): never reported.
        val m = rels(mouse(1, 3f, -2f, Buttons.BACK))
        assertEquals(PointerRel(1000, 3f, -2f, 0), m.single())
        val press = rels(mouse(2, 0f, 0f, Buttons.LEFT or Buttons.BACK, pressed = Buttons.LEFT))
        assertEquals(listOf(Buttons.LEFT), press.map { it.buttons })
        val drag = rels(mouse(3, 4f, 0f, Buttons.LEFT or Buttons.BACK))
        assertEquals(Buttons.LEFT, drag.single().buttons)
        val up = rels(mouse(4, 0f, 0f, 0))
        assertEquals(listOf(0), up.map { it.buttons })
        val w = scrolls(mouse(5, 0f, 0f, 0, v = 2f, h = 1f)).single()
        assertEquals(Scroll.NONE, w.phase)
        assertEquals(20f, w.dy, 0f)
        assertEquals(-10f, w.dx, 0f)
    }

    @Test fun mouseAndPadButtonsShareOneReportedState() {
        t.onMouse(MouseFrame(1000, 0f, 0f, Buttons.RIGHT, Buttons.RIGHT, deviceId = MOUSE), 1)
        assertEquals(Buttons.RIGHT, t.reported)
        // A tap while the mouse holds RIGHT keeps RIGHT set throughout.
        pad(PadAction.DOWN, 10, 0, f(0, 100f, 100f))
        val tap = rels(pad(PadAction.UP, 60, 0, f(0, 100f, 100f)))
        assertEquals(listOf(Buttons.RIGHT or Buttons.LEFT, Buttons.RIGHT), tap.map { it.buttons })
    }

    private companion object {
        const val PAD = 7
        const val MOUSE = 8
    }
}
