package dev.matebridge.client.stream

import dev.matebridge.client.protocol.Stats
import dev.matebridge.client.video.IntervalSummary
import dev.matebridge.client.video.VideoStats
import java.util.Locale

/** Builds the wire STATS message and the overlay text from one per-second window. Pure Kotlin. */
object StatsFormat {
    private const val U32_MAX = 0xFFFF_FFFFL

    fun toMessage(s: VideoStats.Snapshot, intervalMs: Long, latencyAvgUs: Long?) = Stats(
        intervalMs = intervalMs.coerceIn(0, U32_MAX),
        framesReceived = s.received.coerceIn(0, U32_MAX),
        framesDecoded = s.decoded.coerceIn(0, U32_MAX),
        framesRendered = s.rendered.coerceIn(0, U32_MAX),
        framesDropped = s.dropped.coerceIn(0, U32_MAX),
        decodeTimeAvgUs = s.decodeTimeAvgUs.coerceIn(0, U32_MAX),
        // T-168: the only clamp of a latency: u32 on the wire (capture stamp -> decoder output, decision 0021).
        latencyAvgUs = (latencyAvgUs ?: 0).coerceIn(0, U32_MAX),
        bytesReceived = s.bytesReceived.coerceIn(0, U32_MAX),
    )

    /**
     * Overlay lines: FPS, bitrate, decode time, capture-stamp -> decoder-output latency ("Yak→çöz", T-168: it is not a
     * display latency), the pacer's ready -> slot p50 with the clock uncertainty ([clockUncUs], null = unknown), dropped
     * frames.
     */
    fun overlay(
        s: VideoStats.Snapshot, intervalMs: Long, latencyAvgUs: Long?, pacing: String? = null, clockUncUs: Long? = null,
    ): String {
        val secs = intervalMs.coerceAtLeast(1) / 1000.0
        val fps = s.rendered / secs
        val mbps = s.bytesReceived * 8 / secs / 1_000_000.0
        val lat = if (latencyAvgUs == null) "?" else String.format(Locale.ROOT, "%.0f ms", latencyAvgUs / 1000.0)
        return String.format(
            Locale.ROOT, "FPS %.1f | %.1f Mbps\nÇözme %.1f ms | Yak→çöz %s\n%s\nAtılan %d",
            fps, mbps, s.decodeTimeAvgUs / 1000.0, lat, stageLine(s, clockUncUs), s.dropped,
        ) + (if (pacing != null) "\n$pacing" else "") +
            "\n" + gaps("Ağ", s.network) + "\n" + gaps("Hazır", s.ready) + "\n" + gaps("Gösterim", s.shown)
    }

    /** T-168 overlay line: "Hazır→slot p50 14.2 ms | saat ±2.3 ms" (`-` without paced frames, `?` without a clock). */
    fun stageLine(s: VideoStats.Snapshot, clockUncUs: Long?): String {
        val slot = if (s.readySlot.count == 0) "-" else String.format(Locale.ROOT, "%.1f ms", s.readySlot.p50Us / 1000.0)
        val unc = if (clockUncUs == null) "?" else String.format(Locale.ROOT, "%.1f ms", clockUncUs / 1000.0)
        return "Hazır→slot p50 $slot | saat ±$unc"
    }

    /**
     * T-168: `<prefix>_p50_us= <prefix>_p95_us= <prefix>_p99_us=` (and `<prefix>_max_us=` with [withMax]) of a signed
     * stage; every value is `-` when the window has no sample (or [available] is false).
     */
    fun stageFields(prefix: String, g: IntervalSummary, withMax: Boolean = true, available: Boolean = true): String {
        val has = available && g.count > 0
        fun v(x: Long) = if (has) x.toString() else "-"
        return "${prefix}_p50_us=${v(g.p50Us)} ${prefix}_p95_us=${v(g.p95Us)} ${prefix}_p99_us=${v(g.p99Us)}" +
            (if (withMax) " ${prefix}_max_us=${v(g.maxUs)}" else "")
    }

    /**
     * T-168 fields of `MB/render ev=stats`: the latency stages from the capture stamp (cap_dec, ready_slot, cap_rel,
     * cap_cb), then `render_cb_missing= discarded= lat_neg= clock_unc_us=`. [codecCallbacks] false (GL path): cap_cb and
     * render_cb_missing are `-`. [clockUncUs] null (no PONG yet): `-`.
     */
    fun latencyStageFields(s: VideoStats.Snapshot, codecCallbacks: Boolean, clockUncUs: Long?): String =
        stageFields("cap_dec", s.capDec) + " " + stageFields("ready_slot", s.readySlot, withMax = false) + " " +
            stageFields("cap_rel", s.capRel) + " " + stageFields("cap_cb", s.capCb, available = codecCallbacks) +
            " render_cb_missing=${if (codecCallbacks) s.renderCbMissing.toString() else "-"} discarded=${s.discarded} " +
            "lat_neg=${s.latNeg} clock_unc_us=${clockUncUs ?: "-"}"

    /** "Ağ 16.7/24.1/40.2 ms >25.0:5": p50/p95/p99 of the gap between two frames, and the count over the threshold (1.5 x vsync period). */
    fun gaps(label: String, g: IntervalSummary): String = String.format(
        Locale.ROOT, "%s %.1f/%.1f/%.1f ms >%.1f:%d",
        label, g.p50Us / 1000.0, g.p95Us / 1000.0, g.p99Us / 1000.0, g.thresholdUs / 1000.0, g.overThreshold,
    )

    /** Log fields for one interval summary, e.g. `net_p50_us=... net_p95_us=... net_p99_us=... net_over=...`. */
    fun gapFields(prefix: String, g: IntervalSummary) =
        "${prefix}_p50_us=${g.p50Us} ${prefix}_p95_us=${g.p95Us} ${prefix}_p99_us=${g.p99Us} ${prefix}_over=${g.overThreshold}"

    /**
     * Log fields of the presentation scheduler (T-057): second release attempts per slot, frames folded onto the
     * previous slot by the latency bound, p95 frames inside the decoder, timestamp lead, slack D.
     */
    fun presentFields(slotDups: Long, lateDrops: Long, inCodecP95: Int?, leadNs: Long, dUs: Long, limit: Int, phaseLock: Boolean = false, rephase: Long = 0,
        lateMarginP50Us: Long? = null, lateMarginMinUs: Long? = null, recenters: Long? = null,
    ) =
        "slot_dups=$slotDups late_drops=$lateDrops in_codec_p95=${inCodecP95 ?: "-"} " +
            String.format(Locale.ROOT, "lead_ms=%.2f", leadNs / 1e6) + " d_us=$dUs inflight_limit=$limit " +
            "phase_lock=${if (phaseLock) 1 else 0} rephase=$rephase " +
            "late_margin_p50_us=${lateMarginP50Us ?: "-"} late_margin_min_us=${lateMarginMinUs ?: "-"} ${if (recenters != null) "recenters=$recenters" else ""}".trimEnd()

    /** Overlay line for the display mode and jitter buffer ([bufferFrames] < 0 = adaptive pacing). */
    fun pacingLine(
        modeHz: Float, bufferFrames: Int, paceAddUs: Long? = null, skipPct: Double? = null,
        decodeP95Us: Long? = null, paceDUs: Long? = null,
    ) =
        String.format(Locale.ROOT, "Mod %.0f Hz | ", modeHz) +
            (if (bufferFrames < 0) "Uyarlı" else "Tampon $bufferFrames") +
            (if (paceAddUs != null) String.format(Locale.ROOT, " | +%.1f ms", paceAddUs / 1000.0) else "") +
            (if (skipPct != null) String.format(Locale.ROOT, " | atlama %%%.1f", skipPct) else "") +
            (if (paceDUs != null && paceDUs > 0) String.format(Locale.ROOT, " | D %.1f ms", paceDUs / 1000.0) else "") +
            (if (decodeP95Us != null) String.format(Locale.ROOT, " | çözme p95 %.1f ms", decodeP95Us / 1000.0) else "")
}
