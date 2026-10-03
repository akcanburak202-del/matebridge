package dev.matebridge.client.audio

/** Persistent output buffer size per output path, in bursts (T-110). */
interface OutBufStore {
    /** The stored value for [path], or null if none. */
    fun get(path: String): Int?

    /** Stores [bursts] for [path]; must not block the caller for long (the audio writer thread calls it). */
    fun put(path: String, bursts: Int)

    /** T-191: removes every stored value. The default body throws (a store that cannot clear must not look cleared). */
    fun clear() {
        throw UnsupportedOperationException("clear not supported")
    }
}

/**
 * T-110: the AAudio output buffer size per output path ([PATH_EXCLUSIVE] / [PATH_SHARED]), remembered across sessions.
 * Pure Kotlin; synchronized (a slow previous writer may still be running).
 *
 *  - Start: the `--ei audio_buf_bursts` override if given; otherwise max(default, stored), clamped to 1..[MAX].
 *  - [onGrown]: a grown size is stored at once if it is above the stored one; the stored value only ever increases
 *    (the buffer never shrinks, the card's "no shrink" choice).
 */
class OutBufMemory(private val store: OutBufStore) {
    data class Init(val bursts: Int, val source: String, val storedBursts: Int?)

    private val stored = HashMap<String, Int?>()

    /** The start size for [path] (reads the store). */
    @Synchronized fun initial(path: String, override: Int?, default: Int): Init {
        val s = read(path)
        if (override != null) return Init(override.coerceIn(1, MAX), SOURCE_OVERRIDE, s)
        val def = default.coerceIn(1, MAX)
        return if (s != null && s > def) Init(s, SOURCE_STORED, s) else Init(def, SOURCE_DEFAULT, s)
    }

    /** The output on [path] grew to [bursts]: stores it if above the stored value. True if stored. */
    @Synchronized fun onGrown(path: String, bursts: Int): Boolean {
        val b = bursts.coerceIn(1, MAX)
        val s = read(path)
        if (s != null && b <= s) return false
        stored[path] = b
        try { store.put(path, b) } catch (_: RuntimeException) {}
        return true
    }

    /**
     * T-191 "Varsayılanlara dön": forgets every learned size, in memory and in the store, so the next [initial] starts
     * from the default. False if the store could not be cleared (the cache is dropped either way).
     */
    @Synchronized fun clear(): Boolean {
        stored.clear()
        return try { store.clear(); true } catch (_: RuntimeException) { false }
    }

    private fun read(path: String): Int? {
        if (stored.containsKey(path)) return stored[path]
        val raw = try { store.get(path) } catch (_: RuntimeException) { null }
        val v = raw?.coerceIn(1, MAX)
        stored[path] = v
        return v
    }

    companion object {
        const val MAX = AudioBufferConfig.MAX_BURSTS
        const val PATH_EXCLUSIVE = "aaudio_exclusive"
        const val PATH_SHARED = "aaudio_shared"
        const val SOURCE_OVERRIDE = "override"
        const val SOURCE_STORED = "stored"
        const val SOURCE_DEFAULT = "default"
    }
}
