package dev.matebridge.probe.input

import org.junit.Assert.assertEquals
import org.junit.Test

class RateMeterTest {
    @Test fun steady240Hz() {
        val m = RateMeter(500)
        for (i in 0..240) m.add(i * 1000L / 240)
        assertEquals(240.0, m.hz(), 3.0)
    }

    @Test fun emptyAndSingleAreZero() {
        val m = RateMeter()
        assertEquals(0.0, m.hz(), 0.0)
        m.add(10)
        assertEquals(0.0, m.hz(), 0.0)
    }

    @Test fun staleReadsZero() {
        val m = RateMeter(500)
        m.add(0); m.add(10); m.add(20)
        assertEquals(0.0, m.hzAt(2000), 0.0)
    }
}
