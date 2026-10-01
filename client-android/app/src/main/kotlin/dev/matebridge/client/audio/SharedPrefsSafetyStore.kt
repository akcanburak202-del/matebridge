package dev.matebridge.client.audio

import android.content.Context

/** [SafetyStore] in the audio package's own SharedPreferences file (not the app's settings file). */
class SharedPrefsSafetyStore(context: Context) : SafetyStore {
    private val prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    override fun get(api: String): Int? {
        val k = key(api)
        return if (prefs.contains(k)) prefs.getInt(k, 0) else null
    }

    override fun put(api: String, ms: Int) {
        prefs.edit().putInt(key(api), ms).apply()
    }

    private fun key(api: String) = "safety_ms_$api"

    private companion object {
        const val FILE = "matebridge_audio"
    }
}
