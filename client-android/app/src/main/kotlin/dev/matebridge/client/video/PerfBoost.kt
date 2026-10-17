package dev.matebridge.client.video

import android.content.Context
import android.widget.OverScroller
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * T-350 (decision 0039): the "Performans artışı" switch. An invisible [OverScroller.fling] every [PERIOD_MS] makes Huawei's
 * iAware raise DDR and GPU clocks (T-319 measurement). Nothing exists while the switch is off: [PerfBoost] creates no
 * action, scheduler task or thread until [PerfBoost.update] sees every condition true.
 */
object PerfBoostRules {
    const val PERIOD_MS = 1000L

    /** Why the boost is (not) running; [logName] is the `reason=` token. */
    enum class Reason(val logName: String) { SETTING("setting"), STREAM("stream"), BACKGROUND("background"), REMOTE("remote"), OK("ok") }

    /** The first failing condition in a fixed order, or [Reason.OK]; the boost runs only for OK. */
    fun reason(enabled: Boolean, streaming: Boolean, foreground: Boolean, remote: Boolean): Reason = when {
        !enabled -> Reason.SETTING
        remote -> Reason.REMOTE
        !foreground -> Reason.BACKGROUND
        !streaming -> Reason.STREAM
        else -> Reason.OK
    }
}

/** The thing pulsed every period. [pulse] may throw; [release] runs once on stop. */
interface BoostAction {
    fun pulse()
    fun release()
}

/** Runs a task periodically until the returned handle is closed. */
fun interface PulseScheduler {
    fun every(periodMs: Long, task: Runnable): AutoCloseable
}

/** Real scheduler: one daemon thread per started schedule, shut down on close. */
object ExecutorPulseScheduler : PulseScheduler {
    override fun every(periodMs: Long, task: Runnable): AutoCloseable {
        val ex: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { r ->
            Thread(r, "mb-boost").also { it.isDaemon = true }
        }
        ex.scheduleAtFixedRate({ try { task.run() } catch (_: Throwable) {} }, periodMs, periodMs, TimeUnit.MILLISECONDS)
        return AutoCloseable { ex.shutdownNow() }
    }
}

/** The T-319 FLING mechanism: abort, then fling a throw-away scroller (invisible, touches no view). */
class FlingBoost(context: Context) : BoostAction {
    private val scroller = OverScroller(context)
    override fun pulse() {
        scroller.abortAnimation()
        scroller.fling(0, 0, 0, 20000, 0, 0, -100000, 100000)
    }
    override fun release() = scroller.abortAnimation()
}

/**
 * Starts and stops the pulsing from the four conditions. Main thread only. [newAction] and [scheduler] are touched only
 * on start, so with the switch off nothing is called at all. [log] is `(event, fields)`; one line per start/stop, none per pulse.
 */
class PerfBoost(
    private val newAction: () -> BoostAction,
    private val scheduler: PulseScheduler,
    private val log: (String, String) -> Unit,
) {
    private val lock = Any()
    private var action: BoostAction? = null
    private var handle: AutoCloseable? = null

    val running: Boolean get() = synchronized(lock) { handle != null }

    /** Re-evaluates; starts or stops only on a change. */
    fun update(enabled: Boolean, streaming: Boolean, foreground: Boolean, remote: Boolean) {
        val reason = PerfBoostRules.reason(enabled, streaming, foreground, remote)
        synchronized(lock) {
            val want = reason == PerfBoostRules.Reason.OK
            if (want && handle == null) {
                val a = try { newAction() } catch (_: Throwable) { log("perf_boost", "state=off reason=unsupported"); return }
                action = a
                pulse(a)
                handle = scheduler.every(PerfBoostRules.PERIOD_MS) { synchronized(lock) { if (action === a) pulse(a) } }
                log("perf_boost", "state=on reason=${reason.logName} period_ms=${PerfBoostRules.PERIOD_MS}")
            } else if (!want && handle != null) {
                stopLocked()
                log("perf_boost", "state=off reason=${reason.logName}")
            }
        }
    }

    /** Stops without a log line (activity teardown). */
    fun shutdown() = synchronized(lock) { stopLocked() }

    private fun stopLocked() {
        try { handle?.close() } catch (_: Exception) {}
        handle = null
        try { action?.release() } catch (_: Exception) {}
        action = null
    }

    private fun pulse(a: BoostAction) {
        try { a.pulse() } catch (_: Throwable) {}
    }
}
