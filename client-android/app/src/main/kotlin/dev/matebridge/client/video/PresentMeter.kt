package dev.matebridge.client.video

/**
 * Presentation interval meter (T-052), fed by MediaCodec's frame-rendered callback. An interval counts as a
 * skip when it is longer than the expected cadence by more than half a panel period (T-225: it was 1.5 x the
 * cadence, which at a cadence of 2 periods could not see a 3-period hold) while the frame was already available: it
 * was ready no later than one period after the previous frame's shown time (so an idle source does not count).
 * T-225: a diagnostic next to `skip_pct`, which [VideoStats] now takes from the same callback times with the hold
 * rules of [HoldMeter] (content runs, short/long). The callback's `nanoTime` is not the requested render time
 * (it came ~31 ms after the release on the tablet), but only the gaps matter here.
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
        if (gap > cadenceNs + periodNs / 2 && readyNs != null && readyNs <= prev + periodNs) skipped++
    }

    @Synchronized fun breakSequence() { prevShownNs = -1 }

    @Synchronized fun snapshot(reset: Boolean = false): Snapshot {
        val s = Snapshot(intervals, skipped)
        if (reset) { intervals = 0; skipped = 0 }
        return s
    }
}
