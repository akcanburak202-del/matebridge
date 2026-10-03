package dev.matebridge.client.audio

import dev.matebridge.client.session.Transport

/**
 * Persistent learned safety, in whole milliseconds. Keys are [SafetyMemory.key] (`api/transport`, T-123); before
 * T-123 the key was the output API alone ("aaudio" / "track"), still read once as the USB value.
 */
interface SafetyStore {
    /** The stored value for [key], or null if none. */
    fun get(key: String): Int?

    /** Stores [ms] for [key]; must not block the caller for long (the audio writer thread calls it). */
    fun put(key: String, ms: Int)

    /**
     * T-191: removes every stored value, the pre-T-123 single-API keys included. The default body throws (a store that
     * cannot clear must not look cleared).
     */
    fun clear() {
        throw UnsupportedOperationException("clear not supported")
    }
}

/**
 * T-108: the jitter buffer's safety margin ([DriftController.safetyFrames]) per output API and, since T-123, per
 * transport (USB / Wi-Fi), remembered across sessions. Pure Kotlin; called from audio writer threads (synchronized: a
 * slow previous writer may still be flushing).
 *
 *  - Each (API, transport) has a [Profile]: start and decay floor, the most that is remembered, the in-session ceiling.
 *    USB keeps T-118's numbers (AAudio 20 ms, AudioTrack 5 ms, remembered at most 30, in session at most 40). Wi-Fi
 *    starts at [WIFI_DEFAULT_MS] for both APIs (network jitter does not depend on the output), remembers at most
 *    [WIFI_REMEMBER_MAX_MS] and may reach [WIFI_SESSION_MAX_MS] within a session (T-123 card, NOTES 2026-10-02 ~11:35).
 *  - Start: max(the profile's default, the stored value clamped to what is remembered).
 *  - Saving: [onSafety] (each stats second) stores a changed value at most every [SAVE_INTERVAL_MS]; [flush] (output
 *    closed or switched) stores it at once if changed.
 *  - Migration (T-123): without an `api/usb` value the old single-key `api` value is the USB value; Wi-Fi starts from
 *    its default.
 */
class SafetyMemory(private val store: SafetyStore) {
    /** Start value for an output: [ms], and whether a stored value raised it above the default. */
    data class Init(val ms: Int, val stored: Boolean, val storedMs: Int?, val profile: Profile) {
        val source: String get() = if (stored) "stored" else "default"
    }

    /** Safety rules of one (API, transport): [defaultMs] is the start and decay floor. */
    data class Profile(val defaultMs: Int, val rememberMaxMs: Int, val sessionMaxMs: Int) {
        /** [ms] clamped to what is remembered: [DriftController.SAFETY_MIN_MS]..[rememberMaxMs]. */
        fun rememberable(ms: Int): Int = ms.coerceIn(DriftController.SAFETY_MIN_MS, rememberMaxMs)
    }

    private val lastSaved = HashMap<String, Int>()
    private var lastSaveAtMs = Long.MIN_VALUE

    /** The start value of [api] on [transport] (reads the store). */
    @Synchronized fun initial(api: String, transport: Transport): Init {
        val p = profile(api, transport)
        val k = key(api, transport)
        val raw = read(k) ?: if (transport == Transport.USB) read(api) else null // T-123 migration
        val stored = raw?.let(p::rememberable)
        lastSaved[k] = stored ?: p.defaultMs // nothing new to save until the value moves
        return if (stored != null && stored > p.defaultMs) Init(stored, true, stored, p) else Init(p.defaultMs, false, stored, p)
    }

    /** Called about once per second with the current value; stores it if it changed and the last save is old enough. */
    @Synchronized fun onSafety(api: String, transport: Transport, ms: Int, nowMs: Long) {
        val k = key(api, transport)
        val v = profile(api, transport).rememberable(ms)
        if (lastSaved[k] == v) return
        if (lastSaveAtMs != Long.MIN_VALUE && nowMs - lastSaveAtMs < SAVE_INTERVAL_MS) return
        save(k, v)
        lastSaveAtMs = nowMs
    }

    /** The output for [api] on [transport] is closing or being replaced: stores the value now if it changed. */
    @Synchronized fun flush(api: String, transport: Transport, ms: Int) {
        val k = key(api, transport)
        val v = profile(api, transport).rememberable(ms)
        if (lastSaved[k] != v) save(k, v)
    }

    /**
     * T-191 "Varsayılanlara dön": forgets every learned value, in memory and in the store, so the next [initial] starts
     * from the profile's default. False if the store could not be cleared (the cache is dropped either way).
     */
    @Synchronized fun clear(): Boolean {
        lastSaved.clear()
        lastSaveAtMs = Long.MIN_VALUE
        return try { store.clear(); true } catch (_: RuntimeException) { false }
    }

    private fun read(k: String): Int? = try { store.get(k) } catch (_: RuntimeException) { null }

    private fun save(k: String, ms: Int) {
        lastSaved[k] = ms
        try { store.put(k, ms) } catch (_: RuntimeException) {}
    }

    companion object {
        /** Safe AAudio start (and decay floor) on USB: one 10 ms packet plus ~10 ms of network jitter. */
        const val AAUDIO_DEFAULT_MS = 20
        const val TRACK_DEFAULT_MS = DriftController.SAFETY_MIN_MS
        const val SAVE_INTERVAL_MS = 10_000L
        /** T-118: the most a USB session start inherits; a learned 35-40 ms is relearned rather than carried over. */
        const val REMEMBER_MAX_MS = 30

        /**
         * T-123: Wi-Fi start and decay floor (both APIs). Wi-Fi arrival gaps were 41-50 ms (NOTES 2026-10-02 ~11:35):
         * 40 ms of margin plus one 10 ms packet covers a 50 ms gap.
         */
        const val WIFI_DEFAULT_MS = 40
        /** T-123: the most a Wi-Fi session start inherits (just above the observed gap band). */
        const val WIFI_REMEMBER_MAX_MS = 50
        /** T-123: in-session Wi-Fi ceiling: the largest observed `owd` (65 ms) plus a little. */
        const val WIFI_SESSION_MAX_MS = 70

        /** Store key: `api/transport` (`aaudio/usb`, `aaudio/wifi`, `track/usb`, `track/wifi`). */
        fun key(api: String, transport: Transport): String = "$api/${transport.logName}"

        fun profile(api: String, transport: Transport): Profile = when (transport) {
            Transport.USB -> Profile(
                if (api == "aaudio") AAUDIO_DEFAULT_MS else TRACK_DEFAULT_MS,
                REMEMBER_MAX_MS,
                DriftController.SAFETY_MAX_MS,
            )
            Transport.WIFI -> Profile(WIFI_DEFAULT_MS, WIFI_REMEMBER_MAX_MS, WIFI_SESSION_MAX_MS)
        }

        fun defaultMs(api: String, transport: Transport): Int = profile(api, transport).defaultMs
    }
}
