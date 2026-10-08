package dev.matebridge.client.bench

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.VideoFrame
import dev.matebridge.client.security.RecordDecoder
import dev.matebridge.client.security.RecordOpener
import dev.matebridge.client.security.RecordSealer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.lang.management.ManagementFactory

/**
 * T-292: JVM allocation and throughput of the encrypted video receive path of the direct-ByteBuffer path, in the style of
 * `RecordReceiveAllocTest`. The JVM runs SunJCE, not Android's Conscrypt, so this proves the bounds that hold for any
 * provider (no extra full-size heap array per record, same plaintext) and prints the numbers; the Conscrypt-specific gain
 * (internal buffer copy, per-init SPI construction) is measured on the device.
 */
class AeadDecryptBenchTest {
    private val key = ByteArray(32) { (it + 1).toByte() }

    private class Result(val allocPerRecord: Long, val mbPerS: Double)

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

    /** [count] records of [size] bytes through a decoder after a warm-up record. */
    private fun run(size: Int, count: Int): Result {
        val bean = ManagementFactory.getThreadMXBean() as? com.sun.management.ThreadMXBean
        assumeTrue("allocation counter unsupported", bean != null && bean.isThreadAllocatedMemorySupported)
        bean!!.isThreadAllocatedMemoryEnabled = true
        val sealer = RecordSealer(key)
        // Sizes vary a little around [size], as real frames do (Conscrypt reallocates its internal buffer on a size change).
        val frames = Array(count + 1) { frame(it.toLong(), size + (it % 5) * 37, it % 200 + 1) }
        val records = Array(count + 1) { sealer.sealFrame(Codec.encode(frames[it])) }
        val dec = RecordDecoder(1 shl 20, RecordOpener(key))
        feedAll(dec, records[0])
        dec.next() // warm-up
        val tid = Thread.currentThread().id
        val before = bean.getThreadAllocatedBytes(tid)
        val t0 = System.nanoTime()
        var kept: VideoFrame? = null
        for (i in 1..count) {
            feedAll(dec, records[i])
            kept = dec.next() as VideoFrame
        }
        val ns = System.nanoTime() - t0
        val perRecord = (bean.getThreadAllocatedBytes(tid) - before) / count
        assertEquals(frames[count], kept)
        val mbPerS = size.toDouble() * count / (ns / 1e9) / 1e6
        println("aead direct: ${size / 1000} KB records, alloc/record=$perRecord B, ${"%.0f".format(mbPerS)} MB/s")
        return Result(perRecord, mbPerS)
    }

    @Test fun allocatesAboutOneFullSizeArrayPerRecord() {
        val size = 100_000
        val r = run(size, 400)
        assertTrue("allocated ${r.allocPerRecord} B per ~$size B record", r.allocPerRecord < size + size / 2)
    }

    /** Small control-sized records (input events, pings) must stay cheap: the per-record SPI path is the hot one. */
    @Test fun smallRecordsStayCheap() {
        val r = run(1_000, 2000)
        assertTrue("${r.allocPerRecord} B per 1 KB record", r.allocPerRecord < 8_000)
    }
}
