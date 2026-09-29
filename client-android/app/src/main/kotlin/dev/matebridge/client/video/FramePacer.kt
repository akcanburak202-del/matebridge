package dev.matebridge.client.video

/**
 * Estimated display vsync grid, fed from Choreographer frame times (System.nanoTime domain).
 * Written on the UI thread, read on the decoder thread; the state is one immutable object.
 */
class VsyncClock(nominalHz: Float = 60f) {
    private class State(val lastNs: Long, val periodNs: Long)

    @Volatile private var state = State(-1, hzToPeriod(nominalHz))

    private fun hzToPeriod(hz: Float) = (1_000_000_000.0 / hz.coerceIn(24f, 240f)).toLong()

    val hasSample: Boolean get() = state.lastNs >= 0
    val periodNs: Long get() = state.periodNs

    /** Sets the nominal refresh rate (e.g. after a display mode change); keeps the phase. */
    fun setNominalHz(hz: Float) { val s = state; state = State(s.lastNs, hzToPeriod(hz)) }

    /** UI thread: one Choreographer callback. A skipped callback (gap of k periods) does not skew the period. */
    fun onVsync(frameTimeNs: Long) {
        val s = state
        if (s.lastNs < 0 || frameTimeNs <= s.lastNs) { state = State(frameTimeNs, s.periodNs); return }
        val delta = frameTimeNs - s.lastNs
        val k = Math.round(delta.toDouble() / s.periodNs).coerceAtLeast(1)
        val sample = delta / k
        val period = if (sample in s.periodNs * 3 / 4..s.periodNs * 5 / 4) (s.periodNs * 15 + sample) / 16 else s.periodNs
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
 * Frames are delayed by [bufferFrames] content frames, aimed at the middle between two vsyncs (robust to
 * phase error; the compositor shows the frame at the next vsync), and spaced at least one cadence
 * step apart so arrival jitter does not turn into uneven display times. The backlog is bounded to one
 * content frame: beyond that the frame reuses the previous slot, and the compositor shows only the
 * newer one (newest wins). Single-threaded (decoder thread).
 */
class FramePacer(
    private val vsync: VsyncClock,
    @Volatile var bufferFrames: Int,
    private val frameIntervalNs: Long,
    private val phase: Double = 0.5,
) {
    class Decision(val renderNs: Long, val collided: Boolean)

    private var lastSlotNs = Long.MIN_VALUE

    /** Null when no vsync sample exists yet: the caller renders immediately. */
    fun schedule(nowNs: Long): Decision? {
        if (!vsync.hasSample) return null
        val period = vsync.periodNs
        val fi = if (frameIntervalNs > 0) frameIntervalNs else period
        val base = vsync.slotAtOrAfter(nowNs + bufferFrames.coerceIn(0, 2) * fi, phase)
        val cadence = Math.round(fi.toDouble() / period).coerceAtLeast(1) * period
        val desired = if (lastSlotNs == Long.MIN_VALUE) base else maxOf(base, lastSlotNs + cadence)
        if (lastSlotNs != Long.MIN_VALUE && desired - base > fi) return Decision(lastSlotNs, true)
        lastSlotNs = desired
        return Decision(desired, false)
    }

    fun reset() { lastSlotNs = Long.MIN_VALUE }
}
