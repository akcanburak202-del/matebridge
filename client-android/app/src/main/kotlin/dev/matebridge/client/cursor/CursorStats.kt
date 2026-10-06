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
        /** T-278: prediction error (points) of the previous state's forecast against the next state; -1 = no sample. */
        val predN: Int = 0, val predErrP50Pt: Float = -1f, val predErrP95Pt: Float = -1f,
        /** T-278: the same states measured against "stay where the last state said" (the v1 drawing), for comparison. */
        val holdErrP50Pt: Float = -1f, val holdErrP95Pt: Float = -1f,
    ) {
        val idle: Boolean get() = states == 0 && shapes == 0 && stale == 0 && draws == 0 && predN == 0

        /** `key=value` fields of the `cursor_stats` line. */
        fun fields(): String =
            "states=$states shapes=$shapes stale=$stale draws=$draws " +
                "draw_ms_avg=${ms(drawAvgUs)} draw_ms_max=${ms(drawMaxUs)} " +
                "age_ms_p50=${ms(ageP50Us)} age_ms_p95=${ms(ageP95Us)} age_n=$ageSamples " +
                "pred_err_pt_p50=${pt(predErrP50Pt)} pred_err_pt_p95=${pt(predErrP95Pt)} pred_n=$predN " +
                "hold_err_pt_p50=${pt(holdErrP50Pt)} hold_err_pt_p95=${pt(holdErrP95Pt)}"

        private fun pt(v: Float) = if (v < 0f) "-" else String.format(Locale.ROOT, "%.2f", v)

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
    private val predErr = FloatArray(MAX_PRED_SAMPLES)
    private val holdErr = FloatArray(MAX_PRED_SAMPLES)
    private var predCount = 0

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

    /**
     * T-278: one state arrived: [errPt] = distance (Mac points) between where the prediction put the cursor at that state's
     * sample time and where the state says it was; [holdPt] = how far off the previous state alone would have been.
     */
    @Synchronized fun onPred(errPt: Float, holdPt: Float) {
        if (predCount < predErr.size) {
            predErr[predCount] = errPt
            holdErr[predCount] = holdPt
            predCount++
        }
    }

    /** The window since the last call, then a fresh one. */
    @Synchronized fun take(): Snapshot {
        val sorted = ages.copyOf(ageCount).also { it.sort() }
        val pe = predErr.copyOf(predCount).also { it.sort() }
        val he = holdErr.copyOf(predCount).also { it.sort() }
        val snap = Snapshot(
            states, shapes, stale, draws,
            if (draws > 0) drawSumUs / draws else -1, if (draws > 0) drawMaxUs else -1,
            ageCount, percentile(sorted, 50), percentile(sorted, 95),
            predCount, percentile(pe, 50), percentile(pe, 95), percentile(he, 50), percentile(he, 95),
        )
        states = 0; shapes = 0; stale = 0; draws = 0; drawSumUs = 0; drawMaxUs = 0; ageCount = 0; predCount = 0
        return snap
    }

    private fun percentile(sorted: LongArray, p: Int): Long {
        if (sorted.isEmpty()) return -1
        val idx = ((sorted.size - 1) * p + 50) / 100 // nearest rank
        return sorted[idx.coerceIn(0, sorted.size - 1)]
    }

    private fun percentile(sorted: FloatArray, p: Int): Float {
        if (sorted.isEmpty()) return -1f
        val idx = ((sorted.size - 1) * p + 50) / 100
        return sorted[idx.coerceIn(0, sorted.size - 1)]
    }

    companion object {
        const val MAX_PRED_SAMPLES = 512

        /** A second at 144 Hz draws at most ~144 states; double that is plenty. */
        const val MAX_AGE_SAMPLES = 512
    }
}
