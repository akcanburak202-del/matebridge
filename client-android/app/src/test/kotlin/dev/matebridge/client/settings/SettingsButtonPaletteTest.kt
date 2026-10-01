package dev.matebridge.client.settings

import dev.matebridge.client.settings.SettingsButtonPalette.colorFor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-107: settings buttons have explicit, readable colors in every state. */
class SettingsButtonPaletteTest {
    @Test fun restingColorsMatchCard() {
        assertEquals(0xFF3A3A42.toInt(), colorFor(selected = false, pressed = false))
        assertEquals(0xFF2E7DFF.toInt(), colorFor(selected = true, pressed = false))
    }

    @Test fun pressedGivesVisibleFeedback() {
        for (sel in listOf(false, true)) {
            assertNotEquals(colorFor(sel, pressed = false), colorFor(sel, pressed = true))
        }
    }

    @Test fun allBackgroundsAreDarkEnoughForWhiteText() {
        for (sel in listOf(false, true)) for (p in listOf(false, true)) {
            val c = colorFor(sel, p)
            assertEquals("opaque", 0xFF, (c ushr 24) and 0xFF)
            assertTrue("contrast ${contrast(c, SettingsButtonPalette.TEXT)} for $sel/$p", contrast(c, SettingsButtonPalette.TEXT) >= 3.0)
        }
    }

    @Test fun stateOrderPutsDefaultLastAndCoversAll() {
        val order = SettingsButtonPalette.stateOrder
        assertEquals(4, order.toSet().size)
        assertEquals(false to false, order.last())
        assertEquals(true to true, order.first())
    }

    private fun contrast(a: Int, b: Int): Double {
        val la = luminance(a)
        val lb = luminance(b)
        return (maxOf(la, lb) + 0.05) / (minOf(la, lb) + 0.05)
    }

    private fun luminance(c: Int): Double {
        fun ch(v: Int): Double {
            val s = v / 255.0
            return if (s <= 0.03928) s / 12.92 else Math.pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * ch((c shr 16) and 0xFF) + 0.7152 * ch((c shr 8) and 0xFF) + 0.0722 * ch(c and 0xFF)
    }
}
