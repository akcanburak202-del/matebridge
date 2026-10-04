package dev.matebridge.client.video

/**
 * T-159: why the video is not healthy (decision 0019). `stuck` is reported by T-161. T-218: `video_lost` is reported by
 * the session (the video connection ended while streaming), not by the renderer.
 */
enum class FaultCause(val logName: String) {
    GIVE_UP("give_up"),
    NO_OUTPUT("no_output"),
    NOT_RUNNING("not_running"),
    STUCK("stuck"),
    VIDEO_LOST("video_lost"),
}

/**
 * T-159: what the renderer reports through its single `onHealthEvent` callback. Every event names the renderer
 * generation it belongs to; [VideoHealth] ignores events of any generation but the current one.
 *
 * A generation is one `attachSurface` / `reconfigure` / `restartCodec` call. A codec restart after `decode_error`
 * inside the same generation reports nothing (it is not a new generation).
 */
sealed class HealthEvent {
    abstract val gen: Int

    /** A generation began; delivered synchronously on the UI thread, before its decoder thread starts. */
    data class Generation(override val gen: Int) : HealthEvent()
    /** The surface was detached (no video until the next [Generation]). */
    data class Detached(override val gen: Int) : HealthEvent()
    /** The generation's decoder thread passed the hand-off and runs its codec loop. */
    data class Running(override val gen: Int) : HealthEvent()
    /** The generation's decoder thread exited. */
    data class Exited(override val gen: Int) : HealthEvent()
    /** The generation's first decoded (non-config) output was dequeued. */
    data class FirstOutput(override val gen: Int) : HealthEvent()
    /** A fault detected by the renderer (give-up; T-161: stuck hand-off). */
    data class Fault(override val gen: Int, val cause: FaultCause) : HealthEvent()
}

/**
 * T-159: decode progress of the current generation, written by the decoder threads on every input and output (one
 * uncontended lock, no UI post per frame) and read by [VideoHealth.tick]. Only non-config inputs count, and only those
 * queued since the last output; the time of the oldest of them anchors the no-output rule, so a long static screen
 * followed by a burst does not count the idle time.
 */
class DecodeProgress {
    class Snapshot(val gen: Int, val pending: Int, val oldestPendingMs: Long)

    private var gen = -1
    private var pending = 0
    private var oldestMs = 0L
    private var outputs = 0L

    /** A new generation: nothing pending, no output yet. */
    @Synchronized fun begin(gen: Int) {
        this.gen = gen; pending = 0; oldestMs = 0; outputs = 0
    }

    /** A non-config input was queued to the codec of [gen]. */
    @Synchronized fun onInput(gen: Int, nowMs: Long) {
        if (gen != this.gen) return
        if (pending == 0) oldestMs = nowMs
        pending++
    }

    /** A decoded frame of [gen] was dequeued. True for the generation's first one. */
    @Synchronized fun onOutput(gen: Int): Boolean {
        if (gen != this.gen) return false
        pending = 0
        return outputs++ == 0L
    }

    @Synchronized fun snapshot() = Snapshot(gen, pending, oldestMs)
}

/**
 * T-159 (decision 0019): video health as explicit client state. Input capture is live only while [inputAllowed]
 * (HEALTHY = surface attached, the current generation produced a decoded output, no fault). UI thread only; time comes
 * from [clock] (`SystemClock.elapsedRealtime` in the app, the same base as the decoder's [DecodeProgress] stamps).
 *
 * - A new generation is STARTING (input closed) until its first decoded output.
 * - FAULT causes: renderer give-up, no output while >= [NO_OUTPUT_MIN_INPUTS] inputs are pending and the oldest was
 *   queued >= [NO_OUTPUT_MS] ago, decoder thread not running [NOT_RUNNING_MS] after the generation began, `stuck`
 *   (T-161). The rules apply in STARTING and HEALTHY. A static screen (no inputs) is never a fault.
 * - FAULT is left only by a new generation, so input never re-opens before that generation's first decoded output.
 *   Outputs of the faulted generation are ignored.
 * - Recovery ladder: an episode starts at the first fault and ends after [EPISODE_END_HEALTHY_MS] continuously HEALTHY.
 *   Within it the steps run in order, each [STEP_GAPS_MS] after the previous one (or after the fault / re-attach),
 *   only while not HEALTHY and a surface is attached: codec restart (+1 s), codec restart (+3 s), session reconnect
 *   (+6 s), then manual ([manual], "Yeniden dene"). Steps never repeat within an episode; [retry] is the user's.
 * - T-218 video loss: [videoLost] (the session's video connection ended) faults at once with `video_lost`. The decoder
 *   keeps the last picture and gets no input, so no timer rule would ever fire. [videoFlowing] (a new video connection
 *   delivered its first frame) then asks for a codec restart. The restart starts a new generation, so input re-opens
 *   only at a decoded output of video sent after the loss. Resumes are bounded ([MAX_RESUMES] per episode) and never
 *   move the ladder, which runs on its own schedule while the video stays away or keeps half-reconnecting.
 */
class VideoHealth(
    private val clock: () -> Long,
    /** One log line: level ('I' / 'W'), event, fields. */
    private val log: (Char, String, String) -> Unit = { _, _, _ -> },
    /** State, [manual] or [showOverlay] may have changed. */
    private val onChange: () -> Unit = {},
) {
    enum class State(val logName: String) { IDLE("idle"), STARTING("starting"), HEALTHY("healthy"), FAULT("fault") }

    /** What the caller must do for a recovery step. */
    enum class Action { RESTART_CODEC, RECONNECT }

    private enum class Step(val logName: String) { RESTART("restart"), RECONNECT("reconnect"), MANUAL("manual") }

    companion object {
        const val NO_OUTPUT_MIN_INPUTS = 3
        const val NO_OUTPUT_MS = 1500L
        const val NOT_RUNNING_MS = 2000L
        const val EPISODE_END_HEALTHY_MS = 10_000L
        /** T-218: codec restarts on fresh video ([videoFlowing]) per recovery episode, besides the ladder's steps. */
        const val MAX_RESUMES = 3
        private val STEPS = arrayOf(Step.RESTART, Step.RESTART, Step.RECONNECT, Step.MANUAL)
        /** Gap before each step: restart at +1 s, restart at +3 s, reconnect at +6 s, manual at +15 s. */
        val STEP_GAPS_MS = longArrayOf(1000L, 2000L, 3000L, 9000L)
    }

    var state = State.IDLE
        private set
    /** Cause of the current (or last) fault. */
    var cause: FaultCause? = null
        private set
    /** Current renderer generation (-1 before the first). */
    var generation = -1
        private set
    private var genStartMs = 0L
    private var running = false
    private var healthySinceMs = 0L

    /** A recovery episode is open (a fault happened and the video has not been healthy long enough since). */
    var recovering = false
        private set
    private var steps = 0
    private var nextStepAtMs: Long? = null

    /** Input capture may be live. */
    val inputAllowed: Boolean get() = state == State.HEALTHY
    /** The renderer may take frames and send keyframe retries (false in FAULT: no ~2 IDR/s loop). */
    val feedAllowed: Boolean get() = state != State.FAULT
    val keyframeRetriesAllowed: Boolean get() = state != State.FAULT
    /** The automatic steps are used up; only the user's "Yeniden dene" is left. */
    val manual: Boolean get() = recovering && steps >= STEPS.size
    /** The video-fault overlay is due (the caller also requires the connect panel to be hidden). */
    val showOverlay: Boolean get() = !quietOverlay && (state == State.FAULT || (recovering && state == State.STARTING))

    /**
     * T-218: a `video_lost` during a migration proof holds the overlay back (never the input gate) until the episode's
     * first ladder step (+1 s), a loss outside a migration, another fault, or the video is HEALTHY again: a promotion
     * reconfigures at once and should not flash "Görüntü durdu".
     */
    private var quietOverlay = false

    /** T-218: the newest session video connection reported lost (-1: none since the last Detached). */
    private var lostConn = -1
    /** T-218: [videoFlowing] restarts used in the current episode. */
    private var resumes = 0

    /** How long the current generation has been HEALTHY (0 when it is not). */
    fun healthyForMs(): Long = if (state == State.HEALTHY) clock() - healthySinceMs else 0L

    fun onEvent(e: HealthEvent) {
        val now = clock()
        if (e is HealthEvent.Generation) {
            val fromIdle = state == State.IDLE
            generation = e.gen
            genStartMs = now
            running = false
            if (recovering && !manual && (fromIdle || nextStepAtMs == null)) nextStepAtMs = now + STEP_GAPS_MS[steps]
            set(State.STARTING, null, force = true) // logged even from STARTING: a new generation
            return
        }
        if (e.gen != generation) return // a retired generation's late event
        when (e) {
            is HealthEvent.Detached -> {
                running = false
                quietOverlay = false
                lostConn = -1 // the session's connections end with the surface; a new controller may count anew
                nextStepAtMs = null // nothing to recover without a surface; re-armed on the next generation
                set(State.IDLE, null)
            }
            is HealthEvent.Running -> running = true
            is HealthEvent.Exited -> running = false
            is HealthEvent.FirstOutput -> if (state == State.STARTING) {
                healthySinceMs = now
                nextStepAtMs = null
                quietOverlay = false
                set(State.HEALTHY, null)
            }
            is HealthEvent.Fault -> fault(e.cause, now)
            is HealthEvent.Generation -> {}
        }
    }

    /** A fault of the current generation (any cause; T-161 reports `stuck` here through the renderer). */
    fun fault(cause: FaultCause) = fault(cause, clock())

    /**
     * T-218: the session's video connection ended while streaming. FAULT (`video_lost`) at once; this closes input
     * through [onChange]. Without a surface (IDLE) there is nothing to close: input is shut already, and the next
     * generation is STARTING anyway. [quietOverlay] (a migration proof was pending) only holds the overlay back, see
     * [showOverlay]; the gate, the stopped feeding and the recovery ladder are the same.
     */
    fun videoLost(videoConn: Int, quietOverlay: Boolean = false) {
        if (videoConn > lostConn) lostConn = videoConn
        if (state == State.IDLE) return
        if (state == State.FAULT) {
            if (!quietOverlay) showOverlayNow() // a loss outside a migration: the overlay is due now
            return
        }
        // An open episode may already show the overlay: it is never hidden again.
        this.quietOverlay = quietOverlay && !recovering
        if (this.quietOverlay) log('I', "video_overlay", "quiet=1 reason=migration vgen=$generation")
        fault(FaultCause.VIDEO_LOST, clock())
    }

    private fun showOverlayNow() {
        if (!quietOverlay) return
        quietOverlay = false
        onChange()
    }

    /**
     * T-218: video connection [videoConn] delivered its first frame. After a `video_lost` FAULT this returns
     * [Action.RESTART_CODEC]: a new generation (queue reset, keyframe request) that is STARTING until its first decoded
     * output. Otherwise it returns null: a STARTING or HEALTHY generation is fed as usual, and another fault keeps its
     * own recovery.
     *
     * Bounds (review P2):
     * - A resume never moves the ladder's deadline, so restart, reconnect and manual come on schedule however many
     *   connections half-succeed.
     * - At most [MAX_RESUMES] resumes per episode, and none once the ladder is manual. A video that keeps getting a frame
     *   and dropping must not restart the codec (and request a keyframe) every 500 ms.
     * - A notification of a connection that is not newer than the last lost one is stale and dropped. That covers a
     *   replaced reader whose first frame is consumed only after its successor was reported lost. Connection
     *   generations rise within a session machine; [lostConn] is forgotten on Detached.
     */
    fun videoFlowing(videoConn: Int): Action? {
        if (videoConn <= lostConn) {
            log('I', "video_recover", "step=resume_stale conn=$videoConn lost_conn=$lostConn vgen=$generation")
            return null
        }
        if (state != State.FAULT || cause != FaultCause.VIDEO_LOST) return null
        if (manual || resumes >= MAX_RESUMES) {
            log('I', "video_recover", "step=resume_skipped resumes=$resumes manual=${if (manual) 1 else 0} vgen=$generation")
            return null
        }
        resumes++
        log('I', "video_recover", "step=resume n=$resumes vgen=$generation")
        return Action.RESTART_CODEC
    }

    /**
     * Every ticker run (500 ms): evaluates the timer rules against [progress] (the renderer's, null without one), ends
     * an episode after a long enough healthy run, and returns the recovery action that is due, if any.
     */
    fun tick(progress: DecodeProgress.Snapshot?): Action? {
        val now = clock()
        if (state == State.STARTING || state == State.HEALTHY) {
            if (!running && now - genStartMs >= NOT_RUNNING_MS) {
                fault(FaultCause.NOT_RUNNING, now)
            } else if (progress != null && progress.gen == generation && progress.pending >= NO_OUTPUT_MIN_INPUTS &&
                now - progress.oldestPendingMs >= NO_OUTPUT_MS
            ) {
                fault(FaultCause.NO_OUTPUT, now)
            }
        }
        if (state == State.HEALTHY && recovering && now - healthySinceMs >= EPISODE_END_HEALTHY_MS) {
            recovering = false
            steps = 0
            log('I', "video_recover", "step=done vgen=$generation")
        }
        val at = nextStepAtMs ?: return null
        if (state == State.HEALTHY || state == State.IDLE || now < at || steps >= STEPS.size) return null
        val step = STEPS[steps++]
        nextStepAtMs = if (steps < STEPS.size) now + STEP_GAPS_MS[steps] else null
        log('W', "video_recover", "step=${step.logName} n=$steps vgen=$generation")
        showOverlayNow() // T-218: still not healthy at the first step: no promotion fixed it
        return when (step) {
            Step.RESTART -> Action.RESTART_CODEC
            Step.RECONNECT -> Action.RECONNECT
            Step.MANUAL -> { onChange(); null }
        }
    }

    /**
     * "Yeniden dene": restart the codec now and continue the ladder after its first restart step (one bounded ladder
     * per tap). Null when there is no surface.
     */
    fun retry(): Action? {
        if (state == State.IDLE) return null
        val now = clock()
        quietOverlay = false
        recovering = true
        steps = 1
        resumes = 0
        nextStepAtMs = now + STEP_GAPS_MS[steps]
        log('W', "video_recover", "step=retry n=$steps vgen=$generation")
        return Action.RESTART_CODEC
    }

    private fun fault(cause: FaultCause, now: Long) {
        if (state == State.FAULT || state == State.IDLE) return
        if (cause != FaultCause.VIDEO_LOST) quietOverlay = false // T-218: any other fault shows the overlay at once
        if (!recovering) { recovering = true; steps = 0; resumes = 0 }
        if (nextStepAtMs == null && !manual) nextStepAtMs = now + STEP_GAPS_MS[steps]
        set(State.FAULT, cause)
    }

    private fun set(to: State, cause: FaultCause?, force: Boolean = false) {
        if (to == state && !force) return
        val from = state
        state = to
        if (cause != null) this.cause = cause
        log(if (to == State.FAULT) 'W' else 'I', "video_health",
            "state=${to.logName} cause=${cause?.logName ?: "-"} from=${from.logName} vgen=$generation")
        onChange()
    }
}
