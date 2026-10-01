package dev.matebridge.client.security

import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class RecordOutputSizeTest {
    private val key = ByteArray(32) { 7 }

    private fun decryptCipher(): Cipher = Records.newCipher(null).also {
        it.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, Records.nonce(0)))
    }

    @Test
    fun outputIsAtLeastTheFullInputLengthIncludingTheTag() {
        val out = Records.ensureOutput(ByteArray(0), decryptCipher(), 1000)
        assertTrue(out.size >= 1000)
    }

    @Test
    fun largeEnoughBufferIsReusedAndSmallOneGrows() {
        val big = ByteArray(5000)
        assertSame(big, Records.ensureOutput(big, decryptCipher(), 1000))
        assertTrue(Records.ensureOutput(ByteArray(10), decryptCipher(), 1000).size >= 1000)
    }

    @Test
    fun openerReusesScratchAcrossRecordsOfDifferentSizes() {
        val s = RecordSealer(key)
        val o = RecordOpener(key)
        for (n in intArrayOf(10, 5000, 20, 5000)) {
            val rec = s.seal(0x41, ByteArray(n) { (it * 3).toByte() })
            val plain = o.open(rec.copyOf(4), rec.copyOfRange(4, rec.size))
            assertEquals(n + 1, plain.size)
        }
    }
}
