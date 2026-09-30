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
        latencyAvgUs = (latencyAvgUs ?: 0).coerceIn(0, U32_MAX),
        bytesReceived = s.bytesReceived.coerceIn(0, U32_MAX),
    )

    /** Overlay lines: FPS, bitrate, decode time, estimated latency, dropped frames. */
    fun overlay(s: VideoStats.Snapshot, intervalMs: Long, latencyAvgUs: Long?, pacing: String? = null): String {
        val secs = intervalMs.coerceAtLeast(1) / 1000.0
        val fps = s.rendered / secs
        val mbps = s.bytesReceived * 8 / secs / 1_000_000.0
        val lat = if (latencyAvgUs == null) "?" else String.format(Locale.ROOT, "%.0f ms", latencyAvgUs / 1000.0)
        return String.format(
            Locale.ROOT, "FPS %.1f | %.1f Mbps\nÇözme %.1f ms | Gecikme %s\nAtılan %d",
            fps, mbps, s.decodeTimeAvgUs / 1000.0, lat, s.dropped,
        ) + (if (pacing != null) "\n$pacing" else "") +
            "\n" + gaps("Ağ", s.network) + "\n" + gaps("Hazır", s.ready) + "\n" + gaps("Gösterim", s.shown)
    }

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
    fun presentFields(slotDups: Long, lateDrops: Long, inCodecP95: Int?, leadNs: Long, dUs: Long, limit: Int, phaseLock: Boolean = false, rephase: Long = 0) =
        "slot_dups=$slotDups late_drops=$lateDrops in_codec_p95=${inCodecP95 ?: "-"} " +
            String.format(Locale.ROOT, "lead_ms=%.2f", leadNs / 1e6) + " d_us=$dUs inflight_limit=$limit " +
            "phase_lock=${if (phaseLock) 1 else 0} rephase=$rephase"

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
