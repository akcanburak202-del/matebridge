package dev.matebridge.client.input

import android.view.InputDevice
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UnbufferedSourcesTest {
    /** The platform rule (ViewRootImpl): a request matches an event source when any bit overlaps. */
    private fun matches(mask: Int, source: Int) = (source and mask) != 0

    @Test fun parseAcceptsKnownValuesAndDefaultsToOff() {
        assertEquals(UnbufferedSources.OFF, UnbufferedSources.parse(null))
        assertEquals(UnbufferedSources.OFF, UnbufferedSources.parse("off"))
        assertEquals(UnbufferedSources.RELATIVE, UnbufferedSources.parse(" Relative "))
        assertEquals(UnbufferedSources.OFF, UnbufferedSources.parse("touch")) // removed values fall back to off
        assertEquals(UnbufferedSources.OFF, UnbufferedSources.parse("all"))
        assertEquals(UnbufferedSources.OFF, UnbufferedSources.parse(""))
    }

    @Test fun sdkConstantsHaveTheClassBitsTheContractRelies() {
        assertEquals(0x4002, InputDevice.SOURCE_STYLUS)
        assertEquals(0x1002, InputDevice.SOURCE_TOUCHSCREEN)
        assertEquals(0x2002, InputDevice.SOURCE_MOUSE)
        assertEquals(0x20004, InputDevice.SOURCE_MOUSE_RELATIVE)
        assertEquals(0x100008, InputDevice.SOURCE_TOUCHPAD)
        assertEquals(0x2, InputDevice.SOURCE_CLASS_POINTER)
        assertEquals(0x4, InputDevice.SOURCE_CLASS_TRACKBALL)
        assertEquals(0x8, InputDevice.SOURCE_CLASS_POSITION)
    }

    @Test fun offIsTodaysStylusMaskAndAlreadyMatchesThePointerClass() {
        val m = UnbufferedSources.OFF.requestMask
        assertEquals(InputDevice.SOURCE_STYLUS, m)
        assertTrue(matches(m, InputDevice.SOURCE_STYLUS))
        assertTrue(matches(m, InputDevice.SOURCE_TOUCHSCREEN)) // via the pointer-class bit: a separate "touch" knob changes nothing
        assertTrue(matches(m, InputDevice.SOURCE_MOUSE))
        assertFalse(matches(m, InputDevice.SOURCE_MOUSE_RELATIVE))
        assertFalse(matches(m, InputDevice.SOURCE_TOUCHPAD))
        assertFalse(matches(m, InputDevice.SOURCE_KEYBOARD))
    }

    @Test fun relativeAddsExactlyTheSourcesTheStylusMaskMisses() {
        val m = UnbufferedSources.RELATIVE.requestMask
        assertEquals(InputDevice.SOURCE_STYLUS or InputDevice.SOURCE_MOUSE_RELATIVE or InputDevice.SOURCE_TOUCHPAD, m)
        assertTrue(matches(m, InputDevice.SOURCE_STYLUS))
        assertTrue(matches(m, InputDevice.SOURCE_TOUCHSCREEN))
        assertTrue(matches(m, InputDevice.SOURCE_MOUSE))
        assertTrue(matches(m, InputDevice.SOURCE_MOUSE_RELATIVE))
        assertTrue(matches(m, InputDevice.SOURCE_TOUCHPAD))
        assertFalse(matches(m, InputDevice.SOURCE_KEYBOARD))
    }

    @Test fun labelsNameTheSourcesInForce() {
        assertEquals("pointer_class(stylus,touch,mouse)", UnbufferedSources.OFF.label)
        assertEquals("pointer_class(stylus,touch,mouse)+mouse_rel+touchpad", UnbufferedSources.RELATIVE.label)
    }
}
