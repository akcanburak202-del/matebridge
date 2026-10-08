package dev.matebridge.client.input

import dev.matebridge.client.idle.IdleChannel
import dev.matebridge.client.idle.IdleDimPolicy
import dev.matebridge.client.protocol.PenGesture
import dev.matebridge.client.protocol.Pinch
import dev.matebridge.client.protocol.ReleaseAll
import dev.matebridge.client.protocol.Scroll
import dev.matebridge.client.stream.VideoViewport

/**
 * Coordinator for pen and finger capture (T-024). MotionEvent-independent and JVM-tested; the Android
 * glue lives in [MotionEventAdapter] and MainActivity. UI thread only (PROTOCOL.md section 7: every input
 * message and every lifecycle release enters the one FIFO from the same thread, in the order produced).
 *
 * Stuck-input design, one line per path (each has a named test in InputCaptureTest / *TrackerTest):
 *  - `ACTION_CANCEL`: trackers turn it into `flags = 0` / finger UP / SCROLL / PINCH CANCELLED;
 *  - focus loss, background, device removal, deactivation: [releaseAll] flushes held data, sends the
 *    natural releases, then `RELEASE_ALL`, and (focus/background) suspends input until [resume];
 *  - after a release a stroke in progress resumes as hover only (PenTracker needs a fresh DOWN);
 *  - a pen DOWN is held until confirmed (T-029): the host knows nothing of it, so every release path above just drops it
 *    (no extra release), while the pen counts as in range for the finger gate and the (device, pointer) pair is followed;
 *  - backpressure: only plain hover PEN, SCROLL CHANGED and PINCH CHANGED are ever held ([InputOutbox]); a release flushes
 *    them first and is never held; a queue overflow means the connection is reset, the model is forgotten
 *    ([onRefused]) and the host releases on disconnect;
 *  - pointer capture (touchpad and mouse, T-034): [onPointerCaptureLost] and every release path send `buttons = 0` for a
 *    reported button and end an open pad scroll; a held physical button is reported again only after a new press;
 *  - a new control connection ([onSessionReset]) forgets the model as well;
 *  - idle dim (T-234, decision 0031): [idleGate] may swallow a whole motion before any tracker sees it (nothing was sent,
 *    so nothing needs releasing); it never swallows a release whose press went out, and the release paths above
 *    ([releaseAll], [onPointerCaptureLost], [onDeviceRemoved]) never go through it but make it forget what they released.
 *    A swallowed pen contact or finger stays visible to release routing ([PointerFollowers]), so its UP or CANCEL reaches
 *    the gate even when the platform reports it as PALM or UNKNOWN.
 */
class InputCapture(
    private val sink: InputSink,
    private val viewport: () -> VideoViewport,
    /** Rare state events for the `MB/input` log (name, key=value fields): never coordinates or key data. */
    private val onEvent: (String, String) -> Unit = { _, _ -> },
    /**
     * T-322: the send-age fields of the window since the last call (`pen_send_age_ms_p50=...`, "" when nothing was sent),
     * appended to the summary line. Called once per summary interval, on the UI thread.
     */
    private val sendAgeFields: () -> String = { "" },
    /** Once-per-second counter summary for the `MB/input` log. */
    private val onStatsLine: (String) -> Unit = {},
) : PointerFollowers {
    private val counters = InputCounters()
    private val pen = PenTracker(viewport, counters)
    private val touch = TouchTracker(viewport, pen, counters)
    private val doubleTap = DoubleTapDetector()
    private val keys = KeyTracker()
    private val rel = RelPointerTracker(counters)
    private val outbox = InputOutbox(sink, counters) { onRefused() }

    /** T-278: sees every input message that was sent (local cursor prediction); never changes what is sent. */
    var sentObserver: ((dev.matebridge.client.protocol.Message) -> Unit)?
        get() = outbox.observer
        set(v) { outbox.observer = v }

    private var active = false
    private var suspended = false

    /** Local pen indicator tap (T-056); display only, never affects what is sent. */
    var penInk: PenInkListener? = null

    /** T-234 (decision 0031): the idle-dim gate in front of the trackers; null lets every event through. */
    var idleGate: IdleDimPolicy? = null

    // T-234: the (device, pointer) identity of a swallowed pen contact and of swallowed fingers, for release routing only.
    private var idlePenDevice = NO_DEVICE
    private var idlePenPointer = -1
    private var idleTouchDevice = NO_DEVICE
    private val idleTouchIds = HashSet<Int>()

    private fun idleSwallows(kind: Int, deviceId: Int) =
        deviceId != NO_DEVICE && idleGate?.isSwallowing(IdleChannel.of(kind, deviceId)) == true

    private fun idleFollowsPen(deviceId: Int, pointerId: Int) =
        deviceId == idlePenDevice && pointerId == idlePenPointer && idleSwallows(IdleChannel.PEN, deviceId)

    private fun idleFollowsFinger(deviceId: Int, pointerId: Int) =
        deviceId == idleTouchDevice && pointerId in idleTouchIds && idleSwallows(IdleChannel.TOUCH, deviceId)

    /**
     * T-234 review: a pen or finger press the tracker no longer holds (its stale guard released it, a bounce was dropped)
     * stops holding the idle counter. Keys, touchpad and mouse have no such guards and end only by their own releases.
     */
    private fun syncIdleHeld() {
        val g = idleGate ?: return
        g.retainSent { ch ->
            when (IdleChannel.kindOf(ch)) {
                IdleChannel.PEN -> pen.holdsContact(IdleChannel.deviceOf(ch))
                IdleChannel.TOUCH -> touch.deviceInUse == IdleChannel.deviceOf(ch)
                else -> true
            }
        }
    }

    private fun admitPen(gate: IdleDimPolicy, f: PenFrame, nowMs: Long): Boolean {
        val pass = IdleGestures.pen(gate, f, nowMs)
        when (f.action) {
            PenAction.DOWN, PenAction.MOVE -> if (!pass) { idlePenDevice = f.deviceId; idlePenPointer = f.pointerId }
            PenAction.UP, PenAction.CANCEL -> if (f.deviceId == idlePenDevice) { idlePenDevice = NO_DEVICE; idlePenPointer = -1 }
            else -> Unit
        }
        return pass
    }

    private fun admitTouch(gate: IdleDimPolicy, f: TouchFrame, nowMs: Long): Boolean {
        val tracked = f.deviceId == idleTouchDevice && idleSwallows(IdleChannel.TOUCH, f.deviceId)
        // A stale swallow (silent 10 s) does not count: a fresh first finger may end it (IdleDimPolicy rule 1).
        val others = tracked && idleGate?.isSwallowingLive(IdleChannel.of(IdleChannel.TOUCH, f.deviceId)) == true &&
            idleTouchIds.any { it != f.actingId }
        val pass = IdleGestures.touch(gate, f, nowMs, swallowedOthers = others)
        if (!pass) {
            // Ids leave only by their own UP (or a CANCEL): a pointer reclassified as PALM drops out of the finger list
            // while it is still down, and its release must still be routed here.
            if (!tracked) idleTouchIds.clear()
            idleTouchDevice = f.deviceId
            when (f.action) {
                TouchAction.CANCEL -> idleTouchIds.clear()
                TouchAction.UP -> { idleTouchIds.remove(f.actingId); for (x in f.fingers) if (x.id != f.actingId) idleTouchIds += x.id }
                else -> for (x in f.fingers) idleTouchIds += x.id
            }
        } else if (f.deviceId == idleTouchDevice) {
            idleTouchDevice = NO_DEVICE
            idleTouchIds.clear()
        }
        return pass
    }

    /** Mirror of the host's eraser mode (decision 0006: toggled by every PEN_GESTURE DOUBLE_TAP, reset with the session). */
    private var eraserModeMirror = false
    private var lastStatsMs = NEVER_MS
    private val devices = HashSet<Int>()

    val isActive get() = active
    val isSuspended get() = suspended
    val penInRange get() = pen.inRange
    val fingersDisabled get() = touch.disabled

    // Model beliefs about what the host holds, for tests and diagnostics.
    internal val penInContact get() = pen.state == PenTracker.State.CONTACT

    /** The host believes the pen is in range; unlike [penInRange] a held, unconfirmed contact (T-029) does not count. */
    internal val penHostInRange get() = pen.state != PenTracker.State.OUT
    internal val fingerPressed get() = touch.isPressed
    internal val scrollOpen get() = touch.isScrolling
    internal val pinchOpen get() = touch.isPinching

    // PointerFollowers: releases are routed by the (device, pointer id) pair, never by pointer id alone. A motion the
    // idle gate is swallowing (T-234) counts as followed, so its release reaches the gate whatever tool type it reports.
    override fun followsPen(deviceId: Int, pointerId: Int) =
        pen.followsPointer(deviceId, pointerId) || idleFollowsPen(deviceId, pointerId)

    override fun followsFinger(deviceId: Int, pointerId: Int) =
        touch.follows(deviceId, pointerId) || idleFollowsFinger(deviceId, pointerId)

    override val penContactDevice get() = pen.contactDeviceId.takeIf { it != NO_DEVICE }
        ?: idlePenDevice.takeIf { idleSwallows(IdleChannel.PEN, it) } ?: NO_DEVICE

    override val touchDevice get() = touch.deviceInUse.takeIf { it != NO_DEVICE }
        ?: idleTouchDevice.takeIf { idleSwallows(IdleChannel.TOUCH, it) } ?: NO_DEVICE

    /** Pointer id of the open pen contact, or -1 (with [penContactDevice] it identifies the contact). */
    val penContactPointerId get() = pen.contactPointerId

    /** True when events are turned into messages: capture is active (video visible) and not suspended. */
    private val accepting get() = active && !suspended

    /** Stream size in Mac points (STREAM_CONFIG), needed to scale scrolling. */
    fun setStreamGeometry(widthPt: Int, heightPt: Int) {
        touch.widthPt = widthPt
        touch.heightPt = heightPt
        rel.widthPt = widthPt
    }

    /** The finger policy in effect ([FingerPolicy]); [fingersDisabled] is only its OFF case. */
    val fingerPolicy get() = touch.policy

    /**
     * Changes the finger policy (T-223). Whatever the new policy no longer allows is released on the host right here
     * (button up for a held drag, scroll/pinch cancelled for OFF); an open scroll or pinch survives GESTURES_ONLY.
     */
    fun setFingerPolicy(policy: FingerPolicy, nowMs: Long) {
        val outs = gate(Src.TOUCH, touch.setPolicy(policy, nowMs))
        if (outs.isNotEmpty()) dispatch(outs)
    }

    /**
     * The UI decides whether input is routed here (video visible and laid out). Going inactive releases
     * everything held, like any other loss of the input surface.
     */
    fun setActive(on: Boolean, nowMs: Long) {
        if (on == active) return
        if (!on) releaseAll(ReleaseAll.USER, nowMs) // still "active" while the releases go out
        active = on
        onEvent("input_active", "on=${flag(on)}")
    }

    fun onPen(f: PenFrame, nowMs: Long) {
        if (!accepting) return
        idleGate?.let { if (!admitPen(it, f, nowMs)) return }
        devices += f.deviceId
        penInk?.onPenFrame(f, f.eraser || eraserModeMirror)
        val wasInRange = pen.inRange
        if (!dispatch(pen.onFrame(f, nowMs))) return
        if (!wasInRange && pen.inRange) dispatch(gate(Src.TOUCH, touch.onPenRangeBegan(nowMs)))
    }

    fun onTouch(f: TouchFrame, nowMs: Long) {
        if (!accepting) return
        idleGate?.let { if (!admitTouch(it, f, nowMs)) return }
        devices += f.deviceId
        dispatch(gate(Src.TOUCH, touch.onFrame(f, nowMs)))
    }

    /** Speed multipliers of the touchpad and mouse cursor (T-035, from [dev.matebridge.client.session.Settings]). */
    fun setPointerSpeeds(pad: Float, mouse: Float) {
        rel.padSpeed = pad
        rel.mouseSpeed = mouse
    }

    /** The last relative pointer device type that produced an event: the mouse, or (also when none yet) the touchpad. */
    val lastPointerIsMouse get() = rel.lastWasMouse

    /** A touchpad event under pointer capture (T-034). The touchscreen and the pen never come through here. */
    fun onPad(f: PadFrame, nowMs: Long) {
        if (!accepting) return
        idleGate?.let { if (!IdleGestures.pad(it, f, nowMs)) return }
        dispatch(gate(Src.PAD, rel.onPad(f, nowMs)))
    }

    /** A mouse event under pointer capture (T-034). */
    fun onMouse(f: MouseFrame, nowMs: Long) {
        if (!accepting) return
        idleGate?.let { if (!IdleGestures.mouse(it, f, nowMs)) return }
        dispatch(rel.onMouse(f, nowMs))
    }

    /**
     * Pointer capture was lost (system, focus, or we released it): reported buttons go to 0 and an open pad scroll ends
     * (PROTOCOL.md section 7). Not a RELEASE_ALL and does not suspend input: pen, finger and keys are not affected.
     * Works while suspended or inactive too, so nothing reported stays pressed.
     */
    fun onPointerCaptureLost(nowMs: Long) {
        try {
            val outs = gate(Src.PAD, rel.release(nowMs))
            if (outs.isNotEmpty()) dispatch(outs)
        } finally {
            idleGate?.forgetKinds(IdleChannel.PAD, IdleChannel.MOUSE) // T-234: nothing pointer-captured is held any more
        }
    }

    /**
     * A DOWN of the M-Pencil gesture key (repeatCount 0). The key events are consumed by the caller
     * whether or not a gesture results, they are never sent as KEY.
     */
    fun onGestureKeyDown(eventTimeMs: Long) {
        if (!accepting) return
        idleGate?.let { if (!IdleGestures.gestureKey(it, eventTimeMs)) return }
        if (doubleTap.onDown(eventTimeMs)) {
            onEvent("pen_gesture", "gesture=double_tap")
            eraserModeMirror = !eraserModeMirror
            dispatch(listOf(Outgoing(PenGesture(eventTimeMs * 1000, PenGesture.DOUBLE_TAP))))
        }
    }

    /**
     * A physical-keyboard event (T-033). The caller consumes the event when [KeyDecision.consumed]; a
     * [KeyDecision.localToggle] flips the stats overlay. When input is not accepted only F3 (plain or
     * Ctrl+Shift) is handled locally and everything else stays with Android (the connect panel needs its keys).
     */
    fun onKey(f: KeyFrame): KeyDecision {
        if (!accepting) {
            val f3 = f.keyCode == KeyTracker.KEYCODE_F3
            if (f3 && f.down && f.repeatCount == 0) return KeyDecision(consumed = true, local = LocalAction.STATS)
            return KeyDecision(consumed = f3)
        }
        // T-234: a swallowed key (and a local chord typed while dimmed) is consumed and does nothing.
        idleGate?.let { if (!IdleGestures.key(it, f, f.timeUs / 1000)) return KeyDecision(consumed = true) }
        val d = keys.onKey(f)
        if (d.out.isNotEmpty()) dispatch(d.out)
        return d
    }

    /** Every ~25 ms: liveness repeats, stale guards, deferred DOWNs, scroll keepalive, held-message flush, stats. */
    fun tick(nowMs: Long) {
        if (accepting) {
            if (!dispatch(pen.tick(nowMs))) return finishTick(nowMs)
            if (!dispatch(gate(Src.TOUCH, touch.tick(nowMs)))) return finishTick(nowMs)
            if (!dispatch(gate(Src.PAD, rel.tick(nowMs)))) return finishTick(nowMs)
            outbox.tick()
        }
        finishTick(nowMs)
    }

    private fun finishTick(nowMs: Long) {
        syncIdleHeld()
        if (lastStatsMs == NEVER_MS) lastStatsMs = nowMs
        if (nowMs - lastStatsMs >= STATS_INTERVAL_MS) {
            val age = sendAgeFields() // always taken, so a window never carries over
            if (counters.any() || pen.inRange || age.isNotEmpty()) {
                val base = counters.fields(nowMs - lastStatsMs)
                onStatsLine(if (age.isEmpty()) base else "$base $age")
            }
            counters.reset()
            lastStatsMs = nowMs
        }
    }

    /**
     * Ends everything the host may hold: held data is flushed first, then the natural releases (pen
     * `flags = 0`, finger UP, SCROLL CANCELLED), then `RELEASE_ALL(reason)`. BACKGROUND and FOCUS_LOST
     * also suspend input until [resume]. Always sends RELEASE_ALL, even when nothing seems held.
     */
    fun releaseAll(reason: Int, nowMs: Long) {
        var queued = false
        try {
            // Inside the try: a failing log hook must not be able to skip the release or the reset below.
            onEvent("release_all", "reason=$reason contact=${flag(penInContact)} pressed=${flag(fingerPressed)} scroll=${flag(scrollOpen)} pinch=${flag(pinchOpen)}")
            val outs = ArrayList<Outgoing>(3)
            outs += pen.release(nowMs)
            // Pointer sources go last: buttons = 0 for everything reported pressed sits immediately before RELEASE_ALL
            // (PROTOCOL.md section 7, the host's pointer lock would swallow the next press otherwise).
            outs += gate(Src.TOUCH, touch.release(nowMs))
            outs += gate(Src.PAD, rel.release(nowMs))
            doubleTap.reset()
            keys.reset() // the host releases held keys on RELEASE_ALL; a later physical UP must not be sent
            if (reason == ReleaseAll.BACKGROUND || reason == ReleaseAll.FOCUS_LOST) suspended = true
            outs += Outgoing(ReleaseAll(reason))
            queued = dispatch(outs)
        } finally {
            // Whatever happened, the model must not keep believing in a press: the host has released, or is about
            // to (connection closed below), so a stroke in progress cannot come back as a contact from the middle.
            forget()
            // If RELEASE_ALL could not be queued the host still holds what it holds: drop the connection so the
            // host releases on disconnect (PROTOCOL.md section 7).
            if (!queued) closeConnectionSafely()
        }
    }

    private fun closeConnectionSafely() {
        try {
            sink.closeConnection()
        } catch (_: RuntimeException) {
            // nothing left to try; the heartbeat silence rule of the host is the last line
        }
    }

    /** Window focus is back: input flows again. */
    fun resume() {
        if (suspended) onEvent("input_resume", "")
        suspended = false
    }

    /** An input device went away; release if it was one we were reading pen/finger events from. */
    fun onDeviceRemoved(deviceId: Int, nowMs: Long) {
        // A detached keyboard releases only its own keys; pen and finger state is untouched.
        if (keys.holdsDevice(deviceId)) dispatch(keys.releaseDevice(deviceId, nowMs * 1000))
        // A detached touchpad or mouse ends its own scroll and buttons only.
        if (rel.holdsDevice(deviceId)) dispatch(gate(Src.PAD, rel.release(nowMs)))
        if (devices.remove(deviceId)) releaseAll(ReleaseAll.DEVICE_DETACHED, nowMs)
        idleGate?.forgetDevice(deviceId) // T-234: sent or swallowed, nothing of that device is held any more
    }

    /** A new control connection starts: the host has no state for us, forget ours without sending. */
    fun onSessionReset() {
        onEvent("session_reset", "contact=${flag(penInContact)} pressed=${flag(fingerPressed)} scroll=${flag(scrollOpen)} pinch=${flag(pinchOpen)}")
        forget()
    }

    private fun onRefused() {
        forget()
    }

    private fun forget() {
        gestureOwner = Src.NONE
        eraserModeMirror = false
        penInk?.onPenClear()
        pen.reset()
        touch.reset()
        doubleTap.reset()
        keys.reset()
        rel.reset()
        outbox.dropHeld()
        idleGate?.forgetGestures()
        idlePenDevice = NO_DEVICE
        idlePenPointer = -1
        idleTouchDevice = NO_DEVICE
        idleTouchIds.clear()
    }

    private enum class Src { NONE, TOUCH, PAD }

    /** Which tracker owns the host's single open phased gesture (SCROLL or PINCH, PROTOCOL.md section 4), and which kind. */
    private var gestureOwner = Src.NONE
    private var gestureKind = 0

    private fun kindOf(m: dev.matebridge.client.protocol.Message) = when {
        m is Scroll && m.phase != Scroll.NONE -> KIND_SCROLL
        m is Pinch -> KIND_PINCH
        else -> 0
    }

    private fun phaseOf(m: dev.matebridge.client.protocol.Message) = when (m) {
        is Scroll -> m.phase
        is Pinch -> m.phase
        else -> -1
    }

    /**
     * One open phased gesture at a time, a SCROLL or a PINCH: the host has one. The first source to BEGIN owns it; the
     * other source's phased messages (BEGAN, CHANGED, ENDED, CANCELLED) and the owner's messages of the other kind are
     * dropped until the owner ends. The suppressed tracker thinks its gesture is open, which is harmless: it sends
     * nothing the host needs, and its ENDED is dropped as well. A BEGAN of the owner (either kind) passes: the host
     * ends its previous gesture first. Wheel notches (SCROLL phase NONE) are not phased and always pass.
     */
    private fun gate(src: Src, outs: List<Outgoing>): List<Outgoing> {
        if (outs.none { kindOf(it.msg) != 0 }) return outs
        val kept = ArrayList<Outgoing>(outs.size)
        for (o in outs) {
            val m = o.msg
            val kind = kindOf(m)
            if (kind == 0) { kept += o; continue }
            when (phaseOf(m)) {
                Scroll.BEGAN -> if (gestureOwner == Src.NONE || gestureOwner == src) {
                    gestureOwner = src; gestureKind = kind; kept += o
                }
                Scroll.CHANGED -> if (gestureOwner == src && gestureKind == kind) kept += o
                else -> if (gestureOwner == src && gestureKind == kind) { gestureOwner = Src.NONE; kept += o }
            }
        }
        return kept
    }

    /** Sends a batch in order; stops at the first refusal (the model was already reset then). */
    private fun dispatch(outs: List<Outgoing>): Boolean {
        for (o in outs) if (!outbox.send(o)) return false
        return true
    }

    private fun flag(v: Boolean) = if (v) 1 else 0

    companion object {
        const val STATS_INTERVAL_MS = 1000L
        private const val KIND_SCROLL = 1
        private const val KIND_PINCH = 2
    }
}
