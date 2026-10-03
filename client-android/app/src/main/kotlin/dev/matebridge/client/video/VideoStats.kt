package dev.matebridge.client.video

/**
 * Decoder-side counters for STATS (PROTOCOL.md 0x22). Pure Kotlin, thread-safe.
 *
 * T-168 latency stages, all signed and measured from the host's capture stamp (`VIDEO_FRAME.capture_time_us`, the SCK
 * PTS, decision 0021) on the client clock through [latencyOf]: capture -> decoder output ([Snapshot.capDec]), ready ->
 * vsync slot ([Snapshot.readySlot], pacer only), capture -> `releaseOutputBuffer` ([Snapshot.capRel]) and capture ->
 * codec frame-rendered callback ([Snapshot.capCb]). None of them is "on screen": SurfaceFlinger and the panel come
 * after the callback.
 */
class VideoStats {
    companion object {
        /** Per-frame map bound; the oldest entry (insertion order) is evicted first. */
        const val FRAME_MAP_MAX = 64
    }

    data class Snapshot(
        val received: Long,
        val decoded: Long,
        val rendered: Long,
        val dropped: Long,
        val decodeTimeAvgUs: Long,
        val bytesReceived: Long,
        /**
         * Average capture-stamp -> decoder-output latency in the window (each sample clamped at 0: the STATS
         * `latency_avg_us` and A/V sync input, unchanged by T-168), or null when unknown (no clock offset yet).
         */
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
        /** T-168: capture stamp -> decoder output, signed raw samples (every decoded frame, discarded ones too). */
        val capDec: IntervalSummary = IntervalSummary.EMPTY,
        /** T-168: decoder output ready -> the vsync slot the pacer chose (paced modes only). */
        val readySlot: IntervalSummary = IntervalSummary.EMPTY,
        /** T-168: capture stamp -> `releaseOutputBuffer` of a released (rendered) frame; discarded frames excluded. */
        val capRel: IntervalSummary = IntervalSummary.EMPTY,
        /** T-168: capture stamp -> codec frame-rendered callback (codec-render mode only). */
        val capCb: IntervalSummary = IntervalSummary.EMPTY,
        /** T-168: capture -> decoder-output samples below 0 (clock offset error larger than the latency). */
        val latNeg: Long = 0,
        /** T-168: decoded frames handed back unrendered (replaced in their slot / not the newest); also in [dropped]. */
        val discarded: Long = 0,
        /** T-168: released frames whose frame-rendered callback never came (a later frame's callback came first). */
        val renderCbMissing: Long = 0,
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
        var latNeg = 0L; var discarded = 0L; var cbMissing = 0L

        fun add(o: Sums) {
            received += o.received; decoded += o.decoded; rendered += o.rendered; dropped += o.dropped; bytes += o.bytes
            decodeSumUs += o.decodeSumUs; decodeCount += o.decodeCount
            latencySumUs += o.latencySumUs; latencyCount += o.latencyCount
            paceAddSumUs += o.paceAddSumUs; paceAddCount += o.paceAddCount
            scheduled += o.scheduled; scheduleSkips += o.scheduleSkips
            meterIntervals += o.meterIntervals; meterSkipped += o.meterSkipped
            latNeg += o.latNeg; discarded += o.discarded; cbMissing += o.cbMissing
        }

        fun clear() {
            received = 0; decoded = 0; rendered = 0; dropped = 0; bytes = 0
            decodeSumUs = 0; decodeCount = 0
            latencySumUs = 0; latencyCount = 0
            paceAddSumUs = 0; paceAddCount = 0
            scheduled = 0; scheduleSkips = 0
            meterIntervals = 0; meterSkipped = 0
            latNeg = 0; discarded = 0; cbMissing = 0
        }
    }

    private val cur = Sums()
    private val log = Sums()
    /**
     * pts (frame_seq) -> time. T-168: bounded in insertion order, not by the smallest key: frame_seq restarts at 0 on
     * every video connection, and stale high keys (frames lost in a teardown) must not evict the new stream's low ones.
     * Also cleared at every codec start and stream boundary ([resetFrames]).
     */
    private class FrameMap : LinkedHashMap<Long, Long>() {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Long, Long>) = size > FRAME_MAP_MAX
    }
    private val inputTimes = FrameMap() // pts -> input time (us)
    private val captureTimes = FrameMap() // pts -> host capture time (us)
    /** T-168: released frames still waiting for their frame-rendered callback, in release order. */
    private val awaitingCallback = LinkedHashSet<Long>()

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
    // T-168 latency stages (signed values through record(), never mark()).
    private val capDec = IntervalHistogram(); private val capDecLog = IntervalHistogram()
    private val readySlot = IntervalHistogram(); private val readySlotLog = IntervalHistogram()
    private val capRel = IntervalHistogram(); private val capRelLog = IntervalHistogram()
    private val capCb = IntervalHistogram(); private val capCbLog = IntervalHistogram()

    /**
     * T-168: signed time from a host capture stamp to a client event at `clientUs` (`System.nanoTime() / 1000`), or null
     * if unknown (no clock offset yet). Set by the session layer ([dev.matebridge.client.stream.ClockSync.latencySignedUs]).
     */
    @Volatile var latencyOf: ((captureHostUs: Long, clientUs: Long) -> Long?)? = null

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

    /**
     * T-168: a decoded frame went to `releaseOutputBuffer` for rendering at [clientUs] (`System.nanoTime() / 1000`).
     * Counts as rendered (logged as `released=`); with its [captureUs] it adds a capture -> release sample. In
     * codec-render mode the frame was registered with [awaitCallback] before the release.
     */
    @Synchronized fun onReleased(ptsUs: Long?, captureUs: Long?, clientUs: Long) {
        cur.rendered++
        if (ptsUs != null && captureUs != null) latencyOf?.invoke(captureUs, clientUs)?.let { capRel.record(it) }
    }

    /**
     * T-168 (codec-render mode): [ptsUs] is about to be released for rendering; its frame-rendered callback is awaited
     * ([onRenderCallback]). Called BEFORE `releaseOutputBuffer`: the callback runs on the main looper and may arrive
     * before the release call returns. Undone with [cancelCallback] when the release throws.
     */
    @Synchronized fun awaitCallback(ptsUs: Long) {
        awaitingCallback.add(ptsUs)
        if (awaitingCallback.size > FRAME_MAP_MAX) {
            val i = awaitingCallback.iterator(); i.next(); i.remove()
            cur.cbMissing++
        }
    }

    /** T-168: the release registered by [awaitCallback] did not happen; forget [ptsUs] without counting it missing. */
    @Synchronized fun cancelCallback(ptsUs: Long) { awaitingCallback.remove(ptsUs) }

    /** T-168: a decoded frame was handed back unrendered (`releaseOutputBuffer(idx, false)`): dropped and discarded. */
    @Synchronized fun onDiscarded() { cur.dropped++; cur.discarded++ }

    /** T-168: decoder output ready -> the vsync slot the pacer chose for it (signed, us). */
    fun onReadySlot(us: Long) = readySlot.record(us)

    /**
     * T-168: the codec's frame-rendered callback for [ptsUs] at [clientUs] (its `nanoTime / 1000`). Callbacks come in
     * release order, so frames released before [ptsUs] that are still awaited never got one ([Snapshot.renderCbMissing]).
     * A callback for a frame not awaited (after a [resetFrames]) only adds its latency sample.
     */
    @Synchronized fun onRenderCallback(ptsUs: Long, captureUs: Long?, clientUs: Long) {
        if (captureUs != null) latencyOf?.invoke(captureUs, clientUs)?.let { capCb.record(it) }
        if (!awaitingCallback.contains(ptsUs)) return
        val i = awaitingCallback.iterator()
        while (i.hasNext()) {
            val p = i.next()
            i.remove()
            if (p == ptsUs) break
            cur.cbMissing++
        }
    }

    /**
     * T-168: a codec start or stream boundary. The per-frame maps are keyed by frame_seq, which restarts per video
     * connection; entries of the previous codec or stream are dropped (counts and windows are kept).
     */
    @Synchronized fun resetFrames() {
        inputTimes.clear(); captureTimes.clear(); awaitingCallback.clear()
    }

    /** Frame handed to the decoder. Bounded: the oldest entries are evicted ([FRAME_MAP_MAX]). */
    @Synchronized fun onInput(ptsUs: Long, nowUs: Long, captureTimeUs: Long? = null) {
        inputTimes[ptsUs] = nowUs
        if (captureTimeUs != null) captureTimes[ptsUs] = captureTimeUs
    }

    /** Decode latency of the latest timed output (us), or -1 before the first; for the T-121 overflow line. */
    @Volatile var lastDecodeUs = -1L
        private set

    /**
     * Decoder produced an output for [ptsUs]; [nowUs] is on the clock of [onInput]'s times, [clientUs] on
     * [latencyOf]'s (`System.nanoTime() / 1000`).
     */
    @Synchronized fun onOutput(ptsUs: Long, nowUs: Long, clientUs: Long = System.nanoTime() / 1000) {
        cur.decoded++
        readyGaps.mark(nowUs)
        inputTimes.remove(ptsUs)?.let {
            val d = (nowUs - it).coerceAtLeast(0)
            cur.decodeSumUs += d; cur.decodeCount++
            decodeLat.record(d)
            lastDecodeUs = d
        }
        captureTimes.remove(ptsUs)?.let { cap ->
            latencyOf?.invoke(cap, clientUs)?.let { raw ->
                capDec.record(raw)
                if (raw < 0) cur.latNeg++
                cur.latencySumUs += raw.coerceAtLeast(0); cur.latencyCount++ // STATS / A/V: clamped mean, as before
            }
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
            if (reset) decodeLat.summaryInto(decodeLatLog) else decodeLat.summary(),
            stage(capDec, capDecLog, reset), stage(readySlot, readySlotLog, reset),
            stage(capRel, capRelLog, reset), stage(capCb, capCbLog, reset),
            c.latNeg, c.discarded, c.cbMissing)
        if (reset) {
            c.meterIntervals = m.intervals.toLong(); c.meterSkipped = m.skipped.toLong()
            log.add(c)
            c.clear()
        }
        return s
    }

    /**
     * T-141 (review P3): a stream boundary (the stream ends or is reconfigured). The unfinished second is closed into
     * the log window, so a short tail is logged with its stream and never leaks into the next stream's windows.
     */
    fun closeWindow() { snapshot(reset = true); resetFrames() }

    private fun stage(live: IntervalHistogram, log: IntervalHistogram, reset: Boolean) =
        if (reset) live.summaryInto(log) else live.summary()

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
            meterPct, decodeLatLog.summary(reset),
            capDecLog.summary(reset), readySlotLog.summary(reset), capRelLog.summary(reset), capCbLog.summary(reset),
            l.latNeg, l.discarded, l.cbMissing)
        if (reset) l.clear()
        return s
    }
}
