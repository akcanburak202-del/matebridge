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

    private fun key(path: String) = "out_buf_bursts_$path"

    private companion object {
        const val FILE = "matebridge_audio"
    }
}
