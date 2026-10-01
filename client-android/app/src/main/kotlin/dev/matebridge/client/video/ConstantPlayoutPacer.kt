package dev.matebridge.client.video

/** T-080 switch values: [qPermille] jitter quantile (950 = 0.95), [holdNs] hysteresis on the playout delay C. */
class CpdConfig(qPermille: Int = DEFAULT_Q_PERMILLE, holdNs: Long = DEFAULT_HOLD_NS) {
    companion object {
        const val DEFAULT_Q_PERMILLE = 950
        const val DEFAULT_HOLD_NS = 2_000_000L
    }

    val qPermille: Int = qPermille.coerceIn(0, 1000)
    val holdNs: Long = holdNs.coerceIn(0, 50_000_000L)
}

/**
 * Constant playout delay scheduling (T-080, behind `--es pacer cpd`; the phase lock of [AdaptivePacer] stays the
 * default). Built for irregular content (drawing at 120 Hz: the host captures at mouse-event rate, not every 8.33 ms),
 * where the lock's slot prediction drifts and frames get dropped as "too early". The policy matches
 * `tools/pacing/sim.py` exactly:
 *
 *  - x = ready - capture (the constant host/tablet clock offset is part of x and cancels out in t below);
 *    over the last [WINDOW] frames: b = min(x), J = the q-quantile of (x - b), Cn = b + J.
 *  - C = Cn when it differs from the current C by more than the hold (hysteresis: a stable delay, no per-frame wobble).
 *  - Target t = capture + C + L (L = effective presentation deadline). Slot = first vsync at or after
 *    max(t, ready + L): a frame never waits for a slot it cannot make, and is never dropped as too early.
 *  - A frame whose slot is not after the previous frame's slot takes the previous slot ([FramePacer.Decision.collided]):
 *    the newest frame wins; [SlotReleaser] replaces the pending one or moves it past an already released slot (T-065),
 *    so a decoded frame only vanishes when a newer one replaces it. There is no late drop.
 *
 * Resets: a panel-rate epoch change drops everything (the grid and the whole path are re-timed). An idle gap longer
 * than [idleNs] clears the window but keeps C: the window is count based, so with sparse updates it would reach back
 * minutes and its baseline would carry the slow host/tablet clock drift; a fresh window re-measures it. A few samples
 * cannot see the jitter tail, though, so until [REFILL_MIN] samples are in, C may only rise (a lower C there would
 * make the first frames of the next continuous burst late), never fall.
 *
 * Decoder output thread only.
 */
class ConstantPlayoutPacer(
    private val vsync: VsyncClock,
    val config: CpdConfig = CpdConfig(),
    private val frameIntervalNs: Long = 0,
    /** Ready-time gap that clears the window; [Long.MAX_VALUE] = never (offline comparison with plain sim.py). */
    private val idleNs: Long = IDLE_NS,
) {
    companion object {
        const val WINDOW = 256
        const val IDLE_NS = 1_000_000_000L
        /** Samples after an idle reset before C may fall again (above 1/(1-q) = 20 for the default q = 0.95). */
        const val REFILL_MIN = 32
        /** Latency guard: the jitter allowance J never exceeds this (the 120 Hz drawing trace peaks at ~55 ms). */
        const val MAX_JITTER_NS = 100_000_000L
    }

    private val xs = LongArray(WINDOW)
    private val scratch = LongArray(WINDOW)
    private var n = 0
    private var pos = 0
    private var cNs = Long.MIN_VALUE // playout delay C (ready - capture domain); MIN = none yet
    private var lastSlot = Long.MIN_VALUE
    private var lastReadyNs = Long.MIN_VALUE
    private var epoch = -1
    private var refilling = false // from an idle reset until the window holds REFILL_MIN samples again

    /** T-059: effective content interval for a given panel period (skip statistic only); null = the stream's own. */
    @Volatile var intervalProvider: ((Long) -> Long)? = null

    /** T-069: when set, [schedule] writes this frame's values into it (path = cpd). */
    @Volatile var probe: PaceProbe? = null

    /** Diagnostics: C - b of the latest frame (the jitter allowance in use), ns. */
    @Volatile var lastDNs = 0L
        private set

    /** Null when no vsync sample or capture time is known: the caller renders at once. */
    fun schedule(captureUs: Long?, nowNs: Long): FramePacer.Decision? {
        if (captureUs == null || !vsync.hasSample) return null
        return scheduleOn(vsync.grid(), captureUs, nowNs, vsync.leadNs())
    }

    /** The policy on one grid snapshot; [readyNs] is the decode-ready time, [leadNs] the render timestamp lead. */
    fun scheduleOn(grid: VsyncClock.Grid, captureUs: Long, readyNs: Long, leadNs: Long): FramePacer.Decision {
        val period = grid.periodNs
        if (epoch != grid.epoch) {
            cNs = Long.MIN_VALUE; lastSlot = Long.MIN_VALUE; clear()
            epoch = grid.epoch
        } else if (lastReadyNs != Long.MIN_VALUE && readyNs - lastReadyNs > idleNs) {
            clear() // C and the previous slot are kept
        }
        lastReadyNs = readyNs
        val captureNs = captureUs * 1000
        val x = readyNs - captureNs
        xs[pos] = x
        pos = (pos + 1) % WINDOW
        if (n < WINDOW) n++
        var base = Long.MAX_VALUE
        for (i in 0 until n) if (xs[i] < base) base = xs[i]
        for (i in 0 until n) scratch[i] = xs[i] - base
        java.util.Arrays.sort(scratch, 0, n)
        val jitter = scratch[minOf(n - 1, n * config.qPermille / 1000)].coerceAtMost(MAX_JITTER_NS)
        val cNew = base + jitter
        val c0 = cNs
        cNs = when {
            c0 == Long.MIN_VALUE -> cNew
            refilling && n < REFILL_MIN -> if (cNew - c0 > config.holdNs) cNew else c0
            Math.abs(cNew - c0) > config.holdNs -> cNew
            else -> c0
        }
        if (n >= REFILL_MIN) refilling = false
        val c = cNs
        val deadline = grid.deadlineNs
        val target = captureNs + c + deadline
        val earliest = grid.gridSlotAtOrAfter(readyNs + deadline)
        val own = grid.gridSlotAtOrAfter(maxOf(target, readyNs + deadline))
        val previous = lastSlot
        var slot = own
        var collided = false
        if (previous != Long.MIN_VALUE && slot <= previous) { slot = previous; collided = true } else lastSlot = slot
        lastDNs = c - base
        val late = readyNs > captureNs + c // ready + L after the target: the frame is shown later than C
        val fi = intervalProvider?.invoke(period) ?: if (frameIntervalNs > 0) frameIntervalNs else period
        val cadence = Math.round(fi.toDouble() / period).coerceAtLeast(1) * period
        val skipped = late && !collided && previous != Long.MIN_VALUE && (slot - previous) * 2 > cadence * 3
        probe?.let {
            it.path = PaceProbe.PATH_CPD
            it.nowVsyncLastNs = grid.lastNs; it.periodNs = period; it.epoch = grid.epoch; it.deadlineNs = deadline
            it.devNs = x - base; it.dNs = c - base; it.jitterNs = jitter; it.earliestNs = earliest
            it.acquireNs = target; it.lockSlotNs = c; it.k = n.toLong(); it.badRun = if (c != c0) 1 else 0
        }
        return FramePacer.Decision(
            slot - leadNs, collided, (slot - earliest).coerceAtLeast(0), skipped, slotNs = slot,
        )
    }

    private fun clear() {
        n = 0; pos = 0
        refilling = cNs != Long.MIN_VALUE
    }

    fun reset() { clear(); refilling = false; cNs = Long.MIN_VALUE; lastSlot = Long.MIN_VALUE; lastReadyNs = Long.MIN_VALUE; epoch = -1 }
}
