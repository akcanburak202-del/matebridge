package dev.matebridge.client.video

/**
 * T-220 test rig: the decoder output path without a codec. Frames are decoded at their ready time ([VideoStats.onOutput]),
 * then either released at once (buffer 0, [adaptive] false) or scheduled by [AdaptivePacer] and released by [SlotReleaser]
 * at their dispatch deadline, like the output thread. Every release reports the vsync it was released for
 * ([HoldMeter.latchSlot]) to [stats], as `CodecSink.render` does. The content interval of the pacer comes from
 * [FrameInterval.resolve] with an [ArrivalTracker] fed at "input" ([inferCadence] false: the cadence is not passed, the
 * resolve before T-220). Deterministic: a fake vsync grid advanced to each event, no sleeps.
 */
internal class PresentRig(
    panelHz: Int, private val streamNs: Long, val adaptive: Boolean, inferCadence: Boolean = true,
    /**
     * T-225: every release's frame-rendered callback is reported to [stats] ([VideoStats.onRenderCallback]) with the time of
     * the vsync the frame is really shown on (the grid at the release, [releaseDelayNs] excluded) plus a constant
     * [CB_OFFSET_NS] (the device's callbacks come ~31 ms late). [dropCallback] names frames whose callback never comes (SF
     * dropped them); [lateByVsyncs] shows a frame that many vsyncs later than released.
     */
    private val callbacks: Boolean = false,
    /**
     * T-225: the release call returns [releaseDelayNs] plus up to [releaseJitterNs] (uniform) after it started: the
     * thread wake-up and codec call the old latch model was fragile to (the cut it judged late at is 1 ms after the start).
     */
    private val releaseDelayNs: Long = 0,
    private val releaseJitterNs: Long = 0,
    private val dropCallback: (captureUs: Long) -> Boolean = { false },
    private val lateByVsyncs: (captureUs: Long) -> Int = { 0 },
) {
    companion object { const val CB_OFFSET_NS = 31_000_000L }

    val clk = VsyncClock(panelHz.toFloat()).also { it.onVsync(0); it.setDisplayTiming(0, 13_330_000L) }
    var period = clk.grid().periodNs
        private set
    val tracker = ArrivalTracker()
    val stats = VideoStats()
    val pacer = AdaptivePacer(clk, streamNs).also {
        it.intervalProvider = { p -> FrameInterval.resolve(streamNs, p, tracker.intervalNs, if (inferCadence) tracker.cadenceNs else 0) }
    }
    val probe = PaceProbe().also { pacer.probe = it }
    val counters = PresentCounters()
    /** Released frames in release order: capture (us) and the vsync each was released for (the latch model's, with the delay). */
    val released = ArrayList<LongArray>()
    /** T-225: frames that got a callback, in release order: capture (us) and the vsync they were shown on. */
    val shownByCallback = ArrayList<LongArray>()
    val decisions = ArrayList<FramePacer.Decision>()
    val paths = HashMap<Int, Int>()

    private val delayRnd = Lcg(77L)
    private var nowNs = 0L
    private var vsyncNs = 0L
    private val captureOf = HashMap<Int, Long>()
    private val rel = SlotReleaser(object : SlotReleaser.Sink {
        override fun release(idx: Int, renderNs: Long) = present(idx, renderNs)
        override fun discard(idx: Int) { captureOf.remove(idx) }
    }, counters)

    private fun present(idx: Int, renderNs: Long) {
        val cap = captureOf.remove(idx)!!
        val g = clk.grid()
        val slot = HoldMeter.latchSlot(g, renderNs, clk.leadNs(), nowNs + releaseDelayNs + (delayRnd.next() * releaseJitterNs).toLong())
        if (callbacks) stats.awaitCallback(idx.toLong())
        stats.onReleased(idx.toLong(), cap, nowNs / 1000, slot, g.periodNs)
        released.add(longArrayOf(cap, slot))
        if (callbacks && !dropCallback(cap)) {
            val shown = HoldMeter.latchSlot(g, renderNs, clk.leadNs(), nowNs) + lateByVsyncs(cap) * g.periodNs
            stats.onRenderCallback(idx.toLong(), cap, nowNs / 1000, shown + CB_OFFSET_NS, g.periodNs)
            shownByCallback.add(longArrayOf(cap, shown))
        }
    }

    private fun vsyncTo(t: Long) {
        while (vsyncNs + period <= t) { vsyncNs += period; clk.onVsync(vsyncNs) }
    }

    /** Time goes to [t]; a held buffer is released at its own dispatch deadline on the way (the output thread's wait). */
    fun advanceTo(t: Long) {
        while (true) {
            val wait = rel.untilDeadlineNs(nowNs) ?: break
            val due = nowNs + wait
            if (due > t) break
            vsyncTo(due); nowNs = due; rel.flushDue(due)
        }
        vsyncTo(t); nowNs = maxOf(nowNs, t); rel.flushDue(nowNs)
    }

    /** The panel switches to [hz] at [atNs]; its next vsync comes [phaseNs] after the last one of the old rate. */
    fun switchPanel(hz: Int, atNs: Long, phaseNs: Long) {
        advanceTo(atNs)
        clk.setNominalHz(hz.toFloat())
        period = clk.grid().periodNs
        vsyncNs += phaseNs - period // the loop adds one period
    }

    /** Frame [k] captured at [captureNs] reaches the decoder input (the renderer feeds the tracker there). */
    fun input(k: Int, captureNs: Long) {
        tracker.onFrame(captureNs / 1000)
        stats.onInput(k.toLong(), captureNs / 1000, captureNs / 1000)
    }

    /** Frame [k] comes out of the decoder at [readyNs]. */
    fun output(k: Int, captureNs: Long, readyNs: Long): FramePacer.Decision? {
        advanceTo(readyNs)
        stats.onOutput(k.toLong(), readyNs / 1000, readyNs / 1000)
        captureOf[k] = captureNs / 1000
        if (!adaptive) { present(k, 0); return null }
        probe.clear()
        val d = pacer.schedule(captureNs / 1000, readyNs)!!
        paths.merge(probe.path, 1, Int::plus)
        decisions.add(d)
        stats.onScheduled(d.skipped)
        rel.submit(k, d.slotNs, d.renderNs, d.slotNs - (clk.grid().deadlineNs + VideoRenderer.DISPATCH_MARGIN_NS), readyNs, period)
        return d
    }

    fun frame(k: Int, captureNs: Long, readyNs: Long): FramePacer.Decision? { input(k, captureNs); return output(k, captureNs, readyNs) }

    fun finish(t: Long) { advanceTo(t); rel.flushAll() }

    /** Shown frames (a release for the same vsync as the previous one replaces it), as (capture us, slot ns). */
    fun shown(): List<LongArray> {
        val out = ArrayList<LongArray>()
        for (r in released) {
            if (out.isNotEmpty() && Math.abs(r[1] - out.last()[1]) < period / 2) out[out.size - 1] = r else out.add(r)
        }
        return out
    }
}

internal class Lcg(private var seed: Long) {
    fun next(): Double { seed = seed * 6364136223846793005L + 1442695040888963407L; return ((seed ushr 33) % 10_000) / 10_000.0 }
}
