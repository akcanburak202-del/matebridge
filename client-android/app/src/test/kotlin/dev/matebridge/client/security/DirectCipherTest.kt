package dev.matebridge.client.security

import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.Ping
import dev.matebridge.client.protocol.VideoFrame
import dev.matebridge.client.protocol.Bytes
import java.security.Security
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** T-077: the fixed-SPI cipher must be byte-for-byte the provider's AES-GCM. */
class DirectCipherTest {
    private val key = SecretKeySpec(ByteArray(32) { (it * 5 + 3).toByte() }, "AES")

    private fun defaultProvider(): String = Records.newCipher(null).provider.name

    private fun seal(c: Cipher, counter: Long, aad: ByteArray, plain: ByteArray): ByteArray {
        c.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, Records.nonce(counter)))
        c.updateAAD(aad)
        return c.doFinal(plain)
    }

    private fun open(c: Cipher, counter: Long, aad: ByteArray, body: ByteArray): ByteArray? = try {
        c.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, Records.nonce(counter)))
        c.updateAAD(aad)
        c.doFinal(body)
    } catch (e: java.security.GeneralSecurityException) {
        null
    }

    @Test fun unknownProviderGivesNoDirectCipher() {
        assertNull(Records.newDirectCipher("NoSuchProvider-T077"))
    }

    @Test fun directCipherMatchesStandardCipherAcrossManyReinits() {
        val name = defaultProvider()
        val direct = Records.newDirectCipher(name)
        assumeTrue("runtime refuses a fixed-SPI Cipher for $name", direct != null)
        val std = Records.newCipher(name)
        for (counter in 0L until 50L) {
            val size = intArrayOf(0, 1, 17, 3000, 70_000)[(counter % 5).toInt()]
            val plain = ByteArray(size) { (it * 31 + counter).toByte() }
            val aad = Records.header(size + Records.MIN_LENGTH)
            val a = seal(direct!!, counter, aad, plain)
            val b = seal(std, counter, aad, plain)
            assertArrayEquals(b, a)
            assertArrayEquals(plain, open(direct, counter, aad, b))
            val bad = a.copyOf().also { it[0] = (it[0].toInt() xor 0x40).toByte() }
            assertNull(open(direct, counter, aad, bad))
        }
    }

    @Test fun selfTestPassesWhereTheDirectCipherExists() {
        val name = defaultProvider()
        assumeTrue(Records.newDirectCipher(name) != null)
        assertTrue(Records.directSelfTest(name))
    }

    @Test fun fastPathPicksTheFixedSpiCipherWhenTheSelfTestPasses() {
        val name = defaultProvider()
        assumeTrue(Records.directSelfTest(name))
        assertTrue(Records.newCipher().javaClass != Cipher::class.java)
    }

    @Test fun sealerAndOpenerRoundTripWhateverModeWasChosen() {
        val k = ByteArray(32) { 9 }
        val s = RecordSealer(k)
        val o = RecordOpener(k)
        val dec = RecordDecoder(1 shl 20, RecordOpener(k))
        for (n in intArrayOf(3000, 10, 432_000, 3000)) {
            val payload = ByteArray(n) { (it * 7).toByte() }
            val rec = s.seal(0x41, payload)
            val plain = o.open(rec.copyOf(4), rec.copyOfRange(4, rec.size))
            assertEquals(n + 1, plain.size)
            assertArrayEquals(payload, plain.copyOfRange(1, plain.size))
        }
        // RecordDecoder path (openPlain + one copy) yields the same messages.
        val s2 = RecordSealer(k)
        val frame = VideoFrame(5, 77, VideoFrame.KEYFRAME, 0, 1, 3000, Bytes(ByteArray(3000) { it.toByte() }))
        for (m in listOf(Ping(1, 2), frame, Ping(3, 4))) {
            val rec = s2.sealFrame(Codec.encode(m))
            var off = 0
            while (off < rec.size) { val len = minOf(1000, rec.size - off); dec.feed(rec, off, len); off += len }
            assertEquals(m, dec.next())
        }
        assertNull(dec.next())
    }

    @Test fun stampsAreWrittenOnlyWhenEnabledAndInOrder() {
        val k = ByteArray(32) { 4 }
        val rec = RecordSealer(k).seal(0x41, ByteArray(100))
        val st = OpenStamps.current()
        st.startNs = 0; st.initNs = 0; st.finalNs = 0
        RecordOpener(k).open(rec.copyOf(4), rec.copyOfRange(4, rec.size))
        assertEquals(0L, st.startNs)
        try {
            Records.stampOpens = true
            RecordOpener(k).open(rec.copyOf(4), rec.copyOfRange(4, rec.size))
        } finally {
            Records.stampOpens = false
        }
        assertTrue(st.startNs > 0)
        assertTrue(st.initNs >= st.startNs)
        assertTrue(st.finalNs >= st.initNs)
    }

    @Test fun benchReportsEveryProviderWithoutThrowing() {
        val lines = Records.bench()
        assertTrue(lines.isNotEmpty())
        assertTrue(lines.any { it.contains("3k_init_p50_us=") })
        assertTrue(Security.getProviders().isNotEmpty())
    }
}
