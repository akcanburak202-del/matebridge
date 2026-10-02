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

    @Test fun aaudioDefaultIsFourBurstsAndTheExtraOverridesIt() {
        // T-114: 2 bursts (10 ms) crackled in game mode; 4 (20 ms) did not.
        assertEquals(4, AudioBufferConfig.startBursts(null, AudioBufferConfig.AAUDIO_DEFAULT_BURSTS))
        assertEquals(1, AudioBufferConfig.startBursts(1, AudioBufferConfig.AAUDIO_DEFAULT_BURSTS))
        assertEquals(6, AudioBufferConfig.startBursts(9, AudioBufferConfig.AAUDIO_DEFAULT_BURSTS))
    }
}
