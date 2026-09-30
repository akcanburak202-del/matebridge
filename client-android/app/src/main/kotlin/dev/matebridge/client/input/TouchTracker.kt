package dev.matebridge.client.input

import dev.matebridge.client.protocol.Buttons
import dev.matebridge.client.protocol.PointerAbs
import dev.matebridge.client.protocol.Scroll
import dev.matebridge.client.stream.VideoViewport
import kotlin.math.abs

/**
 * Finger capture (PROTOCOL.md section 4 POINTER_ABS and SCROLL, decision 0006). Pure Kotlin.
 *
 * - One finger: `POINTER_ABS source=TOUCH`, LEFT while pressed. The DOWN is held back by [HOLD_MS]
 *   (or until the finger moves more than [SLOP_PX], lifts, or the tick runs) so that a second finger
 *   arriving right after the first starts a scroll without a stray click. Once a DOWN was sent, its UP
 *   is always sent (finger up, cancel, second finger, pen entering range, release).
 * - Two fingers: `SCROLL` BEGAN, CHANGED (centroid motion in Mac points via `width_pt/height_pt`),
 *   ENDED/CANCELLED. While the fingers rest a CHANGED(0,0) keepalive is sent so the host's 500 ms scroll
 *   watchdog does not end the gesture. A finger that stays down after the other lifted is ignored until it lifts.
 * - Palm rejection (decision 0006): a new press is refused while the pen is in range and for [PALM_TAIL_MS]
 *   after the last pen event. Releases are never refused. When the pen enters range, a pending or pressed
 *   single finger is released (it is most likely the palm) and ignored until it lifts.
 * - [disabled] ("Parmak dokunmasını tamamen kapat") refuses every press.
 *
 * Fingers that were refused or abandoned are simply not tracked: their MOVE/UP events are ignored.
 * Coordinates go through [viewport] only. Not thread-safe: UI thread only.
 */
class TouchTracker(
    private val viewport: () -> VideoViewport,
    private val pen: PenPresence,
    private val counters: InputCounters = InputCounters(),
) {
    private enum class Mode { IDLE, PENDING, POINTER, SCROLL }

    /** Mac point size of the stream (STREAM_CONFIG.width_pt/height_pt); scrolling is off until known. */
    var widthPt = 0
    var heightPt = 0

    var disabled = false

    private var mode = Mode.IDLE
    private var pointerId = -1
    private var downX = 0f
    private var downY = 0f
    private var downMs = 0L
    private var lastX = 0f
    private var lastY = 0f
    private var scrollA = -1
    private var scrollB = -1
    private var centroidX = 0f
    private var centroidY = 0f
    private var lastScrollMs = 0L

    val isIdle get() = mode == Mode.IDLE

    /** A DOWN was sent and its UP is owed. */
    val isPressed get() = mode == Mode.POINTER

    /** A SCROLL BEGAN was sent and its ENDED/CANCELLED is owed. */
    val isScrolling get() = mode == Mode.SCROLL

    fun onFrame(f: TouchFrame, nowMs: Long): List<Outgoing> {
        val out = ArrayList<Outgoing>(2)
        when (f.action) {
            TouchAction.DOWN -> down(f, nowMs, out)
            TouchAction.MOVE -> move(f, nowMs, out)
            TouchAction.UP -> up(f, out)
            TouchAction.CANCEL -> forceRelease(f.timeUs, out)
        }
        return out
    }

    fun tick(nowMs: Long): List<Outgoing> {
        val out = ArrayList<Outgoing>(1)
        when (mode) {
            Mode.PENDING -> if (nowMs - downMs >= HOLD_MS) pressNow(nowMs * 1000, out, movedBeyondSlop = false)
            Mode.SCROLL -> if (nowMs - lastScrollMs >= SCROLL_KEEPALIVE_MS) {
                lastScrollMs = nowMs
                out += scroll(nowMs * 1000, 0f, 0f, Scroll.CHANGED, mergeable = true)
            }
            else -> Unit
        }
        return out
    }

    /** Ends everything the host may hold for touch (cancel, background, focus loss, deactivation). */
    fun release(nowMs: Long): List<Outgoing> {
        val out = ArrayList<Outgoing>(1)
        forceRelease(nowMs * 1000, out)
        return out
    }

    /** Forget everything without sending (host released it, or the connection was lost). */
    fun reset() {
        mode = Mode.IDLE
        pointerId = -1
        scrollA = -1
        scrollB = -1
    }

    /** The pen came into range: drop a pending or pressed single finger, it is probably the palm. */
    fun onPenRangeBegan(nowMs: Long): List<Outgoing> {
        val out = ArrayList<Outgoing>(1)
        if (mode == Mode.PENDING || mode == Mode.POINTER) {
            counters.palmRejects++
            forceRelease(nowMs * 1000, out)
        }
        return out
    }

    fun setDisabled(value: Boolean, nowMs: Long): List<Outgoing> {
        disabled = value
        return if (value) release(nowMs) else emptyList()
    }

    // ---- events ----

    private fun down(f: TouchFrame, nowMs: Long, out: MutableList<Outgoing>) {
        val fp = f.fingers.firstOrNull { it.id == f.actingId } ?: return
        if (disabled) return
        if (blocked(nowMs)) {
            counters.palmRejects++
            return
        }
        when (mode) {
            Mode.IDLE -> {
                mode = Mode.PENDING
                pointerId = fp.id
                downX = fp.x; downY = fp.y
                lastX = fp.x; lastY = fp.y
                downMs = nowMs
            }
            Mode.PENDING, Mode.POINTER -> {
                if (fp.id == pointerId || widthPt <= 0 || heightPt <= 0) return
                val first = f.fingers.firstOrNull { it.id == pointerId }
                if (mode == Mode.POINTER) out += ptr(f.timeUs, lastX, lastY, 0) // end the press first
                mode = Mode.SCROLL
                scrollA = pointerId
                scrollB = fp.id
                val ax = first?.x ?: lastX
                val ay = first?.y ?: lastY
                centroidX = (ax + fp.x) / 2f
                centroidY = (ay + fp.y) / 2f
                lastScrollMs = nowMs
                out += scroll(f.timeUs, 0f, 0f, Scroll.BEGAN, mergeable = false)
            }
            Mode.SCROLL -> Unit // a third finger is ignored
        }
    }

    private fun move(f: TouchFrame, nowMs: Long, out: MutableList<Outgoing>) {
        when (mode) {
            Mode.PENDING -> {
                val fp = f.fingers.firstOrNull { it.id == pointerId } ?: return
                lastX = fp.x; lastY = fp.y
                if (abs(fp.x - downX) > SLOP_PX || abs(fp.y - downY) > SLOP_PX) pressNow(f.timeUs, out, movedBeyondSlop = true)
            }
            Mode.POINTER -> {
                val fp = f.fingers.firstOrNull { it.id == pointerId } ?: return
                if (fp.x == lastX && fp.y == lastY) return
                lastX = fp.x; lastY = fp.y
                out += ptr(f.timeUs, fp.x, fp.y, Buttons.LEFT)
            }
            Mode.SCROLL -> {
                val a = f.fingers.firstOrNull { it.id == scrollA } ?: return
                val b = f.fingers.firstOrNull { it.id == scrollB } ?: return
                val cx = (a.x + b.x) / 2f
                val cy = (a.y + b.y) / 2f
                val dxPx = cx - centroidX
                val dyPx = cy - centroidY
                centroidX = cx; centroidY = cy
                if (dxPx == 0f && dyPx == 0f) return
                val vp = viewport()
                if (vp.isEmpty) return
                val dx = dxPx * widthPt / vp.width
                val dy = dyPx * heightPt / vp.height
                lastScrollMs = nowMs
                out += scroll(f.timeUs, dx, dy, Scroll.CHANGED, mergeable = true)
            }
            Mode.IDLE -> Unit
        }
    }

    private fun up(f: TouchFrame, out: MutableList<Outgoing>) {
        val id = f.actingId
        when (mode) {
            Mode.PENDING -> if (id == pointerId) {
                // A tap: DOWN then UP at the touch-down position (within slop), in order, so it is a click and not a drag.
                pressNow(f.timeUs, out, movedBeyondSlop = false)
                out += ptr(f.timeUs, downX, downY, 0)
                mode = Mode.IDLE
            }
            Mode.POINTER -> if (id == pointerId) {
                val fp = f.fingers.firstOrNull { it.id == id }
                if (fp != null) { lastX = fp.x; lastY = fp.y }
                out += ptr(f.timeUs, lastX, lastY, 0)
                mode = Mode.IDLE
            }
            Mode.SCROLL -> if (id == scrollA || id == scrollB) {
                out += scroll(f.timeUs, 0f, 0f, Scroll.ENDED, mergeable = false)
                mode = Mode.IDLE // the remaining finger stays untracked until it lifts
                scrollA = -1
                scrollB = -1
            }
            Mode.IDLE -> Unit
        }
    }

    /**
     * Sends the held-back DOWN at the touch-down position. If the finger already moved beyond the slop, its
     * current position follows; otherwise it is treated as stationary at the down position.
     */
    private fun pressNow(timeUs: Long, out: MutableList<Outgoing>, movedBeyondSlop: Boolean) {
        out += ptr(timeUs, downX, downY, Buttons.LEFT)
        if (movedBeyondSlop) {
            if (lastX != downX || lastY != downY) out += ptr(timeUs, lastX, lastY, Buttons.LEFT)
        } else {
            lastX = downX
            lastY = downY
        }
        mode = Mode.POINTER
    }

    private fun forceRelease(timeUs: Long, out: MutableList<Outgoing>) {
        when (mode) {
            Mode.POINTER -> out += ptr(timeUs, lastX, lastY, 0)
            Mode.SCROLL -> out += scroll(timeUs, 0f, 0f, Scroll.CANCELLED, mergeable = false)
            Mode.PENDING, Mode.IDLE -> Unit // nothing was sent
        }
        reset()
    }

    private fun blocked(nowMs: Long) = pen.inRange || nowMs - pen.lastEventMs < PALM_TAIL_MS

    private fun ptr(timeUs: Long, x: Float, y: Float, buttons: Int): Outgoing {
        val vp = viewport()
        return Outgoing(PointerAbs(timeUs, vp.normX(x), vp.normY(y), buttons, PointerAbs.SOURCE_TOUCH))
    }

    private fun scroll(timeUs: Long, dx: Float, dy: Float, phase: Int, mergeable: Boolean) =
        Outgoing(Scroll(timeUs, dx, dy, phase), mergeable)

    companion object {
        const val HOLD_MS = 40L
        const val SLOP_PX = 16f
        const val SCROLL_KEEPALIVE_MS = 200L
        const val PALM_TAIL_MS = 1000L
    }
}
