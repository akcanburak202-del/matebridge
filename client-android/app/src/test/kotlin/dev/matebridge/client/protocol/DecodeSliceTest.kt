package dev.matebridge.client.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test

/** T-285: `Codec.decodePayload(type, buf, offset, length)` reads a slice in place and equals the copying overload. */
class DecodeSliceTest {
    private fun payloadOf(m: Message): ByteArray = Codec.encode(m).let { it.copyOfRange(5, it.size) }

    private fun embedded(payload: ByteArray, before: Int, after: Int): ByteArray =
        ByteArray(before) { 0x55 } + payload + ByteArray(after) { 0x77 }

    @Test fun sliceDecodesLikeTheWholeArray() {
        val frame = VideoFrame(9, 1234, VideoFrame.KEYFRAME, 0, 1, 300, Bytes(ByteArray(300) { it.toByte() }))
        val messages = listOf<Message>(Ping(1, 2), frame, Key(5, 30, 4, Key.DOWN, 0), Bye(1))
        for (m in messages) {
            val p = payloadOf(m)
            val buf = embedded(p, 1, 40)
            assertEquals(m, Codec.decodePayload(m.type, buf, 1, p.size))
            assertEquals(m, Codec.decodePayload(m.type, p))
        }
    }

    @Test fun bytesBehindTheSliceAreNotReadAsPayload() {
        val p = payloadOf(Ping(1, 2))
        val buf = embedded(p.copyOf(5), 3, 64) // 5 bytes of a 12-byte PING, then unrelated bytes
        try { Codec.decodePayload(MsgType.PING, buf, 3, 5); fail() } catch (e: ProtocolException) {
            assertEquals(ProtocolException.Kind.SHORT_PAYLOAD, e.kind)
        }
        val frame = payloadOf(VideoFrame(1, 2, 0, 0, 1, 100, Bytes(ByteArray(100))))
        val buf2 = embedded(frame.copyOf(frame.size - 1), 7, 200) // frame_size says 100, one byte missing
        try { Codec.decodePayload(MsgType.VIDEO_FRAME, buf2, 7, frame.size - 1); fail() } catch (e: ProtocolException) {
            assertEquals(ProtocolException.Kind.SHORT_PAYLOAD, e.kind)
        }
    }

    @Test fun unknownTypeStillReturnsNullAndBadRangeIsRejected() {
        assertNull(Codec.decodePayload(0x7E, ByteArray(10), 2, 4))
        for ((o, l) in listOf(-1 to 2, 2 to -1, 8 to 4)) {
            try { Codec.decodePayload(MsgType.PING, ByteArray(10), o, l); fail() } catch (_: IllegalArgumentException) {}
        }
    }
}
