package dev.matebridge.client.audio

import android.content.Context

/** [OutBufStore] in the audio package's own SharedPreferences file (shared with [SharedPrefsSafetyStore]). */
class SharedPrefsOutBufStore(context: Context) : OutBufStore {
    private val prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    override fun get(path: String): Int? {
        val k = key(path)
        return if (prefs.contains(k)) prefs.getInt(k, 0) else null
    }

    override fun put(path: String, bursts: Int) {
        prefs.edit().putInt(key(path), bursts).apply()
    }

    /** T-191: removes every `out_buf_bursts_*` key (the safety keys in the same file stay). */
    override fun clear() {
        val e = prefs.edit()
        for (k in prefs.all.keys) if (k.startsWith(PREFIX)) e.remove(k)
        e.apply()
    }

    private fun key(path: String) = PREFIX + path

    private companion object {
        const val FILE = "matebridge_audio"
        const val PREFIX = "out_buf_bursts_"
    }
}
