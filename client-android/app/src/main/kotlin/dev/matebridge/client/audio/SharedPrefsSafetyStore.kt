package dev.matebridge.client.audio

import android.content.Context

/**
 * [SafetyStore] in the audio package's own SharedPreferences file (not the app's settings file). Preference key:
 * `safety_ms_` + the store key with `/` as `_` (`safety_ms_aaudio_usb`); the pre-T-123 `safety_ms_aaudio` is unchanged.
 */
class SharedPrefsSafetyStore(context: Context) : SafetyStore {
    private val prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    override fun get(key: String): Int? {
        val k = prefKey(key)
        return if (prefs.contains(k)) prefs.getInt(k, 0) else null
    }

    override fun put(key: String, ms: Int) {
        prefs.edit().putInt(prefKey(key), ms).apply()
    }

    /** T-191: removes every `safety_ms_*` key, the pre-T-123 ones included (the buffer keys in the same file stay). */
    override fun clear() {
        val e = prefs.edit()
        for (k in prefs.all.keys) if (k.startsWith(PREFIX)) e.remove(k)
        e.apply()
    }

    private fun prefKey(key: String) = PREFIX + key.replace('/', '_')

    private companion object {
        const val FILE = "matebridge_audio"
        const val PREFIX = "safety_ms_"
    }
}
