package dev.matebridge.client.session

import java.io.IOException
import java.net.ConnectException
import java.net.SocketTimeoutException

/**
 * T-134: waking the Mac by a direct connect. Magic packets do not wake this Mac over Wi-Fi and ICMP is answered by the
 * sleeping Wi-Fi chip, but a TCP connect to the host's listening control port dark-wakes it within a second (NOTES
 * 2026-10-02 ~15:05). While a T-129 wake episode runs, the tablet therefore also opens an ordinary session (HELLO,
 * [SessionMachine]) to the stored host IPv4 and control port; once it connects, the normal flow goes on and the episode
 * ends as `connected`. Discovery keeps running: whichever finds the Mac first is used, and never two connections.
 *
 * Pure and clock-injected; main thread only. Each [Step.Attempt] is one connect (Wi-Fi-bound, [CONNECT_TIMEOUT_MS]);
 * the next one waits for its result and then [GAP_MS]. Nothing is attempted outside an episode (the episode itself
 * never runs in the background, after "Bağlantıyı kes" or while the Mac said HOST_SLEEP: [WakePlanner]).
 */
class WakeConnect(
    private val gapMs: Long = GAP_MS,
    private val staleMs: Long = STALE_MS,
) {
    sealed interface Step {
        data object None : Step
        /** Start direct wake attempt [n] of this episode to [endpoint] (`SessionController.start(endpoint, n)`). */
        data class Attempt(val n: Int, val endpoint: Endpoint) : Step
        /** The episode is over and our failed attempt still holds the session: forget its endpoint ("Mac aranıyor…"). */
        data object Release : Step
    }

    /** A wake episode is running (as last seen by [update]). */
    var episode = false
        private set
    /** Attempts started in the current (or last) episode; the next one is number [attempts] + 1. */
    var attempts = 0
        private set
    /** The attempt whose connect result is awaited (0 = none). It may outlive its episode by up to a connect timeout. */
    var inFlight = 0
        private set
    private var inFlightSinceMs = 0L
    private var nextAtMs = 0L
    /** No more attempts this episode: one connected, or discovery found the Mac first. */
    var settled = false
        private set
    /** The endpoint our latest attempt started; the session on it is ours until it connects (then it is adopted). */
    var owned: Endpoint? = null
        private set

    /**
     * One step. [episodeActive]: [WakePlanner.active]. [target]: the stored wake endpoint ([WolStore.wakeEndpoint]).
     * [current]: the endpoint the app's session uses (null: none chosen, e.g. Wi-Fi discovery still searching).
     * [transportOk]: see [transportAllows]. [sessionIdle]: the session is not connecting or up (Idle, Searching,
     * Disconnected), i.e. our last attempt finished.
     */
    fun update(
        nowMs: Long, episodeActive: Boolean, target: Endpoint?, current: Endpoint?, transportOk: Boolean, sessionIdle: Boolean,
    ): Step {
        if (inFlight != 0 && nowMs - inFlightSinceMs >= staleMs) {
            inFlight = 0 // its result never came (e.g. the start was superseded before it ran): do not wait forever
            nextAtMs = nowMs
        }
        if (owned != null && current != owned) owned = null // someone else's session now (discovery, USB, a mode change)
        if (!episodeActive) {
            episode = false
            val o = owned
            if (o != null && inFlight == 0 && sessionIdle) {
                owned = null
                return Step.Release
            }
            return Step.None
        }
        if (!episode) {
            episode = true
            attempts = 0
            settled = false
            nextAtMs = nowMs
        }
        if (settled || inFlight != 0 || target == null || !transportOk || nowMs < nextAtMs) return Step.None
        val free = current == null || (current == owned && sessionIdle)
        if (!free) return Step.None
        attempts++
        inFlight = attempts
        inFlightSinceMs = nowMs
        owned = target
        return Step.Attempt(attempts, target)
    }

    /**
     * The connect of attempt [n] finished. [ok]: connected; the session is now an ordinary one (adopted, no longer
     * [owned]) and no further attempt runs in this episode. Returns the adopted endpoint, or null (failed, stale result
     * for another attempt, or the session was taken over meanwhile).
     */
    fun onResult(n: Int, ok: Boolean, nowMs: Long): Endpoint? {
        if (n == 0 || n != inFlight) return null
        inFlight = 0
        if (!ok) {
            nextAtMs = nowMs + gapMs
            return null
        }
        if (episode) settled = true
        val adopted = owned
        owned = null
        return adopted
    }

    /** An ordinary start (discovery, USB, "Bağlan", a typed address) replaced the session: it is not ours any more. */
    fun disown() {
        owned = null
    }

    /**
     * Discovery found the Mac at some endpoint. Returns whether to connect to it: always when our wake attempt holds the
     * session (the new start closes it first, so there is one connection), otherwise as before: when nothing is chosen
     * yet or the session waits to retry ([disconnected]). In an episode no further direct attempt runs after this.
     */
    fun onDiscovered(current: Endpoint?, disconnected: Boolean): Boolean {
        if (episode) settled = true
        if (owned != null && current == owned) {
            owned = null
            return true
        }
        return current == null || disconnected
    }

    companion object {
        /** Connect timeout of one direct attempt (the measured wake connect took 435 ms). */
        const val CONNECT_TIMEOUT_MS = 3_000
        /** Pause between a failed attempt and the next one. */
        const val GAP_MS = 2_000L
        /** A result that has not come after this is given up on. */
        const val STALE_MS = CONNECT_TIMEOUT_MS + 2_000L

        const val RESULT_OK = "ok"
        const val RESULT_TIMEOUT = "timeout"
        const val RESULT_REFUSED = "refused"
        const val RESULT_ERROR = "error"

        /**
         * Direct attempts run only where the session would go over Wi-Fi: not in USB mode, not while the session is on
         * USB, and not while AUTO is still picking or falling back (its USB probe decides first).
         */
        fun transportAllows(mode: TransportMode, onUsb: Boolean, autoBusy: Boolean): Boolean =
            mode != TransportMode.USB && !onUsb && !autoBusy

        /** `ev=wake_connect result=` for a connect that ended with [e] (null: connected). */
        fun classify(e: IOException?): String = when {
            e == null -> RESULT_OK
            e is SocketTimeoutException -> RESULT_TIMEOUT
            e is ConnectException && e.message.orEmpty().let { it.contains("ECONNREFUSED") || it.contains("refused", ignoreCase = true) } ->
                RESULT_REFUSED
            else -> RESULT_ERROR
        }

        /** `err=` for an [RESULT_ERROR] (class name only, never the message: it carries the address). */
        fun errName(e: IOException): String = if (e is NoWifiException) "no_wifi" else e.javaClass.simpleName
    }

    /** No Wi-Fi network to bind the attempt's socket to: it fails without connecting. */
    class NoWifiException : IOException("no Wi-Fi network")
}
