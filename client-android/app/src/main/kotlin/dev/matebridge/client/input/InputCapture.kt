package dev.matebridge.client.input

import dev.matebridge.client.protocol.PenGesture
import dev.matebridge.client.protocol.ReleaseAll
import dev.matebridge.client.stream.VideoViewport

/**
 * Coordinator for pen and finger capture (T-024). MotionEvent-independent and JVM-tested; the Android
 * glue lives in [MotionEventAdapter] and MainActivity. UI thread only (PROTOCOL.md section 7: every input
 * message and every lifecycle release enters the one FIFO from the same thread, in the order produced).
 *
 * Stuck-input design, one line per path (each has a named test in InputCaptureTest / *TrackerTest):
 *  - `ACTION_CANCEL`: trackers turn it into `flags = 0` / finger UP / SCROLL CANCELLED;
 *  - focus loss, background, device removal, deactivation: [releaseAll] flushes held data, sends the
 *    natural releases, then `RELEASE_ALL`, and (focus/background) suspends input until [resume];
 *  - after a release a stroke in progress resumes as hover only (PenTracker needs a fresh DOWN);
 *  - backpressure: only plain hover PEN and SCROLL CHANGED are ever held ([InputOutbox]); a release flushes
 *    them first and is never held; a queue overflow means the connection is reset, the model is forgotten
 *    ([onRefused]) and the host releases on disconnect;
 *  - a new control connection ([onSessionReset]) forgets the model as well.
 */
class InputCapture(
    private val sink: InputSink,
    private val viewport: () -> VideoViewport,
    /** Rare state events for the `MB/input` log (name, key=value fields): never coordinates or key data. */
    private val onEvent: (String, String) -> Unit = { _, _ -> },
    /** Once-per-second counter summary for the `MB/input` log. */
    private val onStatsLine: (String) -> Unit = {},
) {
    private val counters = InputCounters()
    private val pen = PenTracker(viewport, counters)
    private val touch = TouchTracker(viewport, pen, counters)
    private val doubleTap = DoubleTapDetector()
    private val outbox = InputOutbox(sink, counters) { onRefused() }

    private var active = false
    private var suspended = false
    private var lastStatsMs = NEVER_MS
    private val devices = HashSet<Int>()

    val isActive get() = active
    val isSuspended get() = suspended
    val penInRange get() = pen.inRange
    val fingersDisabled get() = touch.disabled

    // Model beliefs about what the host holds, for tests and diagnostics.
    internal val penInContact get() = pen.state == PenTracker.State.CONTACT
    internal val fingerPressed get() = touch.isPressed
    internal val scrollOpen get() = touch.isScrolling

    /** True when events are turned into messages: capture is active (video visible) and not suspended. */
    private val accepting get() = active && !suspended

    /** Stream size in Mac points (STREAM_CONFIG), needed to scale scrolling. */
    fun setStreamGeometry(widthPt: Int, heightPt: Int) {
        touch.widthPt = widthPt
        touch.heightPt = heightPt
    }

    /** "Parmak dokunmasını tamamen kapat". Turning it on releases any finger currently held. */
    fun setFingersDisabled(disabled: Boolean, nowMs: Long) {
        val outs = touch.setDisabled(disabled, nowMs)
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
        devices += f.deviceId
        val wasInRange = pen.inRange
        if (!dispatch(pen.onFrame(f, nowMs))) return
        if (!wasInRange && pen.inRange) dispatch(touch.onPenRangeBegan(nowMs))
    }

    fun onTouch(f: TouchFrame, nowMs: Long) {
        if (!accepting) return
        devices += f.deviceId
        dispatch(touch.onFrame(f, nowMs))
    }

    /**
     * A DOWN of the M-Pencil gesture key (repeatCount 0). The key events are consumed by the caller
     * whether or not a gesture results, they are never sent as KEY.
     */
    fun onGestureKeyDown(eventTimeMs: Long) {
        if (!accepting) return
        if (doubleTap.onDown(eventTimeMs)) {
            onEvent("pen_gesture", "gesture=double_tap")
            dispatch(listOf(Outgoing(PenGesture(eventTimeMs * 1000, PenGesture.DOUBLE_TAP))))
        }
    }

    /** Every ~25 ms: liveness repeats, stale guards, deferred DOWNs, scroll keepalive, held-message flush, stats. */
    fun tick(nowMs: Long) {
        if (accepting) {
            if (!dispatch(pen.tick(nowMs))) return finishTick(nowMs)
            if (!dispatch(touch.tick(nowMs))) return finishTick(nowMs)
            outbox.tick()
        }
        finishTick(nowMs)
    }

    private fun finishTick(nowMs: Long) {
        if (lastStatsMs == NEVER_MS) lastStatsMs = nowMs
        if (nowMs - lastStatsMs >= STATS_INTERVAL_MS) {
            if (counters.any() || pen.inRange) onStatsLine(counters.fields(nowMs - lastStatsMs))
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
        onEvent("release_all", "reason=$reason contact=${flag(penInContact)} pressed=${flag(fingerPressed)} scroll=${flag(scrollOpen)}")
        val outs = ArrayList<Outgoing>(3)
        outs += pen.release(nowMs)
        outs += touch.release(nowMs)
        doubleTap.reset()
        if (reason == ReleaseAll.BACKGROUND || reason == ReleaseAll.FOCUS_LOST) suspended = true
        outs += Outgoing(ReleaseAll(reason))
        dispatch(outs)
        // The host has released (or the connection is going away): forget everything so a stroke in
        // progress cannot come back as a contact from the middle.
        forget()
    }

    /** Window focus is back: input flows again. */
    fun resume() {
        if (suspended) onEvent("input_resume", "")
        suspended = false
    }

    /** An input device went away; release if it was one we were reading pen/finger events from. */
    fun onDeviceRemoved(deviceId: Int, nowMs: Long) {
        if (devices.remove(deviceId)) releaseAll(ReleaseAll.DEVICE_DETACHED, nowMs)
    }

    /** A new control connection starts: the host has no state for us, forget ours without sending. */
    fun onSessionReset() {
        onEvent("session_reset", "contact=${flag(penInContact)} pressed=${flag(fingerPressed)} scroll=${flag(scrollOpen)}")
        forget()
    }

    private fun onRefused() {
        forget()
    }

    private fun forget() {
        pen.reset()
        touch.reset()
        doubleTap.reset()
        outbox.dropHeld()
    }

    /** Sends a batch in order; stops at the first refusal (the model was already reset then). */
    private fun dispatch(outs: List<Outgoing>): Boolean {
        for (o in outs) if (!outbox.send(o)) return false
        return true
    }

    private fun flag(v: Boolean) = if (v) 1 else 0

    companion object {
        const val STATS_INTERVAL_MS = 1000L
    }
}
