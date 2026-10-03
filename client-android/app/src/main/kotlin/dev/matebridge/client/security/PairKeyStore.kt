package dev.matebridge.client.security

import dev.matebridge.client.session.AtomicKeyValueStore

/**
 * A pairing key the tablet holds but does not trust yet (T-150, decision 0018): stored at the first PAIRING ack of a
 * user-initiated connection, promoted to the trusted key only when the user confirms that [sas] matches the Mac's.
 * [key] and [sas] are secrets: never log them.
 */
class PendingRecord(val key: ByteArray, val sas: String, val createdAtWallMs: Long) {
    /** Identifies exactly this key and code (review #2): a promotion must match the record the user was shown. */
    fun fingerprint(): ByteArray = fingerprint(key, sas)

    companion object {
        /** SHA-256("MB1 pending" ‖ key ‖ sas). Not secret-revealing, but still never logged. */
        fun fingerprint(key: ByteArray, sas: String): ByteArray {
            val md = java.security.MessageDigest.getInstance("SHA-256")
            md.update("MB1 pending".toByteArray(Charsets.US_ASCII))
            md.update(key)
            md.update(sas.toByteArray(Charsets.US_ASCII))
            return md.digest()
        }
    }
}

/**
 * Pairing keys by host_id (PROTOCOL.md section 9, decision 0018). Keys and codes are secrets: never log them.
 *
 * Per host_id there are three records: the **trusted** key (used by PAIRED handshakes), at most one **pending** key with
 * its pairing code (not trusted until the user confirms), and the non-secret **awaiting-host marker** (a confirmed key
 * the Mac has not been seen to accept yet). The methods beyond [get]/[put] have default bodies so that read-only or
 * test stores need not implement them: reads report nothing, writes throw [UnsupportedOperationException].
 */
interface PairKeyStore {
    /** The trusted 32-byte key for [hostId], or null when there is none (or it cannot be read back). */
    fun get(hostId: ByteArray): ByteArray?

    /** Writes the trusted key for [hostId]. Production code trusts a key only through [promote]. */
    fun put(hostId: ByteArray, key: ByteArray)

    /** The pending record for [hostId], or null when there is none or it cannot be read back. */
    fun getPending(hostId: ByteArray): PendingRecord? = null

    /** host_ids that have a pending record entry (readable or not). */
    fun pendingHosts(): List<ByteArray> = emptyList()

    /**
     * Stores [record] as the pending key of [hostId] in one commit that also removes every other host's pending record
     * (one unresolved pairing at a time) and [hostId]'s awaiting-host marker. Throws when it did not persist.
     */
    fun putPending(hostId: ByteArray, record: PendingRecord): Unit = throw UnsupportedOperationException("read-only pair key store")

    /**
     * One atomic commit: the pending key of [hostId] becomes its trusted key, the pending record is removed, and the
     * awaiting-host marker is set to [markerWallMs] (null: removed). Returns false (nothing written) when there is no
     * readable pending record or its [PendingRecord.fingerprint] is not [expectedFingerprint] (it is not the record the
     * user confirmed); throws when the commit did not persist (then nothing changed).
     */
    fun promote(hostId: ByteArray, markerWallMs: Long?, expectedFingerprint: ByteArray): Boolean =
        throw UnsupportedOperationException("read-only pair key store")

    fun dropPending(hostId: ByteArray): Unit = throw UnsupportedOperationException("read-only pair key store")

    /** The awaiting-host marker of [hostId] (its wall-clock time), or null. */
    fun getMarker(hostId: ByteArray): Long? = null

    /** host_ids that have an awaiting-host marker entry. */
    fun markerHosts(): List<ByteArray> = emptyList()

    fun clearMarker(hostId: ByteArray): Unit = throw UnsupportedOperationException("read-only pair key store")

    /** Removes the trusted key, the pending record and the marker of [hostId] in one commit. */
    fun remove(hostId: ByteArray): Unit = throw UnsupportedOperationException("read-only pair key store")
}

/**
 * T-096 / T-150: the store a migration candidate sees. It reads (a PAIRED takeover needs the trusted key, and an
 * unconfirmed pending record must still block a PAIRED derivation) but never writes: a migration must not pair.
 */
class ReadOnlyPairKeyStore(private val inner: PairKeyStore) : PairKeyStore {
    override fun get(hostId: ByteArray): ByteArray? = inner.get(hostId)
    override fun put(hostId: ByteArray, key: ByteArray) = throw java.io.IOException("a migration candidate never stores a pair key")
    override fun getPending(hostId: ByteArray): PendingRecord? = inner.getPending(hostId)
    override fun pendingHosts(): List<ByteArray> = inner.pendingHosts()
    override fun getMarker(hostId: ByteArray): Long? = inner.getMarker(hostId)
    override fun markerHosts(): List<ByteArray> = inner.markerHosts()
}

/**
 * Encrypts/decrypts small secrets with a non-exportable key. The Android Keystore implementation lives in
 * [AndroidKeystoreWrapper], the only class that touches the Keystore; tests use a software fake.
 * [aad] is authenticated but not stored; the store passes the host_id so a blob cannot be moved to another host.
 */
interface KeyWrapper {
    fun wrap(plain: ByteArray, aad: ByteArray): ByteArray

    /** Returns null when the blob is corrupt or the wrapping key is gone/invalidated. */
    fun unwrap(blob: ByteArray, aad: ByteArray): ByteArray?
}

/**
 * Pairing keys wrapped by a [KeyWrapper] and persisted as hex in a key-value store (SharedPreferences on Android).
 * Trusted: `pairkey.<hostIdHex>` = wrap(key, aad = hostId). Pending: `pairpend.<hostIdHex>` = wrap(key ‖ sas ‖
 * createdAtWallMs (8 bytes, big-endian), aad = hostId ‖ "pending"). Marker: `pairwait.<hostIdHex>` = createdAtWallMs.
 */
class EncryptedPairKeyStore(private val store: AtomicKeyValueStore, private val wrapper: KeyWrapper) : PairKeyStore {
    override fun get(hostId: ByteArray): ByteArray? {
        val key = unwrapEntry(TRUSTED + toHex(hostId), hostId) ?: return null
        if (key.size == KEY_BYTES) return key
        key.fill(0)
        return null
    }

    override fun put(hostId: ByteArray, key: ByteArray) {
        require(key.size == KEY_BYTES) { "pair key must be 32 bytes" }
        store.commit(mapOf(TRUSTED + toHex(hostId) to toHex(wrapper.wrap(key, hostId))))
    }

    override fun getPending(hostId: ByteArray): PendingRecord? {
        val plain = unwrapEntry(PENDING + toHex(hostId), pendingAad(hostId)) ?: return null
        try {
            if (plain.size != PENDING_BYTES) return null
            val sas = String(plain, KEY_BYTES, SAS_DIGITS, Charsets.US_ASCII)
            if (!sas.all { it in '0'..'9' }) return null
            var ts = 0L
            for (i in 0 until 8) ts = (ts shl 8) or (plain[KEY_BYTES + SAS_DIGITS + i].toLong() and 0xFF)
            return PendingRecord(plain.copyOf(KEY_BYTES), sas, ts)
        } finally {
            plain.fill(0)
        }
    }

    override fun pendingHosts(): List<ByteArray> = hostsWithPrefix(PENDING)

    override fun putPending(hostId: ByteArray, record: PendingRecord) {
        require(record.key.size == KEY_BYTES) { "pair key must be 32 bytes" }
        require(record.sas.length == SAS_DIGITS && record.sas.all { it in '0'..'9' }) { "pairing code must be 6 digits" }
        val plain = ByteArray(PENDING_BYTES)
        try {
            record.key.copyInto(plain)
            record.sas.toByteArray(Charsets.US_ASCII).copyInto(plain, KEY_BYTES)
            for (i in 0 until 8) plain[KEY_BYTES + SAS_DIGITS + i] = (record.createdAtWallMs ushr (56 - 8 * i)).toByte()
            val changes = LinkedHashMap<String, String?>()
            for (k in store.keys()) if (k.startsWith(PENDING)) changes[k] = null // one unresolved pairing at a time
            changes[MARKER + toHex(hostId)] = null
            changes[PENDING + toHex(hostId)] = toHex(wrapper.wrap(plain, pendingAad(hostId)))
            store.commit(changes)
        } finally {
            plain.fill(0)
        }
    }

    override fun promote(hostId: ByteArray, markerWallMs: Long?, expectedFingerprint: ByteArray): Boolean {
        val pending = getPending(hostId) ?: return false
        try {
            if (!java.security.MessageDigest.isEqual(pending.fingerprint(), expectedFingerprint)) return false
            val h = toHex(hostId)
            store.commit(
                linkedMapOf(
                    TRUSTED + h to toHex(wrapper.wrap(pending.key, hostId)),
                    PENDING + h to null,
                    MARKER + h to markerWallMs?.toString(),
                ),
            )
            return true
        } finally {
            pending.key.fill(0)
        }
    }

    override fun dropPending(hostId: ByteArray) = store.commit(mapOf(PENDING + toHex(hostId) to null))

    override fun getMarker(hostId: ByteArray): Long? = store.getString(MARKER + toHex(hostId))?.toLongOrNull()

    override fun markerHosts(): List<ByteArray> = hostsWithPrefix(MARKER)

    override fun clearMarker(hostId: ByteArray) = store.commit(mapOf(MARKER + toHex(hostId) to null))

    override fun remove(hostId: ByteArray) {
        val h = toHex(hostId)
        store.commit(mapOf(TRUSTED + h to null, PENDING + h to null, MARKER + h to null))
    }

    private fun unwrapEntry(name: String, aad: ByteArray): ByteArray? {
        val hex = store.getString(name) ?: return null
        val blob = fromHex(hex) ?: return null
        return try {
            wrapper.unwrap(blob, aad)
        } catch (e: Exception) {
            null
        }
    }

    private fun hostsWithPrefix(prefix: String): List<ByteArray> =
        store.keys().filter { it.startsWith(prefix) }.mapNotNull { fromHex(it.substring(prefix.length)) }

    private fun pendingAad(hostId: ByteArray) = hostId + PENDING_AAD

    private fun toHex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }

    private fun fromHex(s: String): ByteArray? {
        if (s.length % 2 != 0) return null
        return try {
            ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        } catch (e: NumberFormatException) {
            null
        }
    }

    companion object {
        const val KEY_BYTES = 32
        private const val SAS_DIGITS = 6
        private const val PENDING_BYTES = KEY_BYTES + SAS_DIGITS + 8
        private const val TRUSTED = "pairkey."
        private const val PENDING = "pairpend."
        private const val MARKER = "pairwait."
        private val PENDING_AAD = "pending".toByteArray(Charsets.US_ASCII)
    }
}

/**
 * T-150 (decision 0018): the tablet-side trust rules over a [PairKeyStore]. Pure Kotlin (wall clock injected), so the
 * session machine and the handshake can be tested with it. Thread-safe (the control reader and the engine both use it).
 *
 * A pending record or an awaiting-host marker is **stale** when it is older than [maxAgeMs] of wall-clock time or dated
 * in the future; a stale one is removed when read and never shown or used.
 */
class PairTrust(
    val store: PairKeyStore,
    private val wallMs: () -> Long = System::currentTimeMillis,
    private val maxAgeMs: Long = PENDING_MAX_AGE_MS,
    /** Log sink (`ev`, `fields`); never receives a key, code, host_id or name. */
    private val log: (String, String) -> Unit = { _, _ -> },
) {
    /**
     * An unresolved pairing to show again without a connection: [code] non-null = pending, null = marker only.
     * [fingerprint] identifies the pending record shown (null for a marker); a confirmation promotes only that record.
     */
    class StoredPrompt(val hostId: ByteArray, val code: String?, val atWallMs: Long, val fingerprint: ByteArray? = null)

    @Synchronized fun hasTrusted(hostId: ByteArray): Boolean = store.get(hostId)?.also { it.fill(0) } != null

    @Synchronized fun trusted(hostId: ByteArray): ByteArray? = store.get(hostId)

    /** The fresh pending record of [hostId], or null; a stale or unreadable one is dropped (best effort). */
    @Synchronized fun freshPending(hostId: ByteArray): PendingRecord? {
        val p = store.getPending(hostId)
        if (p != null && fresh(p.createdAtWallMs)) return p
        p?.key?.fill(0)
        if (p != null || store.pendingHosts().any { it.contentEquals(hostId) }) {
            log("pair_pending_expired", "kind=pending")
            try { store.dropPending(hostId) } catch (e: Exception) { /* read-only (candidate) or failed: retried next read */ }
        }
        return null
    }

    /** True when [hostId] has a fresh awaiting-host marker; a stale one is cleared (best effort). */
    @Synchronized fun hasFreshMarker(hostId: ByteArray): Boolean {
        val at = store.getMarker(hostId)
        if (at != null && fresh(at)) return true
        if (at != null || store.markerHosts().any { it.contentEquals(hostId) }) {
            log("pair_pending_expired", "kind=marker")
            try { store.clearMarker(hostId) } catch (e: Exception) { }
        }
        return false
    }

    /** The newest fresh pending record (with its code), else the newest fresh marker; null when nothing is unresolved. */
    @Synchronized fun storedPrompt(): StoredPrompt? {
        var best: StoredPrompt? = null
        for (h in store.pendingHosts()) {
            val p = freshPending(h) ?: continue
            val fp = p.fingerprint()
            p.key.fill(0)
            if (best == null || p.createdAtWallMs > best.atWallMs) best = StoredPrompt(h, p.sas, p.createdAtWallMs, fp)
        }
        if (best != null) return best
        for (h in store.markerHosts()) {
            if (!hasFreshMarker(h)) continue
            val at = store.getMarker(h) ?: continue
            if (best == null || at > best.atWallMs) best = StoredPrompt(h, null, at)
        }
        return best
    }

    /** Stores the pending key and code of a user-initiated PAIRING; throws when it did not persist. */
    @Synchronized fun storePending(hostId: ByteArray, key: ByteArray, sas: String) =
        store.putPending(hostId, PendingRecord(key, sas, wallMs()))

    /**
     * The user confirmed the code: the pending key of [hostId] becomes trusted in one commit. [awaitHost]: the Mac has not
     * been seen to accept it yet, so the awaiting-host marker is written. [fingerprint] is that of the record whose code
     * was shown ([PendingRecord.fingerprint]); the store compares it inside the promotion. False (nothing written) when
     * there is no fresh pending record or it is another one. Throws when the commit did not persist.
     */
    @Synchronized fun promote(hostId: ByteArray, awaitHost: Boolean, fingerprint: ByteArray): Boolean {
        val p = freshPending(hostId) ?: return false
        p.key.fill(0)
        return store.promote(hostId, if (awaitHost) wallMs() else null, fingerprint)
    }

    @Synchronized fun dropPending(hostId: ByteArray) {
        if (store.getPending(hostId) != null || store.pendingHosts().any { it.contentEquals(hostId) }) store.dropPending(hostId)
    }

    @Synchronized fun clearMarker(hostId: ByteArray) {
        if (store.getMarker(hostId) != null || store.markerHosts().any { it.contentEquals(hostId) }) store.clearMarker(hostId)
    }

    /** "Bu Mac'i unut": trusted, pending and marker of [hostId], in one commit. */
    @Synchronized fun forget(hostId: ByteArray) = store.remove(hostId)

    private fun fresh(atWallMs: Long): Boolean {
        val now = wallMs()
        return atWallMs <= now && now - atWallMs < maxAgeMs
    }

    companion object {
        /** Wall-clock age after which an unconfirmed pending key or an awaiting-host marker is dropped (decision 0018). */
        const val PENDING_MAX_AGE_MS = 10 * 60 * 1000L
    }
}
