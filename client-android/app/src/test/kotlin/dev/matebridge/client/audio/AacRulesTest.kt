package dev.matebridge.client.audio

import dev.matebridge.client.protocol.AudioConfig
import dev.matebridge.client.protocol.AudioFrame
import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Capabilities
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-341 (decision 0038 section 4): AAC-LC rules that need no Android classes. */
class AacRulesTest {
    @Test fun audioSpecificConfigOf48kStereoIs1190() {
        assertArrayEquals(byteArrayOf(0x11, 0x90.toByte()), AacRules.audioSpecificConfig(48_000, 2))
    }

    @Test fun audioSpecificConfigOtherRates() {
        // 44.1 kHz stereo: 00010 0100 0010 000 = 0x12 0x10; 48 kHz mono: 00010 0011 0001 000 = 0x11 0x88
        assertArrayEquals(byteArrayOf(0x12, 0x10), AacRules.audioSpecificConfig(44_100, 2))
        assertArrayEquals(byteArrayOf(0x11, 0x88.toByte()), AacRules.audioSpecificConfig(48_000, 1))
        assertNull(AacRules.audioSpecificConfig(47_999, 2))
        assertNull(AacRules.audioSpecificConfig(48_000, 0))
        assertNull(AacRules.audioSpecificConfig(48_000, 8))
    }

    @Test fun onlyWholeUnitsOfThe1024FrameShapeAreValid() {
        assertTrue(AacRules.isValidUnit(1024, 1))
        assertTrue(AacRules.isValidUnit(1024, 300))
        assertTrue(AacRules.isValidUnit(1024, 1536))
        assertFalse(AacRules.isValidUnit(1024, 0))
        assertFalse(AacRules.isValidUnit(1024, 1537))
        assertFalse(AacRules.isValidUnit(960, 300))
        assertFalse(AacRules.isValidUnit(1023, 300))
        assertFalse(AacRules.isValidUnit(0, 300))
    }

    @Test fun bit14IsWrittenOnlyWithAudioAndADecoder() {
        assertEquals(1L shl 14, AacRules.capabilityBits(audioAllowed = true, decoderAvailable = true))
        assertEquals(Capabilities.AUDIO_AAC.toLong(), AacRules.capabilityBits(true, true))
        assertEquals(0L, AacRules.capabilityBits(audioAllowed = true, decoderAvailable = false))
        assertEquals(0L, AacRules.capabilityBits(audioAllowed = false, decoderAvailable = true))
        assertTrue(AacRules.hasAacCapability(0x7FF or (1 shl 14)))
        assertFalse(AacRules.hasAacCapability(0x7FF))
    }

    @Test fun remoteStartBufferIsAtLeast100ms() {
        assertEquals(100, RemoteAudio.startMs(20))
        assertEquals(100, RemoteAudio.startMs(40))
        assertEquals(100, RemoteAudio.startMs(100))
    }

    // --- gate ---

    private fun aacStarted(id: Int, rate: Long = 48_000, ch: Int = 2) =
        AudioConfig(id, AudioConfig.STATE_STARTED, AudioConfig.FORMAT_AAC_LC, rate, ch, 1024)

    private fun aacFrame(id: Int, frames: Int = 1024, bytes: Int = 300) =
        AudioFrame(id, 0, 0, 0, frames, Bytes(ByteArray(bytes)))

    @Test fun gatePlaysAacOnlyWhenTheDeviceDecodesIt() {
        val without = AudioStreamGate().also { it.arm(1) }
        assertEquals(AudioStreamGate.Action.Unsupported, without.onConfig(aacStarted(4), 1))
        val g = AudioStreamGate(aacAllowed = true).also { it.arm(1) }
        assertEquals(AudioStreamGate.Action.Start(4), g.onConfig(aacStarted(4), 1))
        assertEquals(AudioConfig.FORMAT_AAC_LC, g.currentFormat)
        assertEquals(AudioStreamGate.Action.Unsupported, g.onConfig(aacStarted(5, rate = 44_100), 1))
        assertEquals(AudioStreamGate.Action.Unsupported, g.onConfig(aacStarted(6, ch = 1), 1))
    }

    @Test fun gateDropsInvalidAacUnits() {
        val g = AudioStreamGate(aacAllowed = true).also { it.arm(1) }
        g.onConfig(aacStarted(4), 1)
        assertTrue(g.accepts(aacFrame(4), 1))
        assertFalse(g.accepts(aacFrame(4, frames = 960), 1))
        assertFalse(g.accepts(aacFrame(4, bytes = 0), 1))
        assertFalse(g.accepts(aacFrame(4, bytes = 1537), 1))
        assertFalse(g.accepts(aacFrame(5), 1)) // other stream
        // PCM still uses data_len = frame_count x 4 on the next stream
        g.onConfig(AudioConfig(6, AudioConfig.STATE_STARTED, AudioConfig.FORMAT_PCM_S16LE, 48_000, 2, 480), 1)
        assertTrue(g.accepts(AudioFrame(6, 0, 0, 0, 480, Bytes(ByteArray(1920))), 1))
        assertFalse(g.accepts(aacFrame(6), 1))
    }
}
