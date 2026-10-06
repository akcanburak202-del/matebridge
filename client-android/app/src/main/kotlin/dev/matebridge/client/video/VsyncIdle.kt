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
 * T-141 (review P2): the first decoded frame after a vsync-loop sleep is presented at once, whatever happened to the
 * clock meanwhile. Clearing the clock alone is not enough: the woken loop (a frame or pointer input wakes it) may deliver
 * a vsync before the frame is decoded, and the frame would then be paced on the fresh grid (one more panel period with
 * a buffer). Armed by the loop when it falls asleep, taken by the first output. Thread-safe.
 */
class FirstOutputBypass {
    private val armed = AtomicBoolean(false)

    /** The loop fell asleep: the next output goes out at once. */
    fun arm() = armed.set(true)

    /** Streaming (re)starts: nothing pending. */
    fun disarm() = armed.set(false)

    val isArmed: Boolean get() = armed.get()

    /** Output thread, per decoded frame: true exactly once after [arm] (present this one now). */
    fun take(): Boolean = armed.getAndSet(false)

    /**
     * The presentation decision for one decoded frame: null (release now, as without a vsync sample) when this is the
     * first output after a sleep, else [schedule]. The pacer does not see a bypassed frame.
     */
    inline fun schedule(schedule: () -> FramePacer.Decision?): FramePacer.Decision? = if (take()) null else schedule()
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

/**
 * T-286 (dev knob `dec_wait`): how the decoder's input thread waits while nothing is happening. The output thread always
 * keeps the fixed poll ([IdleWait] after 300 ms without an output): the long idle `dequeueOutputBuffer` wait of the
 * dropped `event` arm added ~1.5 ms to `cap_dec` on the device (A/B 2026-10-07) and is gone.
 *
 * [EVENT_IN] (default, adopted after the device A/B: ~958 -> ~690 decoder wake-ups/s and ~34.3% -> ~31% client CPU at
 * 10 fps, `cap_dec` within noise) = the input thread parks until a frame, a retire or an output error (see
 * [DecoderWaits]). [POLL] = the pre-T-286 fixed 4 ms input timeout ([IdleWait] after 300 ms without a frame); kept
 * selectable as a fallback for one cycle and will be removed later.
 */
enum class DecoderWait(val id: String, val parksInput: Boolean) {
    EVENT_IN("event_in", parksInput = true),

    /** Fallback for one cycle only; will be removed (T-286 adoption). */
    POLL("poll", parksInput = false);

    companion object {
        val IDS: Set<String> = values().map { it.id }.toSet()
        val DEFAULT: DecoderWait = EVENT_IN

        /** Absent or unknown (including the removed `event`) = [DEFAULT]. */
        fun parse(raw: String?): DecoderWait =
            values().firstOrNull { it.id == raw?.trim()?.lowercase(java.util.Locale.ROOT) } ?: DEFAULT
    }
}

/**
 * T-286: the wait policy of the two decoder threads. Pure; thread-safe (no state).
 *
 * Input thread ([inputWaitNs], `FrameQueue.awaitNext`): a frame arriving ([FrameQueue.offer] unparks), a retire/revoke
 * and an output-thread error ([FrameQueue.nudge], checked through `abort`) all wake it at once, so in
 * [DecoderWait.EVENT_IN] the timeout is only a safety net against a wake-up nobody thought of ([EVENT_INPUT_WAIT_NS]).
 *
 * Output thread ([outputWaitUs], `dequeueOutputBuffer`): an output ends the wait at once, but nothing can wake a
 * blocked `dequeueOutputBuffer` for a stop, so a short timeout stays and bounds the stop latency.
 */
object DecoderWaits {
    /** Safety net of the input thread's park in [DecoderWait.EVENT_IN]. */
    const val EVENT_INPUT_WAIT_NS = 250_000_000L

    fun inputWaitNs(mode: DecoderWait, sinceLastFrameNs: Long, pollNs: Long): Long =
        if (mode.parksInput) EVENT_INPUT_WAIT_NS else IdleWait.waitNs(sinceLastFrameNs, pollNs)

    /**
     * Longest `dequeueOutputBuffer` wait, in microseconds: [pollUs] ([IdleWait] after 300 ms without an output), shortened
     * by the held buffer's deadline ([untilDeadlineNs], null = none held), never lengthened by it.
     */
    fun outputWaitUs(sinceLastOutputNs: Long, pollUs: Long, untilDeadlineNs: Long?): Long {
        val poll = IdleWait.waitNs(sinceLastOutputNs, pollUs * 1000) / 1000
        return if (untilDeadlineNs == null) poll else (untilDeadlineNs / 1000).coerceIn(0, poll)
    }
}
