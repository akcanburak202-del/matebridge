package dev.matebridge.client.input

import android.view.InputDevice
import android.view.MotionEvent

/**
 * Thin Android glue: turns a [MotionEvent] into the MotionEvent-independent frames of [InputCapture].
 * All decisions live in the JVM-tested trackers and in [ReleaseRouting]; keep this class free of logic beyond
 * field extraction.
 *
 * Presses are classified per pointer by tool type: STYLUS/ERASER go to the pen path, FINGER to the touch path,
 * everything else (mouse, trackpad, unknown, palm) is not started here. Releases are different: `ACTION_UP`,
 * `ACTION_POINTER_UP` and `ACTION_CANCEL` are routed by the pointer id the trackers are following, so a release
 * the platform reports as PALM or UNKNOWN still ends the press it belongs to (PROTOCOL.md section 7). Pen events
 * carry the batched historical samples in order (never dropped) followed by the current sample, for every action.
 */
object MotionEventAdapter {
    /**
     * Feeds [ev] to [capture]. [offX]/[offY] are added to the event coordinates to move them from window
     * coordinates into the coordinate space of `VideoViewport` (root). Returns true when the event
     * belongs to pen or finger input, so the caller consumes it.
     */
    fun handle(ev: MotionEvent, offX: Float, offY: Float, nowMs: Long, capture: InputCapture): Boolean {
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
                val route = ReleaseRouting.routeUp(
                    kindOf(ev.getToolType(idx)), capture.followsPenPointer(pid), capture.followsFingerPointer(pid),
                )
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
                val followedPen = capture.penContactPointerId
                val followedIdx = if (followedPen >= 0) ev.findPointerIndex(followedPen) else -1
                if (ReleaseRouting.cancelReachesPen(penIndex >= 0, followedIdx >= 0)) {
                    capture.onPen(penFrame(ev, if (penIndex >= 0) penIndex else followedIdx, PenAction.CANCEL, offX, offY), nowMs)
                    consumed = true
                }
                // Cancel ends every pointer of the gesture, whatever tool types they carry now.
                capture.onTouch(touchFrame(ev, TouchAction.CANCEL, -1, offX, offY), nowMs)
            }
            else -> return false
        }
        return consumed
    }

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
