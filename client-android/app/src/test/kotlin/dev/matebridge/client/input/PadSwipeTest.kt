package dev.matebridge.client.input

import dev.matebridge.client.protocol.Buttons
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.PadSwipe
import dev.matebridge.client.protocol.PointerRel
import dev.matebridge.client.protocol.Scroll
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-376 (decision 0043): three-finger touchpad swipe recognition. Extent 1000: threshold 120, dominance 2x. */
class PadSwipeTest {
    private val events = ArrayList<String>()
    private val rel = RelPointerTracker(InputCounters()) { ev, f -> events += "$ev $f" }.also { it.widthPt = 1000 }
    private val sent = ArrayList<Message>()
    private val xs = listOf(300f, 400f, 500f, 600f)

    private fun f(id: Int, x: Float, y: Float) = Finger(id, x, y)

    private fun pad(action: PadAction, ms: Long, acting: Int, buttons: Int, fingers: List<Finger>): List<Message> =
        rel.onPad(PadFrame(action, acting, fingers, ms * 1000, 7, buttons, 0, 1000f), ms).messages()

    private fun land(n: Int) {
        for (i in 0 until n) sent += pad(PadAction.DOWN, i * 5L, i, 0, (0..i).map { f(it, xs[it], 500f) })
    }

    /** Moves the first [n] fingers to (landing + dx, landing + dy). */
    private fun move(n: Int, dx: Float, dy: Float, ms: Long, buttons: Int = 0) {
        sent += pad(PadAction.MOVE, ms, 0, buttons, (0 until n).map { f(it, xs[it] + dx, 500f + dy) })
    }

    private fun lift(n: Int, ms: Long, dx: Float = 0f, dy: Float = 0f) {
        for (k in n downTo 1) sent += pad(PadAction.UP, ms + (n - k), k - 1, 0, (0 until k).map { f(it, xs[it] + dx, 500f + dy) })
    }

    private fun swipe(dx: Float, dy: Float, steps: Int = 10) {
        land(3)
        for (i in 1..steps) move(3, dx * i / steps, dy * i / steps, 100L + i * 8)
        lift(3, 1000, dx, dy)
    }

    private fun swipes() = sent.filterIsInstance<PadSwipe>()

    private fun dirOf(dx: Float, dy: Float): List<Int> {
        sent.clear(); rel.reset()
        pad(PadAction.UP, 0, 0, 0, emptyList()) // reset() ignores pointers until the pad is empty
        swipe(dx, dy)
        return swipes().map { it.direction }
    }

    @Test fun fourDirections() {
        assertEquals(listOf(PadSwipe.UP), dirOf(0f, -200f))
        assertEquals(listOf(PadSwipe.DOWN), dirOf(0f, 200f))
        assertEquals(listOf(PadSwipe.LEFT), dirOf(-200f, 0f))
        assertEquals(listOf(PadSwipe.RIGHT), dirOf(200f, 0f))
    }

    @Test fun sentBeforeTheFingersLift() {
        land(3)
        var at = -1
        for (i in 1..10) {
            val n = sent.size
            move(3, 0f, -20f * i, 100L + i * 8)
            if (at < 0 && sent.size > n) at = i
        }
        assertEquals(6, at) // 6 * 20 = 120 = threshold
        assertEquals(1, swipes().size)
        assertEquals(3, swipes().single().fingers)
    }

    @Test fun fastSwipeAndLiftIsRecognizedOnTheFirstUpFrame() {
        land(3)
        move(3, 0f, -110f, 100) // below the threshold (120)
        assertTrue(swipes().isEmpty())
        lift(3, 120, dy = -130f) // the first UP frame still carries all three fingers at -130
        assertEquals(listOf(PadSwipe.UP), swipes().map { it.direction })
    }

    @Test fun belowThresholdSendsNothing() {
        swipe(0f, -100f)
        assertTrue(swipes().isEmpty())
    }

    @Test fun diagonalSendsNothing() {
        swipe(150f, -150f)
        assertTrue(swipes().isEmpty())
    }

    @Test fun movingFurtherSendsOnlyOnce() {
        swipe(0f, -400f, steps = 40)
        assertEquals(1, swipes().size)
    }

    @Test fun settleWindowContactDriftDoesNotCount() {
        land(3)
        move(3, 0f, -150f, 30) // inside the settle window: contacts still moving
        move(3, 0f, -150f, 80)
        assertTrue(swipes().isEmpty())
    }

    @Test fun clickDragSendsNothing() {
        land(3)
        move(3, 0f, 0f, 100, buttons = Buttons.LEFT)
        for (i in 1..10) move(3, 0f, -30f * i, 100L + i * 8, buttons = Buttons.LEFT)
        assertTrue(swipes().isEmpty())
    }

    @Test fun fourFingersSendNothing() {
        land(4)
        for (i in 1..10) move(4, 0f, -30f * i, 100L + i * 8)
        assertTrue(swipes().isEmpty())
    }

    @Test fun fourthFingerAfterThreeStopsTheSwipe() {
        land(3)
        move(3, 0f, -50f, 100)
        sent += pad(PadAction.DOWN, 110, 3, 0, (0..3).map { f(it, xs[it], if (it < 3) 450f else 500f) })
        for (i in 1..10) move(4, 0f, -50f - 30f * i, 120L + i * 8)
        assertTrue(swipes().isEmpty())
    }

    @Test fun twoFingerScrollThenThirdFingerEndsTheScrollThenSwipes() {
        sent += pad(PadAction.DOWN, 0, 0, 0, listOf(f(0, 300f, 500f)))
        sent += pad(PadAction.DOWN, 5, 1, 0, listOf(f(0, 300f, 500f), f(1, 400f, 500f)))
        for (i in 1..8) sent += pad(PadAction.MOVE, 70L + i * 8, 0, 0, listOf(f(0, 300f, 500f - 15f * i), f(1, 400f, 500f - 15f * i)))
        assertTrue(sent.any { it is Scroll && it.phase == Scroll.BEGAN })
        val y = 500f - 120f
        sent += pad(PadAction.DOWN, 200, 2, 0, listOf(f(0, 300f, y), f(1, 400f, y), f(2, 500f, y)))
        assertEquals(Scroll.ENDED, sent.filterIsInstance<Scroll>().last().phase)
        assertTrue(swipes().isEmpty())
        for (i in 1..10) {
            val yy = y - 20f * i
            sent += pad(PadAction.MOVE, 300L + i * 8, 0, 0, listOf(f(0, 300f, yy), f(1, 400f, yy), f(2, 500f, yy)))
        }
        assertEquals(listOf(PadSwipe.UP), swipes().map { it.direction })
        assertEquals(Scroll.ENDED, sent.filterIsInstance<Scroll>().last().phase) // no second scroll after the swipe
    }

    @Test fun stationaryThreeFingerTouchStaysSilent() {
        land(3)
        lift(3, 60)
        assertTrue(sent.isEmpty())
    }

    @Test fun afterASwipeDroppingToTwoFingersDoesNotScrollOrMove() {
        land(3)
        for (i in 1..10) move(3, 0f, -25f * i, 100L + i * 8)
        assertEquals(1, swipes().size)
        sent.clear()
        sent += pad(PadAction.UP, 300, 2, 0, listOf(f(0, 300f, 250f), f(1, 400f, 250f), f(2, 500f, 250f)))
        for (i in 1..6) {
            val yy = 250f - 20f * i
            sent += pad(PadAction.MOVE, 310L + i * 8, 0, 0, listOf(f(0, 300f, yy), f(1, 400f, yy)))
        }
        assertTrue(sent.none { it is Scroll })
        assertTrue(sent.none { it is PointerRel })
    }

    @Test fun logsTheSwipeAndThePathAtTheEnd() {
        swipe(0f, -200f)
        assertTrue(events.any { it == "pad_swipe dir=up" })
        assertTrue(events.any { it.startsWith("pad_swipe3_end ") && it.contains("sent=1") && it.contains("max=3") })
    }
}
