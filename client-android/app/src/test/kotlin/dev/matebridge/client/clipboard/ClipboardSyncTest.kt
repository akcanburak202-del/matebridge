package dev.matebridge.client.clipboard

import dev.matebridge.client.clipboard.ClipboardSync.Decision
import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Clipboard
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardSyncTest {
    private fun sync(accepted: Boolean = true) = ClipboardSync().also { it.onSessionAccepted(accepted, 1000) }
    private fun text(s: String, seq: Long = 1) = Clipboard(seq, Clipboard.KIND_TEXT_UTF8, Bytes(s.toByteArray()))

    @Test fun sendsNewTextWithIncreasingSeq() {
        val s = sync()
        val a = s.onLocalClip("a", false, 2000) as Decision.Send
        val b = s.onLocalClip("b", false, 3000) as Decision.Send
        assertEquals(0L, a.msg.seq)
        assertEquals(1L, b.msg.seq)
        assertEquals("a", String(a.msg.data.value))
    }

    @Test fun notAcceptedOrDisabledIgnored() {
        assertEquals(Decision.Ignore, sync(accepted = false).onLocalClip("a", false, 0))
        val s = sync()
        s.enabled = false
        assertEquals(Decision.Ignore, s.onLocalClip("a", false, 0))
    }

    @Test fun preExistingClipboardIsNotSentButNewerIs() {
        val s = sync()
        assertEquals(Decision.Ignore, s.onLocalClip("old", false, 900))
        assertEquals(Decision.Ignore, s.onLocalClip("old", false, 1000))
        assertTrue(s.onLocalClip("new", false, 1001) is Decision.Send)
    }

    @Test fun listenerWithUnknownTimestampCounts() {
        assertTrue(sync().onLocalClip("x", false, 0) is Decision.Send)
    }

    @Test fun sameTextNotResent() {
        val s = sync()
        assertTrue(s.onLocalClip("a", false, 0) is Decision.Send)
        assertEquals(Decision.Ignore, s.onLocalClip("a", false, 0))
        assertTrue(s.onLocalClip("b", false, 0) is Decision.Send)
        assertTrue(s.onLocalClip("a", false, 0) is Decision.Send)
    }

    @Test fun remoteTextIsNotEchoed() {
        val s = sync()
        assertEquals("Merhaba ğ", s.onRemote(text("Merhaba ğ")))
        assertEquals(Decision.Ignore, s.onLocalClip("Merhaba ğ", false, 0))
        assertTrue(s.onLocalClip("other", false, 0) is Decision.Send)
    }

    @Test fun sensitiveAndEmptyNeverSent() {
        val s = sync()
        assertEquals(Decision.Ignore, s.onLocalClip("secret", true, 0))
        assertEquals(Decision.Ignore, s.onLocalClip(null, false, 0))
        assertEquals(Decision.Ignore, s.onLocalClip("", false, 0))
        assertTrue(s.onLocalClip("secret", false, 0) is Decision.Send)
    }

    @Test fun sizeLimitInBytesReportedOnce() {
        val s = sync()
        assertTrue(s.onLocalClip("a".repeat(60_000), false, 0) is Decision.Send)
        val big = "ğ".repeat(30_001) // 60 002 bytes
        assertEquals(Decision.TooLarge, s.onLocalClip(big, false, 0))
        assertEquals(Decision.Ignore, s.onLocalClip(big, false, 0))
    }

    @Test fun remoteInvalidInputsIgnored() {
        val s = sync()
        assertNull(s.onRemote(Clipboard(1, Clipboard.KIND_EMPTY, Bytes(ByteArray(0)))))
        assertNull(s.onRemote(Clipboard(1, 7, Bytes("x".toByteArray()))))
        assertNull(s.onRemote(Clipboard(1, Clipboard.KIND_TEXT_UTF8, Bytes(byteArrayOf(0xC3.toByte(), 0x28)))))
        assertNull(s.onRemote(Clipboard(1, Clipboard.KIND_TEXT_UTF8, Bytes(ByteArray(0)))))
        assertNull(s.onRemote(Clipboard(1, Clipboard.KIND_TEXT_UTF8, Bytes(ByteArray(60_001) { 'a'.code.toByte() }))))
        s.enabled = false
        assertNull(s.onRemote(text("a")))
    }

    @Test fun reconnectSetsNewBaseline() {
        val s = sync()
        s.onSessionAccepted(false, 1500)
        assertEquals(Decision.Ignore, s.onLocalClip("while away", false, 1600))
        s.onSessionAccepted(true, 2000)
        assertEquals(Decision.Ignore, s.onLocalClip("while away", false, 1600))
        assertTrue(s.onLocalClip("fresh", false, 2100) is Decision.Send)
    }

    @Test fun dedupStateIsResetPerSession() {
        val s = sync()
        assertTrue(s.onLocalClip("A", false, 0) is Decision.Send)
        s.onSessionAccepted(false, 1500)
        s.onSessionAccepted(true, 2000)
        assertTrue(s.onLocalClip("A", false, 2100) is Decision.Send)
        // echo state too: a text received in the old session does not suppress a fresh copy
        assertEquals("B", s.onRemote(text("B")))
        s.onSessionAccepted(false, 2200)
        s.onSessionAccepted(true, 3000)
        assertTrue(s.onLocalClip("B", false, 3100) is Decision.Send)
    }

    @Test fun remoteRespectsAcceptedAndGeneration() {
        val s = ClipboardSync()
        assertNull(s.onRemote(text("a"), 1)) // not accepted
        s.onSessionAccepted(true, 1000, gen = 2)
        assertNull(s.onRemote(text("a"), 1)) // stale generation
        assertEquals("a", s.onRemote(text("a"), 2))
        s.onSessionAccepted(false, 1500, gen = 2)
        assertNull(s.onRemote(text("a"), 2)) // session ended
    }

    @Test fun lastReasonExplainsDecision() { // T-063 diag
        val s = sync()
        s.onLocalClip("a", false, 500); assertEquals(ClipboardSync.Reason.BEFORE_BASELINE, s.lastReason)
        s.onLocalClip("a", true, 2000); assertEquals(ClipboardSync.Reason.SENSITIVE, s.lastReason)
        s.onLocalClip(null, false, 2000); assertEquals(ClipboardSync.Reason.EMPTY, s.lastReason)
        s.onLocalClip("a", false, 2000); assertEquals(ClipboardSync.Reason.SEND, s.lastReason)
        s.onLocalClip("a", false, 0); assertEquals(ClipboardSync.Reason.DUPLICATE, s.lastReason)
        s.enabled = false
        s.onLocalClip("b", false, 0); assertEquals(ClipboardSync.Reason.DISABLED, s.lastReason)
    }
}
