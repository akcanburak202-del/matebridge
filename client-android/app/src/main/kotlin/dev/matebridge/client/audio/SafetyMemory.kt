package dev.matebridge.client.audio

/** Persistent learned safety per output API ("aaudio" / "track"), in whole milliseconds (T-108). */
interface SafetyStore {
    /** The stored value for [api], or null if none. */
    fun get(api: String): Int?

    /** Stores [ms] for [api]; must not block the caller for long (the audio writer thread calls it). */
    fun put(api: String, ms: Int)
}

/**
 * T-108: the jitter buffer's safety margin ([DriftController.safetyFrames]) per output API, remembered across sessions.
 * Pure Kotlin; called from audio writer threads (synchronized: a slow previous writer may still be flushing).
 *
 *  - Start: max(the API's default, the stored value), clamped to the controller's range. AAudio's default is a safe
 *    [AAUDIO_DEFAULT_MS] (5 ms underran every ~minute in game audio, each underrun a short audible hole); AudioTrack's
 *    stays [DriftController.SAFETY_MIN_MS] (unchanged, its 20 ms burst already keeps the level up).
 *  - The decay floor is the API's default: a learned excess shrinks back slowly (the controller's rule) but not below
 *    the safe start.
 *  - Saving: [onSafety] (each stats second) stores a changed value at most every [SAVE_INTERVAL_MS]; [flush] (output
 *    closed or switched) stores it at once if changed.
 */
class SafetyMemory(private val store: SafetyStore) {
    /** Start value for an output: [ms], and whether a stored value raised it above the default. */
    data class Init(val ms: Int, val stored: Boolean, val storedMs: Int?) {
        val source: String get() = if (stored) "stored" else "default"
    }

    private val lastSaved = HashMap<String, Int>()
    private var lastSaveAtMs = Long.MIN_VALUE

    /** The API's start value (reads the store). */
    @Synchronized fun initial(api: String): Init {
        val def = defaultMs(api)
        val raw = try { store.get(api) } catch (_: RuntimeException) { null }
        val stored = raw?.coerceIn(DriftController.SAFETY_MIN_MS, DriftController.SAFETY_MAX_MS)
        lastSaved[api] = stored ?: def // nothing new to save until the value moves
        return if (stored != null && stored > def) Init(stored, true, stored) else Init(def, false, stored)
    }

    /** Called about once per second with the current value; stores it if it changed and the last save is old enough. */
    @Synchronized fun onSafety(api: String, ms: Int, nowMs: Long) {
        if (lastSaved[api] == ms) return
        if (lastSaveAtMs != Long.MIN_VALUE && nowMs - lastSaveAtMs < SAVE_INTERVAL_MS) return
        save(api, ms)
        lastSaveAtMs = nowMs
    }

    /** The output for [api] is closing or being replaced: stores the value now if it changed. */
    @Synchronized fun flush(api: String, ms: Int) {
        if (lastSaved[api] != ms) save(api, ms)
    }

    private fun save(api: String, ms: Int) {
        lastSaved[api] = ms
        try { store.put(api, ms) } catch (_: RuntimeException) {}
    }

    companion object {
        /** Safe AAudio start (and decay floor): one 10 ms packet plus ~10 ms of network jitter. */
        const val AAUDIO_DEFAULT_MS = 20
        const val TRACK_DEFAULT_MS = DriftController.SAFETY_MIN_MS
        const val SAVE_INTERVAL_MS = 10_000L

        fun defaultMs(api: String): Int = if (api == "aaudio") AAUDIO_DEFAULT_MS else TRACK_DEFAULT_MS
    }
}
