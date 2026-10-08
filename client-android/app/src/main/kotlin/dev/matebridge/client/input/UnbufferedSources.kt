package dev.matebridge.client.input

import android.view.InputDevice
import java.util.Locale

/**
 * T-322 (EN3): the unbuffered-dispatch mask for `View.requestUnbufferedDispatch(int)` (`--es unbuffered_src off|relative`,
 * developer gate). Pure; the platform call stays in MainActivity.
 *
 * ViewRootImpl matches a request with `(eventSource & mask) != 0`. `SOURCE_STYLUS` (0x4002) carries the pointer-class bit
 * (`SOURCE_CLASS_POINTER` 0x2), so the pen request already covers every pointer-class source: touchscreen and the
 * absolute mouse. The sources it does NOT cover are the relative / captured pointer (`SOURCE_MOUSE_RELATIVE`, trackball
 * class 0x4) and the touchpad (`SOURCE_TOUCHPAD`, position class 0x8); [RELATIVE] adds exactly those.
 */
enum class UnbufferedSources(val id: String, val extraMask: Int, val label: String) {
    /** Today's mask: the stylus source, which already matches the pointer class (stylus, touchscreen, absolute mouse). */
    OFF("off", 0, "pointer_class(stylus,touch,mouse)"),
    RELATIVE(
        "relative",
        InputDevice.SOURCE_MOUSE_RELATIVE or InputDevice.SOURCE_TOUCHPAD,
        "pointer_class(stylus,touch,mouse)+mouse_rel+touchpad",
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
