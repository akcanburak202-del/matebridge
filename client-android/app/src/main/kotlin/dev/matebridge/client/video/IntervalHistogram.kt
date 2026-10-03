package dev.matebridge.client.video

/** Percentiles of the intervals recorded in one stats window (microseconds). */
data class IntervalSummary(
    val count: Int,
    val p50Us: Long,
    val p95Us: Long,
    val p99Us: Long,
    /** Number of intervals longer than the histogram's threshold (exact, not sampled). */
    val overThreshold: Int,
    /** The threshold [overThreshold] was counted against. */
    val thresholdUs: Long = 16_700,
    /** T-168: largest sample of the window (exact, not sampled); 0 when empty. */
    val maxUs: Long = 0,
) {
    companion object {
        val EMPTY = IntervalSummary(0, 0, 0, 0, 0)
    }
}

/**
 * Records the gap between consecutive events ([mark]) and summarizes a window as p50/p95/p99 plus the
 * number of gaps above [thresholdUs] (default 16.7 ms). Pure Kotlin, thread-safe, bounded
 * (at most [MAX_SAMPLES] samples per window; the over-threshold count and the maximum stay exact).
 * T-168: [record] also takes any signed value (e.g. a latency stage), negative ones included.
 */
class IntervalHistogram(thresholdUs: Long = 16_700) {
    /** Gaps longer than this count as over; may be changed while running (e.g. 1.5 x vsync period). */
    @Volatile var thresholdUs: Long = thresholdUs
    companion object {
        const val MAX_SAMPLES = 4096
    }

    private val samples = LongArray(MAX_SAMPLES)
    private var n = 0
    private var over = 0
    private var total = 0
    private var lastUs = -1L
    private var max = Long.MIN_VALUE

    /** Event at [nowUs]; records the gap to the previous event. */
    @Synchronized fun mark(nowUs: Long) {
        if (lastUs >= 0) record((nowUs - lastUs).coerceAtLeast(0))
        lastUs = nowUs
    }

    @Synchronized fun record(intervalUs: Long) {
        total++
        if (intervalUs > max) max = intervalUs
        if (intervalUs > thresholdUs) over++
        if (n < MAX_SAMPLES) samples[n++] = intervalUs
    }

    /** Forgets the previous event (stream restart), so no bogus gap is recorded across it. */
    @Synchronized fun breakSequence() { lastUs = -1 }

    /**
     * T-141: [summary] with reset, after the window's samples and counts were added to [into] (a longer window, e.g.
     * the 10 s log window built from 1 s windows), so [into]'s percentiles are exact over its whole span. Lock order is
     * always this, then [into]; [into] must never feed this one.
     */
    @Synchronized fun summaryInto(into: IntervalHistogram): IntervalSummary {
        val s = summary(reset = false)
        into.absorb(samples, n, over, total, max)
        n = 0; over = 0; total = 0; max = Long.MIN_VALUE
        return s
    }

    @Synchronized private fun absorb(src: LongArray, count: Int, overCount: Int, totalCount: Int, srcMax: Long) {
        val k = minOf(count, MAX_SAMPLES - n)
        if (k > 0) { System.arraycopy(src, 0, samples, n, k); n += k }
        over += overCount
        total += totalCount
        if (srcMax > max) max = srcMax
    }

    /** Summary of the current window; with [reset] a new window starts (the last event time is kept). */
    @Synchronized fun summary(reset: Boolean = false): IntervalSummary {
        val s = if (n == 0) IntervalSummary.EMPTY else {
            val sorted = samples.copyOf(n).also { it.sort() }
            fun pct(p: Int) = sorted[((n * p + 99) / 100 - 1).coerceIn(0, n - 1)]
            IntervalSummary(total, pct(50), pct(95), pct(99), over, thresholdUs, max)
        }
        if (reset) { n = 0; over = 0; total = 0; max = Long.MIN_VALUE }
        return s
    }
}
