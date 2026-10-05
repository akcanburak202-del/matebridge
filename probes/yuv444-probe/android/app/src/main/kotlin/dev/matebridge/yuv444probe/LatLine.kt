package dev.matebridge.yuv444probe

import java.util.Locale

/** Display-time estimate for the direct path, which has no EGL timestamps (cross-checked with dumpsys). */
object DisplayEstimate {
    const val TOLERANCE_NS = 1_000_000L

    /**
     * A buffer released at [renderNs] is latched [leadNs] later and shown at the first vsync of [grid] from there on;
     * [TOLERANCE_NS] keeps a release exactly on `slot - lead` (the pts variant) on its own slot.
     */
    fun presentNs(grid: VsyncGrid, renderNs: Long, leadNs: Long): Long =
        grid.nextAtOrAfter(renderNs + leadNs - TOLERANCE_NS)
}

/** The `Y444PROBE lat` result line shared by both paths, and its parser for the decision rule. */
object LatLine {
    /** [display] is `measured` (EGL frame timestamps) or `est` (release time + vsync grid). */
    fun format(
        path: String, mode: String, display: String, size: String, fps: Int, panelReq: Int, refreshHz: List<Double>,
        r: PresentResult, frames: Int, notShown: Int, extra: String,
    ): String = String.format(
        Locale.US,
        "Y444PROBE lat mode=%s path=%s display=%s size=%s fps=%d panel_req=%d refresh_hz=%s " +
            "arrival_to_display_ms=%s arrival_to_latch_ms=%s present_gap_ms=%s skipped_gaps=%d unresolved=%d " +
            "frames=%d not_shown=%d %s",
        mode, path, display, size, fps, panelReq, refreshHz, msDist(r.arrivalToPresentNs), msDist(r.arrivalToLatchNs),
        msDist(r.presentGapNs), r.skippedGaps, r.unresolved, frames, notShown, extra,
    )

    private val DIST = Regex("""arrival_to_display_ms=([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)""")

    /** p50 and p95 (ms) of arrival_to_display_ms, or null when the line has none. */
    fun p50p95(line: String): Pair<Double, Double>? {
        val m = DIST.find(line) ?: return null
        return m.groupValues[1].toDouble() to m.groupValues[2].toDouble()
    }
}
