package dev.matebridge.probe.input

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EventJsonTest {
    private fun p(x: Float, pressure: Float = 0.5f, tilt: Float = 0.25f) = PointerSample(
        id = 0, toolType = "STYLUS", x = x, y = 20f, pressure = pressure, size = 0f,
        tilt = tilt, orientation = -1.5f, distance = 0f, relX = 0f, relY = 0f, vScroll = 0f, hScroll = 0f,
    )

    private fun motion(history: List<HistorySample> = emptyList()) = MotionRecord(
        t = 1000, callback = "touch", captured = false, action = "ACTION_MOVE", actionMasked = 2,
        actionIndex = 0, actionButton = 0, buttonState = 32, source = 0x4002, sourceHex = "0x00004002",
        deviceId = 7, deviceName = "huawei,ts_pen", pointerCount = 1, eventTime = 999, downTime = 900,
        historySize = history.size, pointers = listOf(p(10f)), history = history,
    )

    @Test fun motionWithHistoryIncludesAllSamples() {
        val json = EventJson.motion(
            motion(listOf(HistorySample(990, listOf(p(8f))), HistorySample(995, listOf(p(9f))))),
        )
        assertTrue(json.startsWith("{\"type\":\"motion\",\"t\":1000,"))
        assertTrue(json.contains("\"historySize\":2"))
        assertTrue(json.contains("\"eventTime\":990"))
        assertTrue(json.contains("\"eventTime\":995"))
        assertTrue(json.contains("\"tilt\":0.25"))
        assertTrue(json.contains("\"device\":\"huawei,ts_pen\""))
        assertFalse(json.contains("\n"))
    }

    @Test fun nanBecomesNull() {
        val json = EventJson.motion(motion().copy(pointers = listOf(p(Float.NaN))))
        assertTrue(json.contains("\"x\":null"))
    }

    @Test fun nullDeviceName() {
        assertTrue(EventJson.motion(motion().copy(deviceName = null)).contains("\"device\":null"))
    }

    @Test fun keyHasCodesOnlyNoCharacter() {
        val json = EventJson.key(
            KeyRecord(5, "DOWN", 29, "KEYCODE_A", 30, 0, 0, 0, 0x101, 3, "kbd", 4, 4),
        )
        assertEquals(
            "{\"type\":\"key\",\"t\":5,\"action\":\"DOWN\",\"keyCode\":29,\"keyName\":\"KEYCODE_A\"," +
                "\"scanCode\":30,\"metaState\":0,\"repeatCount\":0,\"flags\":0,\"source\":257," +
                "\"deviceId\":3,\"device\":\"kbd\",\"eventTime\":4,\"downTime\":4}",
            json,
        )
    }

    @Test fun escapesStrings() {
        assertEquals("a\\\"b\\\\c\\n\\u0001", EventJson.escape("a\"b\\c\n\u0001"))
    }

    @Test fun metaFields() {
        val json = EventJson.meta(1, "capture", mapOf("on" to true, "n" to 3, "s" to "x", "z" to null))
        assertEquals("{\"type\":\"meta\",\"t\":1,\"name\":\"capture\",\"on\":true,\"n\":3,\"s\":\"x\",\"z\":null}", json)
    }
}
