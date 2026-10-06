package dev.matebridge.client.cursor

import dev.matebridge.client.stream.StreamMode

/**
 * Decides what `CURSOR_PREFS` the host should have (decision 0036, PROTOCOL.md 0x0B/0x0D) and runs the timeout that makes
 * sure the user is never left without a cursor. Pure; the UI thread owns it and passes the clock in milliseconds
 * (`SystemClock.elapsedRealtime`).
 *
 * - **Wish:** the tablet should draw the cursor in Günlük and Çizim when the setting is "Tablette"; never in Oyun and
 *   never when the setting is "Görüntüde" ([wishOf]).
 * - **Wire:** what the host was last told ([wire]); the same value is remembered for the next session so a reconnect
 *   starts with it. While no session is accepted it simply follows the wish.
 * - **Timeout:** after `CURSOR_PREFS(1)` the host must send `CURSOR_STATE` (at least every 500 ms). If none arrives for
 *   [timeoutMs] (or they stop for that long) the layer is hidden and `CURSOR_PREFS(0)` goes out ([Tick.fallback]); the
 *   video cursor is back. Automatic retries wait [retryMs] at the earliest, then double after each fallback that saw no state
 *   in between, up to [maxRetryMs] (an old host that never answers is not bothered every 10 s). A real change of the
 *   wish (the user, a mode switch) is applied at once.
 */
class CursorPrefsPolicy(
    private val timeoutMs: Long = TIMEOUT_MS,
    private val retryMs: Long = RETRY_MS,
    private val maxRetryMs: Long = MAX_RETRY_MS,
) {
    /** A change of [wire] to report; [fallback] true when it is the timeout (log `cursor_fallback`, hide the layer). */
    data class Tick(val wire: Boolean, val fallback: Boolean)

    /** What the host was last told: true = the tablet draws the cursor. */
    var wire = false
        private set

    /** The layer may show: an accepted session and the host was told to leave the cursor to us. */
    val layerOn: Boolean get() = connected && wire

    private var wish = false
    private var connected = false
    private var sentAtMs = 0L
    private var fallbackAtMs = -1L
    private var fallbacks = 0

    /** Consecutive fallbacks without a state in between (for the log). */
    val fallbackCount: Int get() = fallbacks

    /** The delay before the next automatic retry. */
    val retryDelayMs: Long get() = delayAfter(fallbacks)

    /** Returns the new [wire] when the host must be told something now, else null. */
    fun setWish(on: Boolean, nowMs: Long): Boolean? {
        if (on == wish) return null // not a change (a mode switch that keeps the wish does not cut a fallback's wait short)
        wish = on
        if (on == wire) return null
        wire = on
        if (connected) {
            if (on) {
                sentAtMs = nowMs
                fallbackAtMs = -1
            } else {
                fallbackAtMs = -1
                fallbacks = 0
            }
        }
        return wire
    }

    /** The session is accepted ([connected] true) or gone. Returns the [wire] to remember when it changed. */
    fun onSession(connected: Boolean, nowMs: Long): Boolean? {
        if (connected == this.connected) return null
        this.connected = connected
        fallbackAtMs = -1
        fallbacks = 0
        if (connected) {
            sentAtMs = nowMs // the machine sent CURSOR_PREFS with [wire] when it accepted the session
            return null
        }
        if (wire == wish) return null
        wire = wish // a fallen-back session ended: the next one starts with what the user wants
        return wire
    }

    /** A new control connection took over inside a live session (migration): the host starts without state again. */
    fun onNewConnection(nowMs: Long) {
        if (connected && wire) sentAtMs = nowMs
    }

    /**
     * Call often (every ~25 ms). [lastStateMs] is the arrival time of the latest `CURSOR_STATE` (0 = none yet). Returns a
     * change of [wire] to apply and send, else null.
     */
    fun tick(nowMs: Long, lastStateMs: Long): Tick? {
        if (!connected) return null
        if (wire) {
            if (lastStateMs >= sentAtMs && lastStateMs > 0) fallbacks = 0 // the host answers: backoff starts over
            val reference = maxOf(sentAtMs, lastStateMs)
            if (nowMs - reference >= timeoutMs) {
                wire = false
                fallbackAtMs = nowMs
                fallbacks++
                return Tick(wire = false, fallback = true)
            }
        } else if (wish && fallbackAtMs >= 0 && nowMs - fallbackAtMs >= delayAfter(fallbacks)) {
            wire = true
            sentAtMs = nowMs
            fallbackAtMs = -1
            return Tick(wire = true, fallback = false)
        }
        return null
    }

    private fun delayAfter(failures: Int): Long {
        var d = retryMs
        var n = failures
        while (n > 1 && d < maxRetryMs) { d *= 2; n-- }
        return minOf(d, maxRetryMs)
    }

    companion object {
        /** PROTOCOL.md 0x0D: no `CURSOR_STATE` for 1.5 s after (or during) `CURSOR_PREFS(1)` ends the local cursor. */
        const val TIMEOUT_MS = 1_500L

        /** PROTOCOL.md 0x0D: an automatic retry no earlier than 10 s after the fallback. */
        const val RETRY_MS = 10_000L
        const val MAX_RETRY_MS = 60_000L

        /** The tablet draws the cursor: Günlük and Çizim with the "Tablette" setting; never in Oyun. */
        fun wishOf(mode: StreamMode, onTablet: Boolean): Boolean = onTablet && !mode.isGame
    }
}
