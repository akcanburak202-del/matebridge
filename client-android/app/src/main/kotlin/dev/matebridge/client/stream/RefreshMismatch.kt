package dev.matebridge.client.stream

import java.util.Locale
import kotlin.math.abs

/**
 * T-169: requested vs measured panel refresh. The target is [FrameRatePolicy.modeTargetHz] (0 = "leave the mode alone"),
 * the measurement is the median Choreographer vsync gap of one per-second stats window (`Display.refreshRate` is only a
 * proxy: on this tablet pen, touch and trackpad input raise the panel to 120 Hz, keyboard-only input lets it fall to
 * 60 Hz). A mismatch beyond [tolerance] that lasts longer than [minDurationMs] while streaming yields one [Event] per
 * episode, and events are at least [minIntervalMs] apart. Pure logic, one thread (fed once per second).
 */
class RefreshMismatch(
    private val minDurationMs: Long = MIN_DURATION_MS,
    private val minIntervalMs: Long = MIN_INTERVAL_MS,
    private val maxGapMs: Long = MAX_GAP_MS,
    private val tolerance: Double = TOLERANCE,
) {
    companion object {
        const val MIN_DURATION_MS = 5_000L
        const val MIN_INTERVAL_MS = 60_000L

        /** A mismatch episode survives seconds without a vsync measurement (idle vsync loop) up to this gap. */
        const val MAX_GAP_MS = 3_000L
        const val TOLERANCE = 0.10

        /** Hz from a median vsync gap in µs; null without a measurement. */
        fun measuredHz(vsyncP50Us: Long?): Double? = vsyncP50Us?.takeIf { it > 0 }?.let { 1_000_000.0 / it }

        /**
         * The refresh part of `MB/render ev=stats`. `hz=` is the deprecated alias of `display_hz=` (rounded) and stays
         * first so a naive `hz=` match does not hit `target_hz=`.
         */
        fun statsFields(targetHz: Int, displayHz: Float, vsyncPeriodUs: Long, vsyncP50Us: Long?, streamMode: String): String =
            "hz=${"%.0f".format(Locale.ROOT, displayHz)} target_hz=$targetHz vsync_period_us=$vsyncPeriodUs " +
                "display_hz=${"%.1f".format(Locale.ROOT, displayHz)} " +
                "vsync_ms_p50=${vsyncP50Us?.let { "%.2f".format(Locale.ROOT, it / 1000.0) } ?: "-"} stream_mode=$streamMode"
    }

    /** One sustained mismatch: `ev=refresh_mismatch` fields. */
    data class Event(val targetHz: Int, val measuredHz: Double, val durMs: Long) {
        fun fields(): String = "target_hz=$targetHz measured_hz=${"%.1f".format(Locale.ROOT, measuredHz)} dur_ms=$durMs"
    }

    private var lastTickMs = -1L
    private var episodeStartMs = -1L
    private var episodeTargetHz = 0
    private var lastMismatchMs = -1L
    private var reported = false
    private var lastEventMs = -1L

    /**
     * One per-second sample at [nowMs]: [targetHz] (0 = none), the window's median vsync gap ([vsyncP50Us], null when
     * the vsync loop measured nothing) and whether a stream is shown. Returns an event at most once per episode.
     */
    fun update(targetHz: Int, vsyncP50Us: Long?, streaming: Boolean, nowMs: Long): Event? {
        val prevTick = lastTickMs
        lastTickMs = nowMs
        if (!streaming || targetHz <= 0) {
            endEpisode()
            return null
        }
        // No measurement: an open episode stays open; the gap check below ends it if the pause is long.
        val measured = measuredHz(vsyncP50Us) ?: return null
        if (abs(measured - targetHz) <= targetHz * tolerance) {
            endEpisode()
            return null
        }
        if (episodeStartMs >= 0 && (targetHz != episodeTargetHz || nowMs - lastMismatchMs > maxGapMs)) endEpisode()
        if (episodeStartMs < 0) {
            // The sample covers the window since the previous tick, so the episode starts there.
            episodeStartMs = if (prevTick in 0..nowMs && nowMs - prevTick <= maxGapMs) prevTick else nowMs
            episodeTargetHz = targetHz
        }
        lastMismatchMs = nowMs
        val dur = nowMs - episodeStartMs
        if (reported || dur <= minDurationMs) return null
        if (lastEventMs >= 0 && nowMs - lastEventMs < minIntervalMs) return null
        reported = true
        lastEventMs = nowMs
        return Event(targetHz, measured, dur)
    }

    private fun endEpisode() {
        episodeStartMs = -1L
        lastMismatchMs = -1L
        reported = false
    }
}
