package dev.matebridge.client.audio

/**
 * Probation of a shared AAudio stream (decision 0012 point 2: "only if the measured latency is reasonable"). Pure.
 *
 * The writer feeds one sample per burst: the frames played since the stream was opened (the device's clock) and the
 * output latency of the newest written frame ([OutputClock.latencyUs]), or null when the timestamp failed. Samples
 * of the first [warmupMs] are ignored (start-up skews them). After a further [measureMs] the median of the valid
 * samples decides: ≤ [maxLatencyMs] accepts. Mostly failing timestamps, negative latencies (an inconsistent clock)
 * or no decision by [deadlineMs] reject.
 *
 * [maxLatencyMs] 60 = AudioTrack's measured 99 ms minus T-097's 40 ms gain threshold: a slower shared stream is not
 * worth the switch.
 */
class SharedLatencyProbe(
    private val sampleRate: Int = 48_000,
    warmupMs: Int = 300,
    measureMs: Int = 500,
    deadlineMs: Int = 2_000,
    val maxLatencyMs: Int = 60,
    private val minSamples: Int = 10,
) {
    enum class Result { PENDING, ACCEPT, REJECT }

    private val warmupFrames = warmupMs.toLong() * sampleRate / 1000
    private val decideFrames = (warmupMs + measureMs).toLong() * sampleRate / 1000
    private val deadlineFrames = deadlineMs.toLong() * sampleRate / 1000
    private val values = ArrayList<Long>()

    var failures = 0
        private set
    val samples: Int get() = values.size
    /** Median of the valid samples at the decision, in µs (null before, or without samples). */
    var medianUs: Long? = null
        private set
    var result = Result.PENDING
        private set

    fun add(playedFrames: Long, latencyUs: Long?): Result {
        if (result != Result.PENDING) return result
        if (playedFrames < warmupFrames) return result
        if (latencyUs == null || latencyUs < 0) failures++ else values.add(latencyUs)
        if (playedFrames >= decideFrames && values.size >= minSamples && failures <= values.size) {
            val m = median()
            medianUs = m
            result = if (m <= maxLatencyMs * 1000L) Result.ACCEPT else Result.REJECT
        } else if (playedFrames >= deadlineFrames) {
            medianUs = if (values.isEmpty()) null else median()
            result = Result.REJECT
        }
        return result
    }

    private fun median(): Long {
        val s = values.sorted()
        val n = s.size
        return if (n % 2 == 1) s[n / 2] else (s[n / 2 - 1] + s[n / 2]) / 2
    }
}
