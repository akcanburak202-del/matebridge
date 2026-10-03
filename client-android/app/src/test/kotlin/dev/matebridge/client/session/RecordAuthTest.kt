package dev.matebridge.client.session

import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.Limits
import dev.matebridge.client.protocol.Ping
import dev.matebridge.client.protocol.ProtocolException
import dev.matebridge.client.security.RecordDecoder
import dev.matebridge.client.security.RecordOpener
import dev.matebridge.client.security.RecordSealer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** T-156 review: the control reader's authentication hook sits at the AEAD boundary, not at message delivery. */
class RecordAuthTest {
    private val key = ByteArray(32) { 0x11 }
    private val wrongKey = ByteArray(32) { 0x22 }
    private val unknownType = 0x7F

    private fun decoder() = RecordDecoder(Limits.CONTROL_MAX_PAYLOAD, RecordOpener(key))
    private fun ping() = Codec.encode(Ping(1, 2))

    @Test fun anAuthenticatedUnknownRecordFollowedByACorruptOneInOneReadStillCounts() {
        val unknown = RecordSealer(key).seal(unknownType, ByteArray(3))
        val corrupt = RecordSealer(wrongKey, 1).sealFrame(ping()) // the right counter, the wrong key
        val dec = decoder()
        dec.feed(unknown + corrupt)
        var hooked = 0
        try {
            RecordAuth.next(dec) { hooked++ }
            fail("the corrupt record must throw")
        } catch (e: ProtocolException) {
            assertEquals(ProtocolException.Kind.AUTH_FAILED, e.kind)
        }
        assertEquals(1, hooked)
    }

    @Test fun aCorruptFirstRecordNeverCounts() {
        val dec = decoder()
        dec.feed(RecordSealer(wrongKey).sealFrame(ping()))
        var hooked = false
        try {
            RecordAuth.next(dec) { hooked = true }
            fail()
        } catch (e: ProtocolException) {
            assertEquals(ProtocolException.Kind.AUTH_FAILED, e.kind)
        }
        assertFalse(hooked)
    }

    @Test fun aReturnedMessageOrASkippedRecordCountsAndAPartialOneDoesNot() {
        val dec = decoder()
        val rec = RecordSealer(key).sealFrame(ping())
        dec.feed(rec.copyOf(rec.size - 1))
        var hooked = 0
        assertNull(RecordAuth.next(dec) { hooked++ }) // incomplete: nothing opened yet
        assertEquals(0, hooked)
        dec.feed(rec, rec.size - 1, 1)
        assertEquals(Ping(1, 2), RecordAuth.next(dec) { hooked++ })
        assertEquals(1, hooked)
        // an unknown type alone: next() returns null after opening and skipping it
        val dec2 = decoder()
        dec2.feed(RecordSealer(key).seal(unknownType, ByteArray(1)))
        var hooked2 = false
        assertNull(RecordAuth.next(dec2) { hooked2 = true })
        assertTrue(hooked2)
    }
}
