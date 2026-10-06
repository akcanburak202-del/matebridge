package dev.matebridge.client.video

/**
 * T-290: test-only CPU model of the full-chroma GL state pass (moved out of production code, where nothing used it).
 * The production rule it exercises is [ChromaReuse.blockUnchanged]; see [ChromaReuse] for the state layout.
 */

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
