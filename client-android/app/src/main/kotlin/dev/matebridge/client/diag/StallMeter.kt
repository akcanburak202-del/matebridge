package dev.matebridge.client.diag

/**
 * T-120: wake-up lateness of a periodic high-priority tick (measurement only). Pure Kotlin.
 *
 * A tick thread sleeps until [nextDeadlineNs] and then calls [onTick]. How late it woke tells whether the whole process
 * (or the CPU) was not running: if a 5 ms tick is 200 ms late, nothing in the process ran either. The audio arrival
 * gap line asks [maxLateUs] for the gap's window: a late tick there means the tablet stalled; an on-time tick means the
 * data really arrived late (network stack or Mac).
 *
 * Clocks: `nowNs` is the monotonic clock that does not run during suspend (`System.nanoTime()`, Android uptime);
 * `realtimeNs` is the one that does (`SystemClock.elapsedRealtimeNanos()`). Their difference grows only while the
 * device is suspended, so a stall with a matching suspend is deep sleep, one without is scheduling/freezing.
 *
 * Recording never allocates (preallocated ring, reused [Window]/[Stall]); the tick thread and the readers meet in short
 * `synchronized` sections.
 */
class StallMeter(
    val periodNs: Long = 5_000_000,
    private val stallNs: Long = 30_000_000,
    private val logStallNs: Long = 50_000_000,
    private val maxStallLogsPerSec: Int = 5,
    ringSize: Int = 256,
) {
    /** One window's figures; [NONE] = no data. Reused by the caller. */
    class Window {
        var ticks = 0
        var lateMaxUs = NONE
        var stalls = 0
        var suspendUs = NONE

        /** The `ev=stall_stats` fields (docs/LOGGING.md); [cpuKhz] < 0 = unreadable (`-`). */
        fun logFields(cpuKhz: Long): String =
            "ticks=$ticks tick_late_max_ms=${ms1(lateMaxUs)} stalls=$stalls suspend_ms=${ms1(suspendUs)} " +
                "cpu_freq_khz=${if (cpuKhz < 0) "-" else cpuKhz.toString()}"
    }

    /** The last reported stall (valid right after [onTick] returned true, on the tick thread). */
    class Stall {
        /** Wake-up lateness. */
        var durUs = 0L
        /** Time the device spent suspended during that tick interval (realtime minus uptime growth). */
        var suspendUs = 0L
        /** When the stall was detected (`nowNs` of the late tick). */
        var atNs = 0L
        /** Stalls suppressed by the rate limit since the previous reported one. */
        var suppressed = 0
    }

    val stall = Stall()

    private val mask: Int
    private val ringAt: LongArray
    private val ringLate: LongArray
    private var ringCount = 0L // ticks recorded since start (head = ringCount - 1)

    private var active = false
    private var nextDeadline = 0L
    private var lastOffsetNs = 0L // realtime - uptime at the latest tick

    // Window (guarded by this).
    private var ticks = 0
    private var lateMax = NONE
    private var stalls = 0
    private var windowOffsetNs = 0L

    // Rate limit (guarded by this).
    private var limitStartNs = NONE
    private var limitCount = 0
    private var suppressed = 0

    init {
        require(ringSize > 0 && ringSize and (ringSize - 1) == 0) { "ringSize must be a power of two" }
        mask = ringSize - 1
        ringAt = LongArray(ringSize)
        ringLate = LongArray(ringSize)
    }

    /** Starts measuring at [nowNs]; the first tick is due one period later. The ring and window are cleared. */
    @Synchronized fun start(nowNs: Long, realtimeNs: Long) {
        active = true
        ringCount = 0
        nextDeadline = nowNs + periodNs
        lastOffsetNs = realtimeNs - nowNs
        windowOffsetNs = lastOffsetNs
        ticks = 0; lateMax = NONE; stalls = 0
        limitStartNs = NONE; limitCount = 0; suppressed = 0
    }

    /** Stops measuring: [maxLateUs] answers [NONE] until the next [start]. */
    @Synchronized fun stop() {
        active = false
    }

    /** When the tick thread should wake next. */
    @Synchronized fun nextDeadlineNs(): Long = nextDeadline

    /**
     * The tick thread woke at [nowNs] (at or after [nextDeadlineNs]). Returns true when a stall above the log threshold
     * should be logged now (details in [stall]); false otherwise, including when the rate limit suppressed it.
     */
    @Synchronized fun onTick(nowNs: Long, realtimeNs: Long): Boolean {
        if (!active) return false
        val lateNs = (nowNs - nextDeadline).coerceAtLeast(0)
        val lateUs = lateNs / 1000
        val offset = realtimeNs - nowNs
        val suspendNs = (offset - lastOffsetNs).coerceAtLeast(0)
        lastOffsetNs = offset

        val i = (ringCount and mask.toLong()).toInt()
        ringAt[i] = nowNs
        ringLate[i] = lateUs
        ringCount++

        ticks++
        if (lateMax == NONE || lateUs > lateMax) lateMax = lateUs
        if (lateNs > stallNs) stalls++

        // A late tick does not catch up on the missed ones: the next is one period after this wake-up.
        nextDeadline = if (lateNs > periodNs) nowNs + periodNs else nextDeadline + periodNs

        if (lateNs <= logStallNs) return false
        if (limitStartNs == NONE || nowNs - limitStartNs >= 1_000_000_000L) {
            limitStartNs = nowNs
            limitCount = 0
        }
        if (limitCount >= maxStallLogsPerSec) {
            suppressed++
            return false
        }
        limitCount++
        stall.durUs = lateUs
        stall.suspendUs = suspendNs / 1000
        stall.atNs = nowNs
        stall.suppressed = suppressed
        suppressed = 0
        return true
    }

    /**
     * The largest tick lateness whose stopped interval (`[wake - late, wake]`) overlaps `[fromNs, toNs]`, in µs. A tick
     * that is overdue at [nowNs] but has not run yet counts too (`[deadline, now]`): when the whole process resumes,
     * a reader can get there before the tick thread. [NONE] when not measuring or nothing covers the window.
     */
    @Synchronized fun maxLateUs(fromNs: Long, toNs: Long, nowNs: Long): Long {
        if (!active) return NONE
        var best = NONE
        if (nowNs > nextDeadline && nextDeadline < toNs && nowNs > fromNs) best = (nowNs - nextDeadline) / 1000
        val n = minOf(ringCount, ringAt.size.toLong()).toInt()
        for (k in 0 until n) {
            val i = ((ringCount - 1 - k) and mask.toLong()).toInt()
            val at = ringAt[i]
            val late = ringLate[i]
            if (at <= fromNs) break // older ticks end even earlier (wake times are increasing)
            if (at > fromNs && at - late * 1000 < toNs) {
                if (best == NONE || late > best) best = late
            }
        }
        return best
    }

    /** Copies the current window into [out] and starts a new one. */
    @Synchronized fun takeWindow(out: Window) {
        out.ticks = ticks
        out.lateMaxUs = lateMax
        out.stalls = stalls
        out.suspendUs = if (ticks > 0) ((lastOffsetNs - windowOffsetNs) / 1000).coerceAtLeast(0) else NONE
        windowOffsetNs = lastOffsetNs
        ticks = 0; lateMax = NONE; stalls = 0
    }

    companion object {
        /** "No value" marker for the µs fields. */
        const val NONE = Long.MIN_VALUE

        /** [us] as milliseconds with one decimal, signed; `-` for [NONE]. */
        fun ms1(us: Long): String {
            if (us == NONE) return "-"
            val neg = us < 0
            val tenths = (if (neg) -us else us) / 100
            return "${if (neg) "-" else ""}${tenths / 10}.${tenths % 10}"
        }

        /** The largest kHz value among `scaling_cur_freq` file contents; -1 when none parses. */
        fun maxKhz(values: List<String?>): Long {
            var best = -1L
            for (v in values) {
                val k = v?.trim()?.toLongOrNull() ?: continue
                if (k > best) best = k
            }
            return best
        }
    }
}
