package dev.matebridge.client.idle

import dev.matebridge.client.session.KeyValueStore

/** "Boşta karart" choices (decision 0031): how long without local input before the window dims. Default 5 min. */
enum class IdleTimeout(val id: String, val label: String, val minutes: Int?) {
    MIN_2("2", "2 dk", 2),
    MIN_5("5", "5 dk", 5),
    MIN_10("10", "10 dk", 10),
    MIN_15("15", "15 dk", 15),
    OFF("off", "Kapalı", null);

    /** Milliseconds until the dim stage, null for [OFF]. */
    val ms: Long? get() = minutes?.let { it * 60_000L }

    companion object {
        val DEFAULT = MIN_5

        fun parse(id: String?): IdleTimeout = entries.firstOrNull { it.id == id } ?: DEFAULT
    }
}

/** Persists the [IdleTimeout] choice in the app prefs (key [KEY]). Main thread only. */
class IdleTimeoutStore(private val store: KeyValueStore) {
    fun get(): IdleTimeout = IdleTimeout.parse(store.getString(KEY))

    fun set(t: IdleTimeout) = store.putString(KEY, t.id)

    /** T-191 "Varsayılanlara dön": back to [IdleTimeout.DEFAULT]. */
    fun reset() = store.remove(KEY)

    companion object {
        const val KEY = "idle_dim"
    }
}
