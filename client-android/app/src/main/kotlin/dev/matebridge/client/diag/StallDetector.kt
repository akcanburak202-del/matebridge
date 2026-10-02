package dev.matebridge.client.diag

import android.os.Process
import android.os.SystemClock
import dev.matebridge.client.session.MbLog
import java.io.File
import java.util.concurrent.locks.LockSupport

/**
 * T-120: a diagnostic tick thread that wakes every 5 ms at the highest priority it gets and records how late it woke
 * ([StallMeter]). Measurement only; it changes no behaviour. Runs only between [start] and [stop] (the controller ties
 * it to the control connection). [start]/[stop] are called from one thread (the session engine).
 *
 * Logs (component `diag`, docs/LOGGING.md):
 *  - once per second `ev=stall_stats ticks= tick_late_max_ms= stalls= suspend_ms= cpu_freq_khz=`;
 *  - per stall above 50 ms (at most 5 per second) `ev=stall dur_ms= suspend_ms= ctl_idle_ms= video_idle_ms= suppressed=`.
 * The tick path does not allocate; string work happens only for these lines.
 */
class StallDetector(private val readers: Readers) {
    /** The readers' latest data-carrying `read()` return times (`System.nanoTime()`, 0 = none yet). */
    interface Readers {
        fun lastControlReadNs(): Long
        fun lastVideoReadNs(): Long
    }

    val meter = StallMeter()

    private var runner: Runner? = null

    /** Starts the tick thread if it is not running. */
    fun start() {
        if (runner != null) return
        runner = Runner().also { it.thread.start() }
    }

    /** Stops the tick thread (waits briefly for it, so a later [start] never overlaps it). */
    fun stop() {
        val r = runner ?: return
        runner = null
        r.stopped = true
        meter.stop()
        LockSupport.unpark(r.thread)
        try { r.thread.join(JOIN_MS) } catch (_: InterruptedException) { Thread.currentThread().interrupt() }
    }

    private inner class Runner {
        @Volatile var stopped = false
        val thread = Thread({ loop() }, "mb-stall").also { it.isDaemon = true }

        private fun loop() {
            val prio = raisePriority()
            val cpu = CpuFreq()
            val window = StallMeter.Window()
            MbLog.i("stall_detector_start", "prio=$prio period_ms=${meter.periodNs / 1_000_000} cpu_freq_files=${cpu.files}", COMPONENT)
            var now = System.nanoTime()
            meter.start(now, SystemClock.elapsedRealtimeNanos())
            var lastStatsNs = now
            while (!stopped) {
                val deadline = meter.nextDeadlineNs()
                now = System.nanoTime()
                while (now < deadline && !stopped) {
                    LockSupport.parkNanos(deadline - now) // may return early: loop until the deadline
                    now = System.nanoTime()
                }
                if (stopped) break
                if (meter.onTick(now, SystemClock.elapsedRealtimeNanos())) logStall(now)
                if (now - lastStatsNs >= 1_000_000_000L) {
                    lastStatsNs = now
                    meter.takeWindow(window)
                    MbLog.i("stall_stats", window.logFields(cpu.maxKhz()), COMPONENT)
                }
            }
            MbLog.i("stall_detector_stop", "", COMPONENT)
        }

        private fun logStall(nowNs: Long) {
            val s = meter.stall
            MbLog.i(
                "stall",
                "dur_ms=${StallMeter.ms1(s.durUs)} suspend_ms=${StallMeter.ms1(s.suspendUs)} " +
                    "ctl_idle_ms=${idle(nowNs, readers.lastControlReadNs())} video_idle_ms=${idle(nowNs, readers.lastVideoReadNs())} " +
                    "suppressed=${s.suppressed}",
                COMPONENT,
            )
        }

        private fun idle(nowNs: Long, lastNs: Long): String = if (lastNs == 0L) "-" else StallMeter.ms1((nowNs - lastNs) / 1000)
    }

    /** `THREAD_PRIORITY_URGENT_AUDIO`, else `THREAD_PRIORITY_AUDIO`; returns the priority the thread has. */
    private fun raisePriority(): Int {
        for (p in intArrayOf(Process.THREAD_PRIORITY_URGENT_AUDIO, Process.THREAD_PRIORITY_AUDIO)) {
            try {
                Process.setThreadPriority(p)
                break
            } catch (_: RuntimeException) {
                // not permitted: try the next one
            }
        }
        return try { Process.getThreadPriority(Process.myTid()) } catch (_: RuntimeException) { 0 }
    }

    /** Current CPU frequency (the largest `scaling_cur_freq` over all cores); stops trying after a failed read. */
    private class CpuFreq {
        private val paths: List<File> = (0 until MAX_CPUS)
            .map { File("/sys/devices/system/cpu/cpu$it/cpufreq/scaling_cur_freq") }
            .filter { try { it.canRead() } catch (_: SecurityException) { false } }
        private var broken = paths.isEmpty()

        val files: Int get() = paths.size

        /** kHz, or -1 when unreadable. Called once per second (allocates; off the tick path). */
        fun maxKhz(): Long {
            if (broken) return -1
            val khz = StallMeter.maxKhz(paths.map { f -> try { f.readText() } catch (_: Exception) { null } })
            if (khz < 0) broken = true
            return khz
        }
    }

    private companion object {
        const val COMPONENT = "diag"
        const val JOIN_MS = 100L
        const val MAX_CPUS = 16
    }
}
