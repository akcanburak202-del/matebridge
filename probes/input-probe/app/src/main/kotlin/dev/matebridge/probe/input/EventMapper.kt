package dev.matebridge.probe.input

import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent

/** Android adapter: MotionEvent/KeyEvent to plain records. All batched samples are kept. */
object EventMapper {

    fun toolName(t: Int): String = when (t) {
        MotionEvent.TOOL_TYPE_FINGER -> "FINGER"
        MotionEvent.TOOL_TYPE_STYLUS -> "STYLUS"
        MotionEvent.TOOL_TYPE_MOUSE -> "MOUSE"
        MotionEvent.TOOL_TYPE_ERASER -> "ERASER"
        MotionEvent.TOOL_TYPE_UNKNOWN -> "UNKNOWN"
        else -> "TOOL_$t"
    }

    private fun current(e: MotionEvent, i: Int) = PointerSample(
        id = e.getPointerId(i),
        toolType = toolName(e.getToolType(i)),
        x = e.getX(i),
        y = e.getY(i),
        pressure = e.getPressure(i),
        size = e.getSize(i),
        tilt = e.getAxisValue(MotionEvent.AXIS_TILT, i),
        orientation = e.getAxisValue(MotionEvent.AXIS_ORIENTATION, i),
        distance = e.getAxisValue(MotionEvent.AXIS_DISTANCE, i),
        relX = e.getAxisValue(MotionEvent.AXIS_RELATIVE_X, i),
        relY = e.getAxisValue(MotionEvent.AXIS_RELATIVE_Y, i),
        vScroll = e.getAxisValue(MotionEvent.AXIS_VSCROLL, i),
        hScroll = e.getAxisValue(MotionEvent.AXIS_HSCROLL, i),
    )

    private fun historical(e: MotionEvent, i: Int, h: Int) = PointerSample(
        id = e.getPointerId(i),
        toolType = toolName(e.getToolType(i)),
        x = e.getHistoricalX(i, h),
        y = e.getHistoricalY(i, h),
        pressure = e.getHistoricalPressure(i, h),
        size = e.getHistoricalSize(i, h),
        tilt = e.getHistoricalAxisValue(MotionEvent.AXIS_TILT, i, h),
        orientation = e.getHistoricalAxisValue(MotionEvent.AXIS_ORIENTATION, i, h),
        distance = e.getHistoricalAxisValue(MotionEvent.AXIS_DISTANCE, i, h),
        relX = e.getHistoricalAxisValue(MotionEvent.AXIS_RELATIVE_X, i, h),
        relY = e.getHistoricalAxisValue(MotionEvent.AXIS_RELATIVE_Y, i, h),
        vScroll = e.getHistoricalAxisValue(MotionEvent.AXIS_VSCROLL, i, h),
        hScroll = e.getHistoricalAxisValue(MotionEvent.AXIS_HSCROLL, i, h),
    )

    fun motion(e: MotionEvent, callback: String, captured: Boolean): MotionRecord {
        val n = e.pointerCount
        val hs = e.historySize
        return MotionRecord(
            t = SystemClock.elapsedRealtime(),
            callback = callback,
            captured = captured,
            action = MotionEvent.actionToString(e.action),
            actionMasked = e.actionMasked,
            actionIndex = e.actionIndex,
            actionButton = e.actionButton,
            buttonState = e.buttonState,
            source = e.source,
            sourceHex = "0x%08x".format(e.source),
            deviceId = e.deviceId,
            deviceName = InputDevice.getDevice(e.deviceId)?.name,
            pointerCount = n,
            eventTime = e.eventTime,
            downTime = e.downTime,
            historySize = hs,
            pointers = (0 until n).map { current(e, it) },
            history = (0 until hs).map { h ->
                HistorySample(e.getHistoricalEventTime(h), (0 until n).map { historical(e, it, h) })
            },
        )
    }

    /** Codes only. KeyEvent.getUnicodeChar / getCharacters are intentionally never called. */
    fun key(e: KeyEvent) = KeyRecord(
        t = SystemClock.elapsedRealtime(),
        action = when (e.action) {
            KeyEvent.ACTION_DOWN -> "DOWN"
            KeyEvent.ACTION_UP -> "UP"
            KeyEvent.ACTION_MULTIPLE -> "MULTIPLE"
            else -> "ACTION_${e.action}"
        },
        keyCode = e.keyCode,
        keyName = KeyEvent.keyCodeToString(e.keyCode),
        scanCode = e.scanCode,
        metaState = e.metaState,
        repeatCount = e.repeatCount,
        flags = e.flags,
        source = e.source,
        deviceId = e.deviceId,
        deviceName = InputDevice.getDevice(e.deviceId)?.name,
        eventTime = e.eventTime,
        downTime = e.downTime,
    )

    /** One-line description of every attached input device for the session header. */
    fun deviceList(): List<Map<String, Any?>> = InputDevice.getDeviceIds().toList().mapNotNull { id ->
        InputDevice.getDevice(id)?.let {
            mapOf(
                "id" to it.id,
                "name" to it.name,
                "sources" to "0x%08x".format(it.sources),
                "vendor" to it.vendorId,
                "product" to it.productId,
                "external" to it.isExternal,
            )
        }
    }
}
