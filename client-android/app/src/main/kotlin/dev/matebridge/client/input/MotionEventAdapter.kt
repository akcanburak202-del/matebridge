package dev.matebridge.client.input

import android.view.InputDevice
import android.view.MotionEvent

/**
 * Thin Android glue: turns a [MotionEvent] into the MotionEvent-independent frames of [InputCapture].
 * All decisions live in the JVM-tested trackers; keep this class free of logic beyond field extraction.
 *
 * Tool types are classified per pointer: STYLUS/ERASER go to the pen path, FINGER to the touch path,
 * everything else (mouse, trackpad, unknown, palm) is not handled here. Pen events carry the batched
 * historical samples in order (never dropped) followed by the current sample.
 */
object MotionEventAdapter {
    /**
     * Feeds [ev] to [capture]. [offX]/[offY] are added to the event coordinates to move them from window
     * coordinates into the coordinate space of `VideoViewport` (root). Returns true when the event
     * contained pen or finger pointers, so the caller consumes it.
     */
    fun handle(ev: MotionEvent, offX: Float, offY: Float, nowMs: Long, capture: InputCapture): Boolean {
        // Only the screen digitizers. The keyboard touchpad and mice report FINGER/MOUSE tools too (source MOUSE
        // or TOUCHPAD in normal mode, NOTES 2026-09-29) and belong to the later trackpad task.
        if (!ev.isFromSource(InputDevice.SOURCE_TOUCHSCREEN) && !ev.isFromSource(InputDevice.SOURCE_STYLUS)) return false
        var penIndex = -1
        var hasFinger = false
        for (i in 0 until ev.pointerCount) {
            val t = ev.getToolType(i)
            if (isPen(t)) {
                if (penIndex < 0) penIndex = i
            } else if (t == MotionEvent.TOOL_TYPE_FINGER) {
                hasFinger = true
            }
        }
        if (penIndex < 0 && !hasFinger) return false
        val deviceId = ev.deviceId
        when (val action = ev.actionMasked) {
            MotionEvent.ACTION_HOVER_ENTER, MotionEvent.ACTION_HOVER_MOVE, MotionEvent.ACTION_HOVER_EXIT -> {
                if (penIndex < 0) return false
                val a = when (action) {
                    MotionEvent.ACTION_HOVER_ENTER -> PenAction.HOVER_ENTER
                    MotionEvent.ACTION_HOVER_MOVE -> PenAction.HOVER_MOVE
                    else -> PenAction.HOVER_EXIT
                }
                capture.onPen(penFrame(ev, penIndex, a, offX, offY, batched = true), nowMs)
            }
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                val idx = ev.actionIndex
                val t = ev.getToolType(idx)
                if (isPen(t)) capture.onPen(penFrame(ev, idx, PenAction.DOWN, offX, offY, batched = false), nowMs)
                else if (t == MotionEvent.TOOL_TYPE_FINGER) {
                    capture.onTouch(touchFrame(ev, TouchAction.DOWN, ev.getPointerId(idx), offX, offY), nowMs)
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> {
                val idx = ev.actionIndex
                val t = ev.getToolType(idx)
                if (isPen(t)) capture.onPen(penFrame(ev, idx, PenAction.UP, offX, offY, batched = false), nowMs)
                else if (t == MotionEvent.TOOL_TYPE_FINGER) {
                    capture.onTouch(touchFrame(ev, TouchAction.UP, ev.getPointerId(idx), offX, offY), nowMs)
                }
            }
            MotionEvent.ACTION_MOVE -> {
                if (penIndex >= 0) capture.onPen(penFrame(ev, penIndex, PenAction.MOVE, offX, offY, batched = true), nowMs)
                if (hasFinger) capture.onTouch(touchFrame(ev, TouchAction.MOVE, -1, offX, offY), nowMs)
            }
            MotionEvent.ACTION_CANCEL -> {
                if (penIndex >= 0) capture.onPen(penFrame(ev, penIndex, PenAction.CANCEL, offX, offY, batched = false), nowMs)
                if (hasFinger) capture.onTouch(touchFrame(ev, TouchAction.CANCEL, -1, offX, offY), nowMs)
            }
            else -> return false
        }
        return true
    }

    private fun isPen(tool: Int) = tool == MotionEvent.TOOL_TYPE_STYLUS || tool == MotionEvent.TOOL_TYPE_ERASER

    private fun penFrame(ev: MotionEvent, idx: Int, action: PenAction, offX: Float, offY: Float, batched: Boolean): PenFrame {
        val n = if (batched) ev.historySize else 0
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
        return PenFrame(action, ev.getToolType(idx) == MotionEvent.TOOL_TYPE_ERASER, pts, ev.deviceId)
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
