package dev.matebridge.client.cursor

import java.util.Locale

/**
 * Per-second counters of the local cursor (decision 0036, T-276): states and shapes received, stale states dropped,
 * draws, the cost of a draw and the age of a state when it is drawn (client clock minus host sample time, corrected by the
 * PING/PONG clock offset). Counts only: no positions, no images. Thread-safe (the reader thread and the UI thread both write).
 */
class CursorStats {
    /** One closed window. Ages and draw times are microseconds; -1 = no sample. */
    class Snapshot(
        val states: Int, val shapes: Int, val stale: Int, val draws: Int,
        val drawAvgUs: Long, val drawMaxUs: Long, val ageSamples: Int, val ageP50Us: Long, val ageP95Us: Long,
    ) {
        val idle: Boolean get() = states == 0 && shapes == 0 && stale == 0 && draws == 0

        /** `key=value` fields of the `cursor_stats` line. */
        fun fields(): String =
            "states=$states shapes=$shapes stale=$stale draws=$draws " +
                "draw_ms_avg=${ms(drawAvgUs)} draw_ms_max=${ms(drawMaxUs)} " +
                "age_ms_p50=${ms(ageP50Us)} age_ms_p95=${ms(ageP95Us)} age_n=$ageSamples"

        private fun ms(us: Long) = if (us < 0) "-" else String.format(Locale.ROOT, "%.2f", us / 1000.0)
    }

    private var states = 0
    private var shapes = 0
    private var stale = 0
    private var draws = 0
    private var drawSumUs = 0L
    private var drawMaxUs = 0L
    private val ages = LongArray(MAX_AGE_SAMPLES)
    private var ageCount = 0

    @Synchronized fun onState() { states++ }

    @Synchronized fun onShape() { shapes++ }

    @Synchronized fun onStale() { stale++ }

    /** One [android.view.View.onDraw] of the layer that took [us] microseconds. */
    @Synchronized fun onDraw(us: Long) {
        draws++
        drawSumUs += us
        if (us > drawMaxUs) drawMaxUs = us
    }

    /** One state drawn for the first time, [us] after the host sampled it (may be negative while the clock offset is rough). */
    @Synchronized fun onAge(us: Long) {
        if (ageCount < ages.size) ages[ageCount++] = us
    }

    /** The window since the last call, then a fresh one. */
    @Synchronized fun take(): Snapshot {
        val sorted = ages.copyOf(ageCount).also { it.sort() }
        val snap = Snapshot(
            states, shapes, stale, draws,
            if (draws > 0) drawSumUs / draws else -1, if (draws > 0) drawMaxUs else -1,
            ageCount, percentile(sorted, 50), percentile(sorted, 95),
        )
        states = 0; shapes = 0; stale = 0; draws = 0; drawSumUs = 0; drawMaxUs = 0; ageCount = 0
        return snap
    }

    private fun percentile(sorted: LongArray, p: Int): Long {
        if (sorted.isEmpty()) return -1
        val idx = ((sorted.size - 1) * p + 50) / 100 // nearest rank
        return sorted[idx.coerceIn(0, sorted.size - 1)]
    }

    companion object {
        /** A second at 144 Hz draws at most ~144 states; double that is plenty. */
        const val MAX_AGE_SAMPLES = 512
    }
}
