package dev.matebridge.client.video

/**
 * Adaptive frame scheduling (T-052). Replaces the fixed N-period jitter buffer of [FramePacer], which
 * was only an integer shift of the vsync grid (ceil(t + P) = ceil(t) + P) and therefore never changed
 * which vsync a jittery frame landed on.
 *
 * The host captures frames at an exactly regular cadence, so the capture timestamp is the ideal clock:
 *  - x = readyNs - captureUs*1000 (the constant host/tablet clock offset cancels out); m = its minimum over
 *    a sliding [WINDOW_NS] window = best-case pipeline delay; dev = x - m >= 0 is this frame's extra delay.
 *  - D = p98 of recent dev + margin + feedback [extraNs]. Target display time = readyNs - dev + D, i.e.
 *    capture + m + D: frames are evenly spaced by the content interval, so the jitter is absorbed and each
 *    frame maps to its own vsync. Added latency is about D (usually below one vsync) plus the wait for the grid.
 *  - Slot = first vsync >= target (never before the earliest vsync), at least one period after the previous
 *    slot. When the backlog would exceed D + 2 periods the newest frame takes the previous slot (collided).
 *  - [onSkipWindow] closes the loop with the measured skip percentage: more slack when frames are skipped,
 *    slowly less when none are.
 *
 * Decoder thread only for [schedule]/[reset]; [onSkipWindow] may come from another thread.
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
    }

    // Monotonic deque for the sliding-window minimum of x (values increasing from first to last).
    private val minT = ArrayDeque<Long>()
    private val minX = ArrayDeque<Long>()
    private val devs = LongArray(DEV_SAMPLES)
    private var devN = 0
    private var devPos = 0
    private var lastSlot = Long.MIN_VALUE
    private var lastPeriod = 0L

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

    /** Diagnostics: the slack D applied to the latest frame. */
    @Volatile var lastDNs = 0L
        private set

    /** Null when no vsync sample or capture time is known: the caller renders at once. */
    fun schedule(captureUs: Long?, nowNs: Long): FramePacer.Decision? {
        if (captureUs == null || !vsync.hasSample) return null
        val period = vsync.periodNs
        if (lastPeriod != 0L && Math.abs(period - lastPeriod) * 10 > lastPeriod) {
            resetState() // panel rate changed (60 <-> 120): everything measured against the old grid is stale
        }
        lastPeriod = period

        val x = nowNs - captureUs * 1000
        while (minX.isNotEmpty() && minX.last() >= x) { minX.removeLast(); minT.removeLast() }
        minX.addLast(x); minT.addLast(nowNs)
        while (minT.first() < nowNs - WINDOW_NS) { minT.removeFirst(); minX.removeFirst() }
        val dev = x - minX.first()
        // Slack comes from the jitter seen so far: a frame that is worse than everything before it is late.
        // Content faster than the panel (e.g. 120 fps on a 60 Hz panel): some frames must be dropped. Never queue
        // them behind each other (that builds latency and stalls the decoder's output buffers): one vsync of slack
        // at most, and a frame whose slot is already taken replaces the older one (newest wins).
        val fi = if (frameIntervalNs > 0) frameIntervalNs else period
        val surplus = fi * 4 < period * 3
        val d = if (surplus) (percentile() + MARGIN_NS).coerceAtMost(period + MARGIN_NS)
        else (percentile() + MARGIN_NS + extraNs).coerceAtMost(3 * period)
        devs[devPos] = dev
        devPos = (devPos + 1) % DEV_SAMPLES
        if (devN < DEV_SAMPLES) devN++
        lastDNs = d
        val earliest = vsync.slotAtOrAfter(nowNs, 0.0)
        val targetSlot = vsync.slotAtOrAfter(nowNs - dev + d, 0.0)
        val late = targetSlot < earliest // the frame missed its own ideal slot: the content gap is our doing
        var slot = maxOf(targetSlot, earliest)
        var collided = false
        val previous = lastSlot
        if (lastSlot != Long.MIN_VALUE && slot <= lastSlot) {
            // Same vsync as the previous frame (or earlier): one period after it, unless that is too far behind.
            val pushed = lastSlot + period
            if (!surplus && pushed - earliest <= d + 2 * period) slot = pushed else { slot = lastSlot; collided = true }
        }
        lastSlot = slot
        val cadence = Math.round(fi.toDouble() / period).coerceAtLeast(1) * period
        // A skip: a vsync went by without a new frame although this one was decoded (late, not an idle source).
        val skipped = late && previous != Long.MIN_VALUE && (slot - previous) * 2 > cadence * 3
        return FramePacer.Decision(slot - period / 2, collided, (slot - earliest).coerceAtLeast(0), skipped)
    }

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

    private fun resetState() {
        minT.clear(); minX.clear()
        devN = 0; devPos = 0
        lastSlot = Long.MIN_VALUE
        level = 0; highRun = 0; lowRun = 0; hold = 0
    }

    fun reset() { resetState(); lastPeriod = 0 }
}
