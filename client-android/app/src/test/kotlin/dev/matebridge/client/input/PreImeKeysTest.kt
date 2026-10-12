package dev.matebridge.client.input

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PreImeKeysTest {
    @Test fun ownsKeysWhileStreaming() = assertTrue(PreImeKeys().owns(true))
    @Test fun ownsNothingOnConnectPanel() = assertFalse(PreImeKeys().owns(false))
    @Test fun markedEventIsSkippedOnceByActivity() {
        val p = PreImeKeys()
        p.markRouted(3, 113, 0, 0, 1000L)
        assertFalse(p.consumeIfRouted(3, 113, 1, 0, 1000L))
        assertTrue(p.consumeIfRouted(3, 113, 0, 0, 1000L))
        assertFalse(p.consumeIfRouted(3, 113, 0, 0, 1000L))
    }
}
