package dev.matebridge.client.input

import java.util.Locale

/**
 * T-360 (decision 0041): "Kumandayla 120 Hz". With a gamepad or keyboard the Huawei panel stays at 60 Hz; one held,
 * motionless fake touch keeps it at 120. Pure logic only: [Hold120Controller] decides when the touch is held and talks to a
 * [Hold120Actuator] (the accessibility service). The fake touch never reaches the Mac: the target is the service's own
 * overlay window (or, as the fallback, a recognised surface touch that is dropped).
 */
object Hold120Rules {
    /** Streams below this rate do not need the trick (the panel is not the limit). */
    const val MIN_FPS = 120

    /** Why the touch is (not) held; [logName] is the `reason=` token. */
    enum class Reason(val logName: String) {
        SETTING("setting"), REMOTE("remote"), SERVICE("service"), BACKGROUND("background"), STREAM("stream"), MODE("mode"),
        TOUCH("touch"), CANCELLED("cancelled"), OK("ok"),
    }

    /** The first failing condition in a fixed order, or [Reason.OK]; the touch is held only for OK. */
    fun reason(
        enabled: Boolean, serviceBound: Boolean, streaming: Boolean, foreground: Boolean, remote: Boolean, game: Boolean, fps: Int, touchQuiet: Boolean = true,
    ): Reason = when {
        !enabled -> Reason.SETTING
        remote -> Reason.REMOTE
        !serviceBound -> Reason.SERVICE
        !foreground -> Reason.BACKGROUND
        !streaming -> Reason.STREAM
        !game || fps < MIN_FPS -> Reason.MODE
        !touchQuiet -> Reason.TOUCH
        else -> Reason.OK
    }

    /** Retry delay after the n-th quick cancellation in a row (n >= 1): 1 s, 2 s, 4 s, then 8 s at most. */
    fun retryDelayMs(consecutive: Int): Long = 1000L shl (consecutive - 1).coerceIn(0, 3)

    /** No real contact for this long before a (re)start: dispatching a gesture cancels a real one in progress. */
    const val QUIET_MS = 1000L

    /** A hold that lasted this long counts as stable: the next cancellation starts the back-off over. */
    const val STABLE_MS = 5000L
}

/** `hold120_target` dev knob: where the fake touch lands. */
enum class Hold120Target(val id: String) {
    OVERLAY("overlay"), SURFACE("surface");

    companion object {
        /** Unknown or absent = [OVERLAY]. */
        fun parse(v: String?): Hold120Target = entries.firstOrNull { it.id == v?.trim()?.lowercase(Locale.ROOT) } ?: OVERLAY
    }
}

/** The thing that holds the touch. [stop] must send the UP and be safe to call when nothing is held. */
interface Hold120Actuator {
    /** Starts holding; [onCancelled] fires (any thread; the caller posts to main) when the system cancelled the touch. */
    fun start(onCancelled: () -> Unit, canDispatch: () -> Boolean)
    fun stop()

    /**
     * A real contact began. If the first gesture has not been dispatched yet, abandons the preparation (overlay removed,
     * no UP needed) and returns true; a running hold is left alone (returns false: Android cancels it itself).
     */
    fun abortIfPreparing(): Boolean
}

/** One delayed main-thread task, cancellable. */
fun interface Hold120Timer {
    fun postDelayed(ms: Long, task: Runnable): AutoCloseable
}

/**
 * Starts and stops the held touch from the conditions. Main thread only ([Hold120Actuator.start]'s callback must be
 * delivered on it too). [newActuator] is touched only on start: with the switch off nothing exists, no timer, no window.
 * One log line per state change, none per chain segment.
 */
class Hold120Controller(
    private val newActuator: () -> Hold120Actuator?,
    private val timer: Hold120Timer,
    private val nowMs: () -> Long,
    private val log: (String, String) -> Unit,
) {
    private var actuator: Hold120Actuator? = null
    private var retry: AutoCloseable? = null
    private var startedAt = 0L
    private var quickCancels = 0
    private var last: Conditions? = null
    private var generation = 0
    private var touching = false
    private var touchEndedAt = -10 * Hold120Rules.QUIET_MS
    private var backoffMs = 0L
    private var wasForeground = true

    private data class Conditions(
        val enabled: Boolean, val serviceBound: Boolean, val streaming: Boolean, val foreground: Boolean,
        val remote: Boolean, val game: Boolean, val fps: Int,
    ) {
        fun reason(touchQuiet: Boolean) = Hold120Rules.reason(enabled, serviceBound, streaming, foreground, remote, game, fps, touchQuiet)
    }

    private fun touchQuiet() = !touching && nowMs() - touchEndedAt >= Hold120Rules.QUIET_MS
    private fun quietRemainingMs() = if (touching) Hold120Rules.QUIET_MS else (Hold120Rules.QUIET_MS - (nowMs() - touchEndedAt)).coerceAtLeast(0)

    /**
     * A real finger/stylus contact started ([down]) or the last one ended. Never releases a held touch (the UP would cancel
     * the real gesture); only defers (re)starts until contacts are up and [Hold120Rules.QUIET_MS] has passed.
     */
    fun onTouch(down: Boolean) {
        if (down == touching) return
        touching = down
        if (!down) touchEndedAt = nowMs()
        if (down) {
            val a = actuator
            if (a != null && try { a.abortIfPreparing() } catch (_: Throwable) { false }) {
                actuator = null
                generation++
                log("hold120", "state=off reason=${Hold120Rules.Reason.TOUCH.logName}")
            }
        }
        val c = last ?: return
        if (!down && actuator == null) {
            val r = c.reason(touchQuiet())
            if (r == Hold120Rules.Reason.OK || r == Hold120Rules.Reason.TOUCH) scheduleStart()
        }
    }

    private fun scheduleStart() {
        if (retry != null || touching) return // a touch end schedules it
        val delay = maxOf(quietRemainingMs(), backoffMs)
        retry = timer.postDelayed(delay) {
            retry = null
            val l = last
            if (l != null && actuator == null) {
                when (l.reason(touchQuiet())) {
                    Hold120Rules.Reason.OK -> startNow()
                    Hold120Rules.Reason.TOUCH -> scheduleStart()
                    else -> {}
                }
            }
        }
    }

    val holding: Boolean get() = actuator != null
    val retryPending: Boolean get() = retry != null

    fun update(enabled: Boolean, serviceBound: Boolean, streaming: Boolean, foreground: Boolean, remote: Boolean, game: Boolean, fps: Int) {
        val c = Conditions(enabled, serviceBound, streaming, foreground, remote, game, fps)
        last = c
        // Coming back to the foreground (focus regained after the shade, resume) starts a quiet period like a lifted touch.
        if (foreground && !wasForeground) touchEndedAt = maxOf(touchEndedAt, nowMs())
        wasForeground = foreground
        val reason = c.reason(touchQuiet())
        when (reason) {
            Hold120Rules.Reason.OK -> if (actuator == null && retry == null) startNow()
            Hold120Rules.Reason.TOUCH -> if (actuator == null) scheduleStart() // a held touch is left alone
            else -> {
                cancelRetry()
                if (actuator != null) release(reason)
                quickCancels = 0
                backoffMs = 0
            }
        }
    }

    /** Stops without a log line (activity teardown). */
    fun shutdown() {
        cancelRetry()
        last = null
        wasForeground = true
        val a = actuator ?: return
        actuator = null
        generation++
        try { a.stop() } catch (_: Throwable) {}
    }

    private fun startNow() {
        val a = try { newActuator() } catch (_: Throwable) { null } ?: return
        actuator = a
        startedAt = nowMs()
        val gen = ++generation
        try {
            a.start({ onCancelled(gen) }, { last?.reason(touchQuiet()) == Hold120Rules.Reason.OK })
        } catch (_: Throwable) {
            actuator = null
            try { a.stop() } catch (_: Throwable) {}
            return
        }
        log("hold120", "state=on reason=${Hold120Rules.Reason.OK.logName}")
    }

    private fun onCancelled(gen: Int) {
        if (gen != generation) return // a stale callback of an earlier hold
        val a = actuator ?: return
        actuator = null
        generation++
        try { a.stop() } catch (_: Throwable) {}
        log("hold120", "state=off reason=${Hold120Rules.Reason.CANCELLED.logName}")
        quickCancels = if (nowMs() - startedAt >= Hold120Rules.STABLE_MS) 1 else quickCancels + 1
        backoffMs = Hold120Rules.retryDelayMs(quickCancels)
        val c = last ?: return
        val r = c.reason(touchQuiet())
        if (r == Hold120Rules.Reason.OK || r == Hold120Rules.Reason.TOUCH) scheduleStart()
    }

    private fun release(reason: Hold120Rules.Reason) {
        val a = actuator ?: return
        actuator = null
        generation++
        try { a.stop() } catch (_: Throwable) {}
        log("hold120", "state=off reason=${reason.logName}")
    }

    private fun cancelRetry() {
        try { retry?.close() } catch (_: Exception) {}
        retry = null
    }
}

/**
 * Geometry of the held touch (pure). A stroke that never moves produces only a DOWN in AOSP's injector and an unmoved
 * continuation is reported as a failure, so every segment travels 2 x [AMPLITUDE_PX] inside the overlay: segment n goes
 * A->B for even n and B->A for odd n, so each starts where the previous ended. All points stay inside the overlay.
 */
object HoldPathGeometry {
    const val OVERLAY_SIZE_PX = 24
    const val INSET_PX = 48
    const val AMPLITUDE_PX = 6
    const val FINAL_STEP_PX = 2

    /**
     * Timing contract: a `continueStroke(..., false)` is queued after the running chunk, so the UP lands up to one chunk
     * after stop. Chunks are short ([CHUNK_MS]) to bound that; the overlay outlives the UP by [removalTimeoutMs].
     */
    const val CHUNK_MS = 500L
    const val FINAL_MS = 50L
    const val MARGIN_MS = 300L

    /** The most the UP can lag behind a stop, and the overlay's removal fallback (chunk + final stroke + margin). */
    fun maxUpLagMs(chunkMs: Long = CHUNK_MS): Long = chunkMs + FINAL_MS
    fun removalTimeoutMs(chunkMs: Long = CHUNK_MS): Long = maxUpLagMs(chunkMs) + MARGIN_MS

    data class Seg(val x0: Float, val y0: Float, val x1: Float, val y1: Float)

    private const val CX = (INSET_PX + OVERLAY_SIZE_PX / 2).toFloat()
    private const val CY = (INSET_PX + OVERLAY_SIZE_PX / 2).toFloat()

    /** The n-th chunk (n >= 0). */
    fun segment(n: Int): Seg {
        val a = CX - AMPLITUDE_PX
        val b = CX + AMPLITUDE_PX
        return if (n % 2 == 0) Seg(a, CY, b, CY) else Seg(b, CY, a, CY)
    }

    /** The closing UP stroke after chunk [n]: starts where chunk n ended and moves [FINAL_STEP_PX] toward the middle. */
    fun finalSegment(n: Int): Seg {
        val end = segment(n)
        val dx = if (end.x1 > CX) -FINAL_STEP_PX else FINAL_STEP_PX
        return Seg(end.x1, end.y1, end.x1 + dx, end.y1)
    }

    fun inside(x: Float, y: Float): Boolean =
        x > INSET_PX && x < INSET_PX + OVERLAY_SIZE_PX && y > INSET_PX && y < INSET_PX + OVERLAY_SIZE_PX
}

/**
 * Counts concurrent REAL contacts (finger on the touchscreen, stylus) from raw events, per source, so a mouse click or a
 * trackpad cannot clear a finger that is still down. Sources are matched on all bits (mouse, touchscreen and stylus share
 * SOURCE_CLASS_POINTER). Pure: the caller passes the numbers.
 */
class ContactTracker {
    private var finger = 0
    private var stylus = 0

    val contacts: Int get() = finger + stylus
    val touching: Boolean get() = contacts > 0

    /** [pointerCount] is the event's own count (a POINTER_UP still includes the lifting pointer). Returns [touching]. */
    fun onEvent(source: Int, actionMasked: Int, pointerCount: Int): Boolean {
        val isStylus = (source and SRC_STYLUS) == SRC_STYLUS
        val isFinger = (source and SRC_TOUCH) == SRC_TOUCH
        if ((source and SRC_MOUSE) == SRC_MOUSE || (!isStylus && !isFinger)) return touching
        val n = when (actionMasked) {
            ACTION_DOWN, ACTION_POINTER_DOWN -> pointerCount
            ACTION_POINTER_UP -> pointerCount - 1
            ACTION_UP, ACTION_CANCEL -> 0
            else -> return touching
        }.coerceAtLeast(0)
        if (isStylus) stylus = n else finger = n
        return touching
    }

    fun reset() { finger = 0; stylus = 0 }

    companion object {
        const val SRC_TOUCH = 0x00001002 // InputDevice.SOURCE_TOUCHSCREEN
        const val SRC_STYLUS = 0x00004002 // InputDevice.SOURCE_STYLUS
        const val SRC_MOUSE = 0x00002002 // InputDevice.SOURCE_MOUSE
        const val ACTION_DOWN = 0
        const val ACTION_UP = 1
        const val ACTION_CANCEL = 3
        const val ACTION_POINTER_DOWN = 5
        const val ACTION_POINTER_UP = 6
    }
}

/** Gate for the first dispatch: the overlay must be attached, laid out and settled, or the DOWN could land on the video surface. */
object OverlayReadiness {
    const val SETTLE_MS = 100L
    const val TIMEOUT_MS = 1000L
    const val POLL_MS = 50L

    enum class Verdict { WAIT, GO, FAIL }

    /**
     * [readySinceMs]: ms since the view was first seen attached and laid out (null = not yet); [elapsedMs]: ms since addView.
     * [locationOk]: the on-screen location was readable and the view has its size.
     */
    fun decide(attachedAndLaidOut: Boolean, locationOk: Boolean, readySinceMs: Long?, elapsedMs: Long): Verdict = when {
        attachedAndLaidOut && locationOk && readySinceMs != null && readySinceMs >= SETTLE_MS -> Verdict.GO
        elapsedMs >= TIMEOUT_MS -> Verdict.FAIL
        else -> Verdict.WAIT
    }
}

/**
 * stop() bookkeeping of the actuator: a second stop while the final stroke drains is a no-op, so the overlay is removed
 * only by the drain's end (completion, cancel or timeout). Pure.
 */
class DrainGate {
    enum class Action { NOOP, DRAIN, REMOVE_NOW }

    var active = false
        private set
    var draining = false
        private set

    fun onStart() { active = true; draining = false }

    /** [hasStroke]: a stroke is running, so there is a touch to end. */
    fun onStop(hasStroke: Boolean): Action {
        if (draining) return Action.NOOP
        val was = active
        active = false
        return if (was && hasStroke) { draining = true; Action.DRAIN } else Action.REMOVE_NOW
    }

    fun onDrained() { draining = false }
}

/**
 * Belt and braces: while the overlay exists, a touchscreen/stylus stream (per input device) whose DOWN lands inside the
 * overlay's on-screen rect, with every pointer inside it, is dropped (never forwarded to the Mac) through its UP/CANCEL.
 * Events of any other device, and events that mix pointers inside and outside the rect, always pass: an UP is only ever
 * consumed for a stream whose DOWN was consumed too. Pure; the caller passes raw coordinates.
 */
class OverlayDropFilter {
    private val dropped = HashSet<Int>()

    /** [rect] = l, t, r, b on screen, or null when no overlay exists. [n] pointers in [xs]/[ys]. True = drop the event. */
    fun drop(deviceId: Int, source: Int, actionMasked: Int, xs: FloatArray, ys: FloatArray, n: Int, rect: IntArray?): Boolean {
        val real = (source and ContactTracker.SRC_MOUSE) != ContactTracker.SRC_MOUSE &&
            ((source and ContactTracker.SRC_TOUCH) == ContactTracker.SRC_TOUCH || (source and ContactTracker.SRC_STYLUS) == ContactTracker.SRC_STYLUS)
        if (!real) return false
        if (deviceId in dropped) {
            if (actionMasked == ContactTracker.ACTION_UP || actionMasked == ContactTracker.ACTION_CANCEL) dropped.remove(deviceId)
            return true
        }
        if (actionMasked == ContactTracker.ACTION_DOWN && rect != null && n > 0) {
            var allInside = true
            for (i in 0 until n) if (!(xs[i] >= rect[0] && xs[i] < rect[2] && ys[i] >= rect[1] && ys[i] < rect[3])) allInside = false
            if (allInside) { dropped.add(deviceId); return true }
        }
        return false
    }

    val activeStreams: Int get() = dropped.size
}
