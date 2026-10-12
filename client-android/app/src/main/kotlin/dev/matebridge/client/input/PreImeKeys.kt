package dev.matebridge.client.input

import android.content.Context
import android.util.AttributeSet
import android.view.KeyEvent
import android.widget.FrameLayout

/** T-342: pure ownership rules for physical-keyboard keys around the IME stage. */
object PreImeKeys {
    /** What [lateDisposition] says to do with an event that reached the activity's dispatchKeyEvent. */
    enum class Late { ROUTE, DROP, RELEASE_ONLY }

    /**
     * Pre-IME, while the stream is on screen: every physical-keyboard key and the pen double-tap key belong to
     * MateBridge (routed, then always consumed). On the connect panel nothing is owned (the IME path stays as is).
     */
    fun ownsPreIme(streaming: Boolean, physicalKeyboard: Boolean, gestureKey: Boolean): Boolean =
        streaming && (physicalKeyboard || gestureKey)

    /**
     * Activity dispatchKeyEvent, while streaming: a physical-keyboard event can only arrive here if it entered the IME
     * before the transition, so it is stale. A stale DOWN (or repeat) is dropped, a stale UP is routed so the key
     * tracker can release a held key (it ignores an UP it has no DOWN for). Anything else is routed as before.
     */
    fun lateDisposition(streaming: Boolean, physicalKeyboard: Boolean, down: Boolean): Late = when {
        !streaming || !physicalKeyboard -> Late.ROUTE
        down -> Late.DROP
        else -> Late.RELEASE_ONLY
    }
}

/** Root view that offers key events to [handler] in the pre-IME stage (before an input method can consume them). */
class PreImeFrameLayout @JvmOverloads constructor(c: Context, a: AttributeSet? = null) : FrameLayout(c, a) {
    var handler: ((KeyEvent) -> Boolean)? = null
    override fun dispatchKeyEventPreIme(event: KeyEvent): Boolean = handler?.invoke(event) == true || super.dispatchKeyEventPreIme(event)
}
