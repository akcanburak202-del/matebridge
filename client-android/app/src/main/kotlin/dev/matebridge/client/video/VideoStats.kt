package dev.matebridge.client.video

/**
 * Decoder-side counters for STATS (PROTOCOL.md 0x22). Pure Kotlin, thread-safe.
 *
 * T-168 latency stages, all signed and measured from the host's capture stamp (`VIDEO_FRAME.capture_time_us`, the SCK
 * PTS, decision 0021) on the client clock through [latencyOf]: capture -> decoder output ([Snapshot.capDec]), ready ->
 * vsync slot ([Snapshot.readySlot], pacer only), capture -> `releaseOutputBuffer` ([Snapshot.capRel]) and capture ->
 * codec frame-rendered callback ([Snapshot.capCb]). None of them is "on screen": SurfaceFlinger and the panel come
 * after the callback.
 *
 * T-220: `skip_pct` ([Snapshot.skipPct]) is one presentation metric for every pacer ([HoldMeter]): the hold of each
 * released frame against its content cadence, from the vsync it was released for. Before, it came from the adaptive
 * pacer's own decisions in that mode and from the frame-rendered callback otherwise, so buffer 0 and adaptive did not
 * compare.
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
        /**
         * T-220: percent of judged presentation intervals held longer than the content cadence ([holdLong] of
         * [holdJudged], [HoldMeter]), the same calculation for every pacer; null when none was judged. Only a caller
         * that never reports a presentation slot ([onReleased] without one: tests, legacy) gets the old definition: the
         * adaptive pacer's own skips, else the callback meter.
         */
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
        /** T-220: presentation intervals judged by [HoldMeter] (continuous content, one panel rate). */
        val holdJudged: Long = 0,
        /** T-220: judged intervals held shorter than the content cadence (a 1-vsync hold of 60 fps on 120 Hz). */
        val holdShort: Long = 0,
        /** T-220: judged intervals held longer than the content cadence (a late frame, or a dropped successor). */
        val holdLong: Long = 0,
        /** T-220 diagnostic: the adaptive pacer's own skip decisions ([FramePacer.Decision.skipped]), or null. */
        val schedSkipPct: Double? = null,
    )

    /** T-220: [HoldMeter] counts of one `render ev=present` window ([holdWindow]). */
    data class HoldCounts(val judged: Long, val short: Long, val long: Long) {
        val shortPct: Double? get() = if (judged > 0) short * 100.0 / judged else null
        val longPct: Double? get() = if (judged > 0) long * 100.0 / judged else null

        /** `hold_n=<judged> hold_short_pct=<%.1f|-> hold_long_pct=<%.1f|->` (docs/LOGGING.md). */
        fun logFields(): String {
            fun pct(v: Double?) = v?.let { String.format(java.util.Locale.ROOT, "%.1f", it) } ?: "-"
            return "hold_n=$judged hold_short_pct=${pct(shortPct)} hold_long_pct=${pct(longPct)}"
        }
    }

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
        var holdJudged = 0L; var holdShort = 0L; var holdLong = 0L

        fun add(o: Sums) {
            holdJudged += o.holdJudged; holdShort += o.holdShort; holdLong += o.holdLong
            received += o.received; decoded += o.decoded; rendered += o.rendered; dropped += o.dropped; bytes += o.bytes
            decodeSumUs += o.decodeSumUs; decodeCount += o.decodeCount
            latencySumUs += o.latencySumUs; latencyCount += o.latencyCount
            paceAddSumUs += o.paceAddSumUs; paceAddCount += o.paceAddCount
            scheduled += o.scheduled; scheduleSkips += o.scheduleSkips
            meterIntervals += o.meterIntervals; meterSkipped += o.meterSkipped
            latNeg += o.latNeg; discarded += o.discarded; cbMissing += o.cbMissing
        }

        fun clear() {
            holdJudged = 0; holdShort = 0; holdLong = 0
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
    /** T-220: the presentation metric; under this object's lock. */
    private val holds = HoldMeter()
    /** T-220: true once a presentation slot was reported; from then on `skip_pct` is [holds] only. */
    private var presentationReported = false
    private var winJudged = 0L; private var winShort = 0L; private var winLong = 0L
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
    fun breakGaps() {
        networkGaps.breakSequence(); readyGaps.breakSequence(); shownGaps.breakSequence(); meter.breakSequence()
        synchronized(this) { holds.reset() } // T-220: no presentation interval or content run spans it either
    }
    @Synchronized fun onDropped(n: Int) { cur.dropped += n }
    @Synchronized fun onRendered() { cur.rendered++ }

    /**
     * T-168: a decoded frame went to `releaseOutputBuffer` for rendering at [clientUs] (`System.nanoTime() / 1000`).
     * Counts as rendered (logged as `released=`); with its [captureUs] it adds a capture -> release sample. In
     * codec-render mode the frame was registered with [awaitCallback] before the release.
     *
     * T-220: [slotNs] is the vsync it was released for ([HoldMeter.latchSlot], 0 = unknown) on a panel of [periodNs];
     * it feeds the presentation metric ([HoldMeter]).
     */
    @Synchronized fun onReleased(ptsUs: Long?, captureUs: Long?, clientUs: Long, slotNs: Long = 0, periodNs: Long = 0) {
        cur.rendered++
        if (ptsUs != null && captureUs != null) latencyOf?.invoke(captureUs, clientUs)?.let { capRel.record(it) }
        if (slotNs == 0L || periodNs <= 0 || captureUs == null) { holds.breakSequence(); return }
        presentationReported = true
        when (holds.onPresented(captureUs, slotNs, periodNs)) {
            HoldMeter.SHORT -> { cur.holdJudged++; cur.holdShort++; winJudged++; winShort++ }
            HoldMeter.EXACT -> { cur.holdJudged++; winJudged++ }
            HoldMeter.LONG -> { cur.holdJudged++; cur.holdLong++; winJudged++; winLong++ }
        }
    }

    /** T-220: [HoldMeter] counts since the last reset of this window (the `render ev=present` line). */
    @Synchronized fun holdWindow(reset: Boolean = true): HoldCounts {
        val h = HoldCounts(winJudged, winShort, winLong)
        if (reset) { winJudged = 0; winShort = 0; winLong = 0 }
        return h
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
        holds.reset()
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
            holds.onDecoded(cap) // T-220: the content sequence every released frame is judged against
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
            skipPctOf(c, m.skipPct),
            m.skipPct,
            if (reset) decodeLat.summaryInto(decodeLatLog) else decodeLat.summary(),
            stage(capDec, capDecLog, reset), stage(readySlot, readySlotLog, reset),
            stage(capRel, capRelLog, reset), stage(capCb, capCbLog, reset),
            c.latNeg, c.discarded, c.cbMissing, c.holdJudged, c.holdShort, c.holdLong, schedPctOf(c))
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
            skipPctOf(l, meterPct),
            meterPct, decodeLatLog.summary(reset),
            capDecLog.summary(reset), readySlotLog.summary(reset), capRelLog.summary(reset), capCbLog.summary(reset),
            l.latNeg, l.discarded, l.cbMissing, l.holdJudged, l.holdShort, l.holdLong, schedPctOf(l))
        if (reset) l.clear()
        return s
    }

    /** T-220: see [Snapshot.skipPct]; [meterPct] is the callback meter's share (legacy fallback only). */
    private fun skipPctOf(s: Sums, meterPct: Double?): Double? =
        if (presentationReported) (if (s.holdJudged > 0) s.holdLong * 100.0 / s.holdJudged else null)
        else schedPctOf(s) ?: meterPct

    private fun schedPctOf(s: Sums): Double? = if (s.scheduled > 0) s.scheduleSkips * 100.0 / s.scheduled else null
}

/**
 * T-220: the presentation metric, one calculation for every pacer (adaptive, fixed buffer, buffer 0). Each frame
 * released for rendering is reported with the vsync it was released for ([releasedSlot]: the slot the pacer asked for,
 * or the earliest vsync a buffer queued when the release call returned can still make); its hold is the distance to
 * the next shown frame's vsync, in panel periods, compared with the content cadence n:
 *  - content runs: decoded frames whose capture gaps all stay within [RUN_TOLERANCE_NS] of the run's first gap are one
 *    continuous run ([onDecoded], decode order = capture order). Two shown frames are judged only when the later one's
 *    run reaches back to the earlier one (no source gap, no irregular capture in between), the panel rate is the same,
 *    and the run gap is n panel periods (+-[RUN_TOLERANCE_NS], 1 <= n <= [MAX_CADENCE]);
 *  - hold < n is [SHORT], = n [EXACT], > n [LONG]. A decoded frame never shown in between (discarded, replaced) makes
 *    its predecessor's hold long: one content frame went missing on screen;
 *  - two releases for the same vsync: the newer replaces the older one, which was never shown. So an interval is judged
 *    only once the next release lands on a later vsync (one frame later).
 * `tools/pacing/sim.py --holds` implements the same rules on a pace trace. The vsync is the one the frame was handed
 * over for; SurfaceFlinger's actual latch is not observed (`cb_skip_pct` and `dumpsys SurfaceFlinger --latency` are
 * the cross-checks). Not thread-safe: [VideoStats] calls it under its own lock.
 */
class HoldMeter {
    companion object {
        /** Capture gaps of one content run stay this close to its first gap; the run gap this close to n periods. */
        const val RUN_TOLERANCE_NS = 1_000_000L
        const val MAX_CADENCE = 3L
        /** Decoded frames remembered for the run lookup (a shown frame is at most a few frames behind the decoder). */
        const val DECODED_MAX = 64
        const val NONE = 0
        const val SHORT = 1
        const val EXACT = 2
        const val LONG = 3

        /**
         * The vsync a frame released at [releaseNs] is due on: the requested one ([renderNs] + [leadNs], the pacer's slot)
         * unless the buffer was handed over too late for it; then, and for a frame released at once ([renderNs] <= 0),
         * the earliest vsync a buffer queued at [releaseNs] can make (presentation deadline). 0 while [grid] has no sample.
         */
        fun latchSlot(grid: VsyncClock.Grid, renderNs: Long, leadNs: Long, releaseNs: Long): Long {
            if (grid.lastNs < 0 || grid.periodNs <= 0) return 0
            val earliest = grid.slotAtOrAfter(releaseNs + grid.deadlineNs, 0.0)
            if (renderNs <= 0) return earliest
            val requested = renderNs + leadNs
            return if (requested < earliest - grid.periodNs / 2) earliest else requested
        }

        /**
         * T-220 review: runs [release] (the codec's `releaseOutputBuffer`) and [report]s the vsync the frame is due on
         * and the panel period, from [clock] and [vsync]'s grid read AFTER the call returned. A release that stalled past its slot's deadline
         * inside the call is attributed to the next vsync it can make, not to the slot it was meant for, so a missed
         * deadline is never hidden. The same for every pacer (buffer 0: [renderNs] 0).
         */
        inline fun releasedSlot(
            vsync: VsyncClock, renderNs: Long, clock: () -> Long, release: () -> Unit, report: (slotNs: Long, periodNs: Long) -> Unit,
        ) {
            release()
            val g = vsync.grid() // one snapshot: the slot and its period belong to the same grid
            report(latchSlot(g, renderNs, vsync.leadNs(), clock()), g.periodNs)
        }
    }

    private val decCapture = LongArray(DECODED_MAX)
    private val decRunStart = LongArray(DECODED_MAX)
    private val decRunGap = LongArray(DECODED_MAX)
    private var decPos = 0
    private var decN = 0
    private var lastDecodedUs = Long.MIN_VALUE
    private var runStartUs = Long.MIN_VALUE
    private var runGapNs = 0L

    // The latest release (not yet confirmed: a newer one for the same vsync replaces it) and the shown one before it.
    private var lastCapUs = Long.MIN_VALUE
    private var lastSlotNs = 0L
    private var lastPeriodNs = 0L
    private var prevCapUs = Long.MIN_VALUE
    private var prevSlotNs = 0L
    private var prevPeriodNs = 0L

    /** A frame came out of the decoder (shown or not); [captureUs] is its host capture stamp. */
    fun onDecoded(captureUs: Long) {
        val last = lastDecodedUs
        if (last != Long.MIN_VALUE && captureUs > last) {
            val gap = (captureUs - last) * 1000
            if (runGapNs == 0L || Math.abs(gap - runGapNs) > RUN_TOLERANCE_NS) { runStartUs = last; runGapNs = gap }
        } else {
            runStartUs = captureUs; runGapNs = 0 // first frame, or capture time went back (a new stream)
        }
        lastDecodedUs = captureUs
        decCapture[decPos] = captureUs; decRunStart[decPos] = runStartUs; decRunGap[decPos] = runGapNs
        decPos = (decPos + 1) % DECODED_MAX
        if (decN < DECODED_MAX) decN++
    }

    /**
     * The frame captured at [captureUs] was released for the vsync at [slotNs] on a panel of [periodNs]. Returns the
     * verdict of the interval confirmed by it ([SHORT]/[EXACT]/[LONG]), or [NONE].
     */
    fun onPresented(captureUs: Long, slotNs: Long, periodNs: Long): Int {
        if (lastCapUs != Long.MIN_VALUE) {
            val d = slotNs - lastSlotNs
            if (Math.abs(d) < periodNs / 2) { lastCapUs = captureUs; lastSlotNs = slotNs; lastPeriodNs = periodNs; return NONE }
            if (d < 0) { prevCapUs = Long.MIN_VALUE; lastCapUs = captureUs; lastSlotNs = slotNs; lastPeriodNs = periodNs; return NONE }
        }
        var verdict = NONE
        if (lastCapUs != Long.MIN_VALUE) {
            if (prevCapUs != Long.MIN_VALUE) verdict = judge()
            prevCapUs = lastCapUs; prevSlotNs = lastSlotNs; prevPeriodNs = lastPeriodNs
        }
        lastCapUs = captureUs; lastSlotNs = slotNs; lastPeriodNs = periodNs
        return verdict
    }

    /** The interval from the previous shown frame to the latest one (both known shown). */
    private fun judge(): Int {
        val p = lastPeriodNs
        if (Math.abs(prevPeriodNs - p) * 20 > p) return NONE // another panel rate
        val i = find(lastCapUs)
        if (i < 0) return NONE
        val start = decRunStart[i]
        val gap = decRunGap[i]
        if (gap <= 0 || start == Long.MIN_VALUE || prevCapUs < start || prevCapUs >= lastCapUs) return NONE
        val n = Math.round(gap.toDouble() / p)
        if (n < 1 || n > MAX_CADENCE || Math.abs(gap - n * p) > RUN_TOLERANCE_NS) return NONE
        val hold = Math.round((lastSlotNs - prevSlotNs).toDouble() / p)
        return if (hold < n) SHORT else if (hold == n) EXACT else LONG
    }

    private fun find(captureUs: Long): Int {
        for (k in 1..decN) {
            val i = Math.floorMod(decPos - k, DECODED_MAX)
            if (decCapture[i] == captureUs) return i
        }
        return -1
    }

    /** The shown sequence is broken (a release with no known slot): no interval spans it. */
    fun breakSequence() { lastCapUs = Long.MIN_VALUE; prevCapUs = Long.MIN_VALUE }

    /** Stream or codec boundary: shown sequence and content runs start over. */
    fun reset() {
        breakSequence()
        decPos = 0; decN = 0
        lastDecodedUs = Long.MIN_VALUE; runStartUs = Long.MIN_VALUE; runGapNs = 0
    }
}
