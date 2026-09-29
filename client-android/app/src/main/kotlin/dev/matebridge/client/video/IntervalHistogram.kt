package dev.matebridge.client.video

/** Percentiles of the intervals recorded in one stats window (microseconds). */
data class IntervalSummary(
    val count: Int,
    val p50Us: Long,
    val p95Us: Long,
    val p99Us: Long,
    /** Number of intervals longer than the histogram's threshold (exact, not sampled). */
    val overThreshold: Int,
) {
    companion object {
        val EMPTY = IntervalSummary(0, 0, 0, 0, 0)
    }
}

/**
 * Records the gap between consecutive events ([mark]) and summarizes a window as p50/p95/p99 plus the
 * number of gaps above [thresholdUs] (16.7 ms = one 60 Hz frame). Pure Kotlin, thread-safe, bounded
 * (at most [MAX_SAMPLES] samples per window; the over-threshold count stays exact).
 */
class IntervalHistogram(private val thresholdUs: Long = 16_700) {
    companion object {
        const val MAX_SAMPLES = 4096
    }

    private val samples = LongArray(MAX_SAMPLES)
    private var n = 0
    private var over = 0
    private var total = 0
    private var lastUs = -1L

    /** Event at [nowUs]; records the gap to the previous event. */
    @Synchronized fun mark(nowUs: Long) {
        if (lastUs >= 0) record((nowUs - lastUs).coerceAtLeast(0))
        lastUs = nowUs
    }

    @Synchronized fun record(intervalUs: Long) {
        total++
        if (intervalUs > thresholdUs) over++
        if (n < MAX_SAMPLES) samples[n++] = intervalUs
    }

    /** Forgets the previous event (stream restart), so no bogus gap is recorded across it. */
    @Synchronized fun breakSequence() { lastUs = -1 }

    /** Summary of the current window; with [reset] a new window starts (the last event time is kept). */
    @Synchronized fun summary(reset: Boolean = false): IntervalSummary {
        val s = if (n == 0) IntervalSummary.EMPTY else {
            val sorted = samples.copyOf(n).also { it.sort() }
            fun pct(p: Int) = sorted[((n * p + 99) / 100 - 1).coerceIn(0, n - 1)]
            IntervalSummary(total, pct(50), pct(95), pct(99), over)
        }
        if (reset) { n = 0; over = 0; total = 0 }
        return s
    }
}
