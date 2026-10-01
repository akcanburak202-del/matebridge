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

    @Test fun shortAndErrorWritesDoNotMoveBackwards() {
        val c = OutputClock()
        c.reset(0)
        c.onWrite(-1)
        c.onWrite(0)
        assertEquals(0L, c.written)
    }
}
