package dev.matebridge.client.video

/**
 * Adaptive frame scheduling (T-052, T-057). Replaces the fixed N-period jitter buffer of [FramePacer], which
 * was only an integer shift of the vsync grid (ceil(t + P) = ceil(t) + P) and therefore never changed
 * which vsync a jittery frame landed on.
 *
 * The host captures frames at an exactly regular cadence, so the capture timestamp is the ideal clock:
 *  - x = readyNs - captureUs*1000 (the constant host/tablet clock offset cancels out); m = its minimum over
 *    a sliding [WINDOW_NS] window = best-case pipeline delay; dev = x - b >= 0 is this frame's extra delay,
 *    where b is m followed with a bounded step per frame ([BASE_SLEW_UP_NS]/[BASE_SLEW_DOWN_NS]).
 *  - D = p99 of recent dev + margin + feedback [extraNs], followed with a bounded step per frame too, and at
 *    most 1.5 periods. Target display time = readyNs - dev + D (+ the presentation deadline), i.e.
 *    capture + b + D: frames are evenly spaced by the content interval, so the jitter is absorbed and each
 *    frame maps to its own vsync. Added latency is about D (usually below one vsync) plus the wait for the grid.
 *  - Slot = first vsync >= target, never before the earliest vsync a frame handed over now can make, never
 *    after the earliest + one period (the latency bound applies to the FINAL slot, T-057), at least one period
 *    after the previous slot. A frame that would land beyond the bound shares the previous frame's slot
 *    (collided + lateDrop): the newer frame replaces a still-pending older one or is dropped, instead of being
 *    pushed onto a later free slot.
 *  - [onSkipWindow] closes the loop with the measured skip percentage: more slack when frames are skipped,
 *    slowly less when none are.
 *  - Phase and period come from one [VsyncClock.Grid] snapshot; the panel-rate epoch (not a period
 *    comparison) resets the state; an idle gap longer than [IDLE_REANCHOR_NS] re-anchors it.
 *
 *  - Phase lock (T-060): when the content interval is about one panel period (+-15%, no thinning left to do),
 *    per-frame rounding of each time to "its" vsync flips jittery frames between two slots (double slot + empty
 *    slot, 33 ms gaps at 60 Hz). Then slots follow frame order instead: slot(n) = slot(n-1) + round(dCapture/P),
 *    snapped to the real grid. The lock slot is first chosen so the arrival window [ideal, ideal + p99 jitter]
 *    sits in the middle of the slot (never earlier than the worst case needs). The error between that ideal
 *    and the slot is tracked on the jitter-free ideal time, so one late frame never moves the lock: it either
 *    fits its slot or is dropped (newest wins) and the next frames continue on the lock. Only an error above
 *    half a period (or missed slots) that lasts [REPHASE_FRAMES] frames re-phases (hysteresis).
 *
 * Decoder/output thread only for [schedule]/[reset]; [onSkipWindow] may come from another thread.
 */
class AdaptivePacer(private val vsync: VsyncClock, private val frameIntervalNs: Long = 0) {
    companion object {
        const val WINDOW_NS = 2_000_000_000L
        const val DEV_SAMPLES = 256
        const val PERCENTILE = 99
        const val MARGIN_NS = 500_000L
        /** Skip rate above which a window counts toward adding slack, below which toward removing it. */
        const val SKIP_HIGH_PCT = 3.0
        const val SKIP_LOW_PCT = 1.0
        /** Consecutive high windows before one more level of slack is added. */
        const val HIGH_WINDOWS = 3
        /** Consecutive low windows before a level is removed. */
        const val LOW_WINDOWS = 5
        /** Windows after any level change during which no further change is made (anti-flapping). */
        const val HOLD_WINDOWS = 10
        const val MAX_LEVEL = 2
        /** D never exceeds this many half periods (3 = 1.5 periods). */
        const val MAX_D_HALF_PERIODS = 3L
        /** Per-frame slew of the baseline m: rises slowly (a spike must not look like a new normal), falls faster. */
        const val BASE_SLEW_UP_NS = 50_000L
        const val BASE_SLEW_DOWN_NS = 200_000L
        /** Per-frame slew of D: rises fast enough to absorb new jitter within a few frames, falls slowly. */
        const val D_SLEW_UP_NS = 1_000_000L
        const val D_SLEW_DOWN_NS = 100_000L
        /** No frame for this long (static screen): window, baseline and slot are forgotten. */
        const val IDLE_REANCHOR_NS = 1_000_000_000L
        /** Phase lock applies when the content interval is within this fraction of the panel period. */
        const val LOCK_TOLERANCE = 0.15
        /** Consecutive frames with slot error above half a period (or a missed slot) before re-phasing. */
        const val REPHASE_FRAMES = 30
    }

    // Monotonic deque for the sliding-window minimum of x (values increasing from first to last).
    private val minT = ArrayDeque<Long>()
    private val minX = ArrayDeque<Long>()
    private val devs = LongArray(DEV_SAMPLES)
    private var devN = 0
    private var devPos = 0
    private var lastSlot = Long.MIN_VALUE
    private var lastPeriod = 0L
    private var epoch = -1
    private var lastScheduleNs = Long.MIN_VALUE
    private var baseNs = Long.MIN_VALUE // slewed baseline b
    private var dNs = Long.MIN_VALUE // slewed D
    private var lockSlot = Long.MIN_VALUE // slot of the previous frame on the phase lock (MIN = not locked)
    private var badRun = 0
    private var lastCaptureUs = Long.MIN_VALUE

    /**
     * Slack level added by the skip feedback on top of the measured jitter: 0 = none, 1 = half a vsync,
     * 2 = a full extra vsync. Only raised when the skip rate stays high for [HIGH_WINDOWS] windows.
     */
    @Volatile var level = 0
        private set
    val extraNs: Long get() = when (level) { 0 -> 0L; 1 -> lastPeriod / 2; else -> lastPeriod }
    private var highRun = 0
    private var lowRun = 0
    private var hold = 0

    /** T-059: effective content interval for a given panel period; null = the stream's own interval. */
    @Volatile var intervalProvider: ((Long) -> Long)? = null

    /** T-060 diagnostics: slots are currently assigned on the phase lock. */
    @Volatile var phaseLock = false
        private set

    /** T-060 diagnostics: number of re-phasings of an established lock since the last reset (cumulative). */
    @Volatile var rephases = 0L
        private set

    /** Diagnostics: the slack D applied to the latest frame. */
    @Volatile var lastDNs = 0L
        private set

    /** Null when no vsync sample or capture time is known: the caller renders at once. */
    fun schedule(captureUs: Long?, nowNs: Long): FramePacer.Decision? {
        if (captureUs == null || !vsync.hasSample) return null
        val grid = vsync.grid() // one snapshot: phase, period, epoch and deadline belong together
        val period = grid.periodNs
        if (epoch != grid.epoch) {
            resetState() // panel rate really changed (60 <-> 120): everything measured against the old grid is stale
            epoch = grid.epoch
        } else if (lastScheduleNs != Long.MIN_VALUE && nowNs - lastScheduleNs > IDLE_REANCHOR_NS) {
            reanchor()
        }
        lastScheduleNs = nowNs
        lastPeriod = period
        val prevCaptureUs = lastCaptureUs
        lastCaptureUs = captureUs

        val x = nowNs - captureUs * 1000
        while (minX.isNotEmpty() && minX.last() >= x) { minX.removeLast(); minT.removeLast() }
        minX.addLast(x); minT.addLast(nowNs)
        while (minT.first() < nowNs - WINDOW_NS) { minT.removeFirst(); minX.removeFirst() }
        val m = minX.first()
        baseNs = if (baseNs == Long.MIN_VALUE) m else slew(baseNs, m, BASE_SLEW_UP_NS, BASE_SLEW_DOWN_NS)
        val dev = (x - baseNs).coerceAtLeast(0)
        // Slack comes from the jitter seen so far: a frame that is worse than everything before it is late.
        // Content faster than the panel (e.g. 120 fps on a 60 Hz panel): some frames must be dropped. Never queue
        // them behind each other (that builds latency and stalls the decoder's output buffers): one vsync of slack
        // at most, and a frame whose slot is already taken replaces the older one (newest wins).
        val fi = intervalProvider?.invoke(period) ?: if (frameIntervalNs > 0) frameIntervalNs else period
        val surplus = fi * 4 < period * 3
        val lockable = Math.abs(fi - period) <= period * LOCK_TOLERANCE
        val jitter = percentile()
        val dTarget = if (surplus) (jitter + MARGIN_NS).coerceAtMost(period + MARGIN_NS)
        else if (lockable) (jitter + MARGIN_NS + extraNs).coerceAtMost(period)
        else (jitter + MARGIN_NS + extraNs).coerceAtMost(MAX_D_HALF_PERIODS * period / 2)
        val d = if (dNs == Long.MIN_VALUE) dTarget else slew(dNs, dTarget, D_SLEW_UP_NS, D_SLEW_DOWN_NS)
        dNs = d
        devs[devPos] = dev
        devPos = (devPos + 1) % DEV_SAMPLES
        if (devN < DEV_SAMPLES) devN++
        lastDNs = d
        // Earliest vsync a frame handed over now can still make (the compositor needs the deadline before it).
        val earliest = grid.slotAtOrAfter(nowNs + grid.deadlineNs, 0.0)
        if (lockable) {
            return scheduleLocked(grid, nowNs, captureUs, prevCaptureUs, dev, d, jitter, earliest)
        }
        phaseLock = false; lockSlot = Long.MIN_VALUE; badRun = 0
        val targetSlot = grid.slotAtOrAfter(nowNs - dev + d + grid.deadlineNs, 0.0)
        val late = targetSlot < earliest // the frame missed its own ideal slot: the content gap is our doing
        // Latency bound on the final slot: at most one vsync after the earliest possible one.
        val limit = earliest + period
        var slot = minOf(maxOf(targetSlot, earliest), limit)
        var collided = false
        var lateDrop = false
        val previous = lastSlot
        if (previous != Long.MIN_VALUE && slot <= previous) {
            // Same vsync as the previous frame (or earlier): the next free one, unless that is beyond the bound.
            val pushed = previous + period
            if (!surplus && pushed <= limit) slot = pushed
            else { slot = previous; collided = true; lateDrop = !surplus }
        }
        lastSlot = slot
        val cadence = Math.round(fi.toDouble() / period).coerceAtLeast(1) * period
        // A skip: a vsync went by without a new frame although this one was decoded (late, not an idle source).
        val skipped = late && previous != Long.MIN_VALUE && (slot - previous) * 2 > cadence * 3
        return FramePacer.Decision(
            slot - vsync.leadNs(), collided, (slot - earliest).coerceAtLeast(0), skipped,
            slotNs = slot, lateDrop = lateDrop,
        )
    }

    /** Slot assignment on the phase lock (see class doc). [dev] is this frame's extra delay, [jitter] the p99. */
    private fun scheduleLocked(
        grid: VsyncClock.Grid, nowNs: Long, captureUs: Long, prevCaptureUs: Long, dev: Long, d: Long, jitter: Long,
        earliest: Long,
    ): FramePacer.Decision {
        val period = grid.periodNs
        val ideal = nowNs - dev + grid.deadlineNs // jitter-free ready time of this frame, plus the deadline
        val centered = ideal + jitter / 2 + period / 2 // slot point that puts the arrival window mid-slot
        val minimum = ideal + d // slot point below which the worst-case jitter would miss the slot
        fun acquire(): Long {
            val nearest = grid.slotAtOrAfter(centered - period / 2, 0.0)
            return maxOf(nearest, grid.slotAtOrAfter(minimum, 0.0), earliest)
        }
        // Latency bound (T-057) for the final slot: one period after the earliest possible one, plus the half-jitter
        // the centered phase adds on purpose.
        val latencyBound = period + minOf(jitter, period) / 2
        var slot: Long
        if (lockSlot == Long.MIN_VALUE || prevCaptureUs == Long.MIN_VALUE) {
            slot = acquire()
            badRun = 0
        } else {
            val k = Math.round((captureUs - prevCaptureUs) * 1000.0 / period).coerceAtLeast(0)
            slot = grid.gridSlotAtOrAfter(lockSlot + k * period - period / 2) // may lie before the live anchor
            // The lock is off when a fresh acquisition would pick another slot: the error to the centered point
            // is above half a period, or the worst-case jitter / this frame would miss the slot. The error is
            // measured on the jitter-free ideal time, so one late frame does not count as drift by itself.
            if (slot != acquire() || slot > earliest + latencyBound) badRun++ else badRun = 0
            if (badRun >= REPHASE_FRAMES) {
                slot = acquire()
                badRun = 0
                rephases++
            }
        }
        phaseLock = true
        lockSlot = slot
        val previous = lastSlot
        if (previous != Long.MIN_VALUE && (slot < earliest || slot > earliest + latencyBound)) {
            // Too late for its own slot, or a backlog that would exceed the latency bound: dropped (newest wins, it
            // shares the previous slot), the next frames stay on the lock.
            return FramePacer.Decision(
                previous - vsync.leadNs(), true, 0, slot < earliest, slotNs = previous, lateDrop = true,
            )
        }
        var collided = false
        if (previous != Long.MIN_VALUE && slot <= previous) { slot = previous; collided = true }
        lastSlot = slot
        return FramePacer.Decision(
            slot - vsync.leadNs(), collided, (slot - earliest).coerceAtLeast(0), false, slotNs = slot,
        )
    }

    private fun slew(cur: Long, target: Long, up: Long, down: Long) =
        if (target > cur) minOf(target, cur + up) else maxOf(target, cur - down)

    private fun percentile(): Long {
        if (devN == 0) return 0
        val sorted = devs.copyOf(devN).also { it.sort() }
        return sorted[((devN * PERCENTILE + 99) / 100 - 1).coerceIn(0, devN - 1)]
    }

    /**
     * Feedback once per stats window from the pacer's own schedule ([FramePacer.Decision.skipped]); [skipPct]
     * null = no measurement. Conservative: a level is added only after [HIGH_WINDOWS] high windows in a row,
     * removed after [LOW_WINDOWS] low ones, and never within [HOLD_WINDOWS] of the previous change.
     */
    fun onSkipWindow(skipPct: Double?) {
        if (skipPct == null) return
        if (hold > 0) hold--
        if (skipPct > SKIP_HIGH_PCT) { highRun++; lowRun = 0 }
        else if (skipPct < SKIP_LOW_PCT) { lowRun++; highRun = 0 }
        else { highRun = 0; lowRun = 0 }
        if (hold > 0) return
        if (highRun >= HIGH_WINDOWS && level < MAX_LEVEL) { level++; hold = HOLD_WINDOWS; highRun = 0 }
        else if (lowRun >= LOW_WINDOWS && level > 0) { level--; hold = HOLD_WINDOWS; lowRun = 0 }
    }

    /** After a long idle gap: measurements restart, the feedback level is kept. */
    private fun reanchor() {
        minT.clear(); minX.clear()
        devN = 0; devPos = 0
        lastSlot = Long.MIN_VALUE
        lockSlot = Long.MIN_VALUE; badRun = 0; lastCaptureUs = Long.MIN_VALUE; phaseLock = false
        baseNs = Long.MIN_VALUE; dNs = Long.MIN_VALUE
    }

    private fun resetState() {
        reanchor()
        level = 0; highRun = 0; lowRun = 0; hold = 0
        rephases = 0
    }

    fun reset() { resetState(); lastPeriod = 0; epoch = -1; lastScheduleNs = Long.MIN_VALUE }
}
