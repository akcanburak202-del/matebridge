package dev.matebridge.client.video

/** Decoder-side counters for STATS (PROTOCOL.md 0x22). Pure Kotlin, thread-safe. */
class VideoStats {
    data class Snapshot(
        val received: Long,
        val decoded: Long,
        val rendered: Long,
        val dropped: Long,
        val decodeTimeAvgUs: Long,
        val bytesReceived: Long,
        /** Average capture-to-output latency in the window, or null when unknown (no clock offset yet). */
        val latencyAvgUs: Long? = null,
        /** Gaps between frame arrivals from the network. */
        val network: IntervalSummary = IntervalSummary.EMPTY,
        /** Gaps between decoded frames becoming ready. */
        val ready: IntervalSummary = IntervalSummary.EMPTY,
        /** Gaps between frames shown on screen (MediaCodec frame-rendered callback). */
        val shown: IntervalSummary = IntervalSummary.EMPTY,
        /** Average delay the pacer added versus presenting at the earliest vsync, or null when unpaced. */
        val paceAddAvgUs: Long? = null,
        /** Percent of presentation intervals that skipped a vsync while a frame was ready, or null when unmeasured. */
        val skipPct: Double? = null,
        /** Decode latency per frame (queueInputBuffer to output available): p50/p95/p99 in the window. */
        val decode: IntervalSummary = IntervalSummary.EMPTY,
    )

    private var received = 0L
    private var decoded = 0L
    private var rendered = 0L
    private var dropped = 0L
    private var bytes = 0L
    private var decodeSumUs = 0L
    private var decodeCount = 0L
    private val inputTimes = HashMap<Long, Long>() // pts -> input time (us)
    private val captureTimes = HashMap<Long, Long>() // pts -> host capture time (us)
    private var latencySumUs = 0L
    private var latencyCount = 0L

    private val networkGaps = IntervalHistogram()
    private val readyGaps = IntervalHistogram()
    private val shownGaps = IntervalHistogram()
    private val meter = PresentMeter()
    private val decodeLat = IntervalHistogram()

    /** Maps a host capture time to the latency now (client clock), or null if unknown. Set by the session layer. */
    @Volatile var latencyOf: ((Long) -> Long?)? = null

    @Synchronized fun onReceived(size: Int, nowUs: Long = System.nanoTime() / 1000, isConfig: Boolean = false) {
        received++; bytes += size
        if (!isConfig) networkGaps.mark(nowUs)
    }

    private var paceAddSumUs = 0L
    private var paceAddCount = 0L

    /** Threshold for the ">threshold" gap counters (1.5 x vsync period). */
    fun setGapThresholdUs(us: Long) {
        networkGaps.thresholdUs = us; readyGaps.thresholdUs = us; shownGaps.thresholdUs = us
    }

    /** Delay the pacer added to one frame. */
    @Synchronized fun onPaceAdd(us: Long) { paceAddSumUs += us; paceAddCount++ }

    /** A frame reached the screen at [nowUs] (client monotonic clock). */
    fun onShown(nowUs: Long) = shownGaps.mark(nowUs)

    /** Codec-reported shown time of a frame that became ready at [readyNs]; feeds the skip meter too. */
    fun onShownPaced(readyNs: Long?, shownNs: Long, periodNs: Long, cadenceNs: Long) {
        shownGaps.mark(shownNs / 1000)
        meter.onShown(readyNs, shownNs, periodNs, cadenceNs)
    }

    /** Stream restart: gaps must not span it. */
    fun breakGaps() { networkGaps.breakSequence(); readyGaps.breakSequence(); shownGaps.breakSequence(); meter.breakSequence() }
    @Synchronized fun onDropped(n: Int) { dropped += n }
    @Synchronized fun onRendered() { rendered++ }

    /** Frame handed to the decoder. Bounded: stale entries are evicted. */
    @Synchronized fun onInput(ptsUs: Long, nowUs: Long, captureTimeUs: Long? = null) {
        inputTimes[ptsUs] = nowUs
        if (captureTimeUs != null) captureTimes[ptsUs] = captureTimeUs
        if (inputTimes.size > 64) inputTimes.remove(inputTimes.keys.min())
        if (captureTimes.size > 64) captureTimes.remove(captureTimes.keys.min())
    }

    /** Decoder produced an output for [ptsUs]. */
    @Synchronized fun onOutput(ptsUs: Long, nowUs: Long) {
        decoded++
        readyGaps.mark(nowUs)
        inputTimes.remove(ptsUs)?.let {
            val d = (nowUs - it).coerceAtLeast(0)
            decodeSumUs += d; decodeCount++
            decodeLat.record(d)
        }
        captureTimes.remove(ptsUs)?.let { cap ->
            latencyOf?.invoke(cap)?.let { latencySumUs += it; latencyCount++ }
        }
    }

    /** Current window; with [reset] a new window starts (per-second STATS). */
    @Synchronized fun snapshot(reset: Boolean = false): Snapshot {
        val s = Snapshot(received, decoded, rendered, dropped,
            if (decodeCount > 0) decodeSumUs / decodeCount else 0, bytes,
            if (latencyCount > 0) latencySumUs / latencyCount else null,
            networkGaps.summary(reset), readyGaps.summary(reset), shownGaps.summary(reset),
            if (paceAddCount > 0) paceAddSumUs / paceAddCount else null,
            meter.snapshot(reset).skipPct, decodeLat.summary(reset))
        if (reset) {
            received = 0; decoded = 0; rendered = 0; dropped = 0; bytes = 0
            decodeSumUs = 0; decodeCount = 0
            latencySumUs = 0; latencyCount = 0
            paceAddSumUs = 0; paceAddCount = 0
        }
        return s
    }
}
