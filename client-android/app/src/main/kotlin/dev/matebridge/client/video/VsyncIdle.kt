package dev.matebridge.client.video

import java.util.concurrent.atomic.AtomicBoolean

/**
 * T-141: lets a vsync-driven loop (the activity's Choreographer loop, the GL presenter's) sleep while no video frame
 * arrives, and wakes it on the next one. Pure logic, clock passed in (System.nanoTime domain).
 *
 * Threads: [onActivity] from any thread (video reader, input, GL frame-available); everything else on the loop's own
 * thread. While asleep the loop does not re-register its vsync callback; [onActivity] returns true exactly once per
 * sleep, and the caller then gets the loop thread to call [wake] (a post, or directly when already on it).
 *
 * No lost wake-up: [onActivity] writes the activity time and then reads the sleep flag; [onVsync] sets the sleep flag
 * and then re-reads the activity time. With volatile/atomic accesses at least one side sees the other's write, so a frame
 * that races with falling asleep either keeps the loop running or posts a wake.
 *
 * Idle threshold [DEFAULT_IDLE_AFTER_NS] = 300 ms: any stream of >= 10 fps has gaps <= 100 ms, so a running stream never
 * sleeps (3x margin); the macOS text caret (about 0.5 s per phase) still lets the loop sleep between blinks; decode plus
 * slot of the last frame (< 60 ms) is far inside it, so the clock is never dropped under a frame still being paced.
 */
class VsyncIdleGate(
    private val idleAfterNs: Long = DEFAULT_IDLE_AFTER_NS,
    /** An `idle state=on` log line is due once the loop has slept this long (short sleeps are not logged). */
    private val logAfterNs: Long = DEFAULT_LOG_AFTER_NS,
) {
    companion object {
        const val DEFAULT_IDLE_AFTER_NS = 300_000_000L
        const val DEFAULT_LOG_AFTER_NS = 1_000_000_000L
        /**
         * Vsyncs a woken clock must see before its rate is reported again: [VsyncClock] re-seeds a changed period after
         * [VsyncClock.RESEED_AFTER] odd gaps, and the first callback after a reset only sets the phase.
         */
        const val RATE_VSYNCS_AFTER_WAKE = VsyncClock.RESEED_AFTER + 1
    }

    /** Result of a [wake] that ended a sleep. */
    class Woke(
        /** How long the loop slept (ns). */
        val sleptNs: Long,
        /** True when `idle state=on` was logged for this sleep (so `state=off` belongs to it). */
        val idleLogged: Boolean,
    )

    @Volatile private var lastActivityNs = 0L
    private val asleep = AtomicBoolean(false)
    private val wakePosted = AtomicBoolean(false)

    // Loop thread only.
    private var asleepSinceNs = 0L
    private var idleLogged = false
    private var vsyncsSinceWake = RATE_VSYNCS_AFTER_WAKE

    val isAsleep: Boolean get() = asleep.get()

    /** Nanoseconds since the last activity (frame or input). */
    fun sinceActivityNs(nowNs: Long): Long = nowNs - lastActivityNs

    /** Loop thread: the loop (re)starts from scratch (streaming began). Awake, rate reports allowed at once. */
    fun start(nowNs: Long) {
        lastActivityNs = nowNs
        asleep.set(false)
        wakePosted.set(false)
        idleLogged = false
        vsyncsSinceWake = RATE_VSYNCS_AFTER_WAKE
    }

    /** Loop thread: the loop stopped for good (streaming ended); no wake is requested until [start]. */
    fun stop() {
        asleep.set(false)
        wakePosted.set(false)
        idleLogged = false
    }

    /**
     * Any thread: a frame or an input event arrived at [nowNs]. Returns true when the loop is asleep and no wake was
     * requested yet for this sleep: the caller must then make the loop thread call [wake].
     */
    fun onActivity(nowNs: Long): Boolean {
        lastActivityNs = nowNs
        return asleep.get() && wakePosted.compareAndSet(false, true)
    }

    /** Loop thread, once per vsync callback: true = keep running (re-register), false = the loop is asleep now. */
    fun onVsync(nowNs: Long): Boolean {
        if (vsyncsSinceWake < RATE_VSYNCS_AFTER_WAKE) vsyncsSinceWake++
        if (nowNs - lastActivityNs < idleAfterNs) return true
        wakePosted.set(false)
        asleep.set(true)
        if (nowNs - lastActivityNs < idleAfterNs) { // an activity raced with falling asleep: stay awake
            asleep.set(false)
            return true
        }
        asleepSinceNs = nowNs
        idleLogged = false
        return false
    }

    /** Loop thread: ends a sleep. Null when the loop was not asleep (nothing to restart). */
    fun wake(nowNs: Long): Woke? {
        wakePosted.set(false)
        if (!asleep.getAndSet(false)) return null
        vsyncsSinceWake = 0
        val w = Woke(nowNs - asleepSinceNs, idleLogged)
        idleLogged = false
        return w
    }

    /** Loop thread: true once per sleep when it has lasted [logAfterNs] (time for an `idle state=on` line). */
    fun idleLogDue(nowNs: Long): Boolean {
        if (!asleep.get() || idleLogged || nowNs - asleepSinceNs < logAfterNs) return false
        idleLogged = true
        return true
    }

    /** Loop thread: false right after a wake until the clock has seen [RATE_VSYNCS_AFTER_WAKE] fresh vsyncs. */
    val rateReady: Boolean get() = !asleep.get() && vsyncsSinceWake >= RATE_VSYNCS_AFTER_WAKE
}

/**
 * T-141: blocking waits of the decoder threads. Their timeouts only bound how fast a thread notices a stop (a frame or
 * an output wakes them at once), so after [idleAfterNs] without one they wait [IDLE_WAIT_NS] instead of the busy value.
 */
object IdleWait {
    const val IDLE_WAIT_NS = 20_000_000L

    /** Wait to use [sinceLastNs] after the last frame/output; [busyNs] while the stream flows. */
    fun waitNs(sinceLastNs: Long, busyNs: Long, idleAfterNs: Long = VsyncIdleGate.DEFAULT_IDLE_AFTER_NS): Long =
        if (sinceLastNs >= idleAfterNs) maxOf(busyNs, IDLE_WAIT_NS) else busyNs
}
