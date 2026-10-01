package dev.matebridge.aaudioprobe

import kotlin.math.ceil

/** One timestamp reading taken right after a write: frames written so far, the stream's (position, time) pair, now. */
data class Sample(val written: Long, val presented: Long, val presNs: Long, val nowNs: Long)

object LatencyMath {
    /**
     * Expected time from [Sample.nowNs] until the most recently written frame is presented, in ms.
     *
     * Frame `presented` was (or will be) presented at `presNs`; frame `written` follows it by
     * `(written - presented) / rate`. So latency = presNs + (written - presented) / rate - now
     * (the same formula as Oboe's calculateLatencyMillis). presNs is normally in the past, so the
     * `(now - presNs)` term is *subtracted*: those frames have already been played.
     */
    fun latencyMs(s: Sample, rate: Int): Double {
        require(rate > 0) { "rate must be positive" }
        val queuedNs = (s.written - s.presented) * 1_000_000_000.0 / rate
        return (queuedNs - (s.nowNs - s.presNs)) / 1_000_000.0
    }

    /** Latencies of samples taken at or after `startNs + warmupNs` (the first moments after start are skewed). */
    fun latencies(samples: List<Sample>, rate: Int, startNs: Long, warmupNs: Long): DoubleArray =
        samples.filter { it.nowNs >= startNs + warmupNs }.map { latencyMs(it, rate) }.toDoubleArray()
}

data class LatencyStats(
    val count: Int,
    val mean: Double,
    val p50: Double,
    val p95: Double,
    val min: Double,
    val max: Double,
) {
    companion object {
        /** Nearest-rank percentiles. Returns null for an empty input. */
        fun of(values: DoubleArray): LatencyStats? {
            if (values.isEmpty()) return null
            val sorted = values.sortedArray()
            return LatencyStats(
                count = sorted.size,
                mean = sorted.average(),
                p50 = rank(sorted, 0.50),
                p95 = rank(sorted, 0.95),
                min = sorted.first(),
                max = sorted.last(),
            )
        }

        private fun rank(sorted: DoubleArray, p: Double): Double {
            val idx = ceil(p * sorted.size).toInt() - 1
            return sorted[idx.coerceIn(0, sorted.size - 1)]
        }
    }
}
