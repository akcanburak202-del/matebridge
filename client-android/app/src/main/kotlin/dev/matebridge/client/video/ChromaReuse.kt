package dev.matebridge.client.video

/**
 * T-261 (decision 0034, option B): temporal reuse of the last full colour in unchanged blocks, plus the decision for
 * upgrading a frame whose auxiliary view arrived after the main frame was shown. This file is the CPU reference of the
 * GL state pass in `cpp/mbfullchroma.cpp` (`kFsStateMain` / `kFsStateMerge`): same rule, same tolerance, same state layout.
 *
 * State (per full-resolution pixel, 8-bit decoder samples): `y` (shown luma), `cb`, `cr` (full resolution chroma shown),
 * `yRef` (the luma of the frame the block's chroma was last (re)set from; kept while the block stays unchanged, so slow
 * drifts cannot accumulate).
 *
 * A main-only frame is judged per 2x2 block: the block is unchanged when all four luma samples are within the tolerance
 * of `yRef` and the main picture's chroma sample (the host's `pick`: Cb/Cr at the block's (even, even) pixel) is within
 * the tolerance of the state's chroma at that pixel. Unchanged: the state's full chroma is kept, only luma is current.
 * Changed: the main chroma is replicated over the block (what the plain main-only pass shows) and `yRef` is reset.
 * A paired frame replaces the whole state with the merged 4:4:4 picture.
 */
object ChromaReuse {
    /** |dY|, |dCb|, |dCr| <= TOLERANCE (8-bit steps): T-253 sharpening shifts static areas slightly. Tuned on the device. */
    const val TOLERANCE = 2

    /** The block rule on the 4 luma samples (current vs reference) and the main chroma vs the state's chroma. */
    fun blockUnchanged(
        y: IntArray, yRef: IntArray, mainCb: Int, mainCr: Int, stateCb: Int, stateCr: Int, tolerance: Int = TOLERANCE,
    ): Boolean {
        if (tolerance < 0) return false
        for (i in 0 until 4) if (Math.abs(y[i] - yRef[i]) > tolerance) return false
        return Math.abs(mainCb - stateCb) <= tolerance && Math.abs(mainCr - stateCr) <= tolerance
    }
}

/**
 * Whether a frame already shown main-only may be shown again with its auxiliary view because that arrived late
 * (the static screen case: nothing newer will replace the frame, so without this it would stay 4:2:0 until the next
 * change). The upgrade is only offered once the original is known to have been presented ([onShown]) or its target time
 * plus [GRACE_NS] has passed, so that it does not replace the original in the BufferQueue before it was displayed.
 * Pure state; the presenter owns the held image.
 */
class LateUpgrade {
    private var heldCaptureUs = NONE
    private var heldPaired = true
    private var heldShown = false
    private var notBeforeNs = 0L

    companion object {
        /** `capture_time_us` of a frame without an expectation (never matched). */
        const val NONE = Long.MIN_VALUE

        /** Margin after the original's target (or draw) time, covering the compositor latch (>= 1 vsync at 60 Hz). */
        const val GRACE_NS = 20_000_000L

        /**
         * How long after [GRACE_NS] a main-only frame's image is kept for a late auxiliary frame (T-263). The auxiliary
         * ring ([AuxPairing]) forgets older frames anyway; holding longer would only take one of the main reader's images.
         */
        const val HOLD_NS = 250_000_000L
    }

    /**
     * Whether the presenter must still keep the held main image at [nowNs]: only while an upgrade is possible (frame not
     * paired yet, within [HOLD_NS] of its upgrade window). Once false the image goes to the retire queue.
     */
    fun holdsImage(nowNs: Long): Boolean =
        !heldPaired && heldCaptureUs != NONE && nowNs < notBeforeNs + HOLD_NS

    /**
     * The main frame [captureUs] was just drawn; [paired] = with its auxiliary view (or a draw that cannot be upgraded);
     * [targetNs] = the later of its presentation target and the draw time.
     */
    fun onMainDrawn(captureUs: Long, paired: Boolean, targetNs: Long = 0L) {
        heldCaptureUs = captureUs
        heldPaired = paired || captureUs == NONE
        heldShown = false
        notBeforeNs = targetNs + GRACE_NS
    }

    /** The held frame's own presentation was confirmed (EGL timestamps). */
    fun onShown() { heldShown = true }

    /** `capture_time_us` to look up in the auxiliary ring when the held frame is due an upgrade at [nowNs], else null. */
    fun candidate(nowNs: Long): Long? =
        if (heldPaired || heldCaptureUs == NONE || !(heldShown || nowNs >= notBeforeNs)) null else heldCaptureUs

    /** The held frame was redrawn with its auxiliary view. */
    fun onUpgraded() { heldPaired = true }

    fun clear() {
        heldCaptureUs = NONE
        heldPaired = true
        heldShown = false
    }
}

/** Reports each frame tag's first presentation only (an upgrade redraw shares its original's tag). Bounded. */
class FirstShown(private val capacity: Int = 64) {
    private val seen = LinkedHashSet<Long>()

    /** True the first time [tag] is offered. */
    fun first(tag: Long): Boolean {
        if (!seen.add(tag)) return false
        while (seen.size > capacity) seen.remove(seen.first())
        return true
    }

    fun clear() = seen.clear()
}

/**
 * Age of the oldest submitted draw whose fence has not signalled, independent of which images are still held (a static
 * screen keeps the last image outside the retire queue). Draw numbers are the presenter's `submitted` counter.
 */
class DrawWatch {
    private val times = ArrayDeque<Pair<Long, Long>>() // (draw number, submit time ns)

    fun onSubmitted(draw: Long, nowNs: Long) { times.addLast(draw to nowNs) }

    /** True while a submitted draw was not seen completed by the last [stalledForNs] (the GL thread must keep polling). */
    fun hasOutstanding(): Boolean = times.isNotEmpty()

    /** 0 when every submitted draw completed, else how long the oldest incomplete one has been waiting. */
    fun stalledForNs(nowNs: Long, completedDraws: Long): Long {
        while (times.isNotEmpty() && times.first().first <= completedDraws) times.removeFirst()
        return if (times.isEmpty()) 0L else nowNs - times.first().second
    }
}
