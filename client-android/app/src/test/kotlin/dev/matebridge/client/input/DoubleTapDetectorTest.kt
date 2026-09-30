package dev.matebridge.client.input

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DoubleTapDetectorTest {
    @Test fun twoDownsFireOneDoubleTap() {
        val d = DoubleTapDetector()
        assertFalse(d.onDown(1000))
        assertTrue(d.onDown(1015)) // the pencil sends both pairs a few ms apart
    }

    @Test fun aSingleDownNeverFires() {
        val d = DoubleTapDetector()
        assertFalse(d.onDown(1000))
    }

    @Test fun twoDownsFarApartAreTwoSingles() {
        val d = DoubleTapDetector()
        assertFalse(d.onDown(1000))
        assertFalse(d.onDown(1000 + DoubleTapDetector.WINDOW_MS + 1)) // becomes the new first
        assertTrue(d.onDown(1000 + DoubleTapDetector.WINDOW_MS + 30))
    }

    @Test fun aBurstFiresOnlyOnce() {
        val d = DoubleTapDetector()
        var fired = 0
        for (t in listOf(1000L, 1010L, 1020L, 1030L, 1040L)) if (d.onDown(t)) fired++
        assertTrue(fired == 1)
    }

    @Test fun aSecondDoubleTapAfterTheLockoutFiresAgain() {
        val d = DoubleTapDetector()
        d.onDown(1000)
        assertTrue(d.onDown(1010))
        val later = 1010 + DoubleTapDetector.LOCKOUT_MS + 100
        assertFalse(d.onDown(later))
        assertTrue(d.onDown(later + 10))
    }

    @Test fun resetForgetsAHalfFinishedGesture() {
        val d = DoubleTapDetector()
        d.onDown(1000)
        d.reset()
        assertFalse(d.onDown(1010))
    }

    @Test fun onlyTheGestureKeyIsRecognised() {
        assertTrue(DoubleTapDetector.isGestureKey(718, 190))
        assertTrue(DoubleTapDetector.isGestureKey(718, 0))
        assertTrue(DoubleTapDetector.isGestureKey(0, 190)) // key layout left the scan code unmapped
        assertFalse(DoubleTapDetector.isGestureKey(0, 0))
        assertFalse(DoubleTapDetector.isGestureKey(131, 190)) // an ordinary keyboard's F20 style key
        assertFalse(DoubleTapDetector.isGestureKey(29, 30))
    }
}
