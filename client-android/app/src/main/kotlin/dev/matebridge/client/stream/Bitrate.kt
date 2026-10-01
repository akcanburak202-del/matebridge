package dev.matebridge.client.stream

import java.util.Locale

/**
 * The user's target bit rate choices (decision 0013, T-105). Sent as `STREAM_PREFS.bitrate_kbps`; [AUTO_KBPS] (0) asks
 * for the host's default for the display mode. The host clamps and may override it (env); what it applies comes back in
 * `STREAM_CONFIG.bitrate_kbps`.
 */
object Bitrate {
    const val AUTO_KBPS = 0L

    /** Panel order: Otomatik, 15, 30, 60, 100 Mbps. */
    val OPTIONS_KBPS: List<Long> = listOf(AUTO_KBPS, 15_000L, 30_000L, 60_000L, 100_000L)

    /** A stored or requested value, kept only when it is one of [OPTIONS_KBPS]; anything else is [AUTO_KBPS]. */
    fun sanitize(kbps: Long?): Long = if (kbps != null && kbps in OPTIONS_KBPS) kbps else AUTO_KBPS

    /** Choice label: "Otomatik" or e.g. "60 Mbps". */
    fun label(kbps: Long): String = if (kbps == AUTO_KBPS) "Otomatik" else mbps(kbps)

    /** What the host applies (STREAM_CONFIG), e.g. "Uygulanan: 60 Mbps"; "Uygulanan: —" without a stream. */
    fun appliedLabel(kbps: Long?): String = "Uygulanan: " + if (kbps == null || kbps <= 0) "—" else mbps(kbps)

    /** "60 Mbps", "12,5 Mbps" (decimal comma, at most one decimal). */
    fun mbps(kbps: Long): String {
        val tenths = Math.round(kbps / 100.0)
        val s = if (tenths % 10 == 0L) (tenths / 10).toString()
        else String.format(Locale.forLanguageTag("tr"), "%.1f", tenths / 10.0)
        return "$s Mbps"
    }
}
