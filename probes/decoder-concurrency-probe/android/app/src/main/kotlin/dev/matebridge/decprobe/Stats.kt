package dev.matebridge.decprobe

import java.util.Locale

/** Nearest-rank percentile of [values] (any order); 0 for an empty array. */
fun percentile(values: LongArray, p: Double): Long {
    if (values.isEmpty()) return 0
    val s = values.sortedArray()
    val rank = Math.ceil(p / 100.0 * s.size).toInt().coerceIn(1, s.size)
    return s[rank - 1]
}

/** Growable primitive long list (no boxing in the decode callbacks). */
class LongList(capacity: Int = 1024) {
    private var a = LongArray(capacity)
    var size = 0
        private set

    fun add(v: Long) {
        if (size == a.size) a = a.copyOf(a.size * 2)
        a[size++] = v
    }

    fun toArray(): LongArray = a.copyOf(size)
}

/** What one decoder session measured inside the common window. */
data class SessionResult(
    val clip: String,
    val width: Int,
    val height: Int,
    /** Output buffers inside the window. */
    val frames: Int,
    /** Queue-to-output time per frame (ns). */
    val latNs: LongArray,
    /** Time between consecutive outputs (ns). */
    val gapNs: LongArray,
    /** ImageReader images received in the window (image output only; -1 otherwise). */
    val images: Int = -1,
    /** Paced runs: ticks with no free input buffer (the decoder fell behind). */
    val missedTicks: Int = 0,
    val error: String? = null,
    /** Queue-to-output time of the IRAP (IDR) frames only (ns); empty when the window held none. */
    val idrLatNs: LongArray = LongArray(0),
    /** HEVC profile the clip needs (`Main`, `Main10`, `Main10HDR10`). */
    val profile: String = "",
)

/**
 * Formats the one-line DECPROBE summary of one scenario run. Per session: `lat` = queue-to-output p50/p95/p99/max (ms),
 * `gap` = time between consecutive outputs p50/p95/p99 (ms), `idrN:p50/max` = latency of the N IDR frames in the window.
 */
object Summary {
    private fun ms(ns: Long) = ns / 1e6

    fun line(
        scenario: String,
        output: String,
        paceFps: Int,
        windowSec: Double,
        codec: String,
        sessions: List<SessionResult>,
    ): String {
        val ok = sessions.filter { it.error == null }
        val fps = sessions.map { if (it.error == null && windowSec > 0) it.frames / windowSec else 0.0 }
        val totalFps = fps.sum()
        val mpx = sessions.sumOf { if (it.error == null) it.frames.toDouble() * it.width * it.height else 0.0 }
        val totalMpxs = if (windowSec > 0) mpx / windowSec / 1e6 else 0.0
        // Split-screen view: a whole screen frame needs every session's frame, so the slowest session sets the rate.
        val minFps = if (ok.size == sessions.size && fps.isNotEmpty()) fps.min() else 0.0
        val per = sessions.indices.joinToString(" ") { i ->
            val s = sessions[i]
            if (s.error != null) {
                "s$i=${s.clip}:ERR(${s.error.replace(' ', '_')})"
            } else {
                String.format(
                    Locale.US, "s%d=%s:%.1ffps,lat%.2f/%.2f/%.2f/%.2f,gap%.2f/%.2f/%.2f%s%s%s", i, s.clip, fps[i],
                    ms(percentile(s.latNs, 50.0)), ms(percentile(s.latNs, 95.0)), ms(percentile(s.latNs, 99.0)),
                    ms(s.latNs.maxOrNull() ?: 0L),
                    ms(percentile(s.gapNs, 50.0)), ms(percentile(s.gapNs, 95.0)), ms(percentile(s.gapNs, 99.0)),
                    if (s.idrLatNs.isNotEmpty()) {
                        String.format(Locale.US, ",idr%d:%.2f/%.2f", s.idrLatNs.size,
                            ms(percentile(s.idrLatNs, 50.0)), ms(s.idrLatNs.max()))
                    } else "",
                    if (s.images >= 0) ",img${s.images}" else "",
                    if (paceFps > 0) ",miss${s.missedTicks}" else "",
                )
            }
        }
        val prof = sessions.map { it.profile }.filter { it.isNotEmpty() }.distinct().joinToString("+").ifEmpty { "-" }
        return String.format(
            Locale.US,
            "DECPROBE scen=%s out=%s pace=%d n=%d ok=%d win=%.1fs total_fps=%.1f min_fps=%.1f total_mpxs=%.1f " +
                "codec=%s prof=%s %s",
            scenario, output, paceFps, sessions.size, ok.size, windowSec, totalFps, minFps, totalMpxs, codec, prof, per,
        )
    }
}
