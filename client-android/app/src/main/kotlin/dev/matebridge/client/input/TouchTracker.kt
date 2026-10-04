package dev.matebridge.client.input

import dev.matebridge.client.protocol.Buttons
import dev.matebridge.client.protocol.Pinch
import dev.matebridge.client.protocol.PointerAbs
import dev.matebridge.client.protocol.Scroll
import dev.matebridge.client.stream.VideoViewport
import kotlin.math.abs
import kotlin.math.hypot

/**
 * Finger capture (PROTOCOL.md section 4 POINTER_ABS and SCROLL, section 7, decision 0006). Pure Kotlin.
 *
 * - One finger: `POINTER_ABS source=TOUCH`, LEFT while pressed. The DOWN is held back by [HOLD_MS]
 *   (or until the finger moves more than [SLOP_PX], lifts, or the tick runs) so that a second finger
 *   arriving right after the first starts a scroll without a stray click. Once a DOWN was sent, its UP
 *   is always sent (finger up, cancel, second finger, pen entering range, release, stale guard).
 * - Two fingers: nothing is sent when the second finger arrives. The first meaningful movement is classified once
 *   ([TwoFingerClassifier], T-037) as a scroll or a pinch and stays that way until the fingers lift (or the gesture is
 *   parked after [SCROLL_IDLE_END_MS]; a parked gesture restarts as the same kind).
 * - Scroll: `SCROLL` BEGAN, CHANGED (centroid motion in Mac points via `width_pt/height_pt`),
 *   ENDED/CANCELLED. While the fingers rest a CHANGED(0,0) keepalive is sent every [SCROLL_KEEPALIVE_MS] so the
 *   host's 500 ms scroll watchdog does not end the gesture, but only for [SCROLL_IDLE_END_MS] of stillness:
 *   then the scroll is closed with ENDED (the keepalive must not hide a lost finger lift forever) and the
 *   fingers are parked; if the same two fingers move again a new BEGAN starts a new gesture.
 * - Pinch: `PINCH` BEGAN (centre = midpoint, normalized), CHANGED (`scale = d / d_previous - 1`, clamped), ENDED when a
 *   finger lifts; same keepalive and idle end as the scroll. Refused while the pen is in range / inside the gate hold,
 *   like every new press.
 * - A pressed finger from which no event arrives for [PRESS_STALE_MS] is released with `buttons = 0` and
 *   forgotten until a fresh DOWN (last-resort guard, like the pen's).
 * - After a scroll ends (finger lift, cancel, pen entering range, release) no new press or scroll starts until
 *   every finger has lifted: the finger that stayed down would otherwise turn into a left click on the next touch.
 * - Palm rejection (decision 0006, PROTOCOL.md section 7): a new press or scroll is refused while the pen is in
 *   range and for [GATE_HOLD_MS] after the last PEN message was sent (the host's clock, plus a margin). Releases are never
 *   refused. When the pen enters range, a pending or pressed single finger is released and an open (or parked)
 *   scroll is cancelled; those fingers are ignored until they lift.
 * - A new contact while this tracker owns none but another finger is already down in the same frame (one it let go of:
 *   an expired contact, one from before a policy change, a refused one) is not a first finger: no press and no gesture
 *   start until every finger has lifted (lockout). Reconciling with the live pointer list covers every path alike.
 * - [policy] ([FingerPolicy]): [FingerPolicy.OFF] ("Parmak dokunmasını tamamen kapat") refuses every press and
 *   gesture. [FingerPolicy.GESTURES_ONLY] (Çizim, decision 0030 §1, T-223) sends nothing for one finger (no click, no
 *   drag: a palm cannot press) but a second finger still starts the two-finger scroll or pinch as usual.
 *   Changing the policy mid-contact ([setPolicy]) releases only what the new policy no longer allows.
 *
 * Fingers that were refused or abandoned are simply not tracked: their MOVE/UP events are ignored. A release is
 * routed here by (device, pointer id) through [follows], whatever tool type the platform reports for it by then.
 * Pointer ids repeat across input devices (the pen and the touchscreen both start at 0), so the gesture remembers
 * the device that started it and frames of any other device are not part of it.
 * Coordinates go through [viewport] only. Not thread-safe: UI thread only.
 */
class TouchTracker(
    private val viewport: () -> VideoViewport,
    private val pen: PenPresence,
    private val counters: InputCounters = InputCounters(),
) {
    private enum class Mode { IDLE, PENDING, POINTER, UNDECIDED, SCROLL, PINCH, PARKED }

    /** Mac point size of the stream (STREAM_CONFIG.width_pt/height_pt); scrolling is off until known. */
    var widthPt = 0
    var heightPt = 0

    /** What fingers may do ([setPolicy] changes it with the releases that needs). */
    var policy = FingerPolicy.ALL
        private set

    /** Every finger refused ([FingerPolicy.OFF]); assigning is [setPolicy] without sending the releases. */
    var disabled: Boolean
        get() = policy == FingerPolicy.OFF
        set(value) { policy = if (value) FingerPolicy.OFF else FingerPolicy.ALL }

    private var mode = Mode.IDLE
    private var pointerId = -1
    private var downX = 0f
    private var downY = 0f
    private var downMs = 0L
    private var lastX = 0f
    private var lastY = 0f
    private var pressEventMs = 0L
    private var scrollA = -1
    private var scrollB = -1
    private var ax = 0f
    private var ay = 0f
    private var bx = 0f
    private var by = 0f
    private var lastScrollMs = 0L
    private var lastMotionMs = 0L
    private var lockout = false

    // Two-finger classification baseline and pinch state (pixels).
    private var baseD = 0f
    private var baseCx = 0f
    private var baseCy = 0f
    private var prevD = 0f
    private var centerX = 0f
    private var centerY = 0f
    private var parkedKind = TwoFingerClassifier.Kind.SCROLL
    private var gestureDevice = NO_DEVICE
    private var lockoutDevice = NO_DEVICE

    val isIdle get() = mode == Mode.IDLE

    /** A DOWN was sent and its UP is owed. */
    val isPressed get() = mode == Mode.POINTER

    /** A SCROLL BEGAN was sent and its ENDED/CANCELLED is owed. */
    val isScrolling get() = mode == Mode.SCROLL

    /** A PINCH BEGAN was sent and its ENDED/CANCELLED is owed. */
    val isPinching get() = mode == Mode.PINCH

    /** True while fingers of a finished scroll (or an abandoned palm) keep new touches locked out. */
    val isLockedOut get() = lockout

    /** True when (device, [id]) is exactly a pointer this tracker holds state for, so its release must reach [onFrame]. */
    fun follows(deviceId: Int, id: Int) = deviceId == gestureDevice && when (mode) {
        Mode.PENDING, Mode.POINTER -> id == pointerId
        Mode.UNDECIDED, Mode.SCROLL, Mode.PINCH, Mode.PARKED -> id == scrollA || id == scrollB
        Mode.IDLE -> false
    }

    /** Device of the gesture held, or of the lockout after a scroll, or [NO_DEVICE]. */
    val deviceInUse get() = when {
        mode != Mode.IDLE -> gestureDevice
        lockout -> lockoutDevice
        else -> NO_DEVICE
    }

    fun onFrame(f: TouchFrame, nowMs: Long): List<Outgoing> {
        val out = ArrayList<Outgoing>(2)
        val others = when (f.action) {
            TouchAction.DOWN, TouchAction.UP -> f.fingers.count { it.id != f.actingId }
            TouchAction.MOVE -> f.fingers.size
            TouchAction.CANCEL -> 0
        }
        // A gesture belongs to the device that started it; frames of another device are not part of it.
        val mine = mode == Mode.IDLE || f.deviceId == gestureDevice
        if (f.action == TouchAction.DOWN && others == 0 && f.deviceId == lockoutDevice) lockout = false // a fresh touch: nothing else is down
        if (mine) {
            when (f.action) {
                TouchAction.DOWN -> down(f, nowMs, out)
                TouchAction.MOVE -> move(f, nowMs, out)
                TouchAction.UP -> up(f, nowMs, out)
                TouchAction.CANCEL -> forceRelease(f.timeUs, out)
            }
        }
        if ((f.action == TouchAction.UP || f.action == TouchAction.CANCEL) && others == 0 && f.deviceId == lockoutDevice) lockout = false
        return out
    }

    fun tick(nowMs: Long): List<Outgoing> {
        val out = ArrayList<Outgoing>(1)
        when (mode) {
            Mode.PENDING -> if (policy == FingerPolicy.GESTURES_ONLY) {
                // A silent single finger: forget it if no event arrived for it for a long time (Android lost its lift;
                // otherwise it would pose as a first finger forever). Measured from its last event, as for a pressed finger:
                // a finger that keeps moving is alive, and a second finger must still find it here.
                if (nowMs - pressEventMs >= PRESS_STALE_MS) { counters.pressStale++; mode = Mode.IDLE }
            } else if (nowMs - downMs >= HOLD_MS) pressNow(nowMs, nowMs * 1000, out, movedBeyondSlop = false)
            Mode.POINTER -> if (nowMs - pressEventMs >= PRESS_STALE_MS) {
                // No event from a pressed finger for this long: Android lost the lift. Release it, forget it.
                counters.pressStale++
                out += ptr(nowMs * 1000, lastX, lastY, 0)
                mode = Mode.IDLE
            }
            Mode.SCROLL -> if (nowMs - lastMotionMs >= SCROLL_IDLE_END_MS) {
                counters.scrollIdleEnds++
                out += scroll(nowMs * 1000, 0f, 0f, Scroll.ENDED, mergeable = false)
                parkedKind = TwoFingerClassifier.Kind.SCROLL
                mode = Mode.PARKED
            } else if (nowMs - lastScrollMs >= SCROLL_KEEPALIVE_MS) {
                lastScrollMs = nowMs
                out += scroll(nowMs * 1000, 0f, 0f, Scroll.CHANGED, mergeable = true)
            }
            Mode.PINCH -> if (nowMs - lastMotionMs >= SCROLL_IDLE_END_MS) {
                counters.scrollIdleEnds++
                out += pinch(nowMs * 1000, 0f, Pinch.ENDED, mergeable = false)
                parkedKind = TwoFingerClassifier.Kind.PINCH
                mode = Mode.PARKED
            } else if (nowMs - lastScrollMs >= SCROLL_KEEPALIVE_MS) {
                lastScrollMs = nowMs
                out += pinch(nowMs * 1000, 0f, Pinch.CHANGED, mergeable = true)
            }
            Mode.UNDECIDED, Mode.PARKED, Mode.IDLE -> Unit
        }
        return out
    }

    /** Ends everything the host may hold for touch (background, focus loss, deactivation). */
    fun release(nowMs: Long): List<Outgoing> {
        val out = ArrayList<Outgoing>(1)
        forceRelease(nowMs * 1000, out)
        return out
    }

    /** Forget everything without sending (host released it, or the connection was lost). */
    fun reset() {
        mode = Mode.IDLE
        gestureDevice = NO_DEVICE
        pointerId = -1
        scrollA = -1
        scrollB = -1
    }

    /** The pen came into range: drop pending/pressed fingers and any scroll, they are probably the palm. */
    fun onPenRangeBegan(nowMs: Long): List<Outgoing> {
        val out = ArrayList<Outgoing>(1)
        if (mode != Mode.IDLE) {
            counters.palmRejects++
            forceRelease(nowMs * 1000, out)
        }
        return out
    }

    fun setDisabled(value: Boolean, nowMs: Long): List<Outgoing> =
        setPolicy(if (value) FingerPolicy.OFF else FingerPolicy.ALL, nowMs)

    /**
     * Switches the finger policy and returns the releases it owes:
     * - [FingerPolicy.OFF]: everything held ends (button up, scroll/pinch cancelled), like [release].
     * - [FingerPolicy.GESTURES_ONLY]: a held one-finger press or drag gets its button up and the finger stays tracked
     *   but silent (a second finger can still start a gesture); an open two-finger scroll or pinch is left running.
     * - [FingerPolicy.ALL]: nothing is owed. A finger that was held silently (one finger, [FingerPolicy.GESTURES_ONLY])
     *   is forgotten until it lifts, so that it does not turn into a press now.
     */
    fun setPolicy(value: FingerPolicy, nowMs: Long): List<Outgoing> {
        val old = policy
        policy = value
        if (value == old) return emptyList()
        val out = ArrayList<Outgoing>(1)
        when (value) {
            FingerPolicy.OFF -> forceRelease(nowMs * 1000, out)
            FingerPolicy.GESTURES_ONLY -> if (mode == Mode.POINTER) {
                out += ptr(nowMs * 1000, lastX, lastY, 0)
                mode = Mode.PENDING // still down, tracked, silent
                downX = lastX; downY = lastY
                downMs = nowMs
                pressEventMs = nowMs
            }
            FingerPolicy.ALL -> if (mode == Mode.PENDING) {
                lockout = true
                lockoutDevice = gestureDevice
                reset()
            }
        }
        return out
    }

    // ---- events ----

    private fun down(f: TouchFrame, nowMs: Long, out: MutableList<Outgoing>) {
        val fp = f.fingers.firstOrNull { it.id == f.actingId } ?: return
        if (policy == FingerPolicy.OFF || (lockout && f.deviceId == lockoutDevice)) return
        // Reconcile with the live pointer list (T-223): a new contact while the tracker owns none but another finger is
        // already down is not a first finger. That finger is one this tracker let go of (a silent one that expired, one
        // from before a policy change or a refused one); pairing the new finger with it, or clicking for it, would be a
        // stray press. So no press and no gesture start until every finger has lifted (the lockout clears on that).
        if (mode == Mode.IDLE && f.fingers.any { it.id != f.actingId }) {
            lockout = true
            lockoutDevice = f.deviceId
            return
        }
        if (blocked(nowMs)) {
            counters.palmRejects++
            return
        }
        when (mode) {
            Mode.IDLE -> {
                mode = Mode.PENDING
                gestureDevice = f.deviceId
                pointerId = fp.id
                downX = fp.x; downY = fp.y
                lastX = fp.x; lastY = fp.y
                downMs = nowMs
                pressEventMs = nowMs // last event of this contact (the stale guard of a silent finger, [tick])
            }
            Mode.PENDING, Mode.POINTER -> {
                if (fp.id == pointerId || widthPt <= 0 || heightPt <= 0) return
                val first = f.fingers.firstOrNull { it.id == pointerId }
                if (mode == Mode.POINTER) out += ptr(f.timeUs, lastX, lastY, 0) // end the press first
                mode = Mode.UNDECIDED // nothing is sent until the first meaningful movement is classified
                scrollA = pointerId
                scrollB = fp.id
                ax = first?.x ?: lastX
                ay = first?.y ?: lastY
                bx = fp.x
                by = fp.y
                baseD = hypot(ax - bx, ay - by)
                baseCx = (ax + bx) / 2f
                baseCy = (ay + by) / 2f
                prevD = baseD
                centerX = baseCx
                centerY = baseCy
                lastMotionMs = nowMs
            }
            Mode.UNDECIDED, Mode.SCROLL, Mode.PINCH, Mode.PARKED -> Unit // a third finger is ignored
        }
    }

    private fun move(f: TouchFrame, nowMs: Long, out: MutableList<Outgoing>) {
        when (mode) {
            Mode.PENDING -> {
                val fp = f.fingers.firstOrNull { it.id == pointerId } ?: return
                pressEventMs = nowMs // any MOVE keeps the contact alive (matters only for a silent finger; ALL resolves in 40 ms)
                lastX = fp.x; lastY = fp.y
                if (abs(fp.x - downX) > SLOP_PX || abs(fp.y - downY) > SLOP_PX) pressNow(nowMs, f.timeUs, out, movedBeyondSlop = true)
            }
            Mode.POINTER -> {
                val fp = f.fingers.firstOrNull { it.id == pointerId } ?: return
                pressEventMs = nowMs
                if (fp.x == lastX && fp.y == lastY) return
                lastX = fp.x; lastY = fp.y
                out += ptr(f.timeUs, fp.x, fp.y, Buttons.LEFT)
            }
            Mode.UNDECIDED, Mode.SCROLL, Mode.PINCH, Mode.PARKED -> {
                val a = f.fingers.firstOrNull { it.id == scrollA } ?: return
                val b = f.fingers.firstOrNull { it.id == scrollB } ?: return
                if (a.x == ax && a.y == ay && b.x == bx && b.y == by) return // nothing moved
                val d = hypot(a.x - b.x, a.y - b.y)
                val cx = (a.x + b.x) / 2f
                val cy = (a.y + b.y) / 2f
                if (viewport().isEmpty) return
                when (mode) {
                    Mode.UNDECIDED -> {
                        val common = hypot(cx - baseCx, cy - baseCy)
                        val kind = TwoFingerClassifier.classify(baseD, d, common, SLOP_PX, MIN_DIST_PX) ?: return
                        openTwoFinger(kind, f, a, b, d, cx, cy, nowMs, out)
                    }
                    Mode.PARKED -> openTwoFinger(parkedKind, f, a, b, d, cx, cy, nowMs, out)
                    Mode.SCROLL -> scrollStep(f, a, b, nowMs, out)
                    else -> pinchStep(f, a, b, d, cx, cy, nowMs, out)
                }
            }
            Mode.IDLE -> Unit
        }
    }

    /** The classified gesture begins (or a parked one restarts): the gate is checked again like for a new press. */
    private fun openTwoFinger(
        kind: TwoFingerClassifier.Kind, f: TouchFrame, a: Finger, b: Finger, d: Float, cx: Float, cy: Float,
        nowMs: Long, out: MutableList<Outgoing>,
    ) {
        if (blocked(nowMs)) {
            counters.palmRejects++
            endScroll()
            return
        }
        lastScrollMs = nowMs
        lastMotionMs = nowMs
        if (kind == TwoFingerClassifier.Kind.SCROLL) {
            mode = Mode.SCROLL
            out += scroll(f.timeUs, 0f, 0f, Scroll.BEGAN, mergeable = false)
            scrollStep(f, a, b, nowMs, out)
        } else {
            mode = Mode.PINCH
            centerX = cx; centerY = cy
            out += pinch(f.timeUs, 0f, Pinch.BEGAN, mergeable = false)
            pinchStep(f, a, b, d, cx, cy, nowMs, out)
        }
    }

    private fun scrollStep(f: TouchFrame, a: Finger, b: Finger, nowMs: Long, out: MutableList<Outgoing>) {
        lastMotionMs = nowMs
        val dxPx = (a.x + b.x) / 2f - (ax + bx) / 2f
        val dyPx = (a.y + b.y) / 2f - (ay + by) / 2f
        ax = a.x; ay = a.y; bx = b.x; by = b.y
        if (dxPx == 0f && dyPx == 0f) return
        val vp = viewport()
        if (vp.isEmpty) return
        val dx = dxPx * widthPt / vp.width
        val dy = dyPx * heightPt / vp.height
        lastScrollMs = nowMs
        out += scroll(f.timeUs, dx, dy, Scroll.CHANGED, mergeable = true)
    }

    private fun pinchStep(f: TouchFrame, a: Finger, b: Finger, d: Float, cx: Float, cy: Float, nowMs: Long, out: MutableList<Outgoing>) {
        lastMotionMs = nowMs
        ax = a.x; ay = a.y; bx = b.x; by = b.y
        centerX = cx; centerY = cy
        val s = TwoFingerClassifier.scale(prevD, d)
        prevD = d
        if (s == 0f) return
        lastScrollMs = nowMs
        out += pinch(f.timeUs, s, Pinch.CHANGED, mergeable = true)
    }

    private fun up(f: TouchFrame, nowMs: Long, out: MutableList<Outgoing>) {
        val id = f.actingId
        when (mode) {
            Mode.PENDING -> if (id == pointerId) {
                // A tap: DOWN then UP at the touch-down position (within slop), in order, so it is a click and not a drag.
                if (pressNow(nowMs, f.timeUs, out, movedBeyondSlop = false)) out += ptr(f.timeUs, downX, downY, 0)
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
                endScroll()
            }
            Mode.PINCH -> if (id == scrollA || id == scrollB) {
                out += pinch(f.timeUs, 0f, Pinch.ENDED, mergeable = false)
                endScroll()
            }
            Mode.UNDECIDED -> if (id == scrollA || id == scrollB) endScroll() // nothing was sent
            Mode.PARKED -> if (id == scrollA || id == scrollB) endScroll() // already ended on the host
            Mode.IDLE -> Unit
        }
    }

    /** The scroll is over; the finger that may still be down must lift before anything new starts. */
    private fun endScroll() {
        lockout = true
        lockoutDevice = gestureDevice
        mode = Mode.IDLE
        gestureDevice = NO_DEVICE
        scrollA = -1
        scrollB = -1
    }

    /**
     * Sends the held-back DOWN at the touch-down position. If the finger already moved beyond the slop, its
     * current position follows; otherwise it is treated as stationary at the down position. The gate is checked
     * again now: a PEN message sent during the hold-off (a stale close, a cancel) would make the host refuse
     * this press, so the finger is dropped instead (returns false, nothing sent, finger untracked).
     */
    private fun pressNow(nowMs: Long, timeUs: Long, out: MutableList<Outgoing>, movedBeyondSlop: Boolean): Boolean {
        if (policy == FingerPolicy.GESTURES_ONLY) return false // one finger sends nothing; it stays tracked (PENDING) for a second finger
        if (blocked(nowMs)) {
            counters.palmRejects++
            mode = Mode.IDLE
            return false
        }
        out += ptr(timeUs, downX, downY, Buttons.LEFT)
        if (movedBeyondSlop) {
            if (lastX != downX || lastY != downY) out += ptr(timeUs, lastX, lastY, Buttons.LEFT)
        } else {
            lastX = downX
            lastY = downY
        }
        mode = Mode.POINTER
        pressEventMs = timeUs / 1000
        return true
    }

    private fun forceRelease(timeUs: Long, out: MutableList<Outgoing>) {
        when (mode) {
            Mode.POINTER -> out += ptr(timeUs, lastX, lastY, 0)
            Mode.SCROLL -> {
                out += scroll(timeUs, 0f, 0f, Scroll.CANCELLED, mergeable = false)
                lockout = true
                lockoutDevice = gestureDevice
            }
            Mode.PINCH -> {
                out += pinch(timeUs, 0f, Pinch.CANCELLED, mergeable = false)
                lockout = true
                lockoutDevice = gestureDevice
            }
            Mode.UNDECIDED, Mode.PARKED -> {
                lockout = true
                lockoutDevice = gestureDevice
            }
            Mode.PENDING, Mode.IDLE -> Unit // nothing was sent
        }
        reset()
    }

    /** The client's gate: pen in range, or less than [GATE_HOLD_MS] since the last PEN message was sent. */
    private fun blocked(nowMs: Long) = pen.inRange || nowMs - pen.lastSentMs < GATE_HOLD_MS

    private fun ptr(timeUs: Long, x: Float, y: Float, buttons: Int): Outgoing {
        val vp = viewport()
        return Outgoing(PointerAbs(timeUs, vp.normX(x), vp.normY(y), buttons, PointerAbs.SOURCE_TOUCH))
    }

    private fun pinch(timeUs: Long, scale: Float, phase: Int, mergeable: Boolean): Outgoing {
        val vp = viewport()
        return Outgoing(Pinch(timeUs, scale, vp.normX(centerX), vp.normY(centerY), phase, Pinch.SOURCE_TOUCH), mergeable)
    }

    private fun scroll(timeUs: Long, dx: Float, dy: Float, phase: Int, mergeable: Boolean) =
        Outgoing(Scroll(timeUs, dx, dy, phase), mergeable)

    companion object {
        const val HOLD_MS = 40L
        const val SLOP_PX = 16f

        /** Floor of the finger distance the pinch threshold is relative to (noise guard for fingers starting very close). */
        const val MIN_DIST_PX = 140f // TwoFingerClassifier.MIN_DIST_FRAC of the 2800 px panel
        const val SCROLL_KEEPALIVE_MS = 200L
        const val SCROLL_IDLE_END_MS = 5_000L
        const val PRESS_STALE_MS = 10_000L

        /**
         * How long after the last PEN message a new finger press or scroll stays refused. The host holds its own gate
         * for 1000 ms from the moment it RECEIVES that message, this side counts from when the message was created.
         * With network jitter a press can overtake the pen message's delay and reach the host inside the host's second,
         * where it would be refused while this side believes a press is down. The extra 200 ms is that margin
         * (PROTOCOL.md section 7); heavier queue delay can still lose a tap, which leaves nothing held.
         */
        const val GATE_HOLD_MS = 1200L
    }
}
