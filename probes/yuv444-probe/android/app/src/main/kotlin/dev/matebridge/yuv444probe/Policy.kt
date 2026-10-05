package dev.matebridge.yuv444probe

/** GL path presentation variants (`--es present`). */
enum class PresentMode(val key: String) {
    /** Today's probe: swap as soon as a frame arrives (the BufferQueue may fill up). */
    QUEUE("queue"),
    /** No new swap until the previous swap's compositor latch is known; the newest frame wins while waiting. */
    DEPTH1("depth1"),
    /** `eglPresentationTimeANDROID` = vsync slot - lead, like the product's slot logic. */
    PTS("pts");

    companion object {
        /** Null for an unknown key; a missing key is [QUEUE]. */
        fun parse(s: String?): PresentMode? = entries.firstOrNull { it.key == (s?.trim()?.lowercase() ?: "queue") }
    }
}

/** Direct (decoder -> SurfaceView) release variants (`--es direct_mode`). */
enum class DirectMode(val key: String) {
    IMMEDIATE("immediate"),
    /** `releaseOutputBuffer(idx, vsync slot - lead)` like the product. */
    PTS("pts");

    companion object {
        fun parse(s: String?): DirectMode? = entries.firstOrNull { it.key == (s?.trim()?.lowercase() ?: "immediate") }
    }
}

/**
 * Depth-1 gate of the GL path: `outstanding` is the number of swapped frames whose latch time is still unknown (-1 when
 * the platform cannot tell: the gate is then always open). The gate also opens after [STALL_NS] of waiting, so a lost
 * timestamp can never wedge the loop.
 */
object Depth1Gate {
    const val STALL_NS = 100_000_000L

    fun open(outstanding: Int, depth: Int, waitedNs: Long): Boolean =
        outstanding < 0 || outstanding < depth || waitedNs >= STALL_NS
}

/** A regular vsync grid: `refNs + k * periodNs` for any integer k. */
class VsyncGrid(val refNs: Long, val periodNs: Long) {
    /** First grid time at or after [t]. */
    fun nextAtOrAfter(t: Long): Long {
        val k = Math.floorDiv(t - refNs + periodNs - 1, periodNs)
        return refNs + k * periodNs
    }
}

/** Builds a [VsyncGrid] from Choreographer frame times (monotonic ns, any order). */
object VsyncEstimator {
    /** Null when fewer than 4 samples or the median step is outside 2..50 ms. [offsetNs] shifts the phase. */
    fun estimate(samples: LongArray, offsetNs: Long = 0): VsyncGrid? {
        if (samples.size < 4) return null
        val s = samples.sortedArray()
        val diffs = LongArray(s.size - 1) { s[it + 1] - s[it] }
        val period = percentile(diffs, 50.0)
        if (period < 2_000_000L || period > 50_000_000L) return null
        return VsyncGrid(s.last() + offsetNs, period)
    }
}

/**
 * The product's slot logic reduced to a target: each frame gets the earliest vsync slot at or after `now + lead`, never
 * the same or an earlier slot than the previous frame (a second frame for a slot moves to the next one, counted in
 * [bumps]); the returned target is the slot minus [leadNs], the value `releaseOutputBuffer(idx, ns)` and
 * `eglPresentationTimeANDROID` receive. [maxAheadSlots] bounds the extra delay a bump chain may add: past it a frame
 * folds onto the last slot (the compositor then replaces the earlier one) and counts in [folds].
 */
class SlotAllocator(private val leadNs: Long, private val maxAheadSlots: Int = 2) {
    private var lastSlot = Long.MIN_VALUE
    var bumps = 0
        private set
    var folds = 0
        private set

    fun targetNs(nowNs: Long, grid: VsyncGrid): Long {
        val earliest = grid.nextAtOrAfter(nowNs + leadNs)
        var slot = earliest
        if (lastSlot != Long.MIN_VALUE && slot <= lastSlot) {
            val moved = lastSlot + grid.periodNs
            if (moved - earliest > maxAheadSlots * grid.periodNs) {
                folds++
                slot = lastSlot
            } else {
                bumps++
                slot = moved
            }
        }
        lastSlot = slot
        return slot - leadNs
    }
}

/** The T-256 decision rule (card): GL path vs direct path arrival-to-display, p50 and p95 deltas in ms. */
enum class LatencyVerdict {
    /** Both deltas <= +5 ms: the 4:4:4 app may proceed. */
    PROCEED,
    /** Either delta > +10 ms: stop, decision 0033 stays. */
    STOP,
    /** In between: talk to the user. */
    DISCUSS;

    companion object {
        fun decide(p50DeltaMs: Double, p95DeltaMs: Double): LatencyVerdict = when {
            p50DeltaMs > 10.0 || p95DeltaMs > 10.0 -> STOP
            p50DeltaMs <= 5.0 && p95DeltaMs <= 5.0 -> PROCEED
            else -> DISCUSS
        }
    }
}
