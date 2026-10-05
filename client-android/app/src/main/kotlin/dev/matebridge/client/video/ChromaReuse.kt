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

/** A 4:2:0 picture of 8-bit samples (the decoder's output of one view): chroma planes are `w/2 x h/2`. */
class Planes420(val w: Int, val h: Int, val y: IntArray, val cb: IntArray, val cr: IntArray)

/** CPU model of the GL state texture and its two update passes (see [ChromaReuse]). */
class ChromaReuseModel(val w: Int, val h: Int, private val tolerance: Int = ChromaReuse.TOLERANCE) {
    init { require(Avc444v2.isValid(w, h)) }

    val y = IntArray(w * h)
    val cb = IntArray(w * h)
    val cr = IntArray(w * h)
    val yRef = IntArray(w * h)

    /** False until the first frame has been drawn (nothing to reuse). */
    var valid = false
        private set

    /** Merged 4:4:4 picture of a paired frame (the GLSL merge pass, [Avc444v2.home]); replaces the whole state. */
    fun drawPaired(main: Planes420, aux: Planes420) {
        val cw = w / 2
        fun sample(h: Avc444v2.Home, isCr: Boolean): Int = when (h.plane) {
            Avc444v2.Plane.MAIN_CHROMA -> (if (isCr) main.cr else main.cb)[h.y * cw + h.x]
            Avc444v2.Plane.AUX_LUMA -> aux.y[h.y * w + h.x]
            Avc444v2.Plane.AUX_CB -> aux.cb[h.y * cw + h.x]
            Avc444v2.Plane.AUX_CR -> aux.cr[h.y * cw + h.x]
        }
        for (py in 0 until h) for (px in 0 until w) {
            val i = py * w + px
            y[i] = main.y[i]
            yRef[i] = main.y[i]
            cb[i] = sample(Avc444v2.home(px, py, w, cr = false), false)
            cr[i] = sample(Avc444v2.home(px, py, w, cr = true), true)
        }
        valid = true
    }

    /**
     * A main-only frame. [reuse] false (or no state yet) = the plain pass (every block replicated). Returns the number of
     * 2x2 blocks that kept the state's full colour.
     */
    fun drawMainOnly(main: Planes420, reuse: Boolean = true): Int {
        val cw = w / 2
        val useRef = reuse && valid && tolerance >= 0
        var reused = 0
        val q = IntArray(4)
        val r = IntArray(4)
        for (by in 0 until h / 2) for (bx in 0 until cw) {
            val x0 = 2 * bx
            val y0 = 2 * by
            for (k in 0 until 4) {
                val i = (y0 + (k shr 1)) * w + x0 + (k and 1)
                q[k] = main.y[i]
                r[k] = yRef[i]
            }
            val mcb = main.cb[by * cw + bx]
            val mcr = main.cr[by * cw + bx]
            val same = useRef && ChromaReuse.blockUnchanged(q, r, mcb, mcr, cb[y0 * w + x0], cr[y0 * w + x0], tolerance)
            if (same) reused++
            for (k in 0 until 4) {
                val i = (y0 + (k shr 1)) * w + x0 + (k and 1)
                y[i] = main.y[i]
                if (!same) {
                    cb[i] = mcb
                    cr[i] = mcr
                    yRef[i] = main.y[i]
                }
            }
        }
        valid = true
        return reused
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
    }

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

    /** 0 when every submitted draw completed, else how long the oldest incomplete one has been waiting. */
    fun stalledForNs(nowNs: Long, completedDraws: Long): Long {
        while (times.isNotEmpty() && times.first().first <= completedDraws) times.removeFirst()
        return if (times.isEmpty()) 0L else nowNs - times.first().second
    }
}
