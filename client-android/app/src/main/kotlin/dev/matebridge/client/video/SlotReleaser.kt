package dev.matebridge.client.video

/**
 * One release per vsync slot (T-057). Decoded output buffers are handed over with a target slot; at most ONE
 * buffer is kept back (the newest one, replaceable) until its dispatch deadline, so a newer frame that lands
 * on the same slot can still replace it. A buffer is released with `releaseOutputBuffer(idx, renderNs)` at most
 * once per slot; everything else goes to [Sink.discard] (`releaseOutputBuffer(idx, false)`).
 *
 *  - new slot > pending slot: the pending buffer is released now (nothing can replace it any more), the new one
 *    becomes pending.
 *  - new slot == pending slot: the pending buffer is discarded, the new one replaces it (newest wins).
 *  - new slot <= an already released slot (T-065): the release cannot be undone, but the new buffer is the
 *    NEWEST frame and must not vanish; it moves to the slot after the released one (slot, render time and deadline
 *    shift by the same amount) and goes through the normal rules. A decoded frame is only ever discarded by a
 *    newer frame replacing it.
 *  - a pending buffer whose dispatch deadline has passed is released at once; [flushDue] does that over time.
 *
 * Every same-slot second attempt counts in [PresentCounters.slotDups]. Single-threaded (output thread).
 */
class SlotReleaser(private val sink: Sink, private val counters: PresentCounters) {
    interface Sink {
        fun release(idx: Int, renderNs: Long)
        fun discard(idx: Int)
    }

    private var pendingIdx = -1
    private var pendingSlot = Long.MIN_VALUE
    private var pendingRenderNs = 0L
    private var pendingDeadlineNs = Long.MAX_VALUE
    private var releasedSlot = Long.MIN_VALUE
    private var pendingTag = -1L

    /** T-069 experiment: per-frame trace of what happened to each submitted buffer (null = off). */
    @Volatile var trace: PaceTrace? = null

    /** Buffers held back (0 or 1). */
    val held: Int get() = if (pendingIdx >= 0) 1 else 0

    /**
     * [deadlineNs]: latest time the buffer may be kept before it must go to the codec so the compositor can
     * still present it on [slotNs] (System.nanoTime domain). [periodNs]: panel period, the step to the next slot.
     */
    fun submit(idx: Int, slotNs: Long, renderNs: Long, deadlineNs: Long, nowNs: Long, periodNs: Long, tag: Long = -1L) {
        var slot = slotNs
        var render = renderNs
        var deadline = deadlineNs
        if (releasedSlot != Long.MIN_VALUE && slot <= releasedSlot) {
            counters.onSlotDup()
            val shift = releasedSlot + periodNs - slot
            slot += shift; render += shift; deadline += shift
            trace?.onMove(tag)
        }
        if (pendingIdx >= 0) {
            if (slot < pendingSlot) { // the pacer never goes backwards; if it did, the pending (later) one stays
                counters.onSlotDup()
                trace?.onDiscard(tag, System.nanoTime(), PaceTrace.ACTION_DISCARD)
                sink.discard(idx)
                return
            }
            if (pendingSlot == slot) {
                counters.onSlotDup()
                trace?.onDiscard(pendingTag, System.nanoTime(), PaceTrace.ACTION_REPLACE)
                sink.discard(pendingIdx)
            } else {
                releasePending()
            }
        }
        pendingIdx = idx; pendingTag = tag; pendingSlot = slot; pendingRenderNs = render; pendingDeadlineNs = deadline
        flushDue(nowNs)
    }

    /** Releases the pending buffer if its deadline has passed. */
    fun flushDue(nowNs: Long) {
        if (pendingIdx >= 0 && nowNs >= pendingDeadlineNs) releasePending()
    }

    /** Releases the pending buffer now (no newer frame can be expected, or no pacing is possible). */
    fun flushAll() {
        if (pendingIdx >= 0) releasePending()
    }

    /** Time until the pending buffer must be released, or null when nothing is held. */
    fun untilDeadlineNs(nowNs: Long): Long? = if (pendingIdx >= 0) (pendingDeadlineNs - nowNs).coerceAtLeast(0) else null

    /** Forgets all state (codec restart); the pending buffer belongs to the old codec and is not touched. */
    fun reset() {
        pendingIdx = -1; pendingSlot = Long.MIN_VALUE; releasedSlot = Long.MIN_VALUE
    }

    private fun releasePending() {
        trace?.onRelease(pendingTag, pendingSlot, System.nanoTime(), pendingRenderNs)
        sink.release(pendingIdx, pendingRenderNs)
        releasedSlot = pendingSlot
        pendingIdx = -1
    }
}

/** Counters of the presentation scheduler, one window per STATS second. Thread-safe. */
class PresentCounters {
    private companion object { const val MAX_MARGINS = 2048 }

    /** [lateMarginP50Us]/[lateMarginMinUs]: how long before its own slot a late-dropped frame was ready (null: none). */
    data class Snapshot(
        val slotDups: Long, val lateDrops: Long, val lateMarginP50Us: Long? = null, val lateMarginMinUs: Long? = null,
    )

    private var slotDups = 0L
    private var lateDrops = 0L
    private val lateMargins = ArrayList<Long>()

    /** A second release attempt for one vsync slot (replaced while pending, or refused after release). */
    @Synchronized fun onSlotDup() { slotDups++ }

    /** A frame found no slot within the latency bound and was folded onto the previous slot. */
    @Synchronized fun onLateDrop(marginUs: Long? = null) {
        lateDrops++
        if (marginUs != null && lateMargins.size < MAX_MARGINS) lateMargins.add(marginUs)
    }

    @Synchronized fun snapshot(reset: Boolean = false): Snapshot {
        val sorted = lateMargins.sorted()
        val s = Snapshot(slotDups, lateDrops, sorted.getOrNull(sorted.size / 2), sorted.firstOrNull())
        if (reset) { slotDups = 0; lateDrops = 0; lateMargins.clear() }
        return s
    }
}

/**
 * Frames inside the decoder: queued as input minus released/discarded as output (a buffer held for a slot still
 * occupies the codec). Optional limit on the count ([canQueue]); 0 = unlimited. [p95AndReset] gives the window's
 * 95th percentile of the count sampled at each queue (a frame waiting for an input buffer counts as one more).
 * Thread-safe (input thread queues, output thread completes).
 */
class InFlightGauge {
    companion object {
        const val MAX_TRACKED = 32
        /** With a limit set, queueing is allowed again when no output completed for this long (no deadlock). */
        const val STALL_NS = 100_000_000L
    }

    private var count = 0
    private var lastDoneNs = 0L
    private val hist = IntArray(MAX_TRACKED + 1)
    private var samples = 0

    @Synchronized fun current(): Int = count

    @Synchronized fun onQueued(nowNs: Long) {
        if (count == 0) lastDoneNs = nowNs
        count++
        sample(count)
    }

    @Synchronized fun onDone(nowNs: Long) {
        if (count > 0) count--
        lastDoneNs = nowNs
    }

    /** A frame is waiting for room: sample the count including it. */
    @Synchronized fun onHeld() = sample(count + 1)

    @Synchronized fun canQueue(limit: Int, nowNs: Long): Boolean =
        limit <= 0 || count < limit || nowNs - lastDoneNs > STALL_NS

    @Synchronized fun reset() { count = 0 }

    @Synchronized fun p95AndReset(): Int? {
        if (samples == 0) return null
        val rank = (samples * 95 + 99) / 100
        var acc = 0
        var result = MAX_TRACKED
        for (i in hist.indices) { acc += hist[i]; if (acc >= rank) { result = i; break } }
        hist.fill(0); samples = 0
        return result
    }

    private fun sample(n: Int) { hist[n.coerceIn(0, MAX_TRACKED)]++; samples++ }
}
