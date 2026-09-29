package dev.matebridge.client.stream

import dev.matebridge.client.protocol.Stats
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
    fun overlay(s: VideoStats.Snapshot, intervalMs: Long, latencyAvgUs: Long?): String {
        val secs = intervalMs.coerceAtLeast(1) / 1000.0
        val fps = s.rendered / secs
        val mbps = s.bytesReceived * 8 / secs / 1_000_000.0
        val lat = if (latencyAvgUs == null) "?" else String.format(Locale.ROOT, "%.0f ms", latencyAvgUs / 1000.0)
        return String.format(
            Locale.ROOT, "FPS %.1f | %.1f Mbps\nÇözme %.1f ms | Gecikme %s\nAtılan %d",
            fps, mbps, s.decodeTimeAvgUs / 1000.0, lat, s.dropped,
        )
    }
}
