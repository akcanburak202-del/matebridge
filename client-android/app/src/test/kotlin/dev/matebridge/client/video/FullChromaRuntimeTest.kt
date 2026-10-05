package dev.matebridge.client.video

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FullChromaRuntimeTest {
    @After fun reset() = FullChromaRuntime.resetForTest()

    @Test fun latchIsProcessScopedAndFlipsOnce() {
        assertFalse(FullChromaRuntime.isOff)
        assertTrue(FullChromaRuntime.disable())
        assertTrue(FullChromaRuntime.isOff)
        assertFalse(FullChromaRuntime.disable())
    }

    @Test fun staleGenerationFailureIsIgnored() {
        val g = RunGeneration()
        val t1 = g.begin()
        assertTrue(g.isCurrent(t1))
        g.end()
        assertFalse(g.isCurrent(t1))
        val t2 = g.begin()
        assertFalse(g.isCurrent(t1))
        assertTrue(g.isCurrent(t2))
        assertEquals(false, g.isCurrent(t2 + 1))
    }
}
