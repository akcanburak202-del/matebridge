package dev.matebridge.client.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OutBufGrowthTest {
    private val burst = 240
    private val max = 6 * burst

    private fun win(min: Long? = 480, underflow: Int = 0) =
        HeadroomMeter.Window(writes = 200, headroomMinFrames = min, headroomP5Frames = min, underflowEst = underflow, gapMaxNs = 0, busyMaxNs = 0)

    @Test fun healthyWindowDoesNotGrow() {
        assertNull(OutBufGrowth.decide(win(min = 470), 0, burst, 480, max, warm = true))
        assertNull(OutBufGrowth.decide(win(min = 240), 0, burst, 480, max, warm = true)) // exactly one burst is enough
    }

    @Test fun headroomBelowOneBurstGrows() {
        assertEquals(OutBufGrowth.Reason.HEADROOM, OutBufGrowth.decide(win(min = 239), 0, burst, 480, max, warm = true))
    }

    @Test fun estimatedUnderflowGrows() {
        assertEquals(OutBufGrowth.Reason.UNDERFLOW, OutBufGrowth.decide(win(min = 0, underflow = 1), 0, burst, 480, max, warm = true))
    }

    @Test fun xrunRuleIsKeptForReportingDevices() {
        assertEquals(OutBufGrowth.Reason.XRUN, OutBufGrowth.decide(win(min = 480), 1, burst, 480, max, warm = true))
        // AudioTrack: no headroom, only xruns (its own grow() keeps its limit).
        assertEquals(OutBufGrowth.Reason.XRUN, OutBufGrowth.decide(win(min = null), 2, 960, 960, Int.MAX_VALUE, warm = true))
        assertNull(OutBufGrowth.decide(win(min = null), 0, 960, 960, Int.MAX_VALUE, warm = true))
    }

    @Test fun firstWindowAfterOpenIsIgnored() {
        assertNull(OutBufGrowth.decide(win(min = -100, underflow = 5), 3, burst, 480, max, warm = false))
    }

    @Test fun neverAboveTheLimit() {
        assertEquals(OutBufGrowth.Reason.UNDERFLOW, OutBufGrowth.decide(win(underflow = 1), 0, burst, 5 * burst, max, warm = true))
        assertNull(OutBufGrowth.decide(win(underflow = 1), 0, burst, 6 * burst, max, warm = true))
        // A capacity below six bursts is the limit.
        assertNull(OutBufGrowth.decide(win(underflow = 1), 0, burst, 3 * burst, 3 * burst + 100, warm = true))
    }

    @Test fun repeatedLowWindowsGrowOneBurstEachUpToTheLimit() {
        var buf = 2 * burst
        var grows = 0
        repeat(10) {
            if (OutBufGrowth.decide(win(min = 0, underflow = 1), 0, burst, buf, max, warm = true) != null) { buf += burst; grows++ }
        }
        assertEquals(max, buf)
        assertEquals(4, grows)
    }

    @Test fun theFourBurstDefaultIsSeenInTheAudioLatency() {
        // T-114: the AAudio default went from 2 to 4 bursts; audio_ms comes from the device counters, so the newest
        // frame's output latency is 20 ms instead of 10 ms (+10 ms), with no change in the A/V math.
        assertEquals(4, AudioBufferConfig.AAUDIO_DEFAULT_BURSTS)
        fun latencyWith(bursts: Int): Long? {
            val c = OutputClock()
            c.reset(240)
            repeat(100) { c.onWrite(240) }
            val now = 5_000_000_000L
            c.onDeviceCounters(deviceWritten = c.written + 1_000, deviceRead = c.written + 1_000 - bursts * 240L, null, 0, now)
            return c.latencyUs(now)
        }
        assertEquals(10_000L, latencyWith(2))
        assertEquals(20_000L, latencyWith(AudioBufferConfig.AAUDIO_DEFAULT_BURSTS))
    }

    @Test fun aGrownBufferIsSeenInTheAudioLatency() {
        // AAudio play position comes from the device counters, so the extra burst written after a grow raises the
        // latency of the newest frame (and audio_ms) by exactly one burst, without any A/V change.
        val c = OutputClock()
        c.reset(240)
        repeat(100) { c.onWrite(240) }
        val now = 5_000_000_000L
        c.onDeviceCounters(deviceWritten = c.written + 1_000, deviceRead = c.written + 1_000 - 480, null, 0, now)
        assertEquals(10_000L, c.latencyUs(now))
        c.onWrite(240) // the buffer grew to 720: the next write returns at once with one more burst queued
        assertEquals(15_000L, c.latencyUs(now))
        // The next counters read agrees.
        c.onDeviceCounters(deviceWritten = c.written + 1_000, deviceRead = c.written + 1_000 - 720, null, 0, now)
        assertEquals(15_000L, c.latencyUs(now))
    }
}
