package dev.matebridge.client.video

/**
 * Effective content interval for presentation scheduling (T-059). The host thins the stream to min(stream fps,
 * panel Hz) once it knows the panel rate, so the incoming interval is no longer the STREAM_CONFIG one. Pure logic.
 */
object FrameInterval {
    /** Arrivals at least this fraction of a panel period apart count as "already thinned to the panel". */
    const val THINNED_FRACTION = 0.75

    /**
     * [arrivalNs] is the measured capture-to-capture interval (0 = unknown). When frames already arrive no faster
     * than about one per panel period, the content cannot be shown faster than the panel: use the larger of the
     * stream interval and the period. Before the host reacts (arrivals still faster than the panel) keep the stream
     * interval, which makes the pacers treat the surplus as droppable.
     */
    fun resolve(streamIntervalNs: Long, periodNs: Long, arrivalNs: Long): Long {
        val stream = if (streamIntervalNs > 0) streamIntervalNs else periodNs
        if (arrivalNs <= 0 || periodNs <= 0) return stream
        return if (arrivalNs >= periodNs * THINNED_FRACTION) maxOf(stream, periodNs) else stream
    }
}

/**
 * Smoothed capture-to-capture interval of the incoming frames. Gaps above [MAX_GAP_NS] (static content, content-driven
 * capture) and implausibly small ones are ignored; the estimate is a slow EMA so one late frame does not move it.
 * Single writer (the input thread), any reader.
 */
class ArrivalTracker {
    companion object {
        const val MAX_GAP_NS = 50_000_000L
        const val MIN_GAP_NS = 1_000_000L
        const val SAMPLES_NEEDED = 8
    }

    private var lastUs = Long.MIN_VALUE
    private var ema = 0.0
    private var n = 0

    @Volatile var intervalNs = 0L
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
    }

    fun reset() { lastUs = Long.MIN_VALUE; n = 0; ema = 0.0; intervalNs = 0 }
}
