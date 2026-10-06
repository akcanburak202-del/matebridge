package dev.matebridge.client.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** T-269 (decision 0035, PROTOCOL.md 0x0A, 0x50-0x52, HELLO bit12): the rules the golden vectors do not show. */
class FilesNetCodecTest {
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

    private val nonce = Bytes(ByteArray(16) { it.toByte() })

    @Test fun capabilityIsBit12AndDistinctFromTheOthers() {
        assertEquals(1 shl 12, Capabilities.FILES_NET)
        assertEquals(0, Capabilities.FILES_NET and (Capabilities.FULL_CHROMA or Capabilities.FILES or Capabilities.SETTINGS_PANEL))
    }

    @Test fun messageTypesMatchTheTable() {
        assertEquals(0x0A, FilesNet(0, 0, 0, 0).type)
        assertEquals(0x50, FilesHello(1, 1, nonce).type)
        assertEquals(0x51, FilesHelloAck(0, nonce).type)
        assertEquals(0x52, FilesData(Bytes(byteArrayOf(1))).type)
    }

    @Test fun filesNetUnknownStateDecodesAndIsNotOpen() {
        val m = decode(frame(MsgType.FILES_NET, byteArrayOf(9, 0x9b.toByte(), 0xb7.toByte(), 2, 12))) as FilesNet
        assertEquals(9, m.state)
        assertFalse(m.isOpen)
        assertTrue(FilesNet(FilesNet.STATE_OPEN, 1, 1, 1).isOpen)
    }

    @Test fun filesNetShortIsRejectedLongerIsTolerated() {
        expectError(ProtocolException.Kind.SHORT_PAYLOAD, frame(MsgType.FILES_NET, byteArrayOf(1, 0, 0, 2)))
        val m = decode(frame(MsgType.FILES_NET, byteArrayOf(1, 0x9b.toByte(), 0xb7.toByte(), 2, 12, 99, 99))) as FilesNet
        assertEquals(FilesNet(FilesNet.STATE_OPEN, 47003, 2, 12), m)
    }

    @Test fun filesHelloShortAndWrongNonceSizeAreRejected() {
        expectError(ProtocolException.Kind.SHORT_PAYLOAD, frame(MsgType.FILES_HELLO, ByteArray(21)))
        try { Codec.encode(FilesHello(1, 1, Bytes(ByteArray(15)))); fail() } catch (e: IllegalArgumentException) { }
        try { Codec.encode(FilesHelloAck(0, Bytes(ByteArray(17)))); fail() } catch (e: IllegalArgumentException) { }
    }

    @Test fun filesHelloAckUnknownStatusIsKeptAndCountsAsRejected() {
        val p = ByteArray(17).also { it[0] = 7 }
        val m = decode(frame(MsgType.FILES_HELLO_ACK, p)) as FilesHelloAck
        assertEquals(7, m.status)
        assertFalse(m.ok)
        assertTrue(FilesHelloAck(FilesHelloAck.OK, nonce).ok)
        expectError(ProtocolException.Kind.SHORT_PAYLOAD, frame(MsgType.FILES_HELLO_ACK, ByteArray(16)))
    }

    @Test fun filesDataSizeBounds() {
        // empty is a protocol error on both sides
        expectError(ProtocolException.Kind.INVALID_VALUE, frame(MsgType.FILES_DATA, byteArrayOf(0, 0)))
        try { Codec.encode(FilesData(Bytes(ByteArray(0)))); fail() } catch (e: IllegalArgumentException) { }
        // the largest legal record: size field 65534, payload 65536 = the control payload limit
        val max = FilesData(Bytes(ByteArray(FilesData.MAX_DATA_BYTES) { (it and 0x7F).toByte() }))
        assertEquals(65_534, FilesData.MAX_DATA_BYTES)
        val wire = Codec.encode(max)
        assertEquals(5 + 65_536, wire.size)
        val dec = FrameDecoder.control()
        dec.feed(wire, 0, 40_000) // one read chunk is at most 64 KiB; the frame arrives in two
        assertNull(dec.next())
        dec.feed(wire, 40_000, wire.size - 40_000)
        assertEquals(max, dec.next())
        try { Codec.encode(FilesData(Bytes(ByteArray(FilesData.MAX_DATA_BYTES + 1)))); fail() } catch (e: IllegalArgumentException) { }
    }

    @Test fun filesDataShorterThanItsSizeIsShortAndTrailingBytesAreIgnored() {
        expectError(ProtocolException.Kind.SHORT_PAYLOAD, frame(MsgType.FILES_DATA, byteArrayOf(5, 0, 1, 2, 3)))
        val m = decode(frame(MsgType.FILES_DATA, byteArrayOf(2, 0, 7, 8, 9, 9))) as FilesData
        assertEquals(Bytes(byteArrayOf(7, 8)), m.data)
    }

    @Test fun filesDataToStringHidesTheBytes() {
        // Bytes.toString prints the size only: a log line of a message never carries HTTP content
        assertFalse(FilesData(Bytes("Authorization: Digest".toByteArray())).toString().contains("Digest"))
    }

    @Test fun filesInfoStandbyHasNoPortAndNoToken() {
        assertEquals(FilesInfo.STATE_STANDBY, FilesInfo.STANDBY.state)
        assertEquals(0, FilesInfo.STANDBY.port)
        assertEquals("", FilesInfo.STANDBY.token)
        assertFalse(FilesInfo.STANDBY.ready)
        assertNull(decode(frame(0x7E, ByteArray(0)))) // an unknown type is still skipped
    }
}
