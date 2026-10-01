package dev.matebridge.client.audio

import org.junit.Assert.assertEquals
import org.junit.Test

class AudioBufferConfigTest {
    @Test fun defaultIsOneBurst() = assertEquals(1, AudioBufferConfig.startBursts(null))

    @Test fun inRangeValuesAreKept() {
        for (n in 1..6) assertEquals(n, AudioBufferConfig.startBursts(n))
    }

    @Test fun outOfRangeValuesAreClamped() {
        assertEquals(1, AudioBufferConfig.startBursts(0))
        assertEquals(1, AudioBufferConfig.startBursts(-3))
        assertEquals(6, AudioBufferConfig.startBursts(7))
        assertEquals(6, AudioBufferConfig.startBursts(Int.MAX_VALUE))
    }
}
