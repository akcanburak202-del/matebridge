package dev.matebridge.client.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

/** Audio message rules from PROTOCOL.md 0x30-0x32 that the fixtures do not cover directly. */
class AudioCodecTest {
    private fun frame(type: Int, payload: ByteArray): ByteArray {
        val b = ByteBuffer.allocate(5 + payload.size).order(ByteOrder.LITTLE_ENDIAN)
        b.put(type.toByte()).putInt(payload.size).put(payload)
        return b.array()
    }

    private fun decode(bytes: ByteArray): Message? {
        val dec = FrameDecoder.control()
        dec.feed(bytes)
        return dec.next()
    }

    private fun expectError(kind: ProtocolException.Kind, bytes: ByteArray) {
        try {
            decode(bytes)
            fail("expected $kind")
        } catch (e: ProtocolException) {
            assertEquals(kind, e.kind)
        }
    }

    private fun audioFramePayload(frameCount: Int, dataLen: Int, dataBytes: Int, trailing: ByteArray = ByteArray(0)): ByteArray {
        val b = ByteBuffer.allocate(AudioFrame.FIXED_BYTES + dataBytes + trailing.size).order(ByteOrder.LITTLE_ENDIAN)
        b.putShort(9).putShort(0).putInt(1).putLong(480).putLong(1_000_000)
        b.putShort(frameCount.toShort()).putShort(dataLen.toShort())
        b.put(ByteArray(dataBytes) { 0x11 }).put(trailing)
        return b.array()
    }

    @Test
    fun typesAndCapabilityBit() {
        assertEquals(0x30, MsgType.AUDIO_PREFS)
        assertEquals(0x31, MsgType.AUDIO_CONFIG)
        assertEquals(0x32, MsgType.AUDIO_FRAME)
        assertEquals(0x100, Capabilities.AUDIO_PCM)
    }

    @Test
    fun prefsEnabledOtherThanOneIsFalse() {
        for (raw in listOf(0, 2, 0x7f, 0xff)) {
            assertEquals("enabled=$raw", AudioPrefs(false), decode(frame(MsgType.AUDIO_PREFS, byteArrayOf(raw.toByte(), 0, 0, 0))))
        }
    }

    @Test
    fun prefsEncodeDisabled() {
        assertArrayEquals(byteArrayOf(0x30, 4, 0, 0, 0, 0, 0, 0, 0), Codec.encode(AudioPrefs(false)))
    }

    @Test
    fun prefsShortPayloadIsAnError() {
        expectError(ProtocolException.Kind.SHORT_PAYLOAD, frame(MsgType.AUDIO_PREFS, byteArrayOf(1, 0, 0)))
    }

    @Test
    fun configKeepsUnknownStateAndFormat() {
        val p = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN)
        p.putShort(5).put(7).put(9).putInt(44100).put(6).put(0).putShort(256)
        val expected = AudioConfig(5, 7, 9, 44100, 6, 256)
        assertEquals(expected, decode(frame(MsgType.AUDIO_CONFIG, p.array())))
        assertArrayEquals(frame(MsgType.AUDIO_CONFIG, p.array()), Codec.encode(expected))
    }

    @Test
    fun configShortPayloadIsAnError() {
        expectError(ProtocolException.Kind.SHORT_PAYLOAD, frame(MsgType.AUDIO_CONFIG, ByteArray(11)))
    }

    @Test
    fun frameCountOutOfRangeIsAnError() {
        for (count in listOf(0, 961, 0xffff)) {
            expectError(ProtocolException.Kind.INVALID_VALUE, frame(MsgType.AUDIO_FRAME, audioFramePayload(count, 4, 4)))
        }
    }

    @Test
    fun frameCountLimitsAccepted() {
        val one = decode(frame(MsgType.AUDIO_FRAME, audioFramePayload(1, 4, 4))) as AudioFrame
        assertEquals(1, one.frameCount)
        assertEquals(4, one.data.size)
        val max = decode(frame(MsgType.AUDIO_FRAME, audioFramePayload(960, 3840, 3840))) as AudioFrame
        assertEquals(960, max.frameCount)
        assertEquals(3840, max.data.size)
    }

    @Test
    fun frameShortDataIsAnError() {
        expectError(ProtocolException.Kind.SHORT_PAYLOAD, frame(MsgType.AUDIO_FRAME, audioFramePayload(4, 16, 15)))
        expectError(ProtocolException.Kind.SHORT_PAYLOAD, frame(MsgType.AUDIO_FRAME, audioFramePayload(4, 0, 0).copyOf(27)))
    }

    @Test
    fun frameTrailingBytesIgnored() {
        val trailing = byteArrayOf(0xaa.toByte(), 0xbb.toByte())
        val m = decode(frame(MsgType.AUDIO_FRAME, audioFramePayload(2, 8, 8, trailing))) as AudioFrame
        assertEquals(AudioFrame(9, 1, 480, 1_000_000, 2, Bytes(ByteArray(8) { 0x11 })), m)
    }

    /** data_len that does not match frame_count x channels x 2 is the client's to drop, not a protocol error. */
    @Test
    fun frameDataLenMismatchDecodes() {
        val m = decode(frame(MsgType.AUDIO_FRAME, audioFramePayload(4, 6, 6))) as AudioFrame
        assertEquals(6, m.data.size)
    }

    @Test
    fun encodeRejectsInvalidFrames() {
        for ((count, size) in listOf(0 to 0, 961 to 0, 960 to 65_536)) {
            try {
                Codec.encode(AudioFrame(1, 0, 0, 0, count, Bytes(ByteArray(size))))
                fail("frame_count=$count size=$size must be refused")
            } catch (e: IllegalArgumentException) {
            }
        }
    }

    @Test
    fun fullTenMsPacketRoundTrips() {
        val pcm = ByteArray(1920) { (it * 7).toByte() }
        val m = AudioFrame(2, 100, 48_000, 5, 480, Bytes(pcm))
        val bytes = Codec.encode(m)
        assertEquals(5 + AudioFrame.FIXED_BYTES + 1920, bytes.size)
        assertEquals(m, decode(bytes))
    }

    /** Large u32/u64 values survive the round trip (unsigned bit patterns). */
    @Test
    fun unsignedExtremesRoundTrip() {
        val m = AudioFrame(0xffff, 0xffffffffL, -1L, Long.MIN_VALUE, 960, Bytes(ByteArray(3840)))
        assertEquals(m, decode(Codec.encode(m)))
        val c = AudioConfig(0xffff, 0xff, 0xff, 0xffffffffL, 0xff, 0xffff)
        assertEquals(c, decode(Codec.encode(c)))
    }
}
