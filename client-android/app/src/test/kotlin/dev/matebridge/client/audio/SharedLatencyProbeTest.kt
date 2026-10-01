package dev.matebridge.client.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SharedLatencyProbeTest {
    private val burst = 240 // 5 ms

    /** Feeds one sample per burst from frame 0 until a verdict, with [latencyUs] (null = timestamp failure). */
    private fun run(p: SharedLatencyProbe, latencyUs: (Long) -> Long?): Pair<SharedLatencyProbe.Result, Long> {
        var played = 0L
        while (played < 48_000L * 5) {
            val r = p.add(played, latencyUs(played))
            if (r != SharedLatencyProbe.Result.PENDING) return r to played
            played += burst
        }
        return SharedLatencyProbe.Result.PENDING to played
    }

    @Test fun lowLatencyIsAcceptedAfterWarmupAndMeasurement() {
        val p = SharedLatencyProbe()
        val (r, at) = run(p) { 25_000L }
        assertEquals(SharedLatencyProbe.Result.ACCEPT, r)
        assertEquals(48_000L * 800 / 1000, at) // 300 ms warm-up + 500 ms measurement
        assertEquals(25_000L, p.medianUs)
    }

    @Test fun warmupSamplesAreIgnored() {
        val p = SharedLatencyProbe()
        val (r, _) = run(p) { played -> if (played < 48_000L * 300 / 1000) 500_000L else 20_000L }
        assertEquals(SharedLatencyProbe.Result.ACCEPT, r)
        assertEquals(20_000L, p.medianUs)
    }

    @Test fun highLatencyIsRejected() {
        val p = SharedLatencyProbe()
        val (r, _) = run(p) { 99_000L }
        assertEquals(SharedLatencyProbe.Result.REJECT, r)
        assertEquals(99_000L, p.medianUs)
    }

    @Test fun thresholdIsInclusive() {
        assertEquals(SharedLatencyProbe.Result.ACCEPT, run(SharedLatencyProbe(maxLatencyMs = 60)) { 60_000L }.first)
        assertEquals(SharedLatencyProbe.Result.REJECT, run(SharedLatencyProbe(maxLatencyMs = 60)) { 60_001L }.first)
    }

    @Test fun medianIgnoresSpikes() {
        val p = SharedLatencyProbe()
        var i = 0
        val (r, _) = run(p) { if (i++ % 10 == 0) 494_000L else 30_000L }
        assertEquals(SharedLatencyProbe.Result.ACCEPT, r)
        assertEquals(30_000L, p.medianUs)
    }

    @Test fun failingTimestampsRejectAtTheDeadline() {
        val p = SharedLatencyProbe()
        val (r, at) = run(p) { null }
        assertEquals(SharedLatencyProbe.Result.REJECT, r)
        assertEquals(48_000L * 2, at)
        assertNull(p.medianUs)
    }

    @Test fun mostlyFailingTimestampsReject() {
        val p = SharedLatencyProbe()
        var i = 0
        val (r, _) = run(p) { if (i++ % 3 == 0) 20_000L else null }
        assertEquals(SharedLatencyProbe.Result.REJECT, r)
    }

    @Test fun negativeLatencyCountsAsFailure() {
        val p = SharedLatencyProbe()
        val (r, _) = run(p) { -5_000L }
        assertEquals(SharedLatencyProbe.Result.REJECT, r)
        assertEquals(0, p.samples)
    }

    @Test fun verdictIsFinal() {
        val p = SharedLatencyProbe()
        run(p) { 10_000L }
        assertEquals(SharedLatencyProbe.Result.ACCEPT, p.add(48_000L * 3, 900_000L))
    }
}
