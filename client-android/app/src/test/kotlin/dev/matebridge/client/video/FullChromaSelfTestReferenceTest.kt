package dev.matebridge.client.video

import java.security.MessageDigest
import org.junit.Test
import org.junit.Assert.assertEquals

class FullChromaSelfTestReferenceTest {
    private fun sha(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

    @Test fun referenceSizesMatchClip() {
        assertEquals(256 * 144, FullChromaSelfTestClip.referenceY.size)
        assertEquals(128 * 72, FullChromaSelfTestClip.referenceCb.size)
        assertEquals(128 * 72, FullChromaSelfTestClip.referenceCr.size)
    }

    @Test fun referenceIntegrity() {
        assertEquals(FullChromaSelfTestClip.REFERENCE_SHA256, sha(FullChromaSelfTestClip.referencePlanes))
    }

    /** Pins the clip: changing it requires regenerating the reference (and both hashes here). */
    @Test fun clipPinned() {
        assertEquals("78e799473f7798cd75b91d4781fd1273e203aae6fd35f62cb6f516b566c8ebb9", sha(FullChromaSelfTestClip.data))
    }
}
