package dev.matebridge.client.audio

import dev.matebridge.client.protocol.AudioConfig
import dev.matebridge.client.protocol.AudioFrame
import dev.matebridge.client.protocol.Bytes
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioStreamGateTest {
    private fun started(id: Int, format: Int = 1, rate: Long = 48_000, ch: Int = 2) =
        AudioConfig(id, AudioConfig.STATE_STARTED, format, rate, ch, 480)

    private fun frame(id: Int, frames: Int = 480, bytes: Int = frames * 4) =
        AudioFrame(id, 0, 0, 0, frames, Bytes(ByteArray(bytes)))

    @Test fun startStopAndFrameMatching() {
        val g = AudioStreamGate()
        assertFalse(g.accepts(frame(1)))
        assertEquals(AudioStreamGate.Action.Start(1), g.onConfig(started(1)))
        assertTrue(g.accepts(frame(1)))
        assertFalse(g.accepts(frame(2))) // other stream
        assertFalse(g.accepts(frame(1, bytes = 480 * 4 - 2))) // data_len mismatch: dropped, not an error
        assertEquals(AudioStreamGate.Action.None, g.onConfig(started(1))) // repeated STARTED keeps the stream
        assertEquals(AudioStreamGate.Action.Start(2), g.onConfig(started(2)))
        assertFalse(g.accepts(frame(1)))
        assertEquals(AudioStreamGate.Action.Stop, g.onConfig(AudioConfig.stopped(2)))
        assertFalse(g.accepts(frame(2)))
        assertEquals(AudioStreamGate.Action.None, g.onConfig(AudioConfig.stopped(2)))
    }

    @Test fun unplayableStreamsAreIgnored() {
        val g = AudioStreamGate()
        g.onConfig(started(1))
        assertEquals(AudioStreamGate.Action.Unsupported, g.onConfig(started(2, format = 9)))
        assertFalse(g.accepts(frame(2)))
        assertFalse(g.accepts(frame(1)))
        assertEquals(AudioStreamGate.Action.Unsupported, g.onConfig(started(3, rate = 44_100)))
        assertEquals(AudioStreamGate.Action.Unsupported, g.onConfig(started(4, ch = 1)))
        assertEquals(AudioStreamGate.Action.Start(5), g.onConfig(started(5)))
    }

    @Test fun unknownStateIsIgnored() {
        val g = AudioStreamGate()
        g.onConfig(started(1))
        assertEquals(AudioStreamGate.Action.None, g.onConfig(AudioConfig(1, 7, 1, 48_000, 2, 480)))
        assertTrue(g.accepts(frame(1)))
    }

    @Test fun resetDropsTheStream() {
        val g = AudioStreamGate()
        g.onConfig(started(1))
        g.reset()
        assertFalse(g.accepts(frame(1)))
        assertEquals(AudioStreamGate.Action.Start(1), g.onConfig(started(1))) // the same id may start again
    }

    @Test fun avArithmetic() {
        // frame 48 000 frames after the stamped one is heard 1 s later
        assertEquals(11_000_000L, AvSync.presentTimeUs(148_000, 100_000, 10_000_000_000L))
        // captured at host 5 s, host clock 2 s ahead of the client, heard at client 3.06 s: 60 ms
        assertEquals(60_000L, AvSync.audioLatencyUs(3_060_000, 5_000_000, 2_000_000))
        assertEquals(null, AvSync.videoLatencyUs(null, 1000, 8333))
        assertEquals(30_000L + 2_000 + 8_333, AvSync.videoLatencyUs(30_000, 2_000, 8_333))
        assertEquals(38_333L, AvSync.videoLatencyUs(30_000, null, 8_333))
    }
}
