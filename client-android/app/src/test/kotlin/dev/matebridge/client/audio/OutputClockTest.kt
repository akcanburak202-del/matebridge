package dev.matebridge.client.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OutputClockTest {
    @Test fun noTimestampNoPosition() {
        val c = OutputClock()
        c.reset(240)
        assertEquals(240L, c.written)
        assertFalse(c.valid)
        assertNull(c.presentTimeUs())
        assertNull(c.latencyUs(0))
    }

    @Test fun latencyMatchesTheProbeFormula() {
        // T-099 exclusive MMAP: 480 frames queued ahead of the presented frame, timestamp 2 ms old -> 8 ms.
        val c = OutputClock()
        c.reset(240)
        c.onWrite(240 * 100)
        val written = c.written
        c.onTimestamp(written - 480, 1_000_000_000L)
        assertTrue(c.valid)
        assertEquals(1_000_000L + 10_000L, c.presentTimeUs())
        assertEquals(8_000L, c.latencyUs(1_002_000_000L))
    }

    @Test fun sameAnswerForBothOutputsGivenTheSameTimestamp() {
        // AudioTrack (960-frame bursts) and AAudio (240-frame bursts) that have written the same frames and report
        // the same (position, time) give the same present time: A/V math does not depend on the output.
        val track = OutputClock().apply { reset(960); repeat(10) { onWrite(960) } }
        val aaudio = OutputClock().apply { reset(240); repeat(43) { onWrite(240) } }
        assertEquals(track.written, aaudio.written)
        track.onTimestamp(5_000, 7_000_000_000L)
        aaudio.onTimestamp(5_000, 7_000_000_000L)
        assertEquals(track.presentTimeUs(), aaudio.presentTimeUs())
        assertEquals(
            AvSync.presentTimeUs(track.written, 5_000, 7_000_000_000L),
            track.presentTimeUs(),
        )
    }

    @Test fun resetDropsTheOldOutputsTimestamp() {
        val c = OutputClock()
        c.reset(0)
        c.onWrite(4800)
        c.onTimestamp(1000, 5_000_000L)
        c.reset(240)
        assertFalse(c.valid)
        assertEquals(240L, c.written)
        assertNull(c.presentTimeUs())
    }

    // ---- T-101: AAudio counters (synthetic) ----

    /**
     * A synthetic MMAP stream: AAudio's write counter starts at [startOffset] + 240 pre-frames (start catch-up moved it
     * that far ahead of our count), the reader stays [bufFrames] behind the writer, and the device presents a frame
     * [hwUs] after reading it. Returns the latency the clock reports for the newest written frame.
     */
    private fun aaudioLatencyUs(
        startOffset: Long,
        bufFrames: Long = 480,
        hwUs: Long = 5_000,
        tsDomainShift: Long = 0,
        tsAgeUs: Long = 2_000,
        withTs: Boolean = true,
    ): Pair<Long, OutputClock.Source> {
        val c = OutputClock()
        c.reset(240)
        repeat(200) { c.onWrite(240) }
        val deviceWritten = c.written + startOffset
        val deviceRead = deviceWritten - bufFrames
        val now = 50_000_000_000L
        val tsNs = now - tsAgeUs * 1000
        // Frame presented at tsNs: what was read hwUs before it, i.e. read counter minus (hw + age) worth of frames.
        val tsPos = deviceRead - (hwUs + tsAgeUs) * 48 / 1000 + tsDomainShift
        val src = c.onDeviceCounters(deviceWritten, deviceRead, if (withTs) tsPos else null, tsNs, now)
        return c.latencyUs(now)!! to src
    }

    @Test fun aaudioLatencyIsBufferPlusHardwareDelay() {
        val (lat, src) = aaudioLatencyUs(startOffset = 0)
        assertEquals(OutputClock.Source.TIMESTAMP, src)
        assertEquals(10_000L + 5_000L, lat) // 480 frames = 10 ms, plus 5 ms in the device
    }

    @Test fun startCatchUpDoesNotDistortTheLatency() {
        // The reader ran ahead of the writer at start, so AAudio advanced its write counter by 20 640 frames (430 ms):
        // our own count is that much behind AAudio's. The latency must still be buffer + device delay.
        val (lat, src) = aaudioLatencyUs(startOffset = 20_640)
        assertEquals(OutputClock.Source.TIMESTAMP, src)
        assertEquals(15_000L, lat)
        // ...and the other way round (our count ahead of AAudio's).
        assertEquals(15_000L, aaudioLatencyUs(startOffset = -20_640).first)
    }

    @Test fun ourCountMixedWithAaudiosTimestampWasTheBug() {
        // The T-100 arithmetic (our count against AAudio's timestamp) with the same synthetic stream is off by the offset.
        val c = OutputClock()
        c.reset(240)
        repeat(200) { c.onWrite(240) }
        val deviceWritten = c.written + 20_640
        val tsPos = deviceWritten - 480 - 7_000 * 48 / 1000
        val now = 50_000_000_000L
        c.onTimestamp(tsPos, now - 2_000_000)
        assertEquals(15_000L - 430_000L, c.latencyUs(now))
    }

    @Test fun inconsistentTimestampFallsBackToTheReadCounter() {
        // A timestamp from another domain (430 ms behind the read counter) is not used: the frame at the read counter
        // is taken as presented now, so the latency is the buffer alone (the device delay is not known then).
        val (lat, src) = aaudioLatencyUs(startOffset = 20_640, tsDomainShift = -20_640)
        assertEquals(OutputClock.Source.READ, src)
        assertEquals(10_000L, lat)
        // A timestamp ahead of the read counter by more than the jitter margin is not used either.
        assertEquals(OutputClock.Source.READ, aaudioLatencyUs(startOffset = 0, tsDomainShift = 4_800).second)
    }

    @Test fun missingTimestampUsesTheReadCounter() {
        val (lat, src) = aaudioLatencyUs(startOffset = 1_000, withTs = false)
        assertEquals(OutputClock.Source.READ, src)
        assertEquals(10_000L, lat)
    }

    @Test fun oldTimestampIsCarriedForward() {
        // A 300 ms old timestamp is still consistent once carried forward to now.
        val (lat, src) = aaudioLatencyUs(startOffset = 0, tsAgeUs = 300_000)
        assertEquals(OutputClock.Source.TIMESTAMP, src)
        assertEquals(15_000L, lat)
    }

    @Test fun deviceCountersTrackLaterWrites() {
        val c = OutputClock()
        c.reset(240)
        c.onWrite(240 * 10)
        val now = 1_000_000_000L
        c.onDeviceCounters(deviceWritten = c.written + 9_600, deviceRead = c.written + 9_600 - 480, null, 0, now)
        assertEquals(9_600L, c.domainOffset)
        c.onWrite(240) // one more burst after the read: 5 ms more queued
        assertEquals(15_000L, c.latencyUs(now))
        c.reset(240)
        assertEquals(0L, c.domainOffset)
        assertEquals(OutputClock.Source.NONE, c.source)
    }

    @Test fun shortAndErrorWritesDoNotMoveBackwards() {
        val c = OutputClock()
        c.reset(0)
        c.onWrite(-1)
        c.onWrite(0)
        assertEquals(0L, c.written)
    }
}
