package dev.matebridge.aaudioprobe

/** Outcome of one measurement (AAudio or AudioTrack). Pure data; formatting lives in [ResultFormat]. */
data class ProbeResult(
    val case: String,
    val api: String,
    val reqSharing: String,
    val sharing: String,
    val perf: String,
    /** 1 MMAP, 0 legacy, -1 unknown, null not applicable (AudioTrack). */
    val mmap: Int?,
    val burst: Int,
    val capacity: Int,
    val bufDefault: Int,
    val bufStart: Int,
    val bufFinal: Int,
    val rate: Int,
    val channels: Int,
    val format: String,
    val xruns: Int,
    val framesWritten: Long,
    val tsFail: Long,
    val error: String,
    val stage: String,
    val startNs: Long,
    val samples: List<Sample>,
) {
    fun stats(warmupNs: Long = WARMUP_NS): LatencyStats? =
        if (rate <= 0) null else LatencyStats.of(LatencyMath.latencies(samples, rate, startNs, warmupNs))

    companion object {
        const val WARMUP_NS = 500_000_000L
    }
}

/** Decodes the LongArray returned by `NativeProbe.runAaudio`; layout mirrors `Header` in aaprobe.cpp. */
object NativeResult {
    const val H_LEN = 0
    const val H_ERROR = 1
    const val H_STAGE = 2
    const val H_REQ_SHARING = 3
    const val H_SHARING = 4
    const val H_PERF = 5
    const val H_MMAP = 6
    const val H_BURST = 7
    const val H_CAPACITY = 8
    const val H_BUF_DEFAULT = 9
    const val H_BUF_START = 10
    const val H_BUF_FINAL = 11
    const val H_RATE = 12
    const val H_CHANNELS = 13
    const val H_FORMAT = 14
    const val H_XRUNS = 15
    const val H_FRAMES_WRITTEN = 16
    const val H_TS_FAIL = 17
    const val H_START_NS = 18
    const val H_SAMPLES = 19
    const val H_COUNT = 20

    fun parse(case: String, a: LongArray): ProbeResult {
        require(a.size >= H_COUNT && a[H_LEN] == H_COUNT.toLong()) { "bad header: size=${a.size}" }
        val n = a[H_SAMPLES].toInt()
        require(n >= 0 && a.size == H_COUNT + 4 * n) { "bad sample count: n=$n size=${a.size}" }
        val samples = List(n) { i ->
            val o = H_COUNT + 4 * i
            Sample(a[o], a[o + 1], a[o + 2], a[o + 3])
        }
        val err = a[H_ERROR].toInt()
        return ProbeResult(
            case = case,
            api = "aaudio",
            reqSharing = sharingName(a[H_REQ_SHARING].toInt()),
            sharing = if (a[H_STAGE] in 1L..2L) "-" else sharingName(a[H_SHARING].toInt()),
            perf = if (a[H_STAGE] in 1L..2L) "-" else aaudioPerfName(a[H_PERF].toInt()),
            mmap = a[H_MMAP].toInt(),
            burst = a[H_BURST].toInt(),
            capacity = a[H_CAPACITY].toInt(),
            bufDefault = a[H_BUF_DEFAULT].toInt(),
            bufStart = a[H_BUF_START].toInt(),
            bufFinal = a[H_BUF_FINAL].toInt(),
            rate = a[H_RATE].toInt(),
            channels = a[H_CHANNELS].toInt(),
            format = aaudioFormatName(a[H_FORMAT].toInt()),
            xruns = a[H_XRUNS].toInt(),
            framesWritten = a[H_FRAMES_WRITTEN],
            tsFail = a[H_TS_FAIL],
            error = if (err == 0) "0" else err.toString(),
            stage = stageName(a[H_STAGE].toInt()),
            startNs = a[H_START_NS],
            samples = samples,
        )
    }

    // AAudio.h constants
    const val SHARING_EXCLUSIVE = 0
    const val SHARING_SHARED = 1

    fun sharingName(v: Int) = when (v) {
        SHARING_EXCLUSIVE -> "exclusive"
        SHARING_SHARED -> "shared"
        else -> "unknown_$v"
    }

    fun aaudioPerfName(v: Int) = when (v) {
        10 -> "none"
        11 -> "power_saving"
        12 -> "low_latency"
        else -> "unknown_$v"
    }

    fun aaudioFormatName(v: Int) = when (v) {
        0 -> "unspecified"
        1 -> "i16"
        2 -> "float"
        3 -> "i24"
        4 -> "i32"
        else -> "unknown_$v"
    }

    fun stageName(v: Int) = when (v) {
        0 -> "none"
        1 -> "builder"
        2 -> "open"
        3 -> "start"
        4 -> "write"
        5 -> "format"
        else -> "unknown_$v"
    }
}
