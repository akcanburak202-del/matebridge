package dev.matebridge.client.video

/**
 * Presentation interval meter (T-052), fed by MediaCodec's frame-rendered callback. An interval counts as a
 * skip when it is longer than 1.5 x the expected cadence while the frame was already available: it was ready
 * no later than one period after the previous frame's shown time (so an idle source does not count).
 * Note: for timed releases the callback time may be the requested render time rather than the real
 * display time, in which case this measures the schedule's regularity; compare with SurfaceFlinger latency.
 * Thread-safe.
 */
class PresentMeter {
    data class Snapshot(val intervals: Int, val skipped: Int) {
        /** Percent of intervals that skipped at least one vsync; null with no intervals. */
        val skipPct: Double? get() = if (intervals > 0) skipped * 100.0 / intervals else null
    }

    private var intervals = 0
    private var skipped = 0
    private var prevShownNs = -1L

    /**
     * A frame was shown at [shownNs]. [readyNs] is when it became available (null if unknown);
     * [periodNs] the vsync period and [cadenceNs] the expected gap between consecutive frames.
     */
    @Synchronized fun onShown(readyNs: Long?, shownNs: Long, periodNs: Long, cadenceNs: Long) {
        val prev = prevShownNs
        prevShownNs = shownNs
        if (prev < 0) return
        intervals++
        val gap = shownNs - prev
        if (gap * 2 > cadenceNs * 3 && readyNs != null && readyNs <= prev + periodNs) skipped++
    }

    @Synchronized fun breakSequence() { prevShownNs = -1 }

    @Synchronized fun snapshot(reset: Boolean = false): Snapshot {
        val s = Snapshot(intervals, skipped)
        if (reset) { intervals = 0; skipped = 0 }
        return s
    }
}
