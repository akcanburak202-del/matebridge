package dev.matebridge.client.overlay

import dev.matebridge.client.input.PenAction
import dev.matebridge.client.input.PenFrame
import dev.matebridge.client.input.PenInkListener

/** Tunables of the local pen indicator (T-056), in one place. */
object PenInkStyle {
    /** Only samples within this window behind the newest one form the trail. */
    const val TRAIL_WINDOW_MS = 40L

    /** A sample fades out linearly and is gone this long after its event time (the Mac's real line catches up meanwhile). */
    const val FADE_MS = 70L

    /** Opacity of the newest trail part, 0..1 (neutral, semi transparent). */
    const val TRAIL_ALPHA = 0.55f

    /** No pen sample for this long hides the ring and clears the trail (a missing HOVER_EXIT must not leave a stuck dot). */
    const val STALE_MS = 250L

    const val DOT_RADIUS_DP = 3f
    const val ERASER_RING_RADIUS_DP = 9f
    const val MIN_WIDTH_DP = 1.5f
    const val MAX_WIDTH_DP = 9f

    /** Trail width in dp, proportional to pressure (0..1, clamped; NaN counts as 0). */
    fun widthDp(pressure: Float): Float {
        val p = if (pressure.isNaN()) 0f else pressure.coerceIn(0f, 1f)
        return MIN_WIDTH_DP + (MAX_WIDTH_DP - MIN_WIDTH_DP) * p
    }
}

/** Receives the visible trail segments of one draw. */
fun interface InkSegmentVisitor {
    fun segment(x0: Float, y0: Float, x1: Float, y1: Float, pressure: Float, alpha: Float)
}

/**
 * Pure state of the local pen indicator: where the pen is (dot) and the last few tens of ms of the stroke (trail).
 * UI thread only, allocation free after construction. Times are event times in ms on the uptime clock, the same base
 * as the `now` passed to drawing. Coordinates are in the overlay's (root) pixel space, as in [PenFrame].
 * In eraser mode no trail is recorded, only the ring.
 */
class PenInkModel : PenInkListener {
    var trailEnabled = true
    var dotEnabled = true

    private val t = LongArray(CAP)
    private val xs = FloatArray(CAP)
    private val ys = FloatArray(CAP)
    private val ps = FloatArray(CAP)
    private val brk = BooleanArray(CAP) // sample starts a new stroke: no segment to its predecessor
    private var head = 0 // index of the oldest
    private var size = 0
    private var inStroke = false
    private var lastSampleMs = 0L

    var dotVisible = false
        private set
    var dotX = 0f
        private set
    var dotY = 0f
        private set
    var inContact = false
        private set
    var eraser = false
        private set

    override fun onPenFrame(f: PenFrame, eraser: Boolean) {
        this.eraser = eraser
        val pts = f.points
        if (pts.isEmpty()) return
        val last = pts[pts.size - 1]
        lastSampleMs = last.timeUs / 1000
        when (f.action) {
            PenAction.DOWN, PenAction.MOVE, PenAction.UP -> {
                if (f.action == PenAction.DOWN) inStroke = false
                if (trailEnabled && !eraser) {
                    for (p in pts) {
                        add(p.timeUs / 1000, p.x, p.y, p.pressure, !inStroke)
                        inStroke = true
                    }
                } else {
                    inStroke = false
                }
                inContact = f.action != PenAction.UP
                if (f.action == PenAction.UP) inStroke = false
                setDot(last.x, last.y)
            }
            PenAction.HOVER_ENTER, PenAction.HOVER_MOVE -> {
                inStroke = false
                inContact = false
                setDot(last.x, last.y)
            }
            PenAction.HOVER_EXIT, PenAction.CANCEL -> {
                inStroke = false
                inContact = false
                dotVisible = false
            }
        }
    }

    override fun onPenClear() = clear()

    fun clear() {
        head = 0
        size = 0
        inStroke = false
        inContact = false
        dotVisible = false
        eraser = false
    }

    /** True while a trail is still visible, so the owner keeps drawing every frame. */
    fun hasLiveTrail(now: Long): Boolean {
        if (!trailEnabled || size == 0) return false
        return now - t[idx(size - 1)] < FADE
    }

    /** The dot is shown (enabled, the pen is known to be in range and a sample arrived within [PenInkStyle.STALE_MS]). */
    fun showDot(now: Long) = dotEnabled && dotVisible && now - lastSampleMs < PenInkStyle.STALE_MS

    /** Clears everything when the last sample is older than [PenInkStyle.STALE_MS]. Returns true if it cleared. */
    fun expireIfStale(now: Long): Boolean {
        if ((dotVisible || size > 0) && now - lastSampleMs >= PenInkStyle.STALE_MS) { clear(); return true }
        return false
    }

    /** Ms until [expireIfStale] would clear, or -1 when there is nothing to expire. */
    fun msUntilStale(now: Long): Long =
        if (dotVisible || size > 0) maxOf(1L, lastSampleMs + PenInkStyle.STALE_MS - now) else -1L

    /** Emits every visible segment at [now], oldest first. */
    fun forEachSegment(now: Long, v: InkSegmentVisitor) {
        if (!trailEnabled || size < 2) return
        val newest = t[idx(size - 1)]
        for (i in 1 until size) {
            val j = idx(i)
            if (brk[j]) continue
            val age = now - t[j]
            if (age >= FADE || newest - t[j] > PenInkStyle.TRAIL_WINDOW_MS) continue
            val k = idx(i - 1)
            val alpha = PenInkStyle.TRAIL_ALPHA * (1f - (if (age < 0) 0L else age).toFloat() / FADE)
            v.segment(xs[k], ys[k], xs[j], ys[j], ps[j], alpha)
        }
    }

    private fun setDot(x: Float, y: Float) {
        dotX = x
        dotY = y
        dotVisible = true
    }

    private fun idx(i: Int) = (head + i) % CAP

    private fun add(timeMs: Long, x: Float, y: Float, p: Float, startsStroke: Boolean) {
        // Drop what has faded relative to the new sample, then make room if the ring is still full.
        while (size > 0 && timeMs - t[head] >= FADE) { head = (head + 1) % CAP; size-- }
        if (size == CAP) { head = (head + 1) % CAP; size-- }
        val j = idx(size)
        t[j] = timeMs; xs[j] = x; ys[j] = y; ps[j] = p; brk[j] = startsStroke
        size++
    }

    private companion object {
        const val CAP = 128
        const val FADE = PenInkStyle.FADE_MS
    }
}
