package dev.matebridge.client.input

import android.content.Context
import android.util.AttributeSet
import android.view.KeyEvent
import android.widget.FrameLayout

/** T-342: pure routing decision and "routed exactly once" bookkeeping for keys taken before the IME stage. */
class PreImeKeys {
    private var seen: Long = NONE_KEY

    /** The pre-IME path owns physical-keyboard keys while the stream is on screen, and nothing on the connect panel. */
    fun owns(streamVisible: Boolean): Boolean = streamVisible

    /** Remember an event the pre-IME path routed but did not consume, so the activity does not route it again. */
    fun markRouted(deviceId: Int, keyCode: Int, action: Int, repeat: Int, eventTime: Long) {
        seen = sig(deviceId, keyCode, action, repeat, eventTime)
    }

    /** True once per marked event: the activity skips its own routing for it. */
    fun consumeIfRouted(deviceId: Int, keyCode: Int, action: Int, repeat: Int, eventTime: Long): Boolean {
        if (seen == NONE_KEY || seen != sig(deviceId, keyCode, action, repeat, eventTime)) return false
        seen = NONE_KEY
        return true
    }

    private fun sig(d: Int, k: Int, a: Int, r: Int, t: Long): Long =
        t * 31 + ((d * 31 + k) * 31 + a) * 31 + r + 1

    private companion object { const val NONE_KEY = Long.MIN_VALUE }
}

/** Root view that offers key events to [handler] in the pre-IME stage (before an input method can consume them). */
class PreImeFrameLayout @JvmOverloads constructor(c: Context, a: AttributeSet? = null) : FrameLayout(c, a) {
    var handler: ((KeyEvent) -> Boolean)? = null
    override fun dispatchKeyEventPreIme(event: KeyEvent): Boolean = handler?.invoke(event) == true || super.dispatchKeyEventPreIme(event)
}
