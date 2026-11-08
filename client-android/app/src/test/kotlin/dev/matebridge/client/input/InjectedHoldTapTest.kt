package dev.matebridge.client.input

import android.view.InputDevice
import android.view.MotionEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InjectedHoldTapTest {
    private val touch = InputDevice.SOURCE_TOUCHSCREEN
    private val down = MotionEvent.ACTION_DOWN
    private val move = MotionEvent.ACTION_MOVE
    private val up = MotionEvent.ACTION_UP
    private val cancel = MotionEvent.ACTION_CANCEL

    private fun InjectedHoldTap.ev(
        action: Int, dev: Int = -1, source: Int = touch, n: Int = 1, x: Float = 2f, y: Float = 2f, real: Boolean = false,
    ) = onTouch(action, dev, source, n, x, y) { real }

    @Test fun virtualCornerTapIsSwallowedFromDownToUp() {
        val t = InjectedHoldTap()
        assertTrue(t.ev(down))
        assertTrue(t.ev(up))
        assertEquals(1, t.swallowedCount)
        assertFalse(t.ev(move)) // gesture is over: a stray event is no longer swallowed
    }

    @Test fun wholeGestureIsSwallowedEvenIfMovesLeaveTheCorner() {
        val t = InjectedHoldTap()
        assertTrue(t.ev(down))
        assertTrue(t.ev(move, x = 500f, y = 500f, real = true))
        assertTrue(t.ev(up, x = 500f, y = 500f))
    }

    @Test fun realDeviceInTheCornerPasses() {
        val t = InjectedHoldTap()
        assertFalse(t.ev(down, dev = 6, real = true))
        assertFalse(t.ev(up, dev = 6, real = true))
        assertEquals(0, t.swallowedCount)
    }

    @Test fun virtualTapElsewherePasses() {
        val t = InjectedHoldTap()
        assertFalse(t.ev(down, x = 1400f, y = 900f))
        assertFalse(t.ev(up, x = 1400f, y = 900f))
        assertFalse(t.ev(down, x = 5f, y = 2f)) // just outside the corner
        assertFalse(t.ev(down, x = 2f, y = 5f))
        assertEquals(0, t.swallowedCount)
    }

    @Test fun cornerBoundaryIsInclusive() {
        val t = InjectedHoldTap()
        assertTrue(t.ev(down, x = 4f, y = 4f))
        assertTrue(t.ev(up))
    }

    @Test fun nonTouchscreenSourcePasses() {
        val t = InjectedHoldTap()
        assertFalse(t.ev(down, source = InputDevice.SOURCE_STYLUS))
        assertFalse(t.ev(down, source = InputDevice.SOURCE_MOUSE))
        assertFalse(t.ev(down, source = InputDevice.SOURCE_TOUCHPAD))
        assertEquals(0, t.swallowedCount)
    }

    @Test fun multiFingerDownPasses() {
        val t = InjectedHoldTap()
        assertFalse(t.ev(down, n = 2))
        assertEquals(0, t.swallowedCount)
    }

    @Test fun cancelClearsTheGesture() {
        val t = InjectedHoldTap()
        assertTrue(t.ev(down))
        assertTrue(t.ev(cancel))
        assertFalse(t.ev(move))
    }

    @Test fun resetClearsAnUnfinishedGesture() {
        val t = InjectedHoldTap()
        assertTrue(t.ev(down))
        t.reset()
        assertFalse(t.ev(up))
    }

    @Test fun nonMatchingDownDropsAStaleSwallowedGesture() {
        val t = InjectedHoldTap()
        assertTrue(t.ev(down)) // its UP never comes
        assertFalse(t.ev(down, x = 1400f, y = 900f)) // a later tap elsewhere from the same device id
        assertFalse(t.ev(move, x = 1400f, y = 900f))
        assertFalse(t.ev(up, x = 1400f, y = 900f))
    }

    @Test fun otherDevicesAreUnaffectedWhileASwallowedGestureIsOpen() {
        val t = InjectedHoldTap()
        assertTrue(t.ev(down))
        assertFalse(t.ev(down, dev = 6, x = 800f, y = 800f, real = true))
        assertFalse(t.ev(move, dev = 6, x = 810f, y = 800f, real = true))
        assertTrue(t.ev(up)) // the swallowed one still ends cleanly
        assertFalse(t.ev(up, dev = 6, real = true))
    }

    @Test fun deviceLookupIsLazy() {
        val t = InjectedHoldTap()
        var calls = 0
        t.onTouch(down, -1, touch, 1, 900f, 900f) { calls++; false }
        t.onTouch(down, -1, InputDevice.SOURCE_STYLUS, 1, 2f, 2f) { calls++; false }
        t.onTouch(move, -1, touch, 1, 2f, 2f) { calls++; false }
        assertEquals(0, calls)
        t.onTouch(down, -1, touch, 1, 2f, 2f) { calls++; false }
        assertEquals(1, calls)
    }

    @Test fun logIsRateLimitedAndOnlyOnChange() {
        val t = InjectedHoldTap()
        assertNull(t.takeLog(1_000)) // nothing swallowed yet
        t.ev(down); t.ev(up)
        assertEquals(1, t.takeLog(1_000)) // first one logs at once
        assertNull(t.takeLog(40_000)) // no change
        t.ev(down); t.ev(up)
        assertNull(t.takeLog(20_000)) // changed, but inside 30 s
        assertEquals(2, t.takeLog(31_000))
        assertNull(t.takeLog(100_000))
    }
}
