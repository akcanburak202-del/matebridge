package dev.matebridge.client.security

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.Ping
import dev.matebridge.client.protocol.ProtocolException
import dev.matebridge.client.protocol.VideoFrame
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.lang.management.ManagementFactory

/** T-285: the encrypted video receive path allocates one full-size array per record (VideoFrame.data), not two. */
class RecordReceiveAllocTest {
    private val key = ByteArray(32) { (it + 1).toByte() }

    private fun frame(seq: Long, size: Int, fill: Int) =
        VideoFrame(seq, seq * 1000, if (seq == 0L) VideoFrame.KEYFRAME else 0, 0, 1, size.toLong(), Bytes(ByteArray(size) { (it * fill + fill).toByte() }))

    private fun feedAll(dec: RecordDecoder, rec: ByteArray) {
        var off = 0
        while (off < rec.size) {
            val len = minOf(RecordDecoder.READ_CHUNK, rec.size - off)
            dec.feed(rec, off, len)
            off += len
        }
    }

    /** The decrypt scratch is reused by the next record, so an earlier frame must keep its bytes. */
    @Test fun earlierFrameSurvivesTheNextOpen() {
        val sealer = RecordSealer(key)
        val dec = RecordDecoder(1 shl 20, RecordOpener(key))
        val a = frame(0, 150_000, 3)
        val b = frame(1, 150_000, 11) // same size: lands in exactly the same scratch bytes
        val c = frame(2, 40_000, 5)
        feedAll(dec, sealer.sealFrame(Codec.encode(a)))
        val gotA = dec.next() as VideoFrame
        feedAll(dec, sealer.sealFrame(Codec.encode(b)))
        val gotB = dec.next() as VideoFrame
        feedAll(dec, sealer.sealFrame(Codec.encode(c)))
        val gotC = dec.next() as VideoFrame
        assertArrayEquals(a.data.value, gotA.data.value)
        assertArrayEquals(b.data.value, gotB.data.value)
        assertArrayEquals(c.data.value, gotC.data.value)
        assertEquals(a, gotA)
        assertEquals(b, gotB)
        assertEquals(c, gotC)
    }

    /** Both records are drained afterwards: the first message must not alias the scratch of the second. */
    @Test fun twoRecordsDrainedTogetherStayIntact() {
        val sealer = RecordSealer(key)
        val dec = RecordDecoder(1 shl 20, RecordOpener(key))
        val a = frame(0, 5000, 3)
        val b = frame(1, 5000, 9)
        feedAll(dec, sealer.sealFrame(Codec.encode(a)))
        feedAll(dec, sealer.sealFrame(Codec.encode(b)))
        val out: List<Message> = dec.drain()
        assertEquals(listOf<Message>(a, b), out)
    }

    @Test fun smallControlMessagesAndErrorPathsBehaveAsBefore() {
        val sealer = RecordSealer(key)
        val dec = RecordDecoder(1 shl 20, RecordOpener(key))
        feedAll(dec, sealer.sealFrame(Codec.encode(Ping(7, 9))))
        assertEquals(Ping(7, 9), dec.next())
        // Unknown type is skipped and counted.
        feedAll(dec, sealer.seal(0x7E, ByteArray(10)))
        feedAll(dec, sealer.sealFrame(Codec.encode(Ping(8, 10))))
        assertEquals(Ping(8, 10), dec.next())
        assertEquals(1, dec.skippedFrames)
        // Short payload: PING needs 12 bytes.
        feedAll(dec, sealer.seal(0x20, ByteArray(5)))
        try { dec.next(); fail() } catch (e: ProtocolException) { assertEquals(ProtocolException.Kind.SHORT_PAYLOAD, e.kind) }
    }

    @Test fun videoFrameShorterThanFrameSizeStillThrowsEvenWithStaleScratchBytes() {
        val sealer = RecordSealer(key)
        val dec = RecordDecoder(1 shl 20, RecordOpener(key))
        // A big record first, so the scratch holds plenty of stale bytes behind the next, shorter record.
        feedAll(dec, sealer.sealFrame(Codec.encode(frame(0, 50_000, 3))))
        dec.next()
        val good = Codec.encode(frame(1, 100, 4)) // 5-byte header + payload
        val payload = good.copyOfRange(5, good.size - 10) // frame_size says 100, only 90 follow
        feedAll(dec, sealer.seal(good[0].toInt() and 0xFF, payload))
        try { dec.next(); fail() } catch (e: ProtocolException) { assertEquals(ProtocolException.Kind.SHORT_PAYLOAD, e.kind) }
    }

    /**
     * 1 000 records of 20 KB (a warm-up record grows the buffers first). Before T-285 each record allocated two
     * full-size arrays on this path (copyOfRange, Reader.bytes; measured 2.06x frame size); now one (1.06x).
     * Allocation is read from the JVM's per-thread counter, so the bound is on bytes: 1.5 frame sizes per record.
     */
    @Test fun oneFullSizeAllocationPerVideoRecord() {
        val bean = ManagementFactory.getThreadMXBean() as? com.sun.management.ThreadMXBean
        assumeTrue("allocation counter unsupported", bean != null && bean.isThreadAllocatedMemorySupported)
        bean!!.isThreadAllocatedMemoryEnabled = true
        val size = 20_000
        val count = 1000
        val sealer = RecordSealer(key)
        val records = Array(count + 1) { sealer.sealFrame(Codec.encode(frame(it.toLong(), size, it % 200 + 1))) }
        val dec = RecordDecoder(1 shl 20, RecordOpener(key))
        feedAll(dec, records[0])
        dec.next() // warm-up
        val tid = Thread.currentThread().id
        val before = bean.getThreadAllocatedBytes(tid)
        var kept: Message? = null
        for (i in 1..count) {
            feedAll(dec, records[i])
            kept = dec.next()
        }
        val perRecord = (bean.getThreadAllocatedBytes(tid) - before) / count
        assertTrue(kept is VideoFrame)
        println("alloc per 20 KB record: $perRecord bytes")
        assertTrue("allocated $perRecord bytes per $size-byte record", perRecord < size + size / 2)
    }
}
