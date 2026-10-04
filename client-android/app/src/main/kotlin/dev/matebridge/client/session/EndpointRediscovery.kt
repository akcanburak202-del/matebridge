package dev.matebridge.client.session

/**
 * T-227: find the Mac again when its stored address stops answering (Mac moved from Wi-Fi to Ethernet, DHCP renewal,
 * restart). NSD reports a service only once per discovery run, and the instance name stays the same when only the
 * address changes, so a long-running [MacDiscovery] never reports the new address (NOTES 2026-10-04 ~22:15). After
 * [FAIL_LIMIT] consecutive drops of the session's endpoint (or [FAIL_AFTER_MS] since it first dropped) discovery is
 * restarted, then again every [RESTART_GAP_MS] doubling to [RESTART_GAP_MAX_MS] while the session stays down.
 *
 * The rediscovery runs *next to* the session machine's own retries of the stored address and the T-134 wake attempts:
 * it never stops them (a sleeping Mac may be absent from Bonjour but still wakes on a direct connect). A newly found
 * address is tried at once ([Pick.CONNECT]). Every automatic start during an episode carries [expectedHost] (the
 * [HostTag] of the last authenticated session), and the session machine refuses any other host at its first answer
 * ([SessionUi.Cause.WRONG_HOST], before HELLO_ACK, so nothing is ever enabled for it). Such an address, or a terminal
 * failure at the candidate (an impostor), is [Verdict.Foreign]: it is skipped for the rest of the episode and the caller
 * returns to the old address. A candidate that cannot be reached is [Verdict.Unreachable] (back to the old address too).
 *
 * Pure and clock-injected; main thread only.
 */
class EndpointRediscovery(
    private val failLimit: Int = FAIL_LIMIT,
    private val failAfterMs: Long = FAIL_AFTER_MS,
    private val firstGapMs: Long = RESTART_GAP_MS,
    private val maxGapMs: Long = RESTART_GAP_MAX_MS,
) {
    /** What [onUi] concluded about a candidate address. The caller logs it and, unless [None]/[Accepted], reconnects to [old]. */
    sealed interface Verdict {
        data object None : Verdict
        /** The candidate is the same host: it is the session's address from now on (update the stored endpoint). */
        data class Accepted(val old: Endpoint, val new: Endpoint) : Verdict
        /** Another host (or an impostor) answered at [foreign]: reconnect to [old]; [foreign] is skipped this episode. */
        data class Foreign(val old: Endpoint, val foreign: Endpoint) : Verdict
        /** The candidate did not answer: reconnect to [old] (a later restart may offer it again). */
        data class Unreachable(val old: Endpoint, val candidate: Endpoint) : Verdict
    }

    /** What to do with a discovered endpoint ([onDiscovered]). */
    enum class Pick {
        /** Connect to it now (it is a new address for the failing host, a candidate). */
        CONNECT,
        /** Never connect to it automatically: it answered as another host in this episode. */
        SKIP,
        /** Not a rediscovery matter: the usual discovery rules decide. */
        DEFAULT,
    }

    /** Identity of the last authenticated session (null: none seen yet) and its endpoint. Survive [reset]. */
    private var known: HostTag? = null
    private var knownEp: Endpoint? = null

    /** Endpoint whose consecutive drops are counted (null: the session is not failing). */
    private var streakEp: Endpoint? = null
    /** Consecutive drops of [streakEp]. */
    var failures = 0
        private set
    private var downSinceMs = -1L
    /** The last state seen was a drop (so a repeated render of it does not count twice). */
    private var down = false

    /** A rediscovery episode runs: discovery was restarted at least once and the session has not come back since. */
    var active = false
        private set
    /** Restarts in the current (or last) episode. */
    var restarts = 0
        private set
    private var nextRestartAtMs = 0L
    private var gapMs = firstGapMs
    /** The address that stopped answering (the episode's stored address). */
    var old: Endpoint? = null
        private set
    /** The new address being tried (null: none). */
    var candidate: Endpoint? = null
        private set
    /**
     * The session to [candidate] has been seen connecting. Until then a state is a late one of the old session (the
     * controller hops threads), so it settles nothing about the candidate.
     */
    private var candidateStarted = false
    private val foreign = HashSet<Endpoint>()

    /**
     * One rendered session state. [current]: the endpoint the app's session uses (null: none chosen). Returns the verdict
     * on a candidate, if this state settles one.
     */
    fun onUi(state: SessionUi, current: Endpoint?, nowMs: Long): Verdict {
        if (candidate != null && candidate != current) dropCandidate() // someone else replaced the candidate's session
        // A terminal state of a superseded start (its address is not the session's any more; review 3 #1) settles nothing.
        if (state is SessionUi.Failed && state.endpoint != null && state.endpoint != current) return Verdict.None
        if (state is SessionUi.Failed && state.cause == SessionUi.Cause.WRONG_HOST) return onWrongHost(state.endpoint, current, nowMs)
        if (candidate != null && !candidateStarted) {
            if (state is SessionUi.Connecting && state.endpoint == candidate) {
                candidateStarted = true
            } else if (state is SessionUi.Failed && state.endpoint == candidate) {
                candidateStarted = true // the candidate's own start ended before connecting (a latch): judged below
            } else if (state is SessionUi.StoredTrust || state is SessionUi.Failed) {
                // The candidate's start may end like this without connecting (an unresolved pairing, a latch). It cannot
                // be told from a late state of the old session: stop tracking; the machine's host gate still holds.
                dropCandidate()
                clearStreak()
                return Verdict.None
            } else {
                // A late state of the old session (the controller hops threads; review #2): settles nothing.
                return Verdict.None
            }
        }
        val cand = candidate // non-null only once its session was seen connecting
        when (state) {
            is SessionUi.Connected -> {
                clearStreak() // reachable
                val tag = state.hostTag ?: return Verdict.None // not authenticated yet: wait for it
                if (cand != null) {
                    val o = old ?: cand
                    val k = known
                    // Defence in depth: the machine's host gate already refused another host before its HELLO_ACK.
                    if (k != null && tag != k) return foreignVerdict(o, cand)
                    learn(tag, cand)
                    endEpisode()
                    return Verdict.Accepted(o, cand)
                }
                if (current != null) learn(tag, current)
                endEpisode() // the session works again: no more rediscovery
            }
            is SessionUi.Disconnected -> {
                if (current == null) return Verdict.None
                if (current != streakEp) startStreak(current)
                if (!down) {
                    down = true
                    failures++
                    if (downSinceMs < 0) downSinceMs = nowMs
                }
                if (cand != null) {
                    dropCandidate()
                    clearStreak()
                    return Verdict.Unreachable(old ?: cand, cand)
                }
            }
            is SessionUi.Connecting -> {
                if (current != null && current != streakEp && streakEp != null) startStreak(current)
                down = false
            }
            is SessionUi.Failed -> {
                clearStreak() // the session ended for good: not an address problem
                if (cand != null) return foreignVerdict(old ?: cand, cand) // e.g. KEY_MISMATCH: an impostor of our host
            }
            is SessionUi.PairingNeedsUser -> {
                // Past the host gate this is our own host asking to pair again (it forgot the tablet): the usual prompt.
                clearStreak()
                dropCandidate()
            }
            else -> clearStreak() // Idle, Searching, pairing prompts: nothing is being retried
        }
        return Verdict.None
    }

    /**
     * The host every automatic start must reach during an episode (null: no episode, or no host authenticated yet in
     * this process). The caller passes it to `SessionController.start` (expectHost), so the session machine refuses
     * another host at its first answer, before any HELLO_ACK: nothing (clipboard, files, input) is ever enabled for it.
     */
    fun expectedHost(): HostTag? = if (active) known else null

    /**
     * The machine refused the host at [refused] ([SessionUi.Cause.WRONG_HOST]): another Mac, or a Mac asking to pair, at
     * that address. It is skipped for the rest of the episode; the caller goes back to the old address (or, when the
     * episode already ended, to the address of the last authenticated session). A refusal of a superseded start (its
     * address is no longer the session's, review 2 #2) settles nothing: the next address must not be blamed for it.
     * Refused at the old address itself: there is no address to go back to, so the episode goes on as if that address
     * kept failing (discovery restarts, and a new address of our host is connected to from this state, [onDiscovered]).
     */
    private fun onWrongHost(refused: Endpoint?, current: Endpoint?, nowMs: Long): Verdict {
        if (refused == null || refused != current) return Verdict.None
        dropCandidate()
        foreign += refused
        val back = old ?: knownEp
        if (back != null && back != refused) {
            clearStreak()
            return Verdict.Foreign(back, refused)
        }
        startStreak(refused)
        failures = failLimit
        downSinceMs = nowMs
        down = true
        return Verdict.None
    }

    private fun learn(tag: HostTag, ep: Endpoint) {
        known = tag
        knownEp = ep
    }

    /**
     * Whether to restart NSD discovery now. [eligible]: the app searches the Mac by Wi-Fi discovery (Wi-Fi or AUTO on
     * Wi-Fi, not a typed address, not USB, not after "Bağlantıyı kes", not while the Mac said HOST_SLEEP, started).
     */
    fun shouldRestart(nowMs: Long, eligible: Boolean): Boolean {
        if (!eligible || streakEp == null || candidate != null) return false
        val due = failures >= failLimit || (downSinceMs >= 0 && nowMs - downSinceMs >= failAfterMs)
        if (!due) return false
        if (active && nowMs < nextRestartAtMs) return false
        if (!active) {
            active = true
            restarts = 0
            old = streakEp
            gapMs = firstGapMs
        }
        restarts++
        nextRestartAtMs = nowMs + gapMs
        gapMs = minOf(gapMs * 2, maxGapMs)
        return true
    }

    /** `reason=` of the latest restart: enough consecutive drops, or down for [failAfterMs]. */
    fun restartReason(): String = if (failures >= failLimit) REASON_CONNECT_FAILED else REASON_DOWN_TIME

    /**
     * Discovery reported [ep]. During an episode a new address is a candidate and is connected to at once, also while the
     * session is still connecting to the old address (NSD reports it once; it must not be lost to that connect's timeout).
     * [ui]: the last rendered state, [current]: the session's endpoint.
     */
    fun onDiscovered(ep: Endpoint, current: Endpoint?, ui: SessionUi?): Pick {
        if (!active) return Pick.DEFAULT
        if (ep in foreign) return Pick.SKIP
        val o = old ?: return Pick.DEFAULT
        if (ep == o || ep == current) return Pick.DEFAULT // the same address: nothing new
        val retrying = ui is SessionUi.Disconnected || (ui is SessionUi.Connecting && ui.endpoint == current) ||
            (ui is SessionUi.Failed && ui.cause == SessionUi.Cause.WRONG_HOST) // refused at the old address: stuck otherwise
        if (!retrying || current == null) return Pick.DEFAULT // connected, prompting, or nothing chosen: usual rules
        candidate = ep
        candidateStarted = false
        return Pick.CONNECT
    }

    /** [onDiscovered] picked [ep], but the caller will not connect to it (e.g. it answered PAIRING before, T-151). */
    fun forgetCandidate(ep: Endpoint) {
        if (candidate == ep) dropCandidate()
    }

    /** [ep] answered as another host in this episode: no automatic start goes there (T-151's pick fallback included). */
    fun isSkipped(ep: Endpoint): Boolean = active && ep in foreign

    /**
     * The user started a connection themselves ("Bağlan", a typed address, "Eşleş", …): the episode is over (review 3 #2),
     * so the host they picked is never judged against the old one and the app never jumps back to the old address.
     */
    fun onUserStart() = reset()

    /** The transport was applied again, the activity stopped, or the user disconnected: forget the episode (not [known]). */
    fun reset() {
        clearStreak()
        endEpisode()
    }

    private fun foreignVerdict(o: Endpoint, cand: Endpoint): Verdict {
        foreign += cand
        dropCandidate()
        clearStreak()
        return Verdict.Foreign(o, cand)
    }

    private fun dropCandidate() {
        candidate = null
        candidateStarted = false
    }

    private fun startStreak(ep: Endpoint) {
        streakEp = ep
        failures = 0
        downSinceMs = -1L
        down = false
    }

    private fun clearStreak() {
        streakEp = null
        failures = 0
        downSinceMs = -1L
        down = false
    }

    private fun endEpisode() {
        active = false
        dropCandidate()
        old = null
        foreign.clear()
        nextRestartAtMs = 0L
        gapMs = firstGapMs
    }

    companion object {
        /** Consecutive drops of the stored address before discovery restarts (the drop itself plus one failed retry). */
        const val FAIL_LIMIT = 2
        /** ... or this long since the session first dropped, whichever comes first. */
        const val FAIL_AFTER_MS = 4_000L
        /** Pause before the next restart while the session stays down; doubles up to [RESTART_GAP_MAX_MS]. */
        const val RESTART_GAP_MS = 8_000L
        const val RESTART_GAP_MAX_MS = 30_000L

        const val REASON_CONNECT_FAILED = "connect_failed"
        const val REASON_DOWN_TIME = "down_time"

        const val RESULT_ACCEPTED = "accepted"
        const val RESULT_FOREIGN = "foreign"
        const val RESULT_UNREACHABLE = "unreachable"

        /**
         * An address for the log: only the last IPv4 octet (`*.107`), so a shared log does not carry the LAN layout
         * (NOTES 2026-10-04, `migrate_request`). Anything else (a DNS name, IPv6) is `*`.
         */
        fun octet(ep: Endpoint?): String {
            val h = ep?.host ?: return "-"
            val parts = h.split('.')
            val ipv4 = parts.size == 4 && parts.all { p -> p.isNotEmpty() && p.length <= 3 && p.all { it in '0'..'9' } }
            return if (ipv4) "*.${parts[3]}" else "*"
        }

        /** `ev=endpoint_rediscover_result` fields for [v] (null for [Verdict.None]). */
        fun resultFields(v: Verdict): String? = when (v) {
            Verdict.None -> null
            is Verdict.Accepted -> "result=$RESULT_ACCEPTED old=${octet(v.old)} new=${octet(v.new)}"
            is Verdict.Foreign -> "result=$RESULT_FOREIGN old=${octet(v.old)} new=${octet(v.foreign)}"
            is Verdict.Unreachable -> "result=$RESULT_UNREACHABLE old=${octet(v.old)} new=${octet(v.candidate)}"
        }
    }
}
