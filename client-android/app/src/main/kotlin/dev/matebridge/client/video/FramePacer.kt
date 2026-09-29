package dev.matebridge.client.video

/**
 * Estimated display vsync grid, fed from Choreographer frame times (System.nanoTime domain).
 * Written on the UI thread, read on the decoder thread; the state is one immutable object.
 *
 * The period follows an EMA of the observed vsync gaps. Gaps that do not fit the current period
 * (a 60 <-> 120 Hz switch) re-seed it after [RESEED_AFTER] consecutive consistent samples; a single
 * odd gap (skipped callback) is ignored. Also seed it with [setNominalHz] from the real display rate.
 */
class VsyncClock(private val initialHz: Float = 60f) {
    companion object {
        const val RESEED_AFTER = 4
    }

    private class State(val lastNs: Long, val periodNs: Long)

    @Volatile private var state = State(-1, hzToPeriod(initialHz))

    // UI-thread only: run of consecutive gaps that disagree with the current period.
    private var oddRun = 0
    private var oddDeltaNs = 0L

    private fun hzToPeriod(hz: Float) = (1_000_000_000.0 / hz.coerceIn(24f, 240f)).toLong()

    val hasSample: Boolean get() = state.lastNs >= 0
    val periodNs: Long get() = state.periodNs

    /** Sets the nominal refresh rate (display mode change); keeps the phase. */
    fun setNominalHz(hz: Float) {
        oddRun = 0
        val s = state
        state = State(s.lastNs, hzToPeriod(hz))
    }

    /** Forgets phase and observations (streaming stopped). */
    fun reset() {
        oddRun = 0
        state = State(-1, state.periodNs)
    }

    /** UI thread: one Choreographer callback. */
    fun onVsync(frameTimeNs: Long) {
        val s = state
        if (s.lastNs < 0 || frameTimeNs <= s.lastNs) { state = State(frameTimeNs, s.periodNs); return }
        val delta = frameTimeNs - s.lastNs
        val k = Math.round(delta.toDouble() / s.periodNs).coerceAtLeast(1)
        val sample = delta / k
        val fits = k == 1L && sample in s.periodNs * 3 / 4..s.periodNs * 5 / 4
        var period = s.periodNs
        if (fits) {
            oddRun = 0
            period = (s.periodNs * 15 + sample) / 16
        } else {
            // Either a skipped callback (one-off) or the real period changed (persistent, consistent).
            if (oddRun > 0 && Math.abs(delta - oddDeltaNs) * 8 <= oddDeltaNs) oddRun++ else oddRun = 1
            oddDeltaNs = delta
            if (oddRun >= RESEED_AFTER && delta in 3_000_000L..50_000_000L) { period = delta; oddRun = 0 }
        }
        state = State(frameTimeNs, period)
    }

    /** First point of the grid `vsync + phase * period` that is >= [tNs]. [phase] in 0..1. */
    fun slotAtOrAfter(tNs: Long, phase: Double): Long {
        val s = state
        val origin = s.lastNs + (s.periodNs * phase).toLong()
        if (tNs <= origin) return origin
        val n = (tNs - origin + s.periodNs - 1) / s.periodNs
        return origin + n * s.periodNs
    }
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
    /** [renderNs] goes to releaseOutputBuffer; [addedNs] is the delay versus the earliest possible vsync. */
    class Decision(val renderNs: Long, val collided: Boolean, val addedNs: Long)

    private var lastVsyncNs = Long.MIN_VALUE

    /** Null when no vsync sample exists yet: the caller renders immediately. */
    fun schedule(nowNs: Long): Decision? {
        if (!vsync.hasSample) return null
        val period = vsync.periodNs
        val fi = if (frameIntervalNs > 0) frameIntervalNs else period
        val earliest = vsync.slotAtOrAfter(nowNs, 0.0)
        val base = vsync.slotAtOrAfter(nowNs + bufferFrames.coerceIn(0, 2) * period, 0.0)
        val cadence = Math.round(fi.toDouble() / period).coerceAtLeast(1) * period
        var v = if (lastVsyncNs == Long.MIN_VALUE) base else maxOf(base, lastVsyncNs + cadence)
        if (v - base > fi / 2) v = base // re-anchor: too much cadence debt
        var collided = false
        if (lastVsyncNs != Long.MIN_VALUE && v <= lastVsyncNs) { v = lastVsyncNs; collided = true }
        lastVsyncNs = v
        return Decision(v - period / 2, collided, (v - earliest).coerceAtLeast(0))
    }

    fun reset() { lastVsyncNs = Long.MIN_VALUE }
}
