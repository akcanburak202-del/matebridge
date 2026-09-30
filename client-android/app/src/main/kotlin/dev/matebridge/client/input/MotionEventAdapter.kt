package dev.matebridge.client.input

import android.view.InputDevice
import android.view.MotionEvent
import dev.matebridge.client.protocol.Buttons

/**
 * Thin Android glue: turns a [MotionEvent] into the MotionEvent-independent frames of [InputCapture].
 * All decisions live in the JVM-tested trackers and in [ReleaseRouting]; keep this class free of logic beyond
 * field extraction.
 *
 * Presses are classified per pointer by tool type: STYLUS/ERASER go to the pen path, FINGER to the touch path,
 * everything else (mouse, trackpad, unknown, palm) is not started here. Releases are different: `ACTION_UP`,
 * `ACTION_POINTER_UP` and `ACTION_CANCEL` are routed by the (device, pointer id) pair the trackers are following
 * ([ReleaseRouting]; the pen and the touchscreen are separate devices whose pointer ids both start at 0), so a release
 * the platform reports as PALM or UNKNOWN still ends the press it belongs to and a palm's release never ends a
 * pen stroke (PROTOCOL.md section 7). Pen events
 * carry the batched historical samples in order (never dropped) followed by the current sample, for every action.
 */
object MotionEventAdapter {
    /**
     * Feeds [ev] to [capture]. [offX]/[offY] are added to the event coordinates to move them from window
     * coordinates into the coordinate space of `VideoViewport` (root). Returns true when the event
     * belongs to pen or finger input, so the caller consumes it.
     */
    fun handle(ev: MotionEvent, offX: Float, offY: Float, nowMs: Long, capture: InputCapture): Boolean {
        if (isCapturedPointer(ev)) return handleCaptured(ev, nowMs, capture)
        // Only the screen digitizers. The keyboard touchpad and mice report FINGER/MOUSE tools too (source MOUSE
        // or TOUCHPAD in normal mode, NOTES 2026-09-29) and belong to the later trackpad task.
        if (!ev.isFromSource(InputDevice.SOURCE_TOUCHSCREEN) && !ev.isFromSource(InputDevice.SOURCE_STYLUS)) return false
        var penIndex = -1
        var hasFinger = false
        for (i in 0 until ev.pointerCount) {
            when (kindOf(ev.getToolType(i))) {
                ToolKind.PEN -> if (penIndex < 0) penIndex = i
                ToolKind.FINGER -> hasFinger = true
                ToolKind.OTHER -> Unit
            }
        }
        var consumed = penIndex >= 0 || hasFinger
        when (val action = ev.actionMasked) {
            MotionEvent.ACTION_HOVER_ENTER, MotionEvent.ACTION_HOVER_MOVE, MotionEvent.ACTION_HOVER_EXIT -> {
                if (penIndex < 0) return false
                val a = when (action) {
                    MotionEvent.ACTION_HOVER_ENTER -> PenAction.HOVER_ENTER
                    MotionEvent.ACTION_HOVER_MOVE -> PenAction.HOVER_MOVE
                    else -> PenAction.HOVER_EXIT
                }
                capture.onPen(penFrame(ev, penIndex, a, offX, offY), nowMs)
            }
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                val idx = ev.actionIndex
                when (kindOf(ev.getToolType(idx))) {
                    ToolKind.PEN -> capture.onPen(penFrame(ev, idx, PenAction.DOWN, offX, offY), nowMs)
                    ToolKind.FINGER -> capture.onTouch(touchFrame(ev, TouchAction.DOWN, ev.getPointerId(idx), offX, offY), nowMs)
                    ToolKind.OTHER -> Unit // a palm or unknown tool never starts a press
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> {
                val idx = ev.actionIndex
                val pid = ev.getPointerId(idx)
                val route = ReleaseRouting.routeUp(kindOf(ev.getToolType(idx)), ev.deviceId, pid, capture)
                when (route) {
                    Route.PEN -> capture.onPen(penFrame(ev, idx, PenAction.UP, offX, offY), nowMs)
                    Route.TOUCH -> capture.onTouch(touchFrame(ev, TouchAction.UP, pid, offX, offY), nowMs)
                    Route.NONE -> Unit
                }
                if (route != Route.NONE) consumed = true
            }
            MotionEvent.ACTION_MOVE -> {
                if (penIndex >= 0) capture.onPen(penFrame(ev, penIndex, PenAction.MOVE, offX, offY), nowMs)
                if (hasFinger) capture.onTouch(touchFrame(ev, TouchAction.MOVE, -1, offX, offY), nowMs)
            }
            MotionEvent.ACTION_CANCEL -> {
                // A cancel ends the gesture of ITS device only: pointer ids repeat across the pen and the touchscreen.
                if (ReleaseRouting.cancelReachesPen(ev.deviceId, penIndex >= 0, capture)) {
                    val followed = capture.penContactPointerId
                    val followedIdx = if (followed >= 0) ev.findPointerIndex(followed) else -1
                    val idx = if (penIndex >= 0) penIndex else if (followedIdx >= 0) followedIdx else 0
                    capture.onPen(penFrame(ev, idx, PenAction.CANCEL, offX, offY), nowMs)
                    consumed = true
                }
                if (ReleaseRouting.cancelReachesTouch(ev.deviceId, hasFinger, capture)) {
                    capture.onTouch(touchFrame(ev, TouchAction.CANCEL, -1, offX, offY), nowMs)
                    consumed = true
                }
            }
            else -> return false
        }
        return consumed
    }

    /**
     * Under pointer capture the keyboard touchpad reports source TOUCHPAD and a mouse SOURCE_MOUSE_RELATIVE (NOTES
     * 2026-09-29). Touchscreen and stylus events are never delivered as captured events and keep their own path above.
     */
    fun isCapturedPointer(ev: MotionEvent) =
        ev.isFromSource(InputDevice.SOURCE_TOUCHPAD) || ev.isFromSource(SOURCE_MOUSE_RELATIVE)

    /** Touchpad and mouse events under pointer capture (T-034). Returns true: a captured event is always consumed. */
    fun handleCaptured(ev: MotionEvent, nowMs: Long, capture: InputCapture): Boolean {
        val buttons = mapButtons(ev.buttonState)
        if (ev.isFromSource(InputDevice.SOURCE_TOUCHPAD) && !ev.isFromSource(SOURCE_MOUSE_RELATIVE)) {
            val action = when (ev.actionMasked) {
                MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> PadAction.DOWN
                MotionEvent.ACTION_MOVE -> PadAction.MOVE
                MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> PadAction.UP
                MotionEvent.ACTION_CANCEL -> PadAction.CANCEL
                MotionEvent.ACTION_BUTTON_PRESS, MotionEvent.ACTION_BUTTON_RELEASE -> PadAction.BUTTON
                else -> return true
            }
            val fingers = ArrayList<Finger>(ev.pointerCount)
            for (i in 0 until ev.pointerCount) fingers += Finger(ev.getPointerId(i), ev.getX(i), ev.getY(i))
            val acting = if (action == PadAction.DOWN || action == PadAction.UP) ev.getPointerId(ev.actionIndex) else -1
            val pressed = if (ev.actionMasked == MotionEvent.ACTION_BUTTON_PRESS) mapButtons(ev.actionButton) else 0
            val range = ev.device?.getMotionRange(MotionEvent.AXIS_X, InputDevice.SOURCE_TOUCHPAD)
            val extent = if (range != null) range.max - range.min else 0f
            capture.onPad(PadFrame(action, acting, fingers, ev.eventTime * 1000, ev.deviceId, buttons, pressed, extent), nowMs)
            return true
        }
        var dx = ev.getAxisValue(MotionEvent.AXIS_RELATIVE_X)
        var dy = ev.getAxisValue(MotionEvent.AXIS_RELATIVE_Y)
        // Batched samples each carry their own relative motion: never drop any.
        for (h in 0 until ev.historySize) {
            dx += ev.getHistoricalAxisValue(MotionEvent.AXIS_RELATIVE_X, h)
            dy += ev.getHistoricalAxisValue(MotionEvent.AXIS_RELATIVE_Y, h)
        }
        val scrolling = ev.actionMasked == MotionEvent.ACTION_SCROLL
        val pressed = if (ev.actionMasked == MotionEvent.ACTION_BUTTON_PRESS) mapButtons(ev.actionButton) else 0
        capture.onMouse(
            MouseFrame(
                ev.eventTime * 1000, dx, dy, buttons, pressed,
                if (scrolling) ev.getAxisValue(MotionEvent.AXIS_VSCROLL) else 0f,
                if (scrolling) ev.getAxisValue(MotionEvent.AXIS_HSCROLL) else 0f,
                ev.deviceId,
            ),
            nowMs,
        )
        return true
    }

    /** `MotionEvent.BUTTON_*` bits to PROTOCOL.md `buttons` bits (LEFT, RIGHT, MIDDLE, BACK, FORWARD). */
    fun mapButtons(state: Int): Int {
        var b = 0
        if (state and MotionEvent.BUTTON_PRIMARY != 0) b = b or Buttons.LEFT
        if (state and MotionEvent.BUTTON_SECONDARY != 0) b = b or Buttons.RIGHT
        if (state and MotionEvent.BUTTON_TERTIARY != 0) b = b or Buttons.MIDDLE
        if (state and MotionEvent.BUTTON_BACK != 0) b = b or Buttons.BACK
        if (state and MotionEvent.BUTTON_FORWARD != 0) b = b or Buttons.FORWARD
        return b
    }

    /** `InputDevice.SOURCE_MOUSE_RELATIVE` is API 26 (minSdk is 29), spelled out to keep the glue independent of lint level. */
    private const val SOURCE_MOUSE_RELATIVE = InputDevice.SOURCE_MOUSE_RELATIVE

    private fun kindOf(tool: Int) = when (tool) {
        MotionEvent.TOOL_TYPE_STYLUS, MotionEvent.TOOL_TYPE_ERASER -> ToolKind.PEN
        MotionEvent.TOOL_TYPE_FINGER -> ToolKind.FINGER
        else -> ToolKind.OTHER
    }

    /** History (oldest first) plus the current sample of pointer [idx], for every action. */
    private fun penFrame(ev: MotionEvent, idx: Int, action: PenAction, offX: Float, offY: Float): PenFrame {
        val n = ev.historySize
        val pts = ArrayList<PenPoint>(n + 1)
        val button = ev.buttonState and (MotionEvent.BUTTON_STYLUS_PRIMARY or MotionEvent.BUTTON_STYLUS_SECONDARY) != 0
        for (h in 0 until n) {
            pts += PenPoint(
                ev.getHistoricalEventTime(h) * 1000,
                ev.getHistoricalX(idx, h) + offX,
                ev.getHistoricalY(idx, h) + offY,
                ev.getHistoricalPressure(idx, h),
                ev.getHistoricalAxisValue(MotionEvent.AXIS_TILT, idx, h),
                ev.getHistoricalAxisValue(MotionEvent.AXIS_ORIENTATION, idx, h),
                button,
            )
        }
        pts += PenPoint(
            ev.eventTime * 1000,
            ev.getX(idx) + offX,
            ev.getY(idx) + offY,
            ev.getPressure(idx),
            ev.getAxisValue(MotionEvent.AXIS_TILT, idx),
            ev.getAxisValue(MotionEvent.AXIS_ORIENTATION, idx),
            button,
        )
        return PenFrame(
            action, ev.getToolType(idx) == MotionEvent.TOOL_TYPE_ERASER, pts, ev.deviceId, ev.getPointerId(idx),
        )
    }

    private fun touchFrame(ev: MotionEvent, action: TouchAction, actingId: Int, offX: Float, offY: Float): TouchFrame {
        val fingers = ArrayList<Finger>(ev.pointerCount)
        for (i in 0 until ev.pointerCount) {
            if (ev.getToolType(i) == MotionEvent.TOOL_TYPE_FINGER) {
                fingers += Finger(ev.getPointerId(i), ev.getX(i) + offX, ev.getY(i) + offY)
            }
        }
        return TouchFrame(action, actingId, fingers, ev.eventTime * 1000, ev.deviceId)
    }
}
