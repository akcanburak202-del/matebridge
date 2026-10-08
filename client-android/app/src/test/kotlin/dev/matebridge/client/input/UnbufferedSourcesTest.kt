package dev.matebridge.client.input

import org.junit.Assert.assertEquals
import org.junit.Test

class UnbufferedSourcesTest {
    @Test fun parseAcceptsKnownValuesAndDefaultsToOff() {
        assertEquals(UnbufferedSources.OFF, UnbufferedSources.parse(null))
        assertEquals(UnbufferedSources.OFF, UnbufferedSources.parse("off"))
        assertEquals(UnbufferedSources.TOUCH, UnbufferedSources.parse("touch"))
        assertEquals(UnbufferedSources.ALL, UnbufferedSources.parse(" ALL "))
        assertEquals(UnbufferedSources.OFF, UnbufferedSources.parse("touchpad"))
        assertEquals(UnbufferedSources.OFF, UnbufferedSources.parse(""))
    }

    @Test fun masksUseTheAndroidSourceBits() {
        val stylus = 0x4002
        val touchscreen = 0x1002
        val mouse = 0x2002
        val touchpad = 0x100008
        val mouseRel = 0x20004
        assertEquals(stylus, UnbufferedSources.OFF.requestMask) // pen behaviour unchanged
        assertEquals(stylus or touchscreen, UnbufferedSources.TOUCH.requestMask)
        assertEquals(stylus or touchscreen or mouse or touchpad or mouseRel, UnbufferedSources.ALL.requestMask)
    }

    @Test fun everyModeKeepsTheStylusSource() {
        for (m in UnbufferedSources.values()) assertEquals(0x4002, m.requestMask and 0x4002)
    }

    @Test fun labelsNameTheSourcesInForce() {
        assertEquals("stylus", UnbufferedSources.OFF.label)
        assertEquals("stylus+touch", UnbufferedSources.TOUCH.label)
        assertEquals("stylus+touch+mouse+touchpad+mouse_rel", UnbufferedSources.ALL.label)
    }
}
