package dev.matebridge.client.security

import dev.matebridge.client.session.KeyValueStore

/** Pairing keys by host_id (PROTOCOL.md section 9). Keys are secrets: never log them. */
interface PairKeyStore {
    /** The stored 32-byte key for [hostId], or null when there is none (or it cannot be read back). */
    fun get(hostId: ByteArray): ByteArray?

    fun put(hostId: ByteArray, key: ByteArray)
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

/** Pairing keys wrapped by a [KeyWrapper] and persisted as hex in a key-value store (SharedPreferences on Android). */
class EncryptedPairKeyStore(private val store: KeyValueStore, private val wrapper: KeyWrapper) : PairKeyStore {
    override fun get(hostId: ByteArray): ByteArray? {
        val hex = store.getString(name(hostId)) ?: return null
        val blob = fromHex(hex) ?: return null
        val key = try {
            wrapper.unwrap(blob, hostId)
        } catch (e: Exception) {
            null
        }
        return if (key != null && key.size == KEY_BYTES) key else null
    }

    override fun put(hostId: ByteArray, key: ByteArray) {
        require(key.size == KEY_BYTES) { "pair key must be 32 bytes" }
        store.putString(name(hostId), toHex(wrapper.wrap(key, hostId)))
    }

    private fun name(hostId: ByteArray) = "pairkey." + toHex(hostId)

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
    }
}
