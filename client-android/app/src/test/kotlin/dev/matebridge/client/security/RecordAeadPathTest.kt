package dev.matebridge.client.security

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.ProtocolException
import dev.matebridge.client.protocol.VideoFrame
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** T-292: every [AeadPath] opens the same records, rejects the same forgeries and keeps the same counter behaviour. */
class RecordAeadPathTest {
    private val key = ByteArray(32) { (it * 5 + 1).toByte() }

    private fun payload(n: Int, seed: Int) = ByteArray(n) { (it * seed + seed).toByte() }

    private fun split(rec: ByteArray) = rec.copyOf(4) to rec.copyOfRange(4, rec.size)

    @Test fun parseKnowsTheThreeIdsAndDefaultsToLegacy() {
        assertEquals(AeadPath.LEGACY, AeadPath.parse(null))
        assertEquals(AeadPath.LEGACY, AeadPath.parse("nonsense"))
        assertEquals(AeadPath.SPI, AeadPath.parse(" SPI "))
        assertEquals(AeadPath.DIRECT, AeadPath.parse("direct"))
        assertEquals(setOf("legacy", "spi", "direct"), AeadPath.IDS)
        assertEquals(AeadPath.LEGACY, Records.aeadPath) // the process default stays legacy until the A/B says otherwise
    }

    @Test fun openerUsesTheProcessDefaultUnlessGivenAPath() {
        assertEquals(AeadPath.LEGACY, RecordOpener(key).path)
        assertEquals(AeadPath.DIRECT, RecordOpener(key, 0, AeadPath.DIRECT).path)
        val saved = Records.aeadPath
        try {
            Records.aeadPath = AeadPath.SPI
            assertEquals(AeadPath.SPI, RecordOpener(key).path)
        } finally {
            Records.aeadPath = saved
        }
    }

    @Test fun reusablePathsKeepOneSpiLegacyDoesNot() {
        assertTrue(Records.isReusable(Records.newReusableCipher()))
        assertFalse(Records.isReusable(Records.newCipher()))
    }

    @Test fun allPathsOpenRecordsOfChangingSizes() {
        for (path in AeadPath.values()) {
            val sealer = RecordSealer(key)
            val opener = RecordOpener(key, 0, path)
            // Growing, shrinking, tiny, empty payload, and a size that repeats (buffer reuse).
            for ((i, n) in intArrayOf(0, 1, 10, 5000, 20, 150_000, 150_000, 40_000, 3, 70_000).withIndex()) {
                val p = payload(n, i % 7 + 1)
                val (h, b) = split(sealer.seal(0x41, p))
                val plain = opener.open(h, b)
                assertEquals("$path record $i", n + 1, plain.size)
                assertEquals(0x41, plain[0].toInt() and 0xFF)
                assertArrayEquals("$path record $i", p, plain.copyOfRange(1, plain.size))
            }
        }
    }

    @Test fun openAtReadsHeaderAndBodyInPlaceOnAllPaths() {
        for (path in AeadPath.values()) {
            val sealer = RecordSealer(key)
            val opener = RecordOpener(key, 0, path)
            val p = payload(777, 3)
            val rec = sealer.seal(0x33, p)
            val padded = ByteArray(10) + rec + ByteArray(10) // header and body at an offset, bytes on both sides
            val plain = opener.openAt(padded, 10, padded, 14, rec.size - 4)
            assertArrayEquals(byteArrayOf(0x33) + p, plain)
        }
    }

    @Test fun tamperedBodyOrHeaderOrWrongCounterFailsAuthOnAllPaths() {
        for (path in AeadPath.values()) {
            val sealer = RecordSealer(key)
            val (h, b) = split(sealer.seal(0x41, payload(500, 9)))
            fun expectAuth(what: String, f: () -> Unit) {
                try { f(); fail("$path $what") } catch (e: ProtocolException) { assertEquals("$path $what", ProtocolException.Kind.AUTH_FAILED, e.kind) }
            }
            expectAuth("body") { RecordOpener(key, 0, path).open(h, b.copyOf().also { it[100] = (it[100] + 1).toByte() }) }
            expectAuth("tag") { RecordOpener(key, 0, path).open(h, b.copyOf().also { it[b.size - 1] = (it[b.size - 1] + 1).toByte() }) }
            expectAuth("aad") { RecordOpener(key, 0, path).open(h.copyOf().also { it[0] = (it[0] + 1).toByte() }, b) }
            expectAuth("counter") { RecordOpener(key, 1, path).open(h, b) }
            expectAuth("short") { RecordOpener(key, 0, path).open(h, ByteArray(16)) }
            // The good record still opens with a fresh opener of the same path.
            assertEquals(501, RecordOpener(key, 0, path).open(h, b).size)
        }
    }

    @Test fun counterAdvancesOnlyOnSuccessAndReplayFails() {
        for (path in AeadPath.values()) {
            val sealer = RecordSealer(key)
            val opener = RecordOpener(key, 0, path)
            val r0 = split(sealer.seal(0x41, payload(100, 2)))
            val r1 = split(sealer.seal(0x41, payload(100, 4)))
            assertEquals(101, opener.open(r0.first, r0.second).size)
            try { opener.open(r0.first, r0.second); fail("$path replay") } catch (e: ProtocolException) {
                assertEquals(ProtocolException.Kind.AUTH_FAILED, e.kind)
            }
            // The failed replay did not consume a counter value: record 1 is next in line.
            assertEquals(101, opener.open(r1.first, r1.second).size)
        }
    }

    @Test fun startCounterIsHonouredOnAllPaths() {
        for (path in AeadPath.values()) {
            val sealer = RecordSealer(key, 41)
            val (h, b) = split(sealer.seal(0x41, payload(64, 5)))
            assertEquals(65, RecordOpener(key, 41, path).open(h, b).size)
        }
    }

    @Test fun decoderYieldsIdenticalFramesOnAllPaths() {
        val frames = listOf(
            VideoFrame(0, 0, VideoFrame.KEYFRAME, 0, 1, 150_000, Bytes(payload(150_000, 3))),
            VideoFrame(1, 1000, 0, 0, 1, 20_000, Bytes(payload(20_000, 11))),
            VideoFrame(2, 2000, 0, 0, 1, 150_000, Bytes(payload(150_000, 13))),
        )
        for (path in AeadPath.values()) {
            val sealer = RecordSealer(key)
            val dec = RecordDecoder(1 shl 20, RecordOpener(key, 0, path))
            val out = ArrayList<Message>()
            for (f in frames) {
                val rec = sealer.sealFrame(Codec.encode(f))
                var off = 0
                while (off < rec.size) {
                    val len = minOf(RecordDecoder.READ_CHUNK, rec.size - off)
                    dec.feed(rec, off, len)
                    off += len
                }
                out += dec.next()!! // each frame must keep its bytes although the scratch is reused
            }
            assertEquals("$path", frames, out)
        }
    }
}
