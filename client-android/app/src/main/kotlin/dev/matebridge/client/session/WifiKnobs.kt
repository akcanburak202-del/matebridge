package dev.matebridge.client.session

import java.util.Locale

/**
 * T-089 Wi-Fi experiment knobs, from launch extras. Defaults keep today's behaviour:
 *  - `--ei ping_ms N`   PING interval (default 500, clamped to [MIN_PING_MS, MAX_PING_MS] so the 3 s PONG timeout holds),
 *  - `--ei tos_ctl N`   Socket.setTrafficClass(N) on the control socket (absent = untouched; 0..255, e.g. 0xB8 = EF),
 *  - `--ei tos_video N` the same on the video socket (e.g. 0x88 = AF41),
 *  - `--ez wifi_ll true` hold a WIFI_MODE_FULL_LOW_LATENCY lock while a Wi-Fi session is connected.
 */
data class WifiKnobs(
    val pingMs: Int = DEFAULT_PING_MS,
    val tosCtl: Int? = null,
    val tosVideo: Int? = null,
    val wifiLowLatency: Boolean = false,
) {
    val pingIntervalUs: Long get() = pingMs * 1000L

    fun logFields(): String =
        "ping_ms=$pingMs tos_ctl=${TrafficClass.hex(tosCtl)} tos_video=${TrafficClass.hex(tosVideo)} wifi_ll=${if (wifiLowLatency) 1 else 0}"

    companion object {
        const val DEFAULT_PING_MS = 500
        const val MIN_PING_MS = 20
        const val MAX_PING_MS = 1000

        /** [has] tells whether an extra is present; [int]/[bool] read it (Android: Intent.getIntExtra/getBooleanExtra). */
        fun parse(has: (String) -> Boolean, int: (String) -> Int, bool: (String) -> Boolean): WifiKnobs {
            val ping = if (has("ping_ms")) int("ping_ms").coerceIn(MIN_PING_MS, MAX_PING_MS) else DEFAULT_PING_MS
            fun tos(key: String): Int? = if (has(key)) int(key).takeIf { it in 0..255 } else null
            return WifiKnobs(ping, tos("tos_ctl"), tos("tos_video"), has("wifi_ll") && bool("wifi_ll"))
        }
    }
}

/** Socket traffic class (IP_TOS / IPV6_TCLASS) helpers; a failure is logged, never fatal to the session. */
object TrafficClass {
    fun hex(v: Int?): String = if (v == null) "-" else "0x%02x".format(Locale.ROOT, v)

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

    /** Log fields after connect: the requested value and what [get] (getTrafficClass) reports, -1 if it throws. */
    fun logFields(sock: String, requested: Int, err: String?, get: () -> Int): String {
        val applied = try { hex(get()) } catch (e: Exception) { "-1" }
        return "sock=$sock requested=${hex(requested)} applied=$applied" + (if (err != null) " err=$err" else "")
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

/** When the low-latency Wi-Fi lock is wanted: knob on, Wi-Fi transport, activity started and the session connected. */
object WifiLockPolicy {
    fun shouldHold(enabled: Boolean, transport: Transport, started: Boolean, ui: SessionUi): Boolean =
        enabled && transport == Transport.WIFI && started && ui is SessionUi.Connected
}

/**
 * Idempotent holder around the platform Wi-Fi lock ([Backend] is fake in tests). Every change is logged as
 * `held=0|1 reason=…`. A failed acquire disables further attempts (no log spam on every UI update); a release is
 * always attempted while held, and the lock counts as released afterwards even if the platform call threw.
 */
class WifiLockHolder(private val backend: Backend, private val log: (String) -> Unit) {
    interface Backend {
        fun acquire()
        fun release()
    }

    var held = false
        private set
    private var failed = false

    fun sync(want: Boolean, reason: String) {
        if (want == held) return
        if (want) {
            if (failed) return
            try {
                backend.acquire()
                held = true
                log("held=1 reason=$reason")
            } catch (e: RuntimeException) {
                failed = true
                log("held=0 reason=$reason err=${e.javaClass.simpleName}")
            }
        } else {
            held = false
            try {
                backend.release()
                log("held=0 reason=$reason")
            } catch (e: RuntimeException) {
                log("held=0 reason=$reason err=${e.javaClass.simpleName}")
            }
        }
    }
}
