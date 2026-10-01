package dev.matebridge.client.clipboard

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Clipboard
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

/**
 * Pure clipboard-sharing logic (T-055, PROTOCOL.md 0x06); no Android dependencies. Main thread only.
 * Clipboard text is private: nothing here logs it, and callers must log only direction and byte length.
 */
class ClipboardSync {
    sealed interface Decision {
        data object Ignore : Decision
        /** Text exceeds [Clipboard.MAX_DATA_BYTES]: not sent; the caller shows a one-time hint. */
        data object TooLarge : Decision
        data class Send(val msg: Clipboard) : Decision
    }

    /** T-063 diag: why the last [onLocalClip] decided as it did. */
    enum class Reason { DISABLED, NOT_ACCEPTED, SENSITIVE, EMPTY, BEFORE_BASELINE, DUPLICATE, TOO_LARGE, SEND }

    /** T-063 diag */
    var lastReason: Reason = Reason.EMPTY
        private set
    var accepted = false // T-063 diag: read by the bridge log
        private set
    var baselineMs = 0L // T-063 diag: read by the bridge log
        private set
    private var lastText: String? = null
    private var seq = 0L
    private var sessionGen = 0

    /** Sharing on/off (Settings). */
    var enabled = true

    /**
     * Session accepted or not. On the transition to accepted, anything copied before now counts as "already there" and is
     * never sent ("the existing clipboard is not sent at start", PROTOCOL.md).
     */
    fun onSessionAccepted(accepted: Boolean, nowMs: Long, gen: Int = 0) {
        if (accepted && !this.accepted) {
            baselineMs = nowMs
            lastText = null // dedup/echo state is per session: a fresh copy after a reconnect must go out
            sessionGen = gen
        }
        this.accepted = accepted
    }

    /**
     * The local clipboard holds [text] (null when it is not text or unreadable), copied at [timestampMs] (0 = unknown, e.g. the
     * change listener fired, which is itself proof of a change). [sensitive]: flagged as a password/secret.
     */
    fun onLocalClip(text: String?, sensitive: Boolean, timestampMs: Long): Decision {
        if (!enabled) return ignore(Reason.DISABLED)
        if (!accepted) return ignore(Reason.NOT_ACCEPTED)
        if (sensitive) return ignore(Reason.SENSITIVE)
        if (text.isNullOrEmpty()) return ignore(Reason.EMPTY)
        if (timestampMs in 1..baselineMs) return ignore(Reason.BEFORE_BASELINE)
        if (text == lastText) return ignore(Reason.DUPLICATE) // echo of a received text, or already sent
        lastText = text
        if (timestampMs > baselineMs) baselineMs = timestampMs
        val bytes = text.toByteArray(Charsets.UTF_8)
        if (bytes.size > Clipboard.MAX_DATA_BYTES) { lastReason = Reason.TOO_LARGE; return Decision.TooLarge }
        lastReason = Reason.SEND
        return Decision.Send(Clipboard(seq++ and 0xFFFF_FFFFL, Clipboard.KIND_TEXT_UTF8, Bytes(bytes)))
    }

    private fun ignore(r: Reason): Decision { lastReason = r; return Decision.Ignore }

    /**
     * A CLIPBOARD arrived from the host. Returns the text to write to the local clipboard, or null to ignore it (sharing off,
     * EMPTY, unknown kind, empty/oversized data, invalid UTF-8). The returned text is remembered so the change it causes is not sent back.
     */
    fun onRemote(msg: Clipboard, gen: Int = sessionGen): String? {
        if (!enabled || !accepted || gen != sessionGen || msg.kind != Clipboard.KIND_TEXT_UTF8) return null
        if (msg.data.size == 0 || msg.data.size > Clipboard.MAX_DATA_BYTES) return null
        val text = decodeStrictUtf8(msg.data.value) ?: return null
        lastText = text
        return text
    }

    companion object {
        fun decodeStrictUtf8(b: ByteArray): String? = try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(b)).toString()
        } catch (e: CharacterCodingException) {
            null
        }
    }
}
