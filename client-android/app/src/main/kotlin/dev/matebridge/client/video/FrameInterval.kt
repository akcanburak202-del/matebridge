package dev.matebridge.client.video

/**
 * Effective content interval for presentation scheduling (T-059). The host thins the stream to min(stream fps,
 * panel Hz) once it knows the panel rate, so the incoming interval is no longer the STREAM_CONFIG one. Pure logic.
 */
object FrameInterval {
    /** Arrivals at least this fraction of a panel period apart count as "already thinned to the panel". */
    const val THINNED_FRACTION = 0.75

    /**
     * T-220: the measured content cadence is used only on panels faster than about 90 Hz. At 60 Hz a two-period cadence
     * is 30 fps content, which the 1:1 lattice already steps (k = 2) and T-208 kept as it was.
     */
    const val INFER_MAX_PERIOD_NS = 11_111_111L

    /** T-220: the stable content interval must be this close to two panel periods to count as a 2:1 cadence. */
    const val CADENCE_MATCH_NS = 1_000_000L

    /**
     * [arrivalNs] is the measured capture-to-capture interval (0 = unknown). When frames already arrive no faster
     * than about one per panel period, the content cannot be shown faster than the panel: use the larger of the
     * stream interval and the period. Before the host reacts (arrivals still faster than the panel) keep the stream
     * interval, which makes the pacers treat the surplus as droppable.
     *
     * T-220: [cadenceNs] is the stable content interval of [ArrivalTracker.cadenceNs] (0 = none). On a fast panel
     * ([INFER_MAX_PERIOD_NS]) content that steadily comes every two periods (a 60 fps game in a 120 fps stream on a
     * 120 Hz panel) resolves to two periods, so the pacer forms the 2:1 lock; the stream interval alone said one. The
     * inference only ever lengthens the interval: a stream that is already that slow, or content at the panel rate,
     * resolves as before.
     */
    fun resolve(streamIntervalNs: Long, periodNs: Long, arrivalNs: Long, cadenceNs: Long = 0): Long {
        val stream = if (streamIntervalNs > 0) streamIntervalNs else periodNs
        if (arrivalNs <= 0 || periodNs <= 0) return stream
        val base = if (arrivalNs >= periodNs * THINNED_FRACTION) maxOf(stream, periodNs) else stream
        if (cadenceNs <= 0 || periodNs > INFER_MAX_PERIOD_NS) return base
        val two = 2 * periodNs
        return if (base < two && Math.abs(cadenceNs - two) <= CADENCE_MATCH_NS) two else base
    }
}

/**
 * Smoothed capture-to-capture interval of the incoming frames. Gaps above [MAX_GAP_NS] (static content, content-driven
 * capture) and implausibly small ones are ignored; the estimate is a slow EMA so one late frame does not move it.
 * Single writer (the input thread), any reader.
 *
 * T-220: also the stable content cadence ([cadenceNs]): the interval most of the last [CADENCE_WINDOW] gaps agree on
 * (within [CADENCE_TOLERANCE_NS]). It is set when at least [CADENCE_ENTER] of them match the window's median and kept
 * while at least [CADENCE_EXIT] still match it (hysteresis: a few missed or doubled captures do not flip it, a real
 * change of the content rate does within about ten frames). It does not depend on the panel period, so a panel-rate
 * change does not restart it. The EMA alone cannot tell steady 60 fps from a mix of 120 fps and 40 fps gaps.
 */
class ArrivalTracker {
    companion object {
        const val MAX_GAP_NS = 50_000_000L
        const val MIN_GAP_NS = 1_000_000L
        const val SAMPLES_NEEDED = 8
        const val CADENCE_WINDOW = 16
        const val CADENCE_ENTER = 12
        const val CADENCE_EXIT = 8
        const val CADENCE_TOLERANCE_NS = 1_000_000L
    }

    private var lastUs = Long.MIN_VALUE
    private var ema = 0.0
    private var n = 0
    private val gaps = LongArray(CADENCE_WINDOW)
    private val sorted = LongArray(CADENCE_WINDOW)
    private var gapPos = 0
    private var gapN = 0
    private var stable = 0L

    @Volatile var intervalNs = 0L
        private set

    /** T-220: stable content interval (ns), or 0 while the recent gaps agree on none. */
    @Volatile var cadenceNs = 0L
        private set

    fun onFrame(captureUs: Long) {
        val last = lastUs
        lastUs = captureUs
        if (last == Long.MIN_VALUE) return
        val gap = (captureUs - last) * 1000
        if (gap < MIN_GAP_NS || gap > MAX_GAP_NS) return
        ema = if (n == 0) gap.toDouble() else ema + (gap - ema) / 16
        if (n < SAMPLES_NEEDED) n++
        if (n >= SAMPLES_NEEDED) intervalNs = ema.toLong()
        onCadenceGap(gap)
    }

    private fun onCadenceGap(gap: Long) {
        gaps[gapPos] = gap
        gapPos = (gapPos + 1) % CADENCE_WINDOW
        if (gapN < CADENCE_WINDOW) gapN++
        if (gapN < CADENCE_WINDOW) return
        if (stable > 0 && matching(stable) < CADENCE_EXIT) stable = 0
        if (stable == 0L) {
            gaps.copyInto(sorted); sorted.sort()
            val median = sorted[CADENCE_WINDOW / 2]
            if (matching(median) >= CADENCE_ENTER) stable = median
        }
        cadenceNs = stable
    }

    private fun matching(intervalNs: Long): Int {
        var c = 0
        for (g in gaps) if (Math.abs(g - intervalNs) <= CADENCE_TOLERANCE_NS) c++
        return c
    }

    fun reset() {
        lastUs = Long.MIN_VALUE; n = 0; ema = 0.0; intervalNs = 0
        gapPos = 0; gapN = 0; stable = 0; cadenceNs = 0
    }
}
