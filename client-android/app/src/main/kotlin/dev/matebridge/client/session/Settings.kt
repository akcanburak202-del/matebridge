package dev.matebridge.client.session

import dev.matebridge.client.protocol.Limits
import java.security.SecureRandom

/** Minimal string key-value store so the logic below is JVM-testable (Android impl: SharedPreferences). */
interface KeyValueStore {
    fun getString(key: String): String?
    fun putString(key: String, value: String)
}

/** Persistent settings: the random per-install device id and the last manually entered endpoint. */
class Settings(private val store: KeyValueStore, private val random: java.util.Random = SecureRandom()) {
    /** 16 random bytes generated on first use, then stable (PROTOCOL.md HELLO.device_id). */
    fun deviceId(): ByteArray {
        store.getString(KEY_DEVICE_ID)?.let { hex ->
            val bytes = fromHex(hex)
            if (bytes != null && bytes.size == Limits.DEVICE_ID_BYTES) return bytes
        }
        val fresh = ByteArray(Limits.DEVICE_ID_BYTES).also { random.nextBytes(it) }
        store.putString(KEY_DEVICE_ID, toHex(fresh))
        return fresh
    }

    fun lastEndpoint(): Endpoint? = store.getString(KEY_ENDPOINT)?.let { Endpoint.parse(it) }

    fun saveEndpoint(endpoint: Endpoint) = store.putString(KEY_ENDPOINT, endpoint.toString())

    /** Whether the on-screen statistics overlay is enabled (default off). */
    fun statsOverlay(): Boolean = store.getString(KEY_STATS) == "1"

    fun setStatsOverlay(on: Boolean) = store.putString(KEY_STATS, if (on) "1" else "0")

    private fun toHex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }

    private fun fromHex(s: String): ByteArray? {
        if (s.length % 2 != 0) return null
        return try {
            ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        } catch (e: NumberFormatException) {
            null
        }
    }

    private companion object {
        const val KEY_DEVICE_ID = "device_id"
        const val KEY_ENDPOINT = "last_endpoint"
        const val KEY_STATS = "stats_overlay"
    }
}

/** Truncates to at most [maxBytes] UTF-8 bytes without splitting a code point (str8 limit is 64). */
fun truncateUtf8(s: String, maxBytes: Int = Limits.STR8_MAX_BYTES): String {
    var bytes = 0
    var i = 0
    while (i < s.length) {
        val cp = s.codePointAt(i)
        val n = when {
            cp < 0x80 -> 1
            cp < 0x800 -> 2
            cp < 0x10000 -> 3
            else -> 4
        }
        if (bytes + n > maxBytes) break
        bytes += n
        i += Character.charCount(cp)
    }
    return s.substring(0, i)
}
