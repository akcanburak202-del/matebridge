package dev.matebridge.aaudioprobe

import java.util.Locale

/** Log lines (docs/LOGGING.md shape) and the on-screen table. Never logs audio content, only counters. */
object ResultFormat {
    const val COMPONENT = "aaprobe"

    fun line(monoMs: Long, level: Char, ev: String, fields: String): String =
        if (fields.isEmpty()) "$monoMs $level $COMPONENT sid=- gen=0 ev=$ev"
        else "$monoMs $level $COMPONENT sid=- gen=0 ev=$ev $fields"

    fun ms(v: Double): String = String.format(Locale.ROOT, "%.2f", v)

    fun mmapName(v: Int?): String = when (v) {
        null -> "n/a"
        1 -> "yes"
        0 -> "no"
        else -> "unknown"
    }

    fun resultFields(r: ProbeResult, s: LatencyStats?): String = buildString {
        append("case=").append(r.case)
        append(" api=").append(r.api)
        append(" req_sharing=").append(r.reqSharing)
        append(" sharing=").append(r.sharing)
        append(" perf=").append(r.perf)
        append(" mmap=").append(mmapName(r.mmap))
        append(" rate=").append(r.rate)
        append(" ch=").append(r.channels)
        append(" fmt=").append(r.format)
        append(" burst=").append(r.burst)
        append(" capacity=").append(r.capacity)
        append(" buf_default=").append(r.bufDefault)
        append(" buf_start=").append(r.bufStart)
        append(" buf_final=").append(r.bufFinal)
        append(" xruns=").append(r.xruns)
        append(" frames_written=").append(r.framesWritten)
        append(" ts_ok=").append(r.samples.size)
        append(" ts_fail=").append(r.tsFail)
        if (s != null) {
            append(" lat_n=").append(s.count)
            append(" lat_mean_ms=").append(ms(s.mean))
            append(" lat_p50_ms=").append(ms(s.p50))
            append(" lat_p95_ms=").append(ms(s.p95))
            append(" lat_min_ms=").append(ms(s.min))
            append(" lat_max_ms=").append(ms(s.max))
        } else {
            append(" lat_n=0")
        }
        append(" err=").append(r.error)
        append(" stage=").append(r.stage)
    }

    /**
     * Gain of each AAudio case over AudioTrack, by mean latency (positive = AAudio is lower).
     * Cases without stats are left out.
     */
    fun summaryFields(results: List<Pair<ProbeResult, LatencyStats?>>): String {
        val at = results.firstOrNull { it.first.api == "audiotrack" }?.second
        return buildString {
            for ((r, s) in results) {
                if (isNotEmpty()) append(' ')
                append(r.case).append("_mean_ms=").append(s?.let { ms(it.mean) } ?: "na")
            }
            for ((r, s) in results) {
                if (r.api != "aaudio") continue
                append(" gain_").append(r.case).append("_ms=")
                append(if (s != null && at != null) ms(at.mean - s.mean) else "na")
            }
        }
    }

    val TABLE_HEADER: String = String.format(
        Locale.ROOT, "%-10s %-9s %-11s %-4s %5s %5s %5s %5s %5s %8s %8s %8s %s",
        "case", "sharing", "perf", "mmap", "rate", "burst", "cap", "buf", "xrun", "mean", "p50", "p95", "err",
    )

    fun tableRow(r: ProbeResult, s: LatencyStats?): String = String.format(
        Locale.ROOT, "%-10s %-9s %-11s %-4s %5d %5d %5d %5d %5d %8s %8s %8s %s",
        r.case, r.sharing, r.perf, mmapName(r.mmap), r.rate, r.burst, r.capacity, r.bufFinal, r.xruns,
        s?.let { ms(it.mean) } ?: "-", s?.let { ms(it.p50) } ?: "-", s?.let { ms(it.p95) } ?: "-",
        if (r.error == "0") "-" else "${r.error}@${r.stage}",
    )
}
