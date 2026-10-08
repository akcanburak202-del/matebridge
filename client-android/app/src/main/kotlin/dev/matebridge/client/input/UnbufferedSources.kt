package dev.matebridge.client.input

import android.view.InputDevice
import java.util.Locale

/**
 * T-322 (EN3): which input sources ask for unbuffered dispatch besides the pen (`--es unbuffered_src off|touch|all`,
 * developer gate). Pure; the platform call stays in MainActivity. The pen's source is always part of the mask, the
 * extra sources are added to the same single `View.requestUnbufferedDispatch(int)` mask.
 */
enum class UnbufferedSources(val id: String, val extraMask: Int, val label: String) {
    OFF("off", 0, "stylus"),
    TOUCH("touch", InputDevice.SOURCE_TOUCHSCREEN, "stylus+touch"),
    ALL(
        "all",
        InputDevice.SOURCE_TOUCHSCREEN or InputDevice.SOURCE_MOUSE or InputDevice.SOURCE_TOUCHPAD or InputDevice.SOURCE_MOUSE_RELATIVE,
        "stylus+touch+mouse+touchpad+mouse_rel",
    );

    /** The mask for the request: stylus plus the extras of this mode. */
    val requestMask: Int get() = InputDevice.SOURCE_STYLUS or extraMask

    companion object {
        /** Unknown or absent values mean [OFF]; the raw value is never logged. */
        fun parse(raw: String?): UnbufferedSources {
            val v = raw?.trim()?.lowercase(Locale.ROOT) ?: return OFF
            return values().firstOrNull { it.id == v } ?: OFF
        }
    }
}
