package dev.matebridge.aaudioprobe

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LatencyTest {
    private val rate = 48_000

    @Test
    fun timestampTakenNowGivesQueuedDuration() {
        // 480 frames queued at 48 kHz = 10 ms; timestamp time == now.
        val s = Sample(written = 10_480, presented = 10_000, presNs = 5_000_000_000, nowNs = 5_000_000_000)
        assertEquals(10.0, LatencyMath.latencyMs(s, rate), 1e-9)
    }

    @Test
    fun timeSinceTimestampIsSubtracted() {
        // 960 frames (20 ms) ahead of the timestamped frame, but that timestamp is 4 ms old: 16 ms remain.
        val s = Sample(written = 1_960, presented = 1_000, presNs = 1_000_000_000, nowNs = 1_004_000_000)
        assertEquals(16.0, LatencyMath.latencyMs(s, rate), 1e-9)
    }

    @Test
    fun futurePresentationTimeAdds() {
        // MMAP/DSP may report a frame that will be presented 2 ms from now.
        val s = Sample(written = 1_480, presented = 1_000, presNs = 1_002_000_000, nowNs = 1_000_000_000)
        assertEquals(12.0, LatencyMath.latencyMs(s, rate), 1e-9)
    }

    @Test
    fun warmupSamplesAreDropped() {
        val start = 1_000_000_000L
        val samples = listOf(
            Sample(480, 0, start + 100_000_000, start + 100_000_000), // inside warmup
            Sample(960, 0, start + 600_000_000, start + 600_000_000),
            Sample(1_440, 0, start + 500_000_000, start + 500_000_000), // exactly at the boundary: kept
        )
        val lat = LatencyMath.latencies(samples, rate, start, 500_000_000L)
        assertArrayEquals(doubleArrayOf(20.0, 30.0), lat, 1e-9)
    }

    @Test
    fun statsNearestRank() {
        val v = DoubleArray(20) { (it + 1).toDouble() } // 1..20
        val s = LatencyStats.of(v)!!
        assertEquals(20, s.count)
        assertEquals(10.5, s.mean, 1e-9)
        assertEquals(10.0, s.p50, 1e-9)
        assertEquals(19.0, s.p95, 1e-9)
        assertEquals(1.0, s.min, 1e-9)
        assertEquals(20.0, s.max, 1e-9)
    }

    @Test
    fun statsSingleValueAndEmpty() {
        val s = LatencyStats.of(doubleArrayOf(7.5))!!
        assertEquals(7.5, s.p50, 1e-9)
        assertEquals(7.5, s.p95, 1e-9)
        assertNull(LatencyStats.of(DoubleArray(0)))
    }
}
