package dev.matebridge.client.session

/** What the screen shows. Produced by [SessionMachine] (and "Searching" by the UI layer). */
sealed interface SessionUi {
    data object Idle : SessionUi
    data object Searching : SessionUi
    data class Connecting(val endpoint: Endpoint) : SessionUi
    /**
     * Waiting for the Mac user. [code] is the 6-digit pairing code to compare with the Mac's (null when not pairing);
     * [rePairing] means this tablet had a key for the host but the Mac forgot it. The code must never be logged.
     * [needsLocalConfirm] (T-150): the tablet user must still confirm that the codes match ("Kodlar aynı — Güven" /
     * "İptal"); until then nothing but PING goes out, also when the Mac already accepted. Never [Connected] before it.
     * [promptGen]: pass it to `confirmTrust`/`cancelTrust` so a tap applies to exactly this code (-1: no prompt).
     */
    data class AwaitingApproval(
        val hostName: String,
        val code: String? = null,
        val rePairing: Boolean = false,
        val needsLocalConfirm: Boolean = false,
        val promptGen: Int = -1,
    ) : SessionUi

    /**
     * T-150: an endpoint the user did not pick answered with PAIRING ("Yeni Mac bulundu" / [rePair]: "Mac yeniden
     * eşleşmek istiyor"). The connection was closed before anything was stored; no automatic retry. Pairing starts only
     * from a user action. [hostName] comes from the answerer: display only, never logged. [hostTag] (T-207): the host_id
     * the answer claimed (unauthenticated), so the UI can drop its "asked" mark once that Mac is trusted.
     */
    data class PairingNeedsUser(val hostName: String, val rePair: Boolean, val hostTag: HostTag? = null) : SessionUi

    /**
     * T-150: an unresolved pairing was found and no connection was opened (automatic connects wait for the user).
     * [confirmed] false: a pending key; [code] is its stored pairing code, to confirm ("Kodlar aynı — Güven") or cancel.
     * [confirmed] true: the key was confirmed but the Mac was not seen to accept it yet; [code] is null ("Bağlan").
     * [promptGen]: pass it to `confirmTrust`/`cancelTrust` (see [AwaitingApproval.promptGen]).
     */
    data class StoredTrust(val code: String?, val confirmed: Boolean, val promptGen: Int = -1) : SessionUi
    /**
     * [hostTag] (T-207): the session's host_id, set only once the host authenticated itself on this connection (a sealed
     * record: PAIRED with our trusted key, or a locally confirmed pairing the Mac accepted); null before that.
     */
    data class Connected(val hostName: String, val framesReceived: Long, val hostTag: HostTag? = null) : SessionUi

    /** "Bağlantı yok"; an automatic retry follows in [retryInMs] (0: none, a failed T-134 wake attempt). */
    data class Disconnected(val cause: Cause, val retryInMs: Long) : SessionUi

    /**
     * Terminal until the user retries: no automatic reconnect. [endpoint] (T-227): set for [Cause.WRONG_HOST] only, the
     * address of the start that was refused (a late one of a superseded start must not be blamed on the next address).
     * [Cause.HOST_SLEEP] (BYE HOST_SLEEP, T-133): the Mac went
     * to sleep; nothing is sent to it (no reconnect, no automatic wake) until a user action or the next foreground.
     */
    data class Failed(val cause: Cause, val endpoint: Endpoint? = null) : SessionUi

    enum class Cause {
        LOST, HOST_CLOSED, BUSY, REJECTED, VERSION_MISMATCH, PROTOCOL_ERROR, CONNECT_FAILED, KEY_MISSING, KEY_STORE_FAILED, HOST_SLEEP,

        /** T-150: the user cancelled the code confirmation (or it timed out); no automatic retry until a user start. */
        PAIR_CANCELLED,

        /**
         * T-156: repeated PAIRED connections ended before any host record authenticated (the Mac's key no longer matches
         * ours, or an answerer that knows the host_id cannot seal records). Terminal; in AUTO on USB it falls back to Wi-Fi.
         */
        KEY_MISMATCH,

        /**
         * T-227: the start expected one host (rediscovery after the Mac's address changed) and another host answered: a
         * different host_id, or a PAIRING answer from another Mac. Refused at its first answer, before any HELLO_ACK
         * (nothing is enabled for it); terminal for this start, the UI goes back to the old address.
         */
        WRONG_HOST,
    }
}

/**
 * T-207: an opaque host identity (the 16-byte host_id) for equality checks in the UI layer. It never prints its value
 * ([toString]), so a logged UI state cannot leak it. An empty or all-zero id is no identity ([of] gives null).
 */
class HostTag private constructor(private val id: ByteArray) {
    override fun equals(other: Any?) = other is HostTag && id.contentEquals(other.id)
    override fun hashCode() = id.contentHashCode()
    override fun toString() = "HostTag"

    companion object {
        fun of(id: ByteArray?): HostTag? = id?.takeIf { b -> b.any { it != 0.toByte() } }?.let { HostTag(it.copyOf()) }
    }
}
