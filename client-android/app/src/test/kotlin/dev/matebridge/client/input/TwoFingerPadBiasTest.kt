package dev.matebridge.client.input

import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.Pinch
import dev.matebridge.client.protocol.Scroll
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-349: on the touchpad a two-finger move is a scroll unless it is clearly a pinch. */
class TwoFingerPadBiasTest {
    private val rel = RelPointerTracker(InputCounters()).also { it.widthPt = 1000 }

    // extent 1000: scroll slop 20, pinch floor 2 * slop = 40, fingers start 300 apart.
    private fun f(id: Int, x: Float, y: Float) = Finger(id, x, y)

    private fun pad(action: PadAction, ms: Long, acting: Int, vararg fingers: Finger): List<Message> =
        rel.onPad(PadFrame(action, acting, fingers.toList(), ms * 1000, PAD, 0, 0, 1000f), ms).messages()

    private fun down() {
        pad(PadAction.DOWN, 0, 0, f(0, 100f, 100f))
        pad(PadAction.DOWN, 5, 1, f(0, 100f, 100f), f(1, 400f, 100f))
    }

    // ---- classifier ----

    @Test fun classifierPinchNeedsTheAbsoluteFloor() {
        val k = TwoFingerClassifier.Kind.PINCH
        assertNull(TwoFingerClassifier.classify(300f, 330f, 0f, 20f, 50f, pinchMinAbs = 40f)) // 10 percent but only 30
        assertEquals(k, TwoFingerClassifier.classify(300f, 340f, 0f, 20f, 50f, pinchMinAbs = 40f))
        assertEquals(k, TwoFingerClassifier.classify(300f, 330f, 0f, 20f, 50f)) // default: relative rule only
    }

    @Test fun classifierRelativePinchBelowTheFloorLosesToScroll() {
        assertEquals(TwoFingerClassifier.Kind.SCROLL, TwoFingerClassifier.classify(300f, 330f, 25f, 20f, 50f, pinchMinAbs = 40f))
    }

    @Test fun classifierDominanceSetsTheSameFrameWinner() {
        val k = TwoFingerClassifier.Kind.PINCH
        // 100 spread, 40 slide: pinch at the default 2x, scroll at 3x.
        assertEquals(k, TwoFingerClassifier.classify(300f, 400f, 40f, 20f, 50f))
        assertEquals(TwoFingerClassifier.Kind.SCROLL, TwoFingerClassifier.classify(300f, 400f, 40f, 20f, 50f, dominance = 3f))
    }

    // ---- tracker ----

    @Test fun scrollWithFingerWobbleAndSettlingIsAlwaysAScroll() {
        for (wobble in listOf(15f, 25f, 30f, 35f)) { // up to about 12 percent of the 300 distance
            rel.reset()
            // After a reset the pointers on the pad are ignored until they lift.
            pad(PadAction.UP, 1, 0, f(0, 100f, 100f))
            pad(PadAction.UP, 2, 1, f(1, 400f, 100f))
            down()
            val all = ArrayList<Message>()
            var y = 100f
            for (i in 1..8) {
                val ms = 5L + i * 8
                y += 12f
                val w = if (i % 2 == 0) wobble else -wobble * 0.5f
                val settle = if (i == 1) 12f else 0f // the second contact still sliding in
                all += pad(PadAction.MOVE, ms, -1, f(0, 100f, y), f(1, 400f + w + settle, y))
            }
            assertTrue("wobble $wobble", all.none { it is Pinch })
            assertTrue("wobble $wobble", all.filterIsInstance<Scroll>().isNotEmpty())
            assertFalse(rel.isPinching)
        }
    }

    @Test fun clearPinchStillPinches() {
        down()
        val m = pad(PadAction.MOVE, 80, -1, f(0, 40f, 100f), f(1, 460f, 100f)) // 300 -> 420, centroid fixed
        assertEquals(listOf(Pinch.BEGAN, Pinch.CHANGED), m.filterIsInstance<Pinch>().map { it.phase })
        assertTrue(m.none { it is Scroll })
    }

    @Test fun slidingMotionInsideTheSettleWindowIsNotLost() {
        down()
        // 30 raw units within 15 ms of the second finger: decided as a scroll straight away, carrying the movement.
        val m = pad(PadAction.MOVE, 20, -1, f(0, 100f, 130f), f(1, 400f, 130f)).filterIsInstance<Scroll>()
        assertEquals(listOf(Scroll.BEGAN, Scroll.CHANGED), m.map { it.phase })
        assertEquals(36f, m[1].dy, 0.01f)
    }

    @Test fun slidingMotionAccumulatedAcrossTheWindowGoesOutWithTheDecision() {
        down()
        assertTrue(pad(PadAction.MOVE, 20, -1, f(0, 100f, 112f), f(1, 400f, 112f)).isEmpty()) // 12 < slop
        val m = pad(PadAction.MOVE, 40, -1, f(0, 100f, 124f), f(1, 400f, 124f)).filterIsInstance<Scroll>() // 24 > slop
        assertEquals(36f * 24f / 30f, m[1].dy, 0.01f)
    }

    @Test fun aSpreadInsideTheSettleWindowIsNotAPinchAndTheBaselineIsRetakenAfterIt() {
        down()
        assertTrue(pad(PadAction.MOVE, 20, -1, f(0, 60f, 100f), f(1, 440f, 100f)).isEmpty()) // 300 -> 380 while settling
        assertTrue(pad(PadAction.MOVE, 70, -1, f(0, 61f, 100f), f(1, 439f, 100f)).isEmpty()) // window over: 378 is the baseline
        assertFalse(rel.isPinching)
        val m = pad(PadAction.MOVE, 80, -1, f(0, 30f, 100f), f(1, 470f, 100f)).filterIsInstance<Pinch>() // 378 -> 440
        assertEquals(listOf(Pinch.BEGAN, Pinch.CHANGED), m.map { it.phase })
    }

    private companion object {
        const val PAD = 7
    }
}
