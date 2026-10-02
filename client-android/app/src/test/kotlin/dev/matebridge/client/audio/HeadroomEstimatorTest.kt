package dev.matebridge.client.audio

import org.junit.Assert.assertEquals
import org.junit.Test

class HeadroomEstimatorTest {
    private val ms = 1_000_000L
    private val now = 50_000L * ms
    private val written = 1_000_000L
    /** The MMAP client model: a full 960-frame ring (4 bursts) whenever it is sampled (T-110 on the device). */
    private val read = written - 960

    @Test fun withoutATimestampTheCounterIsUsed() {
        val e = HeadroomEstimator()
        assertEquals(960L, e.estimate(written, read, 0, 0, now))
        assertEquals(HeadroomEstimator.Source.COUNTER, e.source)
        assertEquals(960L, e.counterHeadroom)
    }

    @Test fun timestampIsCarriedForwardToNow() {
        // The timestamp says frame read-144 was at the device 2 ms ago: carried forward it is at read-48 now.
        val e = HeadroomEstimator()
        val h = e.estimate(written, read, tsPosition = read - 144, tsNanoTime = now - 2 * ms, nowNs = now)
        assertEquals(HeadroomEstimator.Source.TIMESTAMP, e.source)
        assertEquals(1008L, h) // the counter's 960 plus the 48 frames the device position is behind it
        assertEquals(960L, e.counterHeadroom)
    }

    @Test fun aDevicePositionAheadOfTheClientModelLowersTheHeadroom() {
        // The counter says the ring is full, but the HAL's position is 10 ms ahead of the client model: only 480 frames
        // are really left. This is what the counter alone cannot see.
        val e = HeadroomEstimator()
        assertEquals(480L, e.estimate(written, read, tsPosition = read + 480 - 96, tsNanoTime = now - 2 * ms, nowNs = now))
        assertEquals(HeadroomEstimator.Source.TIMESTAMP, e.source)
        assertEquals(960L, e.counterHeadroom)
        // 19.8 ms ahead: almost nothing left.
        assertEquals(10L, e.estimate(written, read, tsPosition = read + 950, tsNanoTime = now, nowNs = now))
        assertEquals(HeadroomEstimator.Source.TIMESTAMP, e.source)
    }

    @Test fun anInconsistentTimestampFallsBackToTheCounter() {
        val e = HeadroomEstimator()
        // More than 20 ms ahead of the read counter (OutputClock.MIN_LAG_US).
        assertEquals(960L, e.estimate(written, read, tsPosition = read + 1_000, tsNanoTime = now, nowNs = now))
        assertEquals(HeadroomEstimator.Source.COUNTER, e.source)
        // More than 100 ms behind it (OutputClock.MAX_LAG_US), e.g. a timestamp from before a start catch-up.
        assertEquals(960L, e.estimate(written, read, tsPosition = read - 4_900, tsNanoTime = now, nowNs = now))
        assertEquals(HeadroomEstimator.Source.COUNTER, e.source)
    }

    @Test fun anOldTimestampIsStillCarriedForward() {
        // The service sends timestamps every few bursts: one 40 ms old carried forward at 48 kHz.
        val e = HeadroomEstimator()
        val h = e.estimate(written, read, tsPosition = read - 1_920 - 96, tsNanoTime = now - 40 * ms, nowNs = now)
        assertEquals(HeadroomEstimator.Source.TIMESTAMP, e.source)
        assertEquals(1056L, h)
    }

    @Test fun sourceFollowsEachEstimate() {
        val e = HeadroomEstimator()
        e.estimate(written, read, read, now, now)
        assertEquals(HeadroomEstimator.Source.TIMESTAMP, e.source)
        e.estimate(written, read, 0, 0, now)
        assertEquals(HeadroomEstimator.Source.COUNTER, e.source)
    }

    @Test fun anUnderflowIsSeenAsZeroOrLess() {
        // The device position has passed everything written (headroom <= 0 counts as an estimated underflow).
        val e = HeadroomEstimator()
        val h = e.estimate(written, written - 240, tsPosition = written + 48, tsNanoTime = now, nowNs = now)
        assertEquals(HeadroomEstimator.Source.TIMESTAMP, e.source)
        assertEquals(-48L, h)
        val m = HeadroomMeter()
        m.onWriteStart(h, now, e.counterHeadroom, fromTs = true)
        val w = m.window()
        assertEquals(1, w.underflowEst)
        assertEquals(240L, w.counterMinFrames)
        assertEquals("ts", w.source)
    }
}
