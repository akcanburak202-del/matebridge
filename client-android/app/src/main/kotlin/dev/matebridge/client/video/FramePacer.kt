package dev.matebridge.client.video

/**
 * Estimated display vsync grid, fed from Choreographer frame times (System.nanoTime domain).
 * Written on the UI thread, read on the decoder thread; the whole state is one immutable [Grid], so a reader
 * always sees a phase and period that belong together ([grid]).
 *
 * The period follows an EMA of the observed vsync gaps. A gap that is not one period is either a missed
 * Choreographer callback (one-off, or an exact multiple of the period) or a real panel-rate change. The
 * authoritative source for a rate change is the display listener ([setNominalHz]); from samples alone a
 * persistent, consistent odd gap re-seeds the period after [RESEED_AFTER] samples, or [RESEED_AFTER_MULTIPLE]
 * when the gap is an integer multiple of the period (indistinguishable from a run of missed callbacks for a
 * while). [Grid.epoch] increases only when the period really changed by more than 10 percent.
 *
 * Phase: Choreographer reports the app vsync, which lags the display vsync by `appVsyncOffsetNanos`; the grid
 * is kept in display time (frame time - offset). [Grid.deadlineNs] is `presentationDeadlineNanos`.
 */
class VsyncClock(private val initialHz: Float = 60f) {
    companion object {
        const val RESEED_AFTER = 4
        const val RESEED_AFTER_MULTIPLE = 12
        /**
         * Default timestamp lead before the slot, an absolute time for every panel rate (T-061): the latch deadline
         * is a fixed time, not a fraction of the period. Device sweep at 60 Hz (33 ms gaps): P/2 = 8.3 ms 12.7-18%,
         * 3 ms 11.7%, 6 ms 2.4-4.6%, 12 ms 4.4%, 14.5 ms 3.7%; at 120 Hz 6 ms gave 0.2-1.1% repeats.
         */
        const val DEFAULT_LEAD_NS = 6_000_000L
        /** The lead never exceeds a period minus this. */
        const val LEAD_PERIOD_MARGIN_NS = 1_000_000L
        /**
         * Default presentation deadline (T-071): the real latch time is ~6 ms, HarmonyOS reports 13.3 ms. Device A/B
         * at 120 Hz while drawing: 6 ms gave 99.7% / 0.2% (8.3 / 16.7 ms intervals) vs 91.8% / 6.3% with the reported value.
         * Capped at a period minus [LEAD_PERIOD_MARGIN_NS].
         */
        const val DEFAULT_DEADLINE_NS = 6_000_000L
        /** [VsyncClock.deadlineOverrideNs] value meaning "use the display's reported deadline". */
        const val DEADLINE_DISPLAY = -1L
        /** [VsyncClock.deadlineOverrideNs] value meaning "use [DEFAULT_DEADLINE_NS]". */
        const val DEADLINE_DEFAULT = -2L
    }

    /** One consistent view of the grid. [lastNs] is a display-time vsync (-1: none yet). */
    class Grid(val lastNs: Long, val periodNs: Long, val epoch: Int, val deadlineNs: Long) {
        /** First point of the grid `vsync + phase * period` that is >= [tNs]. [phase] in 0..1. */
        fun slotAtOrAfter(tNs: Long, phase: Double): Long {
            val origin = lastNs + (periodNs * phase).toLong()
            if (tNs <= origin) return origin
            val n = (tNs - origin + periodNs - 1) / periodNs
            return origin + n * periodNs
        }

        /**
         * First grid point `lastNs + n * period` (any integer n, also before the anchor) that is >= [tNs].
         * Pure arithmetic, no clamping to the live anchor (T-060: a locked slot in the past stays in the past).
         */
        fun gridSlotAtOrAfter(tNs: Long): Long = lastNs + Math.floorDiv(tNs - lastNs + periodNs - 1, periodNs) * periodNs
    }

    @Volatile private var grid = Grid(-1, hzToPeriod(initialHz), 0, 0)
    @Volatile private var appOffsetNs = 0L

    /** Release-timestamp lead before the slot; negative = use half a period. Tunable (T-057). */
    @Volatile var leadOverrideNs = -1L

    /** Presentation deadline: >= 0 explicit (capped at a period), [DEADLINE_DISPLAY] = the display's own, [DEADLINE_DEFAULT] = 6 ms (T-071). */
    @Volatile var deadlineOverrideNs = DEADLINE_DEFAULT

    // UI-thread only: run of consecutive gaps that disagree with the current period.
    private var oddRun = 0
    private var oddDeltaNs = 0L

    private fun hzToPeriod(hz: Float) = (1_000_000_000.0 / hz.coerceIn(24f, 240f)).toLong()

    fun grid(): Grid = grid
    val hasSample: Boolean get() = grid.lastNs >= 0
    val periodNs: Long get() = grid.periodNs
    val deadlineNs: Long get() = grid.deadlineNs

    /** Timestamp lead handed to the codec: render time = slot - lead. */
    fun leadNs(): Long {
        val g = grid
        if (leadOverrideNs >= 0) return leadOverrideNs.coerceAtMost(g.periodNs)
        return DEFAULT_LEAD_NS.coerceAtMost((g.periodNs - LEAD_PERIOD_MARGIN_NS).coerceAtLeast(0))
    }

    /**
     * Display timing from `Display.getAppVsyncOffsetNanos()` and `presentationDeadlineNanos`. The phase is
     * kept: the anchor moves by the change of the offset.
     */
    fun setDisplayTiming(appVsyncOffsetNs: Long, presentationDeadlineNs: Long) {
        val g = grid
        val off = appVsyncOffsetNs.coerceIn(0, g.periodNs)
        val last = if (g.lastNs >= 0) g.lastNs + (appOffsetNs - off) else g.lastNs
        appOffsetNs = off
        val o = deadlineOverrideNs
        val deadline = when {
            o >= 0 -> o
            o == DEADLINE_DISPLAY -> presentationDeadlineNs
            else -> minOf(DEFAULT_DEADLINE_NS, g.periodNs - LEAD_PERIOD_MARGIN_NS)
        }
        grid = Grid(last, g.periodNs, g.epoch, deadline.coerceIn(0, g.periodNs))
    }

    /** Sets the nominal refresh rate (display mode change); keeps the phase. */
    fun setNominalHz(hz: Float) {
        oddRun = 0
        val g = grid
        val p = hzToPeriod(hz)
        grid = Grid(g.lastNs, p, if (periodChanged(g.periodNs, p)) g.epoch + 1 else g.epoch, g.deadlineNs)
    }

    /** Forgets phase and observations (streaming stopped). */
    fun reset() {
        oddRun = 0
        val g = grid
        grid = Grid(-1, g.periodNs, g.epoch, g.deadlineNs)
    }

    private fun periodChanged(a: Long, b: Long) = Math.abs(a - b) * 10 > a

    /** UI thread: one Choreographer callback. */
    fun onVsync(callbackTimeNs: Long) {
        val frameTimeNs = callbackTimeNs - appOffsetNs
        val g = grid
        if (g.lastNs < 0 || frameTimeNs <= g.lastNs) { grid = Grid(frameTimeNs, g.periodNs, g.epoch, g.deadlineNs); return }
        val delta = frameTimeNs - g.lastNs
        val k = Math.round(delta.toDouble() / g.periodNs).coerceAtLeast(1)
        val sample = delta / k
        val fits = k == 1L && sample in g.periodNs * 3 / 4..g.periodNs * 5 / 4
        var period = g.periodNs
        var epoch = g.epoch
        if (fits) {
            oddRun = 0
            period = (g.periodNs * 15 + sample) / 16
        } else {
            // Either a missed callback (one-off, often an exact multiple) or the real period changed (persistent).
            if (oddRun > 0 && Math.abs(delta - oddDeltaNs) * 8 <= oddDeltaNs) oddRun++ else oddRun = 1
            oddDeltaNs = delta
            val multiple = Math.abs(delta - k * g.periodNs) * 8 <= g.periodNs && k >= 2
            val need = if (multiple) RESEED_AFTER_MULTIPLE else RESEED_AFTER
            if (oddRun >= need && delta in 3_000_000L..50_000_000L) {
                if (periodChanged(g.periodNs, delta)) epoch++
                period = delta; oddRun = 0
            }
        }
        grid = Grid(frameTimeNs, period, epoch, g.deadlineNs)
    }

    /** First point of the grid `vsync + phase * period` that is >= [tNs]. [phase] in 0..1. */
    fun slotAtOrAfter(tNs: Long, phase: Double): Long = grid.slotAtOrAfter(tNs, phase)
}

/**
 * Chooses the render timestamp for each decoded frame (used with releaseOutputBuffer(idx, ns)).
 *
 * Buffer N means: present at the first vsync V >= decode-ready time + N vsync periods of slack, so the
 * added latency versus rendering at once is about N periods (<= 1 content frame at buffer 1 on a 60 or
 * 120 Hz display). The timestamp handed to the codec is V - period/2 (mid-period, robust to phase error;
 * the compositor shows the frame at V). Consecutive frames keep the content cadence (one cadence step
 * apart) so arrival jitter does not become uneven display times, but the cadence debt is bounded: when a
 * frame would be later than its decode-ready target by more than half a content frame, it re-anchors to
 * its own decode-ready target. A collision is reported only when the newer frame ends up on the previous
 * frame's slot (the older one is superseded: newest wins). Single-threaded (decoder thread).
 */
class FramePacer(
    private val vsync: VsyncClock,
    @Volatile var bufferFrames: Int,
    private val frameIntervalNs: Long,
) {
    /** T-059: effective content interval for a given panel period; null = the stream's own interval. */
    @Volatile var intervalProvider: ((Long) -> Long)? = null

    /**
     * [renderNs] goes to releaseOutputBuffer; [addedNs] is the delay versus the earliest possible vsync; [slotNs]
     * is the target vsync (display time). [lateDrop]: the frame found no slot within the latency bound and shares
     * the previous frame's slot instead of queueing behind it.
     */
    class Decision(
        val renderNs: Long, val collided: Boolean, val addedNs: Long, val skipped: Boolean = false,
        val slotNs: Long = 0, val lateDrop: Boolean = false,
        /** For a [lateDrop]: the slot this frame would have taken (display time); 0 otherwise. */
        val ownSlotNs: Long = 0,
    )

    private var lastVsyncNs = Long.MIN_VALUE

    /** Null when no vsync sample exists yet: the caller renders immediately. */
    fun schedule(nowNs: Long): Decision? {
        if (!vsync.hasSample) return null
        val grid = vsync.grid()
        val period = grid.periodNs
        val fi = intervalProvider?.invoke(period) ?: if (frameIntervalNs > 0) frameIntervalNs else period
        val earliest = grid.slotAtOrAfter(nowNs, 0.0)
        val base = grid.slotAtOrAfter(nowNs + bufferFrames.coerceIn(0, 2) * period, 0.0)
        val cadence = Math.round(fi.toDouble() / period).coerceAtLeast(1) * period
        var v = if (lastVsyncNs == Long.MIN_VALUE) base else maxOf(base, lastVsyncNs + cadence)
        if (v - base > fi / 2) v = base // re-anchor: too much cadence debt
        var collided = false
        if (lastVsyncNs != Long.MIN_VALUE && v <= lastVsyncNs) { v = lastVsyncNs; collided = true }
        lastVsyncNs = v
        return Decision(v - vsync.leadNs(), collided, (v - earliest).coerceAtLeast(0), slotNs = v)
    }

    fun reset() { lastVsyncNs = Long.MIN_VALUE }
}
