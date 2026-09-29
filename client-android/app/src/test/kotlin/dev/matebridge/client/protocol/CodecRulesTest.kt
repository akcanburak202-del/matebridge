package dev.matebridge.client.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Edge rules from PROTOCOL.md sections 1-2 that no fixture covers directly. */
class CodecRulesTest {
    private fun frame(type: Int, payload: ByteArray): ByteArray {
        val b = ByteBuffer.allocate(5 + payload.size).order(ByteOrder.LITTLE_ENDIAN)
        b.put(type.toByte()).putInt(payload.size).put(payload)
        return b.array()
    }

    private fun expectError(kind: ProtocolException.Kind, dec: FrameDecoder) {
        try {
            dec.next()
            fail("expected $kind")
        } catch (e: ProtocolException) {
            assertEquals(kind, e.kind)
        }
    }

    private fun decode(bytes: ByteArray, dec: FrameDecoder = FrameDecoder.control()): Message? {
        dec.feed(bytes)
        return dec.next()
    }

    private fun f32le(v: Float) = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putFloat(v).array()

    private fun pointerRelPayload(dx: Float, dy: Float): ByteArray {
        val b = ByteBuffer.allocate(20).order(ByteOrder.LITTLE_ENDIAN)
        b.putLong(1).putFloat(dx).putFloat(dy)
        return b.array()
    }

    @Test
    fun nonFiniteFloatsRejected() {
        for (v in listOf(Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) {
            val dec = FrameDecoder.control()
            dec.feed(frame(MsgType.POINTER_REL, pointerRelPayload(v, 0f)))
            expectError(ProtocolException.Kind.NON_FINITE, dec)
            val dec2 = FrameDecoder.control()
            dec2.feed(frame(MsgType.SCROLL, pointerRelPayload(0f, v)))
            expectError(ProtocolException.Kind.NON_FINITE, dec2)
        }
    }

    @Test
    fun encodeRejectsNonFinite() {
        try {
            Codec.encode(PointerRel(0, Float.NaN, 0f, 0)); fail()
        } catch (e: IllegalArgumentException) {
        }
    }

    @Test
    fun oversizeRejectedFromHeaderAlone() {
        val dec = FrameDecoder.control()
        dec.feed(byteArrayOf(0x10, 0x01, 0x00, 0x01, 0x00)) // length 65537
        expectError(ProtocolException.Kind.OVERSIZE, dec)
        // exactly at the limit is fine (just needs more bytes)
        val ok = FrameDecoder.control()
        ok.feed(byteArrayOf(0x7f, 0x00, 0x00, 0x01, 0x00)) // 65536
        assertNull(ok.next())
        // video limit is larger
        val v = FrameDecoder.video()
        v.feed(byteArrayOf(0x41, 0x01, 0x00, 0x01, 0x00))
        assertNull(v.next())
        val v2 = FrameDecoder.video()
        v2.feed(byteArrayOf(0x41, 0x01, 0x00, 0x00, 0x01)) // 16 MiB + 1
        expectError(ProtocolException.Kind.OVERSIZE, v2)
    }

    @Test
    fun oversizeUnknownTypeAlsoRejected() {
        val dec = FrameDecoder.control()
        dec.feed(byteArrayOf(0x7f, 0x01, 0x00, 0x01, 0x00))
        expectError(ProtocolException.Kind.OVERSIZE, dec)
    }

    @Test
    fun longerPayloadIgnoresExtraBytes() {
        val p = Codec.encodePayload(Bye(Bye.TIMEOUT)) + byteArrayOf(9, 9, 9)
        assertEquals(Bye(Bye.TIMEOUT), decode(frame(MsgType.BYE, p)))
    }

    @Test
    fun shortPayloadRejectedForEveryKnownType() {
        for (type in listOf(
            MsgType.HELLO, MsgType.HELLO_ACK, MsgType.STREAM_CONFIG, MsgType.BYE, MsgType.PEN, MsgType.KEY,
            MsgType.POINTER_REL, MsgType.POINTER_ABS, MsgType.SCROLL, MsgType.PEN_GESTURE, MsgType.RELEASE_ALL,
            MsgType.PING, MsgType.PONG, MsgType.STATS, MsgType.KEYFRAME_REQUEST, MsgType.VIDEO_HELLO,
            MsgType.VIDEO_FRAME,
        )) {
            val dec = FrameDecoder.control()
            dec.feed(frame(type, ByteArray(0)))
            expectError(ProtocolException.Kind.SHORT_PAYLOAD, dec)
        }
    }

    @Test
    fun reservedBytesIgnoredOnDecode() {
        val p = Codec.encodePayload(Key(5, 30, 29, Key.DOWN, 0))
        p[14] = 0x7f // reserved bytes at the end of KEY
        p[15] = 0x7f
        assertEquals(Key(5, 30, 29, Key.DOWN, 0), decode(frame(MsgType.KEY, p)))
    }

    @Test
    fun penValidation() {
        fun pen(tool: Int, count: Int, dts: List<Long>): ByteArray {
            val b = ByteBuffer.allocate(12 + 16 * dts.size).order(ByteOrder.LITTLE_ENDIAN)
            b.put(tool.toByte()).put(count.toByte()).putShort(0).putLong(0)
            for (dt in dts) b.putInt(dt.toInt()).putShort(1).putShort(1).putShort(0).putShort(0).putShort(0).put(0).put(0)
            return frame(MsgType.PEN, b.array())
        }
        // bad tool
        var dec = FrameDecoder.control(); dec.feed(pen(2, 1, listOf(0)))
        expectError(ProtocolException.Kind.INVALID_VALUE, dec)
        // count 65 (payload also short for 65 samples)
        dec = FrameDecoder.control(); dec.feed(pen(0, 65, List(65) { 0L }))
        expectError(ProtocolException.Kind.INVALID_VALUE, dec)
        // count says 2 but only 1 sample present
        dec = FrameDecoder.control(); dec.feed(pen(0, 2, listOf(0)))
        expectError(ProtocolException.Kind.SHORT_PAYLOAD, dec)
        // decreasing dt
        dec = FrameDecoder.control(); dec.feed(pen(0, 2, listOf(10, 9)))
        expectError(ProtocolException.Kind.DECREASING_TIME, dec)
        // equal dt is fine; 64 samples is fine
        assertTrue(decode(pen(0, 2, listOf(10, 10))) is Pen)
        assertTrue(decode(pen(0, 64, List(64) { it.toLong() })) is Pen)
    }

    @Test
    fun penMinusThirtyTwoSevenSixtyEightClampsToMinus32767() {
        val p = Codec.encodePayload(Pen(0, 0, listOf(PenSample(0, 1, 1, 0, 0, 0, 0))))
        // tilt_x sits at offset 12 + 10
        p[22] = 0x00; p[23] = 0x80.toByte()
        val pen = decode(frame(MsgType.PEN, p)) as Pen
        assertEquals(-32767, pen.samples[0].tiltX)
    }

    @Test
    fun invalidKeyActionRejected() {
        val p = Codec.encodePayload(Key(0, 1, 1, Key.DOWN, 0))
        p[12] = 2
        val dec = FrameDecoder.control(); dec.feed(frame(MsgType.KEY, p))
        expectError(ProtocolException.Kind.INVALID_VALUE, dec)
    }

    @Test
    fun str8Rules() {
        // 64 bytes ok, 65 rejected on encode
        val ok = Hello(0, Bytes(ByteArray(16)), 1, 1, 1, 1, 0, "a".repeat(64))
        assertEquals(ok, decode(Codec.encode(ok)))
        try {
            Codec.encode(ok.copy(deviceName = "a".repeat(65))); fail()
        } catch (e: IllegalArgumentException) {
        }
        // 65 rejected on decode
        val p = Codec.encodePayload(HelloAck(0, 0, 1, 1, "x"))
        val bad = p.copyOf(p.size - 2) + byteArrayOf(65) + ByteArray(65) { 'a'.code.toByte() }
        val dec = FrameDecoder.control(); dec.feed(frame(MsgType.HELLO_ACK, bad))
        expectError(ProtocolException.Kind.INVALID_STRING, dec)
        // invalid UTF-8
        val bad2 = p.copyOf(p.size - 2) + byteArrayOf(1, 0xFF.toByte())
        val dec2 = FrameDecoder.control(); dec2.feed(frame(MsgType.HELLO_ACK, bad2))
        expectError(ProtocolException.Kind.INVALID_STRING, dec2)
        // length byte beyond payload
        val bad3 = p.copyOf(p.size - 2) + byteArrayOf(10, 'a'.code.toByte())
        val dec3 = FrameDecoder.control(); dec3.feed(frame(MsgType.HELLO_ACK, bad3))
        expectError(ProtocolException.Kind.SHORT_PAYLOAD, dec3)
    }

    @Test
    fun u32AndU64ExtremesRoundTrip() {
        val s = Stats(4294967295L, 0, 1, 2, 3, 4, 5, 4294967295L)
        assertEquals(s, decode(Codec.encode(s)))
        val ping = Ping(4294967295L, -1L) // u64 max as bit pattern
        assertEquals(ping, decode(Codec.encode(ping)))
        try {
            Codec.encode(s.copy(intervalMs = 4294967296L)); fail()
        } catch (e: IllegalArgumentException) {
        }
        try {
            Codec.encode(Ping(-1, 0)); fail()
        } catch (e: IllegalArgumentException) {
        }
    }

    @Test
    fun encodeRejectsInvalidPen() {
        for (bad in listOf(
            Pen(2, 0, listOf(PenSample(0, 0, 0, 0, 0, 0, 0))),
            Pen(0, 0, emptyList()),
            Pen(0, 0, List(65) { PenSample(0, 0, 0, 0, 0, 0, 0) }),
            Pen(0, 0, listOf(PenSample(5, 0, 0, 0, 0, 0, 0), PenSample(4, 0, 0, 0, 0, 0, 0))),
        )) {
            try {
                Codec.encode(bad); fail()
            } catch (e: IllegalArgumentException) {
            }
        }
    }

    @Test
    fun errorIsSticky() {
        val dec = FrameDecoder.control()
        dec.feed(frame(MsgType.KEY, ByteArray(3)) + Codec.encode(Ping(1, 1)))
        expectError(ProtocolException.Kind.SHORT_PAYLOAD, dec)
        expectError(ProtocolException.Kind.SHORT_PAYLOAD, dec)
    }

    @Test
    fun largeVideoFrameAcrossChunks() {
        val data = ByteArray(1_000_000) { (it * 31).toByte() }
        val msg = VideoFrame(3, 5, VideoFrame.KEYFRAME, 0, 1, data.size.toLong(), Bytes(data))
        val bytes = Codec.encode(msg)
        val dec = FrameDecoder.video()
        var got: Message? = null
        var pos = 0
        while (pos < bytes.size) {
            val n = minOf(4096, bytes.size - pos)
            dec.feed(bytes, pos, n)
            pos += n
            dec.next()?.let { got = it }
        }
        assertEquals(msg, got)
    }

    private fun videoPayload(index: Int, count: Int, size: Long, data: ByteArray): ByteArray {
        val b = ByteBuffer.allocate(24 + data.size).order(ByteOrder.LITTLE_ENDIAN)
        b.putInt(0).putLong(0).put(1).put(0).putShort(index.toShort()).putShort(count.toShort()).putShort(0)
        b.putInt(size.toInt()).put(data)
        return b.array()
    }

    @Test
    fun videoFragmentFieldsMustDescribeSingleFragment() {
        val d = ByteArray(4)
        assertTrue(decode(frame(MsgType.VIDEO_FRAME, videoPayload(0, 1, 4, d)), FrameDecoder.video()) is VideoFrame)
        for (p in listOf(videoPayload(1, 1, 4, d), videoPayload(0, 2, 4, d), videoPayload(0, 0, 4, d))) {
            val dec = FrameDecoder.video(); dec.feed(frame(MsgType.VIDEO_FRAME, p))
            expectError(ProtocolException.Kind.INVALID_VALUE, dec)
        }
        // fewer data bytes than frame_size is a protocol error
        val dec = FrameDecoder.video(); dec.feed(frame(MsgType.VIDEO_FRAME, videoPayload(0, 1, 5, d)))
        expectError(ProtocolException.Kind.SHORT_PAYLOAD, dec)
        val huge = FrameDecoder.video(); huge.feed(frame(MsgType.VIDEO_FRAME, videoPayload(0, 1, -1, d)))
        expectError(ProtocolException.Kind.SHORT_PAYLOAD, huge)
    }

    @Test
    fun videoTrailingBytesAfterDataAreIgnored() {
        val p = videoPayload(0, 1, 3, byteArrayOf(1, 2, 3, 9, 9))
        val f = decode(frame(MsgType.VIDEO_FRAME, p), FrameDecoder.video()) as VideoFrame
        assertEquals(Bytes(byteArrayOf(1, 2, 3)), f.data)
        assertEquals(3L, f.frameSize)
    }

    @Test
    fun encodeRefusesOversizePayload() {
        val ok = VideoFrame(0, 0, 0, 0, 1, (Limits.VIDEO_MAX_PAYLOAD - 24).toLong(), Bytes(ByteArray(Limits.VIDEO_MAX_PAYLOAD - 24)))
        assertEquals(Limits.VIDEO_MAX_PAYLOAD + 5, Codec.encode(ok).size)
        val big = ok.copy(frameSize = ok.frameSize + 1, data = Bytes(ByteArray(Limits.VIDEO_MAX_PAYLOAD - 23)))
        try { Codec.encode(big); fail() } catch (e: IllegalArgumentException) { }
    }

    @Test
    fun oversizeFailsInFeedWithoutBufferingPayload() {
        val dec = FrameDecoder.control()
        val chunk = ByteArray(10_000_000)
        chunk[0] = 0x7f; chunk[4] = 0x01 // length 16 MiB, far above the control limit
        dec.feed(chunk)
        expectError(ProtocolException.Kind.OVERSIZE, dec)
        assertTrue(dec.bufferedBytes() < 100)
    }

    @Test
    fun feedOffsetDefaultsLengthToRemainder() {
        val bytes = byteArrayOf(9, 9, 9) + Codec.encode(Ping(1, 2))
        val dec = FrameDecoder.control()
        dec.feed(bytes, 3)
        assertEquals(Ping(1, 2), dec.next())
    }

    @Test
    fun headerSplitAcrossFeedsIsValidated() {
        val dec = FrameDecoder.control()
        dec.feed(byteArrayOf(0x7f, 0x01, 0x00))
        dec.feed(byteArrayOf(0x01, 0x00))
        expectError(ProtocolException.Kind.OVERSIZE, dec)
    }

    @Test
    fun undrainedFeedHitsCapWithTypedError() {
        val dec = FrameDecoder.control()
        // a frame header announcing the maximum payload, then endless payload chunks, never drained
        dec.feed(byteArrayOf(0x7f, 0x00, 0x00, 0x01, 0x00))
        val chunk = ByteArray(FrameDecoder.READ_CHUNK)
        repeat(3) { dec.feed(chunk) } // still within the cap
        val big = FrameDecoder.control()
        val ping = Codec.encode(Ping(1, 1))
        repeat(100_000) { big.feed(ping) } // many small complete frames, never drained
        expectError(ProtocolException.Kind.BUFFER_OVERFLOW, big)
        assertTrue(big.bufferedBytes() <= big.bufferCap)
    }

    @Test
    fun encodeRefusesBadVideoFragmentFields() {
        val d = Bytes(ByteArray(4))
        for (bad in listOf(
            VideoFrame(0, 0, 0, 1, 1, 4, d), VideoFrame(0, 0, 0, 0, 2, 4, d),
            VideoFrame(0, 0, 0, 0, 1, 5, d), VideoFrame(0, 0, 0, 0, 1, 3, d),
        )) {
            try { Codec.encode(bad); fail() } catch (e: IllegalArgumentException) { }
        }
    }

    @Test
    fun statusDeterminingEnumsRejectUnknownValues() {
        // (message, payload offset of the enum byte, bad value)
        val cases = listOf(
            Triple(HelloAck(0, 0, 1, 1, ""), 2, 5),
            Triple(StreamConfig(1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1), 2, 3),
            Triple(StreamConfig(1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1), 2, 0),
            Triple(PointerAbs(0, 0, 0, 0, 0), 13, 2),
            Triple(Scroll(0, 0f, 0f, 0), 16, 5),
        )
        for ((msg, off, bad) in cases) {
            val p = Codec.encodePayload(msg)
            p[off] = bad.toByte()
            val dec = FrameDecoder.control(); dec.feed(frame(msg.type, p))
            expectError(ProtocolException.Kind.INVALID_VALUE, dec)
        }
        for (msg in listOf(
            HelloAck(0, 5, 0, 0, ""), StreamConfig(1, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1),
            PointerAbs(0, 0, 0, 0, 2), Scroll(0, 0f, 0f, 5),
        )) {
            try { Codec.encode(msg); fail() } catch (e: IllegalArgumentException) { }
        }
    }

    @Test
    fun informationalEnumsAcceptUnknownValues() {
        for (msg in listOf(
            Bye(200), ReleaseAll(200), KeyframeRequest(200), PenGesture(0, 99),
            StreamConfig(1, 1, 1, 1, 1, 1, 1, 1, 99, 99, 99, 7),
        )) {
            assertEquals(msg, decode(Codec.encode(msg)))
        }
    }
}
