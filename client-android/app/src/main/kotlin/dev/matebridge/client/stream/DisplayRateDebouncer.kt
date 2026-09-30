package dev.matebridge.client.stream

/**
 * Decides when a measured panel rate is reported to the host (T-059, PROTOCOL.md 0x07). Pure logic, one thread.
 * The first value goes out at once; a rise goes out at once; a fall only after the lower value stayed the
 * measurement for [stableMs]; never more than one report per [minIntervalMs] (4 per second). Call [observe] often
 * (the caller polls); a report held back by the spacing is returned by a later call.
 */
class DisplayRateDebouncer(private val stableMs: Long = 500, private val minIntervalMs: Long = 250) {
    private var reported = 0
    private var candidate = 0
    private var candidateSinceMs = 0L
    private var lastSendMs = Long.MIN_VALUE

    /** The last value returned by [observe] (0 = none yet). */
    val current: Int get() = reported

    /** Returns the rate to report now, or null. [hz] <= 0 (unknown) is ignored. */
    fun observe(hz: Int, nowMs: Long): Int? {
        if (hz <= 0) return null
        if (hz == reported) { candidate = 0; return null }
        if (reported != 0 && hz < reported) {
            if (candidate != hz) { candidate = hz; candidateSinceMs = nowMs }
            if (nowMs - candidateSinceMs < stableMs) return null
        }
        if (lastSendMs != Long.MIN_VALUE && nowMs - lastSendMs < minIntervalMs) return null
        reported = hz
        candidate = 0
        lastSendMs = nowMs
        return hz
    }
}
