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
        /** Diagnostic: skip percentage derived from the frame-rendered callback times (overestimates; see PresentMeter). */
        val cbSkipPct: Double? = null,
        /** Decode latency per frame (queueInputBuffer to output available): p50/p95/p99 in the window. */
        val decode: IntervalSummary = IntervalSummary.EMPTY,
    )

    /**
     * Raw sums of one window. T-141: each closed per-second window is added to [log], the log window (10 s by default),
     * so the log summary is exact for its whole span (sums, weighted averages, histogram samples).
     */
    private class Sums {
        var received = 0L; var decoded = 0L; var rendered = 0L; var dropped = 0L; var bytes = 0L
        var decodeSumUs = 0L; var decodeCount = 0L
        var latencySumUs = 0L; var latencyCount = 0L
        var paceAddSumUs = 0L; var paceAddCount = 0L
        var scheduled = 0L; var scheduleSkips = 0L
        /** [PresentMeter] counts (log window only; the live window reads the meter itself). */
        var meterIntervals = 0L; var meterSkipped = 0L

        fun add(o: Sums) {
            received += o.received; decoded += o.decoded; rendered += o.rendered; dropped += o.dropped; bytes += o.bytes
            decodeSumUs += o.decodeSumUs; decodeCount += o.decodeCount
            latencySumUs += o.latencySumUs; latencyCount += o.latencyCount
            paceAddSumUs += o.paceAddSumUs; paceAddCount += o.paceAddCount
            scheduled += o.scheduled; scheduleSkips += o.scheduleSkips
            meterIntervals += o.meterIntervals; meterSkipped += o.meterSkipped
        }

        fun clear() {
            received = 0; decoded = 0; rendered = 0; dropped = 0; bytes = 0
            decodeSumUs = 0; decodeCount = 0
            latencySumUs = 0; latencyCount = 0
            paceAddSumUs = 0; paceAddCount = 0
            scheduled = 0; scheduleSkips = 0
            meterIntervals = 0; meterSkipped = 0
        }
    }

    private val cur = Sums()
    private val log = Sums()
    private val inputTimes = HashMap<Long, Long>() // pts -> input time (us)
    private val captureTimes = HashMap<Long, Long>() // pts -> host capture time (us)

    private val networkGaps = IntervalHistogram()
    private val readyGaps = IntervalHistogram()
    private val shownGaps = IntervalHistogram()
    private val meter = PresentMeter()
    private val decodeLat = IntervalHistogram()
    // T-141: the log window's histograms, fed only by summaryInto() when a per-second window closes.
    private val networkLog = IntervalHistogram()
    private val readyLog = IntervalHistogram()
    private val shownLog = IntervalHistogram()
    private val decodeLatLog = IntervalHistogram()

    /** Maps a host capture time to the latency now (client clock), or null if unknown. Set by the session layer. */
    @Volatile var latencyOf: ((Long) -> Long?)? = null

    @Synchronized fun onReceived(size: Int, nowUs: Long = System.nanoTime() / 1000, isConfig: Boolean = false) {
        cur.received++; cur.bytes += size
        if (!isConfig) networkGaps.mark(nowUs)
    }

    /** Threshold for the ">threshold" gap counters (1.5 x vsync period). */
    fun setGapThresholdUs(us: Long) {
        networkGaps.thresholdUs = us; readyGaps.thresholdUs = us; shownGaps.thresholdUs = us
        networkLog.thresholdUs = us; readyLog.thresholdUs = us; shownLog.thresholdUs = us
    }

    /** Delay the pacer added to one frame. */
    @Synchronized fun onPaceAdd(us: Long) { cur.paceAddSumUs += us; cur.paceAddCount++ }

    /** A frame reached the screen at [nowUs] (client monotonic clock). */
    fun onShown(nowUs: Long) = shownGaps.mark(nowUs)

    /**
     * One frame was scheduled by the adaptive pacer; [skipped] when it left a vsync without a new frame while
     * decoded (late). This is the skip signal: the render callback's times are not display times.
     */
    @Synchronized fun onScheduled(skipped: Boolean) { cur.scheduled++; if (skipped) cur.scheduleSkips++ }

    /** Codec-reported shown time of a frame that became ready at [readyNs]; feeds the skip meter too. */
    fun onShownPaced(readyNs: Long?, shownNs: Long, periodNs: Long, cadenceNs: Long) {
        shownGaps.mark(shownNs / 1000)
        meter.onShown(readyNs, shownNs, periodNs, cadenceNs)
    }

    /** Stream restart: gaps must not span it. */
    fun breakGaps() { networkGaps.breakSequence(); readyGaps.breakSequence(); shownGaps.breakSequence(); meter.breakSequence() }
    @Synchronized fun onDropped(n: Int) { cur.dropped += n }
    @Synchronized fun onRendered() { cur.rendered++ }

    /** Frame handed to the decoder. Bounded: stale entries are evicted. */
    @Synchronized fun onInput(ptsUs: Long, nowUs: Long, captureTimeUs: Long? = null) {
        inputTimes[ptsUs] = nowUs
        if (captureTimeUs != null) captureTimes[ptsUs] = captureTimeUs
        if (inputTimes.size > 64) inputTimes.remove(inputTimes.keys.min())
        if (captureTimes.size > 64) captureTimes.remove(captureTimes.keys.min())
    }

    /** Decode latency of the latest timed output (us), or -1 before the first; for the T-121 overflow line. */
    @Volatile var lastDecodeUs = -1L
        private set

    /** Decoder produced an output for [ptsUs]. */
    @Synchronized fun onOutput(ptsUs: Long, nowUs: Long) {
        cur.decoded++
        readyGaps.mark(nowUs)
        inputTimes.remove(ptsUs)?.let {
            val d = (nowUs - it).coerceAtLeast(0)
            cur.decodeSumUs += d; cur.decodeCount++
            decodeLat.record(d)
            lastDecodeUs = d
        }
        captureTimes.remove(ptsUs)?.let { cap ->
            latencyOf?.invoke(cap)?.let { cur.latencySumUs += it; cur.latencyCount++ }
        }
    }

    /**
     * Current window; with [reset] a new window starts (per-second STATS) and the closed one is added to the log
     * window ([logSnapshot]).
     */
    @Synchronized fun snapshot(reset: Boolean = false): Snapshot {
        val m = meter.snapshot(reset)
        val c = cur
        val s = Snapshot(c.received, c.decoded, c.rendered, c.dropped,
            if (c.decodeCount > 0) c.decodeSumUs / c.decodeCount else 0, c.bytes,
            if (c.latencyCount > 0) c.latencySumUs / c.latencyCount else null,
            if (reset) networkGaps.summaryInto(networkLog) else networkGaps.summary(),
            if (reset) readyGaps.summaryInto(readyLog) else readyGaps.summary(),
            if (reset) shownGaps.summaryInto(shownLog) else shownGaps.summary(),
            if (c.paceAddCount > 0) c.paceAddSumUs / c.paceAddCount else null,
            if (c.scheduled > 0) c.scheduleSkips * 100.0 / c.scheduled else m.skipPct,
            m.skipPct,
            if (reset) decodeLat.summaryInto(decodeLatLog) else decodeLat.summary())
        if (reset) {
            c.meterIntervals = m.intervals.toLong(); c.meterSkipped = m.skipped.toLong()
            log.add(c)
            c.clear()
        }
        return s
    }

    /**
     * T-141: the log window, i.e. every per-second window closed by `snapshot(reset = true)` since the last reset of
     * this one (the window still open is not included). Same fields and meaning as [snapshot], over the longer span.
     */
    @Synchronized fun logSnapshot(reset: Boolean = true): Snapshot {
        val l = log
        val meterPct = if (l.meterIntervals > 0) l.meterSkipped * 100.0 / l.meterIntervals else null
        val s = Snapshot(l.received, l.decoded, l.rendered, l.dropped,
            if (l.decodeCount > 0) l.decodeSumUs / l.decodeCount else 0, l.bytes,
            if (l.latencyCount > 0) l.latencySumUs / l.latencyCount else null,
            networkLog.summary(reset), readyLog.summary(reset), shownLog.summary(reset),
            if (l.paceAddCount > 0) l.paceAddSumUs / l.paceAddCount else null,
            if (l.scheduled > 0) l.scheduleSkips * 100.0 / l.scheduled else meterPct,
            meterPct, decodeLatLog.summary(reset))
        if (reset) l.clear()
        return s
    }
}
