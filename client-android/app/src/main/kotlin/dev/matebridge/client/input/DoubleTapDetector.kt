package dev.matebridge.client.input

/**
 * M-Pencil double tap (PROTOCOL.md PEN_GESTURE). The pencil shows up as a separate Bluetooth input
 * device that reports keyCode 718 / scanCode 190 as two short DOWN/UP pairs per double tap.
 * Two DOWNs within [WINDOW_MS] make one DOUBLE_TAP; further DOWNs within [LOCKOUT_MS] after it are
 * ignored so a burst never fires twice. The key events themselves are always consumed (never KEY).
 */
class DoubleTapDetector {
    private var firstMs = NONE
    private var firedMs = NONE

    /** Feed one gesture-key DOWN (repeatCount 0) at [timeMs]. Returns true when a DOUBLE_TAP must be sent. */
    fun onDown(timeMs: Long): Boolean {
        if (firedMs != NONE && timeMs - firedMs in 0..LOCKOUT_MS) return false
        val first = firstMs
        if (first != NONE && timeMs - first in 0..WINDOW_MS) {
            firstMs = NONE
            firedMs = timeMs
            return true
        }
        firstMs = timeMs
        return false
    }

    fun reset() {
        firstMs = NONE
        firedMs = NONE
    }

    companion object {
        const val WINDOW_MS = 500L
        const val LOCKOUT_MS = 400L
        const val KEYCODE = 718
        const val SCANCODE = 190
        private const val NONE = Long.MIN_VALUE

        /**
         * True for the pencil gesture key. Scan code 190 alone is also Linux KEY_F20 on ordinary keyboards,
         * so it only counts when Android left the key code unmapped (KEYCODE_UNKNOWN = 0).
         */
        fun isGestureKey(keyCode: Int, scanCode: Int) =
            keyCode == KEYCODE || (keyCode == 0 && scanCode == SCANCODE)
    }
}
