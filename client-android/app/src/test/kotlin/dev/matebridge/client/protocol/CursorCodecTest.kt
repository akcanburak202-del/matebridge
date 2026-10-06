package dev.matebridge.client.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** T-276 (decision 0036, PROTOCOL.md 0x0B-0x0D, HELLO bit13): the rules the golden vectors do not show. */
class CursorCodecTest {
    private fun le(vararg parts: Pair<Int, Long>): ByteArray {
        val b = ByteBuffer.allocate(parts.sumOf { it.first }).order(ByteOrder.LITTLE_ENDIAN)
        for ((n, v) in parts) when (n) {
            1 -> b.put(v.toByte())
            2 -> b.putShort(v.toShort())
            4 -> b.putInt(v.toInt())
            8 -> b.putLong(v)
        }
        return b.array()
    }

    private fun frame(type: Int, payload: ByteArray): ByteArray {
        val b = ByteBuffer.allocate(5 + payload.size).order(ByteOrder.LITTLE_ENDIAN)
        b.put(type.toByte()).putInt(payload.size).put(payload)
        return b.array()
    }

    private fun decode(bytes: ByteArray): Message? = FrameDecoder.control().also { it.feed(bytes) }.next()

    private fun expectError(kind: ProtocolException.Kind, bytes: ByteArray) {
        val dec = FrameDecoder.control()
        dec.feed(bytes)
        try {
            dec.next()
            fail("expected $kind")
        } catch (e: ProtocolException) {
            assertEquals(kind, e.kind)
        }
    }

    private fun shapePayload(id: Long = 7, format: Int = 1, dataLen: Int = 4, data: ByteArray = ByteArray(dataLen) { it.toByte() }) =
        le(4 to id, 2 to 144, 2 to 288, 2 to 64, 2 to 144, 1 to format.toLong(), 1 to 0, 2 to dataLen.toLong()) + data

    @Test fun capabilityIsBit13AndDistinct() {
        assertEquals(1 shl 13, Capabilities.LOCAL_CURSOR)
        val others = Capabilities.FILES_NET or Capabilities.FULL_CHROMA or Capabilities.FILES or Capabilities.SETTINGS_PANEL
        assertEquals(0, Capabilities.LOCAL_CURSOR and others)
    }

    @Test fun messageTypesMatchTheTable() {
        assertEquals(0x0B, CursorPrefs(true).type)
        assertEquals(0x0C, CursorShape(1, 1, 1, 0, 0, 1, Bytes(byteArrayOf(1))).type)
        assertEquals(0x0D, CursorState(1, 0, 0, true, 1, 0).type)
    }

    @Test fun prefsUnknownValueCountsAsOff() {
        assertEquals(CursorPrefs(true), decode(frame(MsgType.CURSOR_PREFS, byteArrayOf(1, 0, 0, 0))))
        assertEquals(CursorPrefs(false), decode(frame(MsgType.CURSOR_PREFS, byteArrayOf(2, 0, 0, 0))))
        assertEquals(CursorPrefs(false), decode(frame(MsgType.CURSOR_PREFS, byteArrayOf(255.toByte(), 9, 9, 9))))
    }

    @Test fun prefsShortIsRejectedLongerIsTolerated() {
        expectError(ProtocolException.Kind.SHORT_PAYLOAD, frame(MsgType.CURSOR_PREFS, byteArrayOf(1, 0, 0)))
        assertEquals(CursorPrefs(true), decode(frame(MsgType.CURSOR_PREFS, byteArrayOf(1, 0, 0, 0, 5, 5))))
    }

    @Test fun stateUnknownVisibleValueIsHidden() {
        val p = le(4 to 5, 2 to 10, 2 to 20, 1 to 7, 1 to 0, 4 to 99, 8 to 1234)
        val m = decode(frame(MsgType.CURSOR_STATE, p)) as CursorState
        assertFalse(m.visible)
        assertEquals(CursorState(5, 10, 20, false, 99, 1234), m)
    }

    @Test fun stateExtremesRoundTrip() {
        val s = CursorState(4294967295L, 65535, 0, true, 4294967295L, Long.MAX_VALUE)
        val enc = Codec.encode(s)
        assertEquals(s, decode(enc))
    }

    @Test fun stateShortIsRejectedLongerIsTolerated() {
        val p = le(4 to 5, 2 to 10, 2 to 20, 1 to 1, 1 to 0, 4 to 99, 8 to 1234)
        expectError(ProtocolException.Kind.SHORT_PAYLOAD, frame(MsgType.CURSOR_STATE, p.copyOf(p.size - 1)))
        assertTrue(decode(frame(MsgType.CURSOR_STATE, p + byteArrayOf(1, 2, 3))) is CursorState)
    }

    @Test fun shapeUnknownFormatIsKeptNotAnError() {
        val m = decode(frame(MsgType.CURSOR_SHAPE, shapePayload(format = 7))) as CursorShape
        assertEquals(7, m.format)
        assertEquals(4, m.data.size)
    }

    @Test fun shapeDataLenZeroOrOverTheLimitIsAProtocolError() {
        expectError(ProtocolException.Kind.INVALID_VALUE, frame(MsgType.CURSOR_SHAPE, shapePayload(dataLen = 0, data = ByteArray(0))))
        val big = shapePayload(dataLen = 61_441, data = ByteArray(61_441))
        expectError(ProtocolException.Kind.INVALID_VALUE, frame(MsgType.CURSOR_SHAPE, big))
    }

    @Test fun shapeAtTheLimitFitsTheControlFrame() {
        val m = CursorShape(9, 144, 288, 64, 144, 1, Bytes(ByteArray(CursorShape.MAX_DATA_BYTES)))
        val enc = Codec.encode(m) // 5 + 16 + 61 440 <= control limit
        assertEquals(m, decode(enc))
    }

    @Test fun shapeShorterThanItsDataLenIsRejectedLongerIsTolerated() {
        val short = shapePayload(dataLen = 10, data = ByteArray(3))
        expectError(ProtocolException.Kind.SHORT_PAYLOAD, frame(MsgType.CURSOR_SHAPE, short))
        val longer = shapePayload(dataLen = 4, data = ByteArray(4) { 9 }) + byteArrayOf(1, 2, 3)
        assertEquals(4, (decode(frame(MsgType.CURSOR_SHAPE, longer)) as CursorShape).data.size)
    }

    @Test fun shapeEncodeRejectsWhatTheWireForbids() {
        for (bad in listOf(
            CursorShape(0, 1, 1, 0, 0, 1, Bytes(byteArrayOf(1))), // id 0 is not used
            CursorShape(1, 1, 1, 0, 0, 1, Bytes(ByteArray(0))),
            CursorShape(1, 1, 1, 0, 0, 1, Bytes(ByteArray(CursorShape.MAX_DATA_BYTES + 1))),
        )) {
            try {
                Codec.encode(bad)
                fail("must not encode")
            } catch (e: IllegalArgumentException) {
            }
        }
    }

    @Test fun logTextNeverContainsTheImageOrPosition() {
        assertFalse(CursorShape(1, 144, 288, 64, 144, 1, Bytes(byteArrayOf(1, 2, 3))).toString().contains("[B"))
        assertFalse(CursorState(1, 111, 222, true, 1, 0).toString().contains("111"))
    }
}
