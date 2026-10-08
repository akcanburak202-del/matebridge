package dev.matebridge.client.session

import java.util.Locale

/**
 * Wi-Fi knob from launch extras (T-089). Defaults keep today's behaviour:
 *  - `--ei ping_ms N`   PING interval (default 500, clamped to [MIN_PING_MS, MAX_PING_MS] so the 3 s PONG timeout holds).
 * `tos_ctl`, `tos_video` and `wifi_ll` were removed by T-300 (no effect, T-127).
 */
data class WifiKnobs(
    val pingMs: Int = DEFAULT_PING_MS,
) {
    val pingIntervalUs: Long get() = pingMs * 1000L

    fun logFields(): String = "ping_ms=$pingMs"

    companion object {
        const val DEFAULT_PING_MS = 500
        const val MIN_PING_MS = 20
        const val MAX_PING_MS = 1000

        /** [has] tells whether an extra is present; [int] reads it (Android: Intent.getIntExtra). */
        fun parse(has: (String) -> Boolean, int: (String) -> Int): WifiKnobs {
            val ping = if (has("ping_ms")) int("ping_ms").coerceIn(MIN_PING_MS, MAX_PING_MS) else DEFAULT_PING_MS
            return WifiKnobs(ping)
        }
    }
}

/** Socket traffic class (IP_TOS / IPV6_TCLASS) helper; a failure is never fatal (file sockets use it). */
object TrafficClass {
    /** Applies [requested] through [set] (before connect). Returns null on success or when nothing was requested, else the error name. */
    fun trySet(requested: Int?, set: (Int) -> Unit): String? {
        if (requested == null) return null
        return try {
            set(requested)
            null
        } catch (e: Exception) {
            e.javaClass.simpleName
        }
    }
}

/**
 * RTT samples of one statistics window (PING -> PONG, microseconds). Thread-safe: samples come from the session
 * engine thread, snapshots from the UI thread. Bounded: at most [cap] samples, the oldest go first.
 */
class RttStats(private val cap: Int = 1024) {
    data class Snapshot(val count: Int, val p50Us: Long, val p95Us: Long, val maxUs: Long) {
        /** `rtt_ms_p50_95_max=1.20/3.40/8.90 rtt_n=2`, or `-` values for an empty window. */
        fun fields(): String {
            if (count == 0) return "rtt_ms_p50_95_max=- rtt_n=0"
            fun ms(us: Long) = "%.2f".format(Locale.ROOT, us / 1000.0)
            return "rtt_ms_p50_95_max=${ms(p50Us)}/${ms(p95Us)}/${ms(maxUs)} rtt_n=$count"
        }
    }

    private val samples = ArrayDeque<Long>()

    @Synchronized fun add(rttUs: Long) {
        if (rttUs < 0) return
        samples.addLast(rttUs)
        while (samples.size > cap) samples.removeFirst()
    }

    @Synchronized fun reset() = samples.clear()

    /** Nearest-rank percentiles over the current window; [reset] starts a new window. */
    @Synchronized fun snapshot(reset: Boolean): Snapshot {
        val sorted = samples.sorted()
        if (reset) samples.clear()
        if (sorted.isEmpty()) return Snapshot(0, 0, 0, 0)
        return Snapshot(sorted.size, rank(sorted, 0.50), rank(sorted, 0.95), sorted.last())
    }

    private fun rank(sorted: List<Long>, q: Double): Long {
        val idx = Math.ceil(q * sorted.size).toInt() - 1
        return sorted[idx.coerceIn(0, sorted.size - 1)]
    }
}
