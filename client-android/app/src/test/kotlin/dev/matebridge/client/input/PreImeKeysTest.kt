package dev.matebridge.client.input

import dev.matebridge.client.protocol.Key
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PreImeKeysTest {
    @Test fun streamingPhysicalKeysAreOwnedPreIme() {
        assertTrue(PreImeKeys.ownsPreIme(streaming = true, settingsPanelOpen = false, physicalKeyboard = true, gestureKey = false))
        assertTrue(PreImeKeys.ownsPreIme(streaming = true, settingsPanelOpen = false, physicalKeyboard = false, gestureKey = true))
        assertFalse(PreImeKeys.ownsPreIme(streaming = true, settingsPanelOpen = false, physicalKeyboard = false, gestureKey = false)) // volume etc.
    }

    @Test fun connectPanelOwnsNothing() {
        assertFalse(PreImeKeys.ownsPreIme(streaming = false, settingsPanelOpen = false, physicalKeyboard = true, gestureKey = false))
        assertFalse(PreImeKeys.ownsPreIme(streaming = false, settingsPanelOpen = false, physicalKeyboard = true, gestureKey = true))
    }

    @Test fun staleDownIsDroppedAndStaleUpIsReleaseOnly() {
        assertEquals(PreImeKeys.Late.DROP, PreImeKeys.lateDisposition(true, false, physicalKeyboard = true, down = true))
        assertEquals(PreImeKeys.Late.RELEASE_ONLY, PreImeKeys.lateDisposition(true, false, physicalKeyboard = true, down = false))
    }

    @Test fun otherLateEventsRouteNormally() {
        assertEquals(PreImeKeys.Late.ROUTE, PreImeKeys.lateDisposition(false, false, physicalKeyboard = true, down = true))
        assertEquals(PreImeKeys.Late.ROUTE, PreImeKeys.lateDisposition(true, false, physicalKeyboard = false, down = true))
    }

    @Test fun openSettingsPanelOwnsNothingAndRoutesLate() {
        assertFalse(PreImeKeys.ownsPreIme(streaming = true, settingsPanelOpen = true, physicalKeyboard = true, gestureKey = true))
        assertEquals(PreImeKeys.Late.ROUTE, PreImeKeys.lateDisposition(true, true, physicalKeyboard = true, down = true))
        assertEquals(PreImeKeys.Late.ROUTE, PreImeKeys.lateDisposition(true, true, physicalKeyboard = true, down = false))
    }

    private val sink = FakeSink()
    private val cap = InputCapture(sink, { VP }).also { it.setActive(true, 0) }
    private fun ctrl(down: Boolean) = cap.onKey(KeyFrame(7, 29, 113, down, 0, down, false, false, 1000))

    @Test fun trackerIgnoresUpWithoutDown() {
        assertTrue(ctrl(false).consumed)
        assertTrue(sink.sent.filterIsInstance<Key>().isEmpty())
    }

    @Test fun staleUpAfterPreImeDownReleasesIt() {
        ctrl(true)
        ctrl(false) // the stale UP routed by dispatchKeyEvent
        assertEquals(listOf(Key.DOWN, Key.UP), sink.sent.filterIsInstance<Key>().map { it.action })
    }
}
