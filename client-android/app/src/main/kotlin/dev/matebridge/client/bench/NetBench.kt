package dev.matebridge.client.bench

import dev.matebridge.client.session.Endpoint
import java.util.Locale

/** Direction of a raw throughput measurement, seen from the tablet (T-090). */
enum class BenchDir(val wire: String) {
    DOWN("down"), UP("up");

    companion object {
        /** `both` expands to two separate connection sets, one per direction. */
        fun parseList(text: String?): List<BenchDir> = when (text?.trim()?.lowercase(Locale.ROOT)) {
            "up" -> listOf(UP)
            "both" -> listOf(DOWN, UP)
            else -> listOf(DOWN) // absent or unknown -> down
        }
    }
}

/**
 * Launch extras of the experiment-only raw TCP throughput mode (T-090):
 * `--es net_bench HOST:PORT [--ei net_bench_s 8] [--es net_bench_dir down|up|both] [--ei net_bench_streams 1]
 * [--ei net_bench_rcvbuf_kb N]`. No auth, no encryption, no MateBridge protocol.
 */
data class NetBenchConfig(
    val endpoint: Endpoint,
    val seconds: Int = DEFAULT_SECONDS,
    val dirs: List<BenchDir> = listOf(BenchDir.DOWN),
    val streams: Int = 1,
    /** null = leave SO_RCVBUF alone (kernel auto-tuning). */
    val rcvbufKb: Int? = null,
) {
    val dirLabel: String get() = if (dirs.size > 1) "both" else dirs.single().wire

    fun logFields(): String =
        "host=${endpoint.host} port=${endpoint.port} dir=$dirLabel secs=$seconds streams=$streams rcvbuf_kb=${rcvbufKb ?: "-"}"

    companion object {
        const val EXTRA = "net_bench"
        const val DEFAULT_SECONDS = 8
        const val MAX_SECONDS = 600
        const val MAX_STREAMS = 4

        /** Returns null when the `net_bench` extra is absent; [Invalid] carries a malformed endpoint. */
        fun parse(getString: (String) -> String?, has: (String) -> Boolean, getInt: (String) -> Int): Parsed? {
            val raw = getString(EXTRA) ?: return null
            val ep = Endpoint.parse(raw) ?: return Parsed.Invalid
            fun int(key: String, def: Int) = if (has(key)) getInt(key) else def
            val rcv = if (has("net_bench_rcvbuf_kb")) getInt("net_bench_rcvbuf_kb").takeIf { it > 0 } else null
            return Parsed.Ok(
                NetBenchConfig(
                    endpoint = ep,
                    seconds = int("net_bench_s", DEFAULT_SECONDS).coerceIn(1, MAX_SECONDS),
                    dirs = BenchDir.parseList(getString("net_bench_dir")),
                    streams = int("net_bench_streams", 1).coerceIn(1, MAX_STREAMS),
                    rcvbufKb = rcv?.coerceAtMost(64 * 1024),
                ),
            )
        }
    }

    sealed class Parsed {
        data class Ok(val config: NetBenchConfig) : Parsed()
        object Invalid : Parsed()
    }
}

object Throughput {
    /** Megabits per second (10^6 bit/s) for [bytes] moved in [nanos]; 0 for a non-positive interval. */
    fun mbps(bytes: Long, nanos: Long): Double = if (nanos <= 0) 0.0 else bytes * 8_000.0 / nanos

    fun fmt(mbps: Double): String = String.format(Locale.ROOT, "%.1f", mbps)
}

/** Per-direction accumulator: one sample per tick, average over the whole run (total bytes / total time). */
class ThroughputStats {
    var totalBytes = 0L; private set
    var totalNanos = 0L; private set
    var ticks = 0; private set
    var min = Double.NaN; private set
    var max = Double.NaN; private set

    /** Adds one tick and returns its rate in Mbps. */
    fun add(bytes: Long, nanos: Long): Double {
        val m = Throughput.mbps(bytes, nanos)
        totalBytes += bytes
        totalNanos += nanos
        ticks++
        min = if (min.isNaN()) m else minOf(min, m)
        max = if (max.isNaN()) m else maxOf(max, m)
        return m
    }

    val avg: Double get() = Throughput.mbps(totalBytes, totalNanos)

    fun doneFields(): String {
        val f = { d: Double -> if (d.isNaN()) "-" else Throughput.fmt(d) }
        return "mbps_avg=${if (ticks == 0) "-" else Throughput.fmt(avg)} mbps_min=${f(min)} mbps_max=${f(max)} " +
            "bytes=$totalBytes ticks=$ticks"
    }
}
