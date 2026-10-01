package dev.matebridge.client.audio

import dev.matebridge.client.protocol.AudioConfig
import dev.matebridge.client.protocol.AudioFrame
import dev.matebridge.client.protocol.Bytes
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioStreamGateTest {
    private fun started(id: Int, format: Int = 1, rate: Long = 48_000, ch: Int = 2) =
        AudioConfig(id, AudioConfig.STATE_STARTED, format, rate, ch, 480)

    private fun frame(id: Int, frames: Int = 480, bytes: Int = frames * 4) =
        AudioFrame(id, 0, 0, 0, frames, Bytes(ByteArray(bytes)))

    private fun armed(gen: Int = 7) = AudioStreamGate().also { it.arm(gen) }

    @Test fun startStopAndFrameMatching() {
        val g = armed()
        assertFalse(g.accepts(frame(1), 7))
        assertEquals(AudioStreamGate.Action.Start(1), g.onConfig(started(1), 7))
        assertTrue(g.accepts(frame(1), 7))
        assertFalse(g.accepts(frame(2), 7)) // other stream
        assertFalse(g.accepts(frame(1, bytes = 480 * 4 - 2), 7)) // data_len mismatch: dropped, not an error
        assertEquals(AudioStreamGate.Action.None, g.onConfig(started(1), 7)) // repeated STARTED keeps the stream
        assertEquals(AudioStreamGate.Action.Start(2), g.onConfig(started(2), 7))
        assertFalse(g.accepts(frame(1), 7))
        assertEquals(AudioStreamGate.Action.Stop, g.onConfig(AudioConfig.stopped(2), 7))
        assertFalse(g.accepts(frame(2), 7))
        assertEquals(AudioStreamGate.Action.None, g.onConfig(AudioConfig.stopped(2), 7))
    }

    @Test fun unplayableStreamsAreIgnored() {
        val g = armed()
        g.onConfig(started(1), 7)
        assertEquals(AudioStreamGate.Action.Unsupported, g.onConfig(started(2, format = 9), 7))
        assertFalse(g.accepts(frame(2), 7))
        assertFalse(g.accepts(frame(1), 7))
        assertEquals(AudioStreamGate.Action.Unsupported, g.onConfig(started(3, rate = 44_100), 7))
        assertEquals(AudioStreamGate.Action.Unsupported, g.onConfig(started(4, ch = 1), 7))
        assertEquals(AudioStreamGate.Action.Start(5), g.onConfig(started(5), 7))
    }

    @Test fun unknownStateIsIgnored() {
        val g = armed()
        g.onConfig(started(1), 7)
        assertEquals(AudioStreamGate.Action.None, g.onConfig(AudioConfig(1, 7, 1, 48_000, 2, 480), 7))
        assertTrue(g.accepts(frame(1), 7))
    }

    @Test fun nothingIsTakenBeforeArmingOrAfterDisarming() {
        val g = AudioStreamGate()
        assertEquals(AudioStreamGate.Action.None, g.onConfig(started(1), 3)) // not armed yet
        g.arm(3)
        assertEquals(AudioStreamGate.Action.Start(1), g.onConfig(started(1), 3))
        g.disarm() // connection closed / background
        assertFalse(g.accepts(frame(1), 3))
        // a stale reader delivering STARTED after teardown must not create an orphan stream
        assertEquals(AudioStreamGate.Action.None, g.onConfig(started(2), 3))
        assertFalse(g.armed)
    }

    @Test fun staleGenerationCannotReplaceTheNewStream() {
        val g = AudioStreamGate()
        g.arm(3)
        g.onConfig(started(1), 3)
        g.arm(4) // reconnect: generation 4 is current, the old stream is gone
        assertFalse(g.accepts(frame(1), 3))
        assertEquals(AudioStreamGate.Action.Start(1), g.onConfig(started(1), 4)) // the same id may start again
        // the old reader (gen 3) still delivers a late STARTED and frames: ignored
        assertEquals(AudioStreamGate.Action.None, g.onConfig(started(9), 3))
        assertEquals(AudioStreamGate.Action.None, g.onConfig(AudioConfig.stopped(1), 3))
        assertFalse(g.accepts(frame(1), 3))
        assertTrue(g.accepts(frame(1), 4))
    }

    @Test fun videoLatencyIsMedianFiltered() {
        val f = VideoLatencyFilter(5)
        assertNull(f.value())
        f.add(40_000)
        assertEquals(40_000L, f.value())
        f.add(42_000); f.add(41_000); f.add(43_000)
        f.add(150_000) // one Wi-Fi spike
        assertEquals(42_000L, f.value())
        f.add(150_000)
        assertEquals(43_000L, f.value()) // the oldest (40 ms) left the window
        f.add(null) // no video
        assertNull(f.value())
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
