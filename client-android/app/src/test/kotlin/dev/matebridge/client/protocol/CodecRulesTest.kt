package dev.matebridge.client.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
            MsgType.VIDEO_FRAME, MsgType.STREAM_PREFS, MsgType.DISPLAY_RATE, MsgType.SETTINGS_OPEN,
        )) {
            val dec = FrameDecoder.control()
            dec.feed(frame(type, ByteArray(0)))
            expectError(ProtocolException.Kind.SHORT_PAYLOAD, dec)
        }
    }

    @Test
    fun streamPrefsBitrateFieldIsU32AndTheOldShortFormIsRejected() {
        val prefs = StreamPrefs(144, 800, 150_000)
        val p = Codec.encodePayload(prefs)
        assertEquals(8, p.size)
        // Extra bytes after the (here 0x0) optional groups are ignored; 9-11 and 13 bytes are short (see below).
        assertEquals(prefs, decode(frame(MsgType.STREAM_PREFS, p + byteArrayOf(0, 0, 0, 0, 0, 0, 9, 9))))
        // Full u32 range survives the round trip.
        val max = byteArrayOf(0x78, 0, 0xe8.toByte(), 3, -1, -1, -1, -1)
        assertEquals(StreamPrefs(120, 1000, 0xFFFFFFFFL), decode(frame(MsgType.STREAM_PREFS, max)))
        // fps + scale without the bitrate field is a short payload.
        val dec = FrameDecoder.control()
        dec.feed(frame(MsgType.STREAM_PREFS, byteArrayOf(0x78, 0, 0xe8.toByte(), 3)))
        expectError(ProtocolException.Kind.SHORT_PAYLOAD, dec)
        // The default sends 0 = host default (behaviour unchanged until T-105).
        assertEquals(0L, StreamPrefs(60, 1000).bitrateKbps)
    }

    @Test
    fun streamPrefsOptionalDisplayGroupIsAllOrNothing() {
        // Decision 0029 / PROTOCOL.md 2: 8 bytes -> 0x0, >= 12 -> values (extra ignored), 9-11 -> short payload.
        val base = Codec.encodePayload(StreamPrefs(120, 660, 60_000))
        assertEquals(8, base.size)
        assertEquals(StreamPrefs(120, 660, 60_000, 0, 0), decode(frame(MsgType.STREAM_PREFS, base)))
        val game = StreamPrefs(120, 660, 60_000, 1848, 1214)
        val p = Codec.encodePayload(game)
        assertEquals(12, p.size)
        assertEquals(game, decode(frame(MsgType.STREAM_PREFS, p)))
        // 15 bytes: dynamic_range 0 (SDR), chroma 7 (unknown, decoded as is; the host treats it as normal), excess ignored.
        assertEquals(game.copy(chroma = 7), decode(frame(MsgType.STREAM_PREFS, p + byteArrayOf(0, 7, 7))))
        // Either non-zero field writes the whole group.
        assertEquals(12, Codec.encodePayload(StreamPrefs(120, 660, 0, 1848, 0)).size)
        assertEquals(12, Codec.encodePayload(StreamPrefs(120, 660, 0, 0, 1214)).size)
        for (n in 9..11) {
            val dec = FrameDecoder.control()
            dec.feed(frame(MsgType.STREAM_PREFS, p.copyOf(n)))
            expectError(ProtocolException.Kind.SHORT_PAYLOAD, dec)
        }
        assertEquals(0, StreamPrefs(60, 1000).displayWidthPx)
        assertEquals(0, StreamPrefs(60, 1000).displayHeightPx)
    }

    @Test
    fun streamPrefsDynamicRangeGroupFollowsTheWriteRule() {
        // Decision 0032 / PROTOCOL.md 0x05: the group is written only when non-zero; it forces the display group (0x0 ok).
        assertEquals(8, Codec.encodePayload(StreamPrefs(120, 660, 0, dynamicRange = StreamPrefs.DYNAMIC_RANGE_SDR)).size)
        assertEquals(12, Codec.encodePayload(StreamPrefs(120, 660, 0, 1848, 1214, StreamPrefs.DYNAMIC_RANGE_SDR)).size)
        val native = StreamPrefs(120, 1000, 60_000, dynamicRange = StreamPrefs.DYNAMIC_RANGE_HDR10)
        val p = Codec.encodePayload(native)
        assertEquals(14, p.size)
        assertArrayEquals(byteArrayOf(0, 0, 0, 0, 1, 0), p.copyOfRange(8, 14))
        assertEquals(native, decode(frame(MsgType.STREAM_PREFS, p)))
        // Longer payloads: the excess is ignored.
        assertEquals(native, decode(frame(MsgType.STREAM_PREFS, p + byteArrayOf(5, 5))))
        // Unknown values decode as is (the host treats them as SDR / normal).
        val odd = p.copyOf().also { it[12] = 7; it[13] = 3 }
        assertEquals(native.copy(dynamicRange = 7, chroma = 3), decode(frame(MsgType.STREAM_PREFS, odd)))
        // 12 bytes = SDR; 13 bytes = short payload.
        assertEquals(native.copy(dynamicRange = 0), decode(frame(MsgType.STREAM_PREFS, p.copyOf(12))))
        val dec = FrameDecoder.control()
        dec.feed(frame(MsgType.STREAM_PREFS, p.copyOf(13)))
        expectError(ProtocolException.Kind.SHORT_PAYLOAD, dec)
        assertEquals(StreamPrefs.DYNAMIC_RANGE_SDR, StreamPrefs(60, 1000).dynamicRange)
    }

    @Test
    fun streamPrefsChromaAloneWritesTheGroup() {
        // Decision 0033: chroma = 1 alone writes the display group as 0x0 and the group; both zero keeps 8 / 12 bytes.
        val sharp = StreamPrefs(60, 1000, 0, chroma = StreamPrefs.CHROMA_SHARP)
        val p = Codec.encodePayload(sharp)
        assertEquals(14, p.size)
        assertArrayEquals(byteArrayOf(0, 0, 0, 0, 0, 1), p.copyOfRange(8, 14))
        assertEquals(sharp, decode(frame(MsgType.STREAM_PREFS, p)))
        assertEquals(8, Codec.encodePayload(StreamPrefs(60, 1000, 0)).size)
        assertEquals(12, Codec.encodePayload(StreamPrefs(120, 660, 0, 1848, 1214)).size)
        assertEquals(StreamPrefs.CHROMA_NORMAL, StreamPrefs(60, 1000).chroma)
    }

    @Test
    fun streamConfigHdr10IsReadFromTheTransferCode() {
        assertTrue(StreamConfig(1, 2, 1, 1, 1, 1, 60, 1, 9, 16, 9, 0).isHdr10)
        assertFalse(StreamConfig(1, 2, 1, 1, 1, 1, 60, 1, 1, 13, 1, 1).isHdr10)
        // Only the transfer decides (PROTOCOL.md 0x03).
        assertFalse(StreamConfig(1, 2, 1, 1, 1, 1, 60, 1, 9, 1, 9, 0).isHdr10)
    }

    @Test
    fun settingsOpenReservedIsIgnoredAndShortIsRejected() {
        assertEquals(0x08, MsgType.SETTINGS_OPEN)
        assertEquals(
            listOf<Byte>(0x08, 4, 0, 0, 0, 0, 0, 0, 0),
            Codec.encode(SettingsOpen).toList(),
        )
        assertEquals(SettingsOpen, decode(frame(MsgType.SETTINGS_OPEN, byteArrayOf(1, 2, 3, 4, 5))))
        val dec = FrameDecoder.control()
        dec.feed(frame(MsgType.SETTINGS_OPEN, byteArrayOf(0, 0, 0)))
        expectError(ProtocolException.Kind.SHORT_PAYLOAD, dec)
    }

    @Test
    fun settingsPanelCapabilityIsBit9() {
        assertEquals(0x200, Capabilities.SETTINGS_PANEL)
        assertEquals(0, Capabilities.SETTINGS_PANEL and 0x1ff)
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
        val head = p.copyOf(10) // version, status, reserved, session_id, video_port
        val tail = p.copyOfRange(p.size - 82, p.size) // key_mode, host_id, host_nonce, host_eph_pub
        val bad = head + byteArrayOf(65) + ByteArray(65) { 'a'.code.toByte() } + tail
        val dec = FrameDecoder.control(); dec.feed(frame(MsgType.HELLO_ACK, bad))
        expectError(ProtocolException.Kind.INVALID_STRING, dec)
        // invalid UTF-8
        val bad2 = head + byteArrayOf(1, 0xFF.toByte()) + tail
        val dec2 = FrameDecoder.control(); dec2.feed(frame(MsgType.HELLO_ACK, bad2))
        expectError(ProtocolException.Kind.INVALID_STRING, dec2)
        // length byte beyond payload
        val bad3 = head + byteArrayOf(10, 'a'.code.toByte())
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
        val chunk = ByteArray(FrameDecoder.READ_CHUNK)
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
    fun pinchRejectsUnknownPhaseAndSource() {
        val ok = Pinch(0, 0f, 0, 0, Pinch.BEGAN, Pinch.SOURCE_TOUCH)
        for ((off, bad) in listOf(16 to 0, 16 to 5, 17 to 2)) { // phase 0 is invalid too
            val p = Codec.encodePayload(ok)
            p[off] = bad.toByte()
            val dec = FrameDecoder.control(); dec.feed(frame(ok.type, p))
            expectError(ProtocolException.Kind.INVALID_VALUE, dec)
        }
        for (bad in listOf(Pinch(0, 0f, 0, 0, 0, 0), Pinch(0, 0f, 0, 0, 5, 0), Pinch(0, 0f, 0, 0, 1, 2))) {
            try { Codec.encode(bad); fail() } catch (e: IllegalArgumentException) { }
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

    @Test
    fun fullReadChunkOfSmallFramesDrainsCompletely() {
        val ping = Codec.encode(Ping(1, 1)) // 17 bytes
        val n = FrameDecoder.READ_CHUNK / ping.size
        val chunk = ByteArray(FrameDecoder.READ_CHUNK)
        for (i in 0 until n) System.arraycopy(ping, 0, chunk, i * ping.size, ping.size)
        val dec = FrameDecoder.control()
        repeat(5) { // repeated feed/drain cycles: the cap counts only bytes not yet returned by next()
            dec.feed(chunk, 0, n * ping.size)
            assertEquals(n, dec.drain().size)
        }
    }

    @Test
    fun feedLargerThanReadChunkIsCallerBug() {
        val dec = FrameDecoder.control()
        try { dec.feed(ByteArray(FrameDecoder.READ_CHUNK + 1)); fail() } catch (e: IllegalArgumentException) { }
    }
}
