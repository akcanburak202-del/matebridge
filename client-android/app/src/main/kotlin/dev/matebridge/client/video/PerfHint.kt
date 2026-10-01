package dev.matebridge.client.video

/**
 * T-079 experiment (default off): one performance hint session (API 31 `PerformanceHintManager`) over the threads on
 * the frame's CPU path. Pure Kotlin; the platform is behind [Backend] (see [AndroidPerfHint]). Thread-safe.
 *
 * Threads: [ROLE_NET] (video connection reader), [ROLE_IN] (decoder input), [ROLE_OUT] (decoder output). Each one
 * [register]s its own tid when it starts and [unregister]s it when it ends. API 31 cannot change a session's threads,
 * so a session exists only while all three roles are registered and a target is known; any change to the thread set
 * closes it and builds a new one, and the stream ending (a role gone) closes it, so nothing leaks.
 *
 * Actual work: one duration per frame, from the network read that completed the frame ([onRecv]) to the return of its
 * `queueInputBuffer` ([onInput]), i.e. the trace's `input_ns - recv_ns`. One report per cycle is what the hint API
 * models; per-thread fragments would triple the samples and each would look far under target (a "slow down" signal).
 * Hardware decode time is not CPU work and is left out. The output thread is in the group but its time is not reported.
 */
class PerfHint(
    private val backend: Backend?,
    /** (event, fields) in docs/LOGGING.md form, without `ev=`. */
    private val log: (String, String) -> Unit = { _, _ -> },
) {
    interface Backend {
        /** Recommended minimum interval between reports (ns), or <= 0 when unknown. */
        val preferredUpdateRateNs: Long

        /** Null when the platform refuses (may also throw). */
        fun createSession(tids: IntArray, targetNs: Long): Session?
    }

    interface Session {
        fun updateTargetWorkDuration(targetNs: Long)
        fun reportActualWorkDuration(actualNs: Long)
        fun close()
    }

    companion object {
        const val ROLE_NET = 0
        const val ROLE_IN = 1
        const val ROLE_OUT = 2
        private const val ROLES = 3
        private const val RING = 64
        private const val MAX_REPORT_NS = 1_000_000_000L
    }

    val supported: Boolean get() = backend != null

    private val lock = Any()
    private val tids = IntArray(ROLES)
    private var targetNs = 0L
    private var fixedTarget = false
    private var session: Session? = null
    private var reports = 0L

    // seq -> receive time, written by the network thread, consumed by the input thread. Pre-allocated, own lock.
    private val ringLock = Any()
    private val ringSeq = LongArray(RING) { -1L }
    private val ringNs = LongArray(RING)

    /** True while a session is open. */
    fun hasSession(): Boolean = synchronized(lock) { session != null }

    fun targetNs(): Long = synchronized(lock) { targetNs }

    fun reportCount(): Long = synchronized(lock) { reports }

    /** Startup line fields: `supported=… session=… target_us=… rate_us=…`. */
    fun describe(): String = synchronized(lock) {
        "supported=${if (supported) 1 else 0} session=${if (session != null) 1 else 0} target_us=${targetNs / 1000} " +
            "rate_us=${(backend?.preferredUpdateRateNs ?: 0L) / 1000}"
    }

    fun register(role: Int, tid: Int) {
        synchronized(lock) {
            if (tid <= 0 || tids[role] == tid) return
            tids[role] = tid
            rebuild("threads")
        }
    }

    /** Ignored when [tid] is no longer the registered one (a newer thread of the role took over). */
    fun unregister(role: Int, tid: Int) {
        synchronized(lock) {
            if (tids[role] != tid) return
            tids[role] = 0
            rebuild("thread_gone")
        }
    }

    /**
     * Panel period (or another frame budget). Ignored after [setFixedTargetNs]. Updates the open session in place;
     * builds one if this was the missing piece.
     */
    fun setTargetNs(ns: Long) {
        synchronized(lock) { if (!fixedTarget) applyTarget(ns) }
    }

    /** Experiment override: this target from now on, regardless of [setTargetNs]. */
    fun setFixedTargetNs(ns: Long) {
        synchronized(lock) {
            fixedTarget = ns > 0
            applyTarget(ns)
        }
    }

    private fun applyTarget(ns: Long) {
        if (ns <= 0 || ns == targetNs) return
        targetNs = ns
        val s = session
        if (s == null) { rebuild("target"); return }
        try {
            s.updateTargetWorkDuration(ns)
            log("perf_hint_target", "target_us=${ns / 1000}")
        } catch (e: Exception) {
            log("perf_hint_error", "op=update err=${e.javaClass.simpleName}")
        }
    }

    /** Network thread: the read that completed frame [seq] returned at [recvNs]. */
    fun onRecv(seq: Long, recvNs: Long) {
        val i = (seq and (RING - 1).toLong()).toInt()
        synchronized(ringLock) { ringSeq[i] = seq; ringNs[i] = recvNs }
    }

    /** Input thread: `queueInputBuffer` for frame [seq] returned at [doneNs]; reports the frame's duration once. */
    fun onInput(seq: Long, doneNs: Long) {
        val i = (seq and (RING - 1).toLong()).toInt()
        val recvNs = synchronized(ringLock) {
            if (ringSeq[i] != seq) return
            ringSeq[i] = -1L
            ringNs[i]
        }
        report(doneNs - recvNs)
    }

    /** One actual work duration; dropped when no session is open or the value is not plausible. */
    fun report(actualNs: Long) {
        synchronized(lock) {
            val s = session ?: return
            if (actualNs <= 0 || actualNs > MAX_REPORT_NS) return
            try {
                s.reportActualWorkDuration(actualNs)
                reports++
            } catch (e: Exception) {
                log("perf_hint_error", "op=report err=${e.javaClass.simpleName}")
            }
        }
    }

    /** Closes the session for good (activity gone); later registrations build a new one. */
    fun close() {
        synchronized(lock) {
            tids.fill(0)
            rebuild("close")
        }
    }

    private fun rebuild(cause: String) {
        val old = session
        if (old != null) {
            session = null
            try { old.close() } catch (_: Exception) {}
            log("perf_hint", "supported=1 session=0 target_us=${targetNs / 1000} threads=${threadCount()} cause=$cause reports=$reports")
        }
        val b = backend ?: return
        if (targetNs <= 0 || tids.any { it == 0 }) return
        val s = try {
            b.createSession(tids.copyOf(), targetNs)
        } catch (e: Exception) {
            log("perf_hint_error", "op=create err=${e.javaClass.simpleName}")
            null
        }
        session = s
        reports = 0
        log("perf_hint", "supported=1 session=${if (s != null) 1 else 0} target_us=${targetNs / 1000} threads=${threadCount()} cause=$cause")
    }

    private fun threadCount() = tids.count { it != 0 }
}
