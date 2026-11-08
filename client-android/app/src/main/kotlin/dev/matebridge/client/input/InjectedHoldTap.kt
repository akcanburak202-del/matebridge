package dev.matebridge.client.input

import android.view.InputDevice
import android.view.MotionEvent

/**
 * T-390 (decision 0044): the host keeps the Huawei panel at 120 Hz over USB with `adb shell input touchscreen tap 2 2`
 * about once a second. That tap must never reach the Mac or count as user activity. It is recognised by what it is:
 * a touchscreen-source, single-finger DOWN in the top-left corner (x, y <= [CORNER_PX]) from a device that is not a
 * real input device (unknown `deviceId`, or `isVirtual`; on the MatePad it is deviceId -1). Real devices (touchscreen,
 * pen, touchpad, mouse) are never swallowed, wherever they touch. Other adb taps (test tools) pass as before.
 *
 * The verdict is made on DOWN; every later event of the same `deviceId` is swallowed up to its UP/CANCEL. Pure logic:
 * the platform lookups are passed in. It touches no input state of the capture pipeline.
 */
class InjectedHoldTap {
    private val swallowing = HashSet<Int>()
    private var total = 0
    private var loggedTotal = 0
    private var lastLogMs = Long.MIN_VALUE

    /** Number of taps swallowed so far (one per DOWN). */
    val swallowedCount: Int get() = total

    /**
     * Returns true when the event belongs to a swallowed hold tap. [isRealDevice] is evaluated only for a DOWN that
     * already passed the cheap checks (source, finger count, corner).
     */
    fun onTouch(
        actionMasked: Int,
        deviceId: Int,
        source: Int,
        pointerCount: Int,
        rawX: Float,
        rawY: Float,
        isRealDevice: () -> Boolean,
    ): Boolean {
        if (actionMasked == MotionEvent.ACTION_DOWN) {
            val hit = (source and InputDevice.SOURCE_TOUCHSCREEN) == InputDevice.SOURCE_TOUCHSCREEN &&
                pointerCount == 1 && rawX <= CORNER_PX && rawY <= CORNER_PX && !isRealDevice()
            if (hit) {
                swallowing.add(deviceId)
                total++
            } else {
                swallowing.remove(deviceId) // an earlier swallowed gesture of this device lost its UP
            }
            return hit
        }
        if (!swallowing.contains(deviceId)) return false
        if (actionMasked == MotionEvent.ACTION_UP || actionMasked == MotionEvent.ACTION_CANCEL) swallowing.remove(deviceId)
        return true
    }

    /** Background or focus loss: a swallowed gesture without UP leaves nothing behind. */
    fun reset() = swallowing.clear()

    /** The running total for a log line, at most every [LOG_INTERVAL_MS] and only if it changed; null otherwise. */
    fun takeLog(nowMs: Long): Int? {
        if (total == loggedTotal) return null
        if (lastLogMs != Long.MIN_VALUE && nowMs - lastLogMs < LOG_INTERVAL_MS) return null
        lastLogMs = nowMs
        loggedTotal = total
        return total
    }

    companion object {
        const val CORNER_PX = 4f
        const val LOG_INTERVAL_MS = 30_000L
    }
}
