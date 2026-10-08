package dev.matebridge.client.video

/**
 * Adaptive frame scheduling (T-052, T-057). Replaced the fixed N-period jitter buffer (removed in T-303), which
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
 *  - Lone frames (T-115): a lockable frame with no predecessor in the stream (first frame, or a capture
 *    gap above [LOCK_GAP_PERIODS] periods: a keystroke, a cursor blink, the first frame of a motion) gets no hold: it
 *    goes to the earliest slot, no lock is formed, and its delay stays out of the jitter history (it is no stream
 *    jitter, and it would push the p99 to its one-period cap). The next continuous frame acquires the lock as usual
 *    (replacing the lone frame when both fall on one vsync). Until the history holds [WARMUP_SAMPLES] frames, a late
 *    locked frame re-acquires the lock at once (see [scheduleLocked]).
 *  - Integer cadence (T-208): the lock also applies when the content interval is about n panel periods for an integer
 *    n up to [MAX_LOCK_MULTIPLE] (60 fps content on a 120 Hz panel: n = 2). The lattice already steps by
 *    k = round(dCapture/P) per frame, so every frame is held n vsyncs on one phase instead of 1 or 3 by per-frame
 *    rounding. With n = 1 every rule and value is the T-060 one; with n = 2 three limits scale: D is capped at
 *    1.5 periods (the unlocked cap this content had before, so no extra buffering), the latency bound is n periods
 *    plus the half-jitter, and a lone-frame gap is [LOCK_GAP_PERIODS] content intervals.
 *  - A panel-rate change (epoch) re-times everything, except when the content interval stays the same and is locked
 *    on both grids, n = 2 on one of them (a 60 fps stream while the panel goes 60 <-> 120): the stream's own
 *    measurements (baseline, jitter history, last capture and slot) are kept and only the grid state (lock, slack
 *    level, D) starts over, so the first frame on the new grid re-acquires a centred lock with a full history (one
 *    irregular interval at most, no warm-up re-locks).
 *  - A locked frame at n = 2 that missed its lattice slot is shown on the next free vsync instead of being folded onto
 *    the previous slot (see [scheduleLocked]); n = 1 keeps the T-060 drop rule.
 *  - T-220: n may change on one grid when the content interval is inferred from the arrivals ([FrameInterval.resolve]);
 *    the lock and D then start over ([recadence]).
 *
 * Decoder/output thread only for [schedule]/[reset]; [onSkipWindow] may come from another thread.
 */
class AdaptivePacer(
    private val vsync: VsyncClock,
    private val frameIntervalNs: Long = 0,
    /** T-251: developer knobs; the default changes nothing. */
    private val tuning: PacerTuning = PacerTuning.STANDARD,
) {
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
        /**
         * T-065: the lock only predicts the next slot from the previous one in a continuous stream. A capture gap
         * above this many panel periods (sparse updates: a keystroke, a cursor blink) is no stream; the lock is
         * re-acquired from the frame's own ready time. Three periods is above any content interval that is still
         * lockable (about one period, thinned frames up to two) plus jitter, and below the host idle cadence.
         */
        const val LOCK_GAP_PERIODS = 3L
        /**
         * T-115: jitter samples below which the p99 hold is not trusted yet: a late locked frame then re-acquires the
         * lock at once instead of waiting for [REPHASE_FRAMES]. With 32 samples the p99 is the maximum.
         */
        const val WARMUP_SAMPLES = 32
        /** T-208: largest integer multiple of the panel period a content interval may be to get the phase lock. */
        const val MAX_LOCK_MULTIPLE = 2L
        /** T-208: a panel-rate change keeps the stream's measurements when the content interval moved less than this fraction. */
        const val SAME_INTERVAL_FRACTION = 0.05
    }

    // Monotonic deque for the sliding-window minimum of x (values increasing from first to last).
    private val minT = ArrayDeque<Long>()
    private val minX = ArrayDeque<Long>()
    private val devs = LongArray(DEV_SAMPLES)
    private val sortScratch = LongArray(DEV_SAMPLES)
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
    private var lastFi = 0L // content interval of the previous frame
    private var lastN = 0L // its lock multiple (0 = not lockable)

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

    /** T-069: when set, [schedule] writes the intermediate values of the latest frame into it (output thread). */
    @Volatile var probe: PaceProbe? = null

    /** Diagnostics: the slack D applied to the latest frame. */
    @Volatile var lastDNs = 0L
        private set

    /** T-251 diagnostics: p99 jitter and the cap that applied to D for the latest frame. */
    @Volatile var lastJitterNs = 0L
        private set
    @Volatile var lastCapNs = 0L
        private set

    /** T-251: the components of D for the log (`render ev=present`). */
    fun diag() = PacerDiag(level, lastJitterNs / 1000, extraNs / 1000, lastCapNs / 1000)

    /** Null when no vsync sample or capture time is known: the caller renders at once. */
    fun schedule(captureUs: Long?, nowNs: Long): PacerDecision? {
        if (captureUs == null || !vsync.hasSample) return null
        return scheduleOn(vsync.grid(), captureUs, nowNs) // one snapshot: phase, period, epoch and deadline belong together
    }

    /** [schedule] on a given grid snapshot (also used to replay recorded traces). */
    internal fun scheduleOn(grid: VsyncClock.Grid, captureUs: Long, nowNs: Long): PacerDecision {
        val period = grid.periodNs
        val fi = intervalProvider?.invoke(period) ?: if (frameIntervalNs > 0) frameIntervalNs else period
        val n = lockMultiple(fi, period) // T-208: content interval = n panel periods (0 = no lock)
        val idle = lastScheduleNs != Long.MIN_VALUE && nowNs - lastScheduleNs > IDLE_REANCHOR_NS
        if (epoch != grid.epoch) {
            // Panel rate really changed (60 <-> 120): everything measured against the old grid is stale, unless the
            // stream itself runs on unchanged at an integer cadence on both grids (T-208: 60 fps while the panel goes
            // 60 <-> 120): then only the grid state starts over. 1:1 streams (and the A/B switch off) reset as before.
            val sameStream = epoch >= 0 && lastScheduleNs != Long.MIN_VALUE && !idle && lastN > 0 && n > 0 &&
                maxOf(lastN, n) > 1 && Math.abs(fi - lastFi) <= lastFi * SAME_INTERVAL_FRACTION
            if (sameStream) regrid() else resetState()
            epoch = grid.epoch
        } else if (idle) {
            reanchor()
        } else if (lastN > 0 && n > 0 && n != lastN) {
            recadence() // T-220: the inferred content cadence changed (1 <-> 2) on the same grid
        }
        lastFi = fi; lastN = n
        val readyGapNs = if (lastScheduleNs == Long.MIN_VALUE) Long.MAX_VALUE else nowNs - lastScheduleNs
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
        val surplus = fi * 4 < period * 3
        val lockable = n > 0
        val jitter = percentile()
        val dTarget = if (surplus) (jitter + MARGIN_NS).coerceAtMost(period + MARGIN_NS)
        else (jitter + MARGIN_NS + extraNs).coerceAtMost(tuning.capHalfFor(n) * period / 2)
        lastJitterNs = jitter
        lastCapNs = if (surplus) period + MARGIN_NS else tuning.capHalfFor(n) * period / 2
        val d = if (dNs == Long.MIN_VALUE) dTarget else slew(dNs, dTarget, D_SLEW_UP_NS, D_SLEW_DOWN_NS)
        dNs = d
        // T-115: a lone frame (no predecessor in the stream) is no stream jitter: its delay stays out of the history.
        val lone = lockable && (prevCaptureUs == Long.MIN_VALUE || isGap(captureUs, prevCaptureUs, n * period))
        if (!lone) {
            devs[devPos] = dev
            devPos = (devPos + 1) % DEV_SAMPLES
            if (devN < DEV_SAMPLES) devN++
        }
        lastDNs = d
        // Earliest vsync a frame handed over now can still make (the compositor needs the deadline before it).
        val earliest = grid.slotAtOrAfter(nowNs + grid.deadlineNs, 0.0)
        probe?.let {
            it.nowVsyncLastNs = grid.lastNs; it.periodNs = period; it.epoch = grid.epoch; it.deadlineNs = grid.deadlineNs
            it.devNs = dev; it.dNs = d; it.jitterNs = jitter; it.earliestNs = earliest; it.level = level
            it.path = PaceProbe.PATH_UNLOCKED
        }
        if (lockable) {
            return scheduleLocked(grid, nowNs, captureUs, prevCaptureUs, dev, d, jitter, earliest, lone, readyGapNs, n)
        }
        phaseLock = false; lockSlot = Long.MIN_VALUE; badRun = 0
        val targetSlot = grid.slotAtOrAfter(nowNs - dev + d + grid.deadlineNs, 0.0)
        probe?.let { it.acquireNs = targetSlot }
        val late = targetSlot < earliest // the frame missed its own ideal slot: the content gap is our doing
        // Latency bound on the final slot: at most one vsync after the earliest possible one.
        val limit = earliest + period + tuning.boundExtraHalf(n) * period / 2
        var slot = minOf(maxOf(targetSlot, earliest), limit)
        var collided = false
        var lateDrop = false
        val ownSlot = slot
        val previous = lastSlot
        if (previous != Long.MIN_VALUE && slot <= previous) {
            // Same vsync as the previous frame (or earlier): the next free one, unless that is beyond the bound.
            val pushed = previous + period
            if (!surplus && pushed <= limit) slot = pushed
            else { slot = previous; collided = true; lateDrop = !surplus }
        }
        lastSlot = slot
        val cadence = cadenceNs(fi, period)
        // A skip: a vsync went by without a new frame although this one was decoded (late, not an idle source).
        // T-220: the previous frame is held at least one vsync longer than the cadence (was "> 1.5 x cadence", which
        // missed a 3-vsync hold at cadence 2; at cadence 1 both are the same).
        val skipped = late && previous != Long.MIN_VALUE && slot - previous > cadence + period / 2
        return PacerDecision(
            slot - vsync.leadNs(), collided, (slot - earliest).coerceAtLeast(0), skipped,
            slotNs = slot, lateDrop = lateDrop, ownSlotNs = if (lateDrop) ownSlot else 0,
        )
    }

    /**
     * Slot assignment on the phase lock (see class doc). [dev] is this frame's extra delay, [jitter] the p99, [n] the
     * content interval in panel periods (T-208).
     */
    private fun scheduleLocked(
        grid: VsyncClock.Grid, nowNs: Long, captureUs: Long, prevCaptureUs: Long, dev: Long, d: Long, jitter: Long,
        earliest: Long, lone: Boolean, readyGapNs: Long, n: Long,
    ): PacerDecision {
        val period = grid.periodNs
        val ideal = nowNs - dev + grid.deadlineNs // jitter-free ready time of this frame, plus the deadline
        fun acquire(): Long {
            val nearest = grid.slotAtOrAfter(ideal + jitter / 2, 0.0) // centres the arrival window mid-slot
            // slot point below which the worst-case jitter would miss the slot
            val minimum = ideal + d
            return maxOf(nearest, grid.slotAtOrAfter(minimum, 0.0), earliest)
        }
        // Latency bound (T-057) for the final slot: one period after the earliest possible one, plus the half-jitter
        // the centered phase adds on purpose. T-208: n periods at an integer cadence n (D may then exceed a period).
        val latencyBound = n * period + minOf(jitter, period) / 2 + tuning.boundExtraHalf(n) * period / 2
        var slot: Long
        val sparse = prevCaptureUs != Long.MIN_VALUE && isGap(captureUs, prevCaptureUs, n * period)
        if (lone) {
            // T-115: a lone frame gains nothing from a hold (there is no cadence to keep), so it takes the earliest
            // slot. No lock is formed from it: the next continuous frame acquires one from its own timing.
            badRun = 0
            phaseLock = false
            lockSlot = Long.MIN_VALUE
            probe?.let {
                it.path = if (sparse) PaceProbe.PATH_EARLY_SPARSE else PaceProbe.PATH_EARLY_FIRST
                it.acquireNs = acquire() // the slot the hold would have chosen: the gain is acquire_ns - slot_ns
                it.lockSlotNs = 0
            }
            slot = earliest
            var collided = false
            val prev = lastSlot
            // The previous frame's slot is still ahead (it came very late): newest wins, like a fresh acquisition.
            if (prev != Long.MIN_VALUE && slot <= prev) { slot = prev; collided = true }
            lastSlot = slot
            return PacerDecision(
                slot - vsync.leadNs(), collided, (slot - earliest).coerceAtLeast(0), false, slotNs = slot,
            )
        }
        if (lockSlot == Long.MIN_VALUE || prevCaptureUs == Long.MIN_VALUE || sparse) {
            // A fresh acquisition is never dropped as late: this frame is the newest one on screen (T-065).
            // T-115: after a lone frame this is the second frame of the stream. When the lone frame came later than
            // the stream's hold (a cold decoder), it may sit on this frame's slot: this newer frame then replaces it at
            // the same vsync (nothing visible is lost) and the lock stays centred, instead of starting one vsync late
            // and losing a frame at the re-phase [REPHASE_FRAMES] later.
            slot = acquire()
            badRun = 0
            phaseLock = true
            lockSlot = slot
            probe?.let { it.path = if (sparse) PaceProbe.PATH_SPARSE else PaceProbe.PATH_ACQUIRE; it.acquireNs = slot; it.lockSlotNs = slot }
            var collided = false
            val prev = lastSlot
            if (prev != Long.MIN_VALUE && slot <= prev) { slot = prev; collided = true }
            lastSlot = slot
            return PacerDecision(
                slot - vsync.leadNs(), collided, (slot - earliest).coerceAtLeast(0), false, slotNs = slot,
            )
        } else {
            val k = Math.round((captureUs - prevCaptureUs) * 1000.0 / period).coerceAtLeast(0)
            slot = grid.gridSlotAtOrAfter(lockSlot + k * period - period / 2) // may lie before the live anchor
            // The lock is off when a fresh acquisition would pick another slot: the error to the centered point
            // is above half a period, or the worst-case jitter / this frame would miss the slot. The error is
            // measured on the jitter-free ideal time, so one late frame does not count as drift by itself.
            val acq = acquire()
            if (slot != acq || slot > earliest + latencyBound) badRun++ else badRun = 0
            probe?.let { it.path = PaceProbe.PATH_LOCKED; it.k = k; it.acquireNs = acq; it.badRun = badRun }
            if (badRun >= REPHASE_FRAMES) {
                slot = acquire()
                badRun = 0
                rephases++
                probe?.let { it.path = PaceProbe.PATH_REPHASE }
            }
        }
        phaseLock = true
        val previous = lastSlot
        val late = previous != Long.MIN_VALUE && (slot < earliest || slot > earliest + latencyBound)
        val missed = slot < earliest
        // A burst (frames handed over faster than they were captured) is a backlog, not an off lock: the latency bound
        // drops it as before.
        val burst = readyGapNs < (captureUs - prevCaptureUs) * 1000 / 2
        if (late && devN < WARMUP_SAMPLES && (missed || !burst)) {
            // T-115 warm-up: a lock acquired on a thin jitter history (a fresh session, or motion after lone frames
            // whose delay is kept out of the history) is easily off: too tight, or anchored on a frame that came late.
            // Until the history holds [WARMUP_SAMPLES] frames, a late locked frame re-acquires the lock from its own
            // timing at once instead of starting a drop run that only the [REPHASE_FRAMES] hysteresis would end:
            //  - missed its slot: the new slot is later (one repeated vsync, nothing dropped);
            //  - beyond the latency bound (lock too late): the new slot is earlier; when that is the previous frame's
            //    slot, this newer frame replaces it (T-065), and the lock is centred from then on.
            val own = slot
            val acquired = acquire()
            slot = acquired
            var collided = false
            if (slot <= previous) {
                if (missed) slot = grid.gridSlotAtOrAfter(previous + period / 2) else { slot = previous; collided = true }
            }
            lockSlot = if (collided) acquired else slot
            badRun = 0
            probe?.let { it.path = PaceProbe.PATH_WARMUP; it.acquireNs = acquired; it.lockSlotNs = lockSlot; it.badRun = 0 }
            lastSlot = slot
            // Sharing the previous slot is the same outcome as a late drop (and counted as one); only the lock moved.
            return PacerDecision(
                slot - vsync.leadNs(), collided, (slot - earliest).coerceAtLeast(0), missed, slotNs = slot,
                lateDrop = collided, ownSlotNs = if (collided) own else 0,
            )
        }
        lockSlot = slot
        probe?.let { it.lockSlotNs = slot }
        if (n > 1 && missed && previous != Long.MIN_VALUE && earliest > previous) {
            // T-208: at an integer cadence a frame that missed its lattice slot is shown on the earliest vsync after
            // the previous frame's (that one is held longer), not folded onto the previous slot; the lock stays on the
            // lattice (slot_ns > lock_slot_ns in the trace). One late frame costs one uneven pair of holds, and a
            // pipeline that got slower keeps an even n-vsync cadence until the re-phase instead of a drop run. When the
            // next frame is on time again and lands on the same vsync, it replaces this one (newest wins).
            lastSlot = earliest
            val cadence = n * period
            return PacerDecision(
                earliest - vsync.leadNs(), false, 0, earliest - previous > cadence + period / 2, slotNs = earliest, // T-220
            )
        }
        if (late) {
            // Too late for its own slot, or a backlog that would exceed the latency bound: dropped (newest wins, it
            // shares the previous slot), the next frames stay on the lock.
            return PacerDecision(
                previous - vsync.leadNs(), true, 0, slot < earliest, slotNs = previous, lateDrop = true, ownSlotNs = slot,
            )
        }
        var collided = false
        if (previous != Long.MIN_VALUE && slot <= previous) { slot = previous; collided = true }
        lastSlot = slot
        return PacerDecision(
            slot - vsync.leadNs(), collided, (slot - earliest).coerceAtLeast(0), false, slotNs = slot,
        )
    }

    /** [intervalNs]: the lockable content interval (n periods); a gap is above [LOCK_GAP_PERIODS] of them. */
    private fun isGap(captureUs: Long, prevCaptureUs: Long, intervalNs: Long) =
        (captureUs - prevCaptureUs) * 1000 > LOCK_GAP_PERIODS * intervalNs

    /**
     * T-208: n when the content interval [fi] is within [LOCK_TOLERANCE] of n panel periods, 1 <= n <= [MAX_LOCK_MULTIPLE]; 0 = no lock. For n = 1 this is exactly the T-060 condition.
     */
    private fun lockMultiple(fi: Long, period: Long): Long {
        if (period <= 0) return 0
        val n = Math.round(fi.toDouble() / period)
        return if (n in 1..MAX_LOCK_MULTIPLE && Math.abs(fi - n * period) <= n * period * LOCK_TOLERANCE) n else 0
    }

    private fun slew(cur: Long, target: Long, up: Long, down: Long) =
        if (target > cur) minOf(target, cur + up) else maxOf(target, cur - down)

    private fun percentile(): Long {
        if (devN == 0) return 0
        devs.copyInto(sortScratch, 0, 0, devN)
        java.util.Arrays.sort(sortScratch, 0, devN) // T-303: preallocated, no per-frame garbage
        return sortScratch[((devN * PERCENTILE + 99) / 100 - 1).coerceIn(0, devN - 1)]
    }

    /**
     * Feedback once per stats window from the presentation metric (T-220: `skip_pct`, the share of frames held longer
     * than their content cadence, [VideoStats.Snapshot.skipPct]); [skipPct] null = no measurement. Conservative: a
     * level is added only after [HIGH_WINDOWS] high windows in a row, removed after [LOW_WINDOWS] low ones, and never
     * within [HOLD_WINDOWS] of the previous change.
     */
    fun onSkipWindow(skipPct: Double?) {
        if (skipPct == null || !tuning.feedback) return
        if (hold > 0) hold--
        if (skipPct > SKIP_HIGH_PCT) { highRun++; lowRun = 0 }
        else if (skipPct < SKIP_LOW_PCT) { lowRun++; highRun = 0 }
        else { highRun = 0; lowRun = 0 }
        if (hold > 0) return
        if (highRun >= HIGH_WINDOWS && level < MAX_LEVEL) { level++; hold = HOLD_WINDOWS; highRun = 0 }
        else if (lowRun >= LOW_WINDOWS && level > 0) { level--; hold = HOLD_WINDOWS; lowRun = 0 }
    }

    /** After a long idle gap: measurements restart (jitter distribution, D and the baseline b too), the feedback level is kept. */
    private fun reanchor() {
        minT.clear(); minX.clear()
        lastSlot = Long.MIN_VALUE
        lockSlot = Long.MIN_VALUE; badRun = 0; lastCaptureUs = Long.MIN_VALUE; phaseLock = false
        devN = 0; devPos = 0
        baseNs = Long.MIN_VALUE; dNs = Long.MIN_VALUE
    }

    /**
     * T-252: a backlog was caught up (its newest frame was shown at once, the others were skipped): the measurements of
     * the backlog frames (their delay is the backlog, not jitter) are not used, the pacer restarts like after an idle
     * gap (the next frame is a lone frame at the earliest slot, the one after acquires a lock). The feedback level is
     * kept. Output thread only, like [schedule].
     */
    fun reanchorAfterCatchUp() {
        reanchor()
        lastScheduleNs = Long.MIN_VALUE
    }

    /**
     * T-220: the content cadence n changed on an unchanged grid (the inferred cadence of [FrameInterval.resolve] went
     * 1 <-> 2: a 120 fps stream whose content went 60 <-> 120 fps). The lattice, the latency bound and the cap of D
     * belong to n, so the lock and D start over (the next frame acquires a centred lock). The jitter history, the
     * baseline and the slack level stay (same grid, same stream). A constant n never gets here.
     */
    private fun recadence() {
        lockSlot = Long.MIN_VALUE; badRun = 0; phaseLock = false
        dNs = Long.MIN_VALUE
    }

    /**
     * T-208: panel rate changed under an unchanged, continuous stream. The stream's measurements (baseline window,
     * jitter history, last capture time, last slot) stay valid; what belongs to the old grid starts over: the lock,
     * the slack level (it is counted in periods) and D (re-derived from the kept history on the next frame).
     */
    private fun regrid() {
        lockSlot = Long.MIN_VALUE; badRun = 0; phaseLock = false
        dNs = Long.MIN_VALUE
        level = 0; highRun = 0; lowRun = 0; hold = 0
        rephases = 0
    }

    /** Panel rate (epoch) changed: the whole path is re-timed, so everything measured is dropped, jitter included. */
    private fun resetState() {
        reanchor()
        devN = 0; devPos = 0
        baseNs = Long.MIN_VALUE; dNs = Long.MIN_VALUE
        level = 0; highRun = 0; lowRun = 0; hold = 0
        rephases = 0
    }

    fun reset() { resetState(); lastPeriod = 0; epoch = -1; lastScheduleNs = Long.MIN_VALUE; lastFi = 0; lastN = 0 }
}
