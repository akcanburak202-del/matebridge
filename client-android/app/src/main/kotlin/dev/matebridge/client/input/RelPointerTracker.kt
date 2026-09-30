package dev.matebridge.client.input

import dev.matebridge.client.protocol.Buttons
import dev.matebridge.client.protocol.PointerRel
import dev.matebridge.client.protocol.Scroll
import kotlin.math.hypot

/** Every tuning constant of the touchpad and mouse path in one place (T-034). */
object PadTuning {
    /** A tap is a touch that is over within this time (first finger down to last finger up). */
    const val TAP_MS = 180L

    /** A touch that moves further than this fraction of the pad extent is not a tap; it also arms cursor motion and scrolling. */
    const val SLOP_FRAC = 0.02f

    /** Fallback pad extent (raw units) when the device reports no motion range: NOTES 2026-09-29 measured x 174..1734. */
    const val DEFAULT_EXTENT = 1560f

    /** One pad width is this many Mac screen widths (before acceleration). */
    const val SCREEN_SPAN = 1.2f

    /** Acceleration: gain grows linearly from [GAIN_MIN] at [SLOW_PT_S] to [GAIN_MAX] at [FAST_PT_S] (base Mac points per second). */
    const val GAIN_MIN = 0.8f
    const val GAIN_MAX = 2.6f
    const val SLOW_PT_S = 150f
    const val FAST_PT_S = 1800f

    /** Frame interval clamp used for the speed estimate. */
    const val MIN_DT_MS = 4L
    const val MAX_DT_MS = 50L

    /** Two-finger scroll distance relative to cursor distance (no acceleration; inertia and direction are host work). */
    const val SCROLL_GAIN = 1.0f

    /** Mouse counts to Mac points. Plain 1:1, no acceleration. */
    const val MOUSE_GAIN = 1.0f

    /** One wheel notch in Mac points (PROTOCOL.md section 4 SCROLL). */
    const val WHEEL_NOTCH_PT = 10f

    const val SCROLL_KEEPALIVE_MS = 200L
    const val SCROLL_IDLE_END_MS = 5_000L
}

enum class PadAction { DOWN, MOVE, UP, CANCEL, BUTTON }

/**
 * A touchpad MotionEvent under pointer capture (source TOUCHPAD): raw absolute finger positions, no pressure or relative
 * axes (NOTES 2026-09-29). [buttons] is the physical button state already mapped to protocol bits ([Buttons]);
 * [pressedButton] is the button of an `ACTION_BUTTON_PRESS` (0 otherwise). [extent] is the span of the X axis of the
 * device in raw units (0 = unknown). As in [TouchFrame], [fingers] holds every current pointer including the acting one.
 */
class PadFrame(
    val action: PadAction,
    val actingId: Int,
    val fingers: List<Finger>,
    val timeUs: Long,
    val deviceId: Int,
    val buttons: Int = 0,
    val pressedButton: Int = 0,
    val extent: Float = 0f,
)

/** A captured mouse event: [dx]/[dy] are the summed `AXIS_RELATIVE_X/Y` of the event (history included), wheel in notches. */
class MouseFrame(
    val timeUs: Long,
    val dx: Float,
    val dy: Float,
    val buttons: Int,
    val pressedButton: Int = 0,
    /** `AXIS_VSCROLL`: positive = wheel rotated away (scroll up). */
    val wheelV: Float = 0f,
    /** `AXIS_HSCROLL`: positive = scroll right. */
    val wheelH: Float = 0f,
    val deviceId: Int = 0,
)

/**
 * Relative pointer source: the keyboard touchpad and the mouse under pointer capture (PROTOCOL.md section 4 POINTER_REL
 * and SCROLL, section 7). Pure Kotlin. The host treats POINTER_REL as ONE source whose button state is complete in every
 * message, so both devices, the physical click and the tap-to-click share one reported mask ([reported]).
 *
 * Touchpad (fingers are raw positions, every delta is per pointer id so a finger joining or leaving never jumps the cursor):
 *  - one finger moves the cursor; motion is held back until the touch exceeds the tap slop or [PadTuning.TAP_MS], so a
 *    tap does not nudge the cursor before it clicks;
 *  - a short, still touch is a tap: LEFT down+up (one finger) or RIGHT down+up (two fingers);
 *  - a physical click is LEFT, or RIGHT when two fingers rest on the pad at the press; while a button is held the
 *    fastest finger drags;
 *  - two fingers moving together scroll (BEGAN, CHANGED, ENDED; keepalive and idle end as in [TouchTracker]);
 *  - going from two fingers to one, or to three, locks cursor motion until every finger has lifted.
 * Mouse: relative motion, full button state, wheel notches as SCROLL NONE.
 *
 * Buttons: after [release] (capture or focus loss, release-all) a held physical button is not reported again until a new
 * press event is seen ([ButtonSync]). UI thread only.
 */
class RelPointerTracker(private val counters: InputCounters = InputCounters()) {
    /** Mac point width of the stream (STREAM_CONFIG); motion and scrolling are off until known. */
    var widthPt = 0

    private enum class ScrollMode { NONE, OPEN, PARKED }

    /** Tracks one device's physical button state against "a fresh press" (PROTOCOL.md section 7, pointer lock). */
    private class ButtonSync {
        private var synced = false
        private var ignore = 0

        fun update(phys: Int, pressed: Int): Int {
            if (!synced) {
                ignore = phys and pressed.inv() // held before we looked: not a press we saw
                synced = true
            }
            // The explicit press of an ignored bit (ACTION_DOWN may carry the button before its BUTTON_PRESS) makes it real.
            ignore = ignore and pressed.inv() and phys
            return phys and ignore.inv()
        }

        fun desync() {
            synced = false
            ignore = 0
        }
    }

    private val padSync = ButtonSync()
    private val mouseSync = ButtonSync()
    private var padMask = 0
    private var mouseMask = 0
    private var padLeftMapped = Buttons.LEFT

    /** The button state last sent (complete state, PROTOCOL.md section 4). */
    var reported = 0
        private set

    // Touchpad gesture state.
    private val cur = LinkedHashMap<Int, FloatArray>()
    private val downPos = HashMap<Int, FloatArray>()
    private var settling = false
    private var gestureStartMs = 0L
    private var maxCount = 0
    private var moved = false
    private var clicked = false
    private var locked = false
    private var armed = false
    private var accX = 0f
    private var accY = 0f
    private var twoX = 0f
    private var twoY = 0f
    private var scroll = ScrollMode.NONE
    private var lastScrollMs = 0L
    private var lastMotionMs = 0L
    private var lastFrameUs = NEVER_US
    private var padDevice = NO_DEVICE
    private var mouseDevice = NO_DEVICE

    /** A SCROLL BEGAN was sent for the pad and its ENDED is owed. */
    val isScrolling get() = scroll == ScrollMode.OPEN

    /** True when the tracker holds anything the host may hold (a reported button or an open scroll). */
    val holdsState get() = reported != 0 || scroll == ScrollMode.OPEN

    fun holdsDevice(deviceId: Int) = deviceId == padDevice || deviceId == mouseDevice

    // ---- touchpad ----

    fun onPad(f: PadFrame, nowMs: Long): List<Outgoing> {
        val out = ArrayList<Outgoing>(3)
        padDevice = f.deviceId
        if (f.action == PadAction.CANCEL) return release(nowMs)
        val extent = if (f.extent > 0f) f.extent else PadTuning.DEFAULT_EXTENT
        val slop = extent * PadTuning.SLOP_FRAC

        val next = LinkedHashMap<Int, FloatArray>()
        for (fg in f.fingers) if (!(f.action == PadAction.UP && fg.id == f.actingId)) next[fg.id] = floatArrayOf(fg.x, fg.y)

        if (settling) {
            // After a release the pointers already on the pad are unknown to the host: ignore them until they lift.
            if (next.isEmpty() || (f.action == PadAction.DOWN && next.size == 1)) settling = false
        }
        val deltas = HashMap<Int, FloatArray>()
        for ((id, p) in next) cur[id]?.let { deltas[id] = floatArrayOf(p[0] - it[0], p[1] - it[1]) }
        val before = cur.size
        val added = next.keys.filter { it !in cur }
        val timeUs = f.timeUs
        val dtMs = if (lastFrameUs == NEVER_US) 8L
        else ((timeUs - lastFrameUs) / 1000).coerceIn(PadTuning.MIN_DT_MS, PadTuning.MAX_DT_MS)
        lastFrameUs = timeUs
        cur.clear(); cur.putAll(next)
        val n = cur.size

        if (settling) {
            updatePadButtons(f, n, nowMs, timeUs, out)
            return out
        }

        // Gesture start / finger count changes.
        if (before == 0 && n > 0) {
            gestureStartMs = nowMs; maxCount = 0; moved = false; clicked = false; locked = false; armed = false
            accX = 0f; accY = 0f; twoX = 0f; twoY = 0f; scroll = ScrollMode.NONE
            downPos.clear()
        }
        for (id in added) downPos[id] = next[id]!!.copyOf()
        if (n > maxCount) maxCount = n
        if (n == 2 && before < 2) { twoX = 0f; twoY = 0f }
        if (n >= 3 || (before >= 2 && n in 1 until before)) {
            if (scroll != ScrollMode.NONE) endScroll(timeUs, out)
            locked = true
        }
        // Includes the departing finger of an UP frame: its final position counts (DOWN, then UP elsewhere, is no tap).
        for (fg in f.fingers) downPos[fg.id]?.let { p -> val d = floatArrayOf(fg.x, fg.y); if (hypot(d[0] - p[0], d[1] - p[1]) > slop) moved = true }

        updatePadButtons(f, n, nowMs, timeUs, out)

        // Motion.
        val base = if (widthPt > 0) widthPt * PadTuning.SCREEN_SPAN / extent else 0f
        if (padMask != 0 && n > 0) {
            // A button is held: the finger that moved most drags, whatever the count.
            var best: FloatArray? = null
            for (d in deltas.values) if (best == null || hypot(d[0], d[1]) > hypot(best[0], best[1])) best = d
            if (best != null) emitMotion(best[0], best[1], base, dtMs, timeUs, out)
            armed = true
        } else if (!locked && base > 0f) {
            when (n) {
                1 -> deltas.values.firstOrNull()?.let { d ->
                    if (armed) {
                        emitMotion(d[0], d[1], base, dtMs, timeUs, out)
                    } else {
                        accX += d[0]; accY += d[1]
                        if (moved || nowMs - gestureStartMs > PadTuning.TAP_MS) {
                            armed = true
                            emitMotion(accX, accY, base, dtMs, timeUs, out)
                            accX = 0f; accY = 0f
                        }
                    }
                }
                2 -> twoFingerMotion(deltas, base, slop, nowMs, timeUs, out)
                else -> Unit
            }
        }

        if (n == 0 && before > 0) finishGesture(nowMs, timeUs, out)
        return out
    }

    private fun twoFingerMotion(deltas: Map<Int, FloatArray>, base: Float, slop: Float, nowMs: Long, timeUs: Long, out: MutableList<Outgoing>) {
        val ds = deltas.values.toList()
        if (ds.size < 2) return
        val dx = (ds[0][0] + ds[1][0]) / 2f
        val dy = (ds[0][1] + ds[1][1]) / 2f
        if (dx == 0f && dy == 0f) return
        when (scroll) {
            ScrollMode.NONE -> {
                twoX += dx; twoY += dy
                if (hypot(twoX, twoY) > slop) {
                    scroll = ScrollMode.OPEN
                    moved = true
                    lastScrollMs = nowMs; lastMotionMs = nowMs
                    out += scrollMsg(timeUs, 0f, 0f, Scroll.BEGAN, false)
                    out += scrollMsg(timeUs, twoX * base * PadTuning.SCROLL_GAIN, twoY * base * PadTuning.SCROLL_GAIN, Scroll.CHANGED, true)
                    twoX = 0f; twoY = 0f
                }
            }
            ScrollMode.PARKED -> {
                scroll = ScrollMode.OPEN
                lastScrollMs = nowMs; lastMotionMs = nowMs
                out += scrollMsg(timeUs, 0f, 0f, Scroll.BEGAN, false)
                out += scrollMsg(timeUs, dx * base * PadTuning.SCROLL_GAIN, dy * base * PadTuning.SCROLL_GAIN, Scroll.CHANGED, true)
            }
            ScrollMode.OPEN -> {
                lastScrollMs = nowMs; lastMotionMs = nowMs
                out += scrollMsg(timeUs, dx * base * PadTuning.SCROLL_GAIN, dy * base * PadTuning.SCROLL_GAIN, Scroll.CHANGED, true)
            }
        }
    }

    /** Physical buttons of the pad; a press with two fingers on the pad is a RIGHT click, with one a LEFT click. */
    private fun updatePadButtons(f: PadFrame, n: Int, nowMs: Long, timeUs: Long, out: MutableList<Outgoing>) {
        val eff = padSync.update(f.buttons, f.pressedButton)
        val leftNow = eff and Buttons.LEFT != 0
        if (leftNow && !padLeftActive) padLeftMapped = if (n >= 2) Buttons.RIGHT else Buttons.LEFT // fixed at the press
        padLeftActive = leftNow
        val mapped = (eff and Buttons.LEFT.inv()) or (if (leftNow) padLeftMapped else 0)
        if (mapped and padMask.inv() != 0) { // a new press
            clicked = true
            if (scroll != ScrollMode.NONE) endScroll(timeUs, out)
        }
        padMask = mapped
        emitButtons(timeUs, out)
    }

    private var padLeftActive = false

    private fun finishGesture(nowMs: Long, timeUs: Long, out: MutableList<Outgoing>) {
        val tap = !moved && !clicked && maxCount in 1..2 && scroll == ScrollMode.NONE &&
            nowMs - gestureStartMs <= PadTuning.TAP_MS
        if (tap) {
            val bit = if (maxCount == 2) Buttons.RIGHT else Buttons.LEFT
            counters.taps++
            out += Outgoing(PointerRel(timeUs, 0f, 0f, reported or bit))
            out += Outgoing(PointerRel(timeUs, 0f, 0f, reported))
        }
        scroll = ScrollMode.NONE
        locked = false; armed = false; maxCount = 0; moved = false; clicked = false
        downPos.clear()
    }

    private fun endScroll(timeUs: Long, out: MutableList<Outgoing>) {
        if (scroll == ScrollMode.OPEN) out += scrollMsg(timeUs, 0f, 0f, Scroll.ENDED, false)
        scroll = ScrollMode.NONE
    }

    // ---- mouse ----

    fun onMouse(f: MouseFrame, nowMs: Long): List<Outgoing> {
        val out = ArrayList<Outgoing>(3)
        mouseDevice = f.deviceId
        mouseMask = mouseSync.update(f.buttons, f.pressedButton)
        emitButtons(f.timeUs, out)
        if (f.dx != 0f || f.dy != 0f) {
            out += Outgoing(PointerRel(f.timeUs, f.dx * PadTuning.MOUSE_GAIN, f.dy * PadTuning.MOUSE_GAIN, reported), true)
        }
        if (f.wheelV != 0f || f.wheelH != 0f) {
            out += Outgoing(Scroll(f.timeUs, -f.wheelH * PadTuning.WHEEL_NOTCH_PT, f.wheelV * PadTuning.WHEEL_NOTCH_PT, Scroll.NONE))
        }
        return out
    }

    // ---- lifecycle ----

    /**
     * Pointer capture lost, focus lost, release-all, device gone: the open scroll ends with ENDED and, when a button was
     * reported pressed, `buttons = 0` goes out. Held physical buttons and fingers are not reported again until a new press.
     */
    fun release(nowMs: Long): List<Outgoing> {
        val out = ArrayList<Outgoing>(2)
        val timeUs = nowMs * 1000
        if (scroll == ScrollMode.OPEN) out += scrollMsg(timeUs, 0f, 0f, Scroll.ENDED, false)
        if (reported != 0) {
            reported = 0
            out += Outgoing(PointerRel(timeUs, 0f, 0f, 0))
        }
        reset()
        return out
    }

    /** Forget everything without sending (the host released it, or the connection was lost). */
    fun reset() {
        cur.clear(); downPos.clear()
        padMask = 0; mouseMask = 0; reported = 0; padLeftActive = false
        padSync.desync(); mouseSync.desync()
        scroll = ScrollMode.NONE
        locked = false; armed = false; moved = false; clicked = false; maxCount = 0
        settling = true
        lastFrameUs = NEVER_US
        padDevice = NO_DEVICE; mouseDevice = NO_DEVICE
    }

    /** Scroll keepalive (host watchdog, PROTOCOL.md section 7) and idle end, like the finger scroll. */
    fun tick(nowMs: Long): List<Outgoing> {
        if (scroll != ScrollMode.OPEN) return emptyList()
        val timeUs = nowMs * 1000
        if (nowMs - lastMotionMs >= PadTuning.SCROLL_IDLE_END_MS) {
            counters.scrollIdleEnds++
            scroll = ScrollMode.PARKED
            return listOf(scrollMsg(timeUs, 0f, 0f, Scroll.ENDED, false))
        }
        if (nowMs - lastScrollMs >= PadTuning.SCROLL_KEEPALIVE_MS) {
            lastScrollMs = nowMs
            return listOf(scrollMsg(timeUs, 0f, 0f, Scroll.CHANGED, true))
        }
        return emptyList()
    }

    // ---- helpers ----

    private fun emitButtons(timeUs: Long, out: MutableList<Outgoing>) {
        val want = padMask or mouseMask
        if (want != reported) {
            reported = want
            out += Outgoing(PointerRel(timeUs, 0f, 0f, want))
        }
    }

    private fun emitMotion(rawDx: Float, rawDy: Float, base: Float, dtMs: Long, timeUs: Long, out: MutableList<Outgoing>) {
        if (rawDx == 0f && rawDy == 0f) return
        val bx = rawDx * base
        val by = rawDy * base
        val speed = hypot(bx, by) * 1000f / dtMs
        val t = ((speed - PadTuning.SLOW_PT_S) / (PadTuning.FAST_PT_S - PadTuning.SLOW_PT_S)).coerceIn(0f, 1f)
        val gain = PadTuning.GAIN_MIN + (PadTuning.GAIN_MAX - PadTuning.GAIN_MIN) * t
        out += Outgoing(PointerRel(timeUs, bx * gain, by * gain, reported), true)
    }

    private fun scrollMsg(timeUs: Long, dx: Float, dy: Float, phase: Int, mergeable: Boolean): Outgoing {
        counters.tpScroll++
        return Outgoing(Scroll(timeUs, dx, dy, phase), mergeable)
    }

    private companion object {
        const val NEVER_US = Long.MIN_VALUE
    }
}
