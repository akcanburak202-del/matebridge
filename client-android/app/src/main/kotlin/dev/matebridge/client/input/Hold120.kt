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
        CANCELLED("cancelled"), OK("ok"),
    }

    /** The first failing condition in a fixed order, or [Reason.OK]; the touch is held only for OK. */
    fun reason(
        enabled: Boolean, serviceBound: Boolean, streaming: Boolean, foreground: Boolean, remote: Boolean, game: Boolean, fps: Int,
    ): Reason = when {
        !enabled -> Reason.SETTING
        remote -> Reason.REMOTE
        !serviceBound -> Reason.SERVICE
        !foreground -> Reason.BACKGROUND
        !streaming -> Reason.STREAM
        !game || fps < MIN_FPS -> Reason.MODE
        else -> Reason.OK
    }

    /** Retry delay after the n-th quick cancellation in a row (n >= 1): 1 s, 2 s, 4 s, then 8 s at most. */
    fun retryDelayMs(consecutive: Int): Long = 1000L shl (consecutive - 1).coerceIn(0, 3)

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
    fun start(onCancelled: () -> Unit)
    fun stop()
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

    private data class Conditions(
        val enabled: Boolean, val serviceBound: Boolean, val streaming: Boolean, val foreground: Boolean,
        val remote: Boolean, val game: Boolean, val fps: Int,
    ) {
        fun reason() = Hold120Rules.reason(enabled, serviceBound, streaming, foreground, remote, game, fps)
    }

    val holding: Boolean get() = actuator != null
    val retryPending: Boolean get() = retry != null

    fun update(enabled: Boolean, serviceBound: Boolean, streaming: Boolean, foreground: Boolean, remote: Boolean, game: Boolean, fps: Int) {
        val c = Conditions(enabled, serviceBound, streaming, foreground, remote, game, fps)
        last = c
        val reason = c.reason()
        if (reason == Hold120Rules.Reason.OK) {
            if (actuator == null && retry == null) startNow()
        } else {
            cancelRetry()
            if (actuator != null) release(reason)
            quickCancels = 0
        }
    }

    /** Stops without a log line (activity teardown). */
    fun shutdown() {
        cancelRetry()
        last = null
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
            a.start { onCancelled(gen) }
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
        val c = last ?: return
        if (c.reason() != Hold120Rules.Reason.OK) return
        retry = timer.postDelayed(Hold120Rules.retryDelayMs(quickCancels)) {
            retry = null
            val l = last
            if (l != null && actuator == null && l.reason() == Hold120Rules.Reason.OK) startNow()
        }
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
