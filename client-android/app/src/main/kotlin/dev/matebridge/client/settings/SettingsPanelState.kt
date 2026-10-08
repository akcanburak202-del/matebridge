package dev.matebridge.client.settings

import dev.matebridge.client.input.KeyFrame
import dev.matebridge.client.input.KeyTracker
import dev.matebridge.client.input.LocalAction

/**
 * Open/closed state of the in-stream settings panel (T-105, decision 0013). Pure Kotlin, UI thread only.
 *
 * Input contract (enforced by MainActivity through [inputAllowed]): while the panel is open no input reaches the Mac.
 * The activity turns input capture off when the panel opens, which makes [dev.matebridge.client.input.InputCapture]
 * send the natural releases and then `RELEASE_ALL(USER)` before anything else happens, and releases pointer capture so
 * the panel can be touched. Keyboard events go to [keyWhileOpen] instead of the key tracker, so no KEY is produced.
 */
class SettingsPanelState(
    /** `ev=settings_panel action=open|close|ignored via=…` lines (docs/LOGGING.md key=value): no key or text data, ever. */
    private val onEvent: (String, String) -> Unit = { _, _ -> },
) {
    /** How the panel was opened or closed (the `via=` log field). */
    enum class Via(val logName: String) {
        SHORTCUT("shortcut"), HOST("host"), ESC("esc"), BACK("back"), TAP_OUTSIDE("tap_outside"), CLOSE_BUTTON("close_button"),
        BACKGROUND("background"), STREAM_END("stream_end"), DISCONNECT("disconnect"),
    }

    /** What the activity does with a physical-keyboard event while the panel is open. */
    sealed interface KeyResult {
        /** Close the panel; the event is consumed. */
        data object Close : KeyResult
        /** A tablet-only chord (stats, pointer speed, display mode, background); consumed, never sent. */
        data class Local(val action: LocalAction) : KeyResult
        /** Consumed and dropped (repeats/UPs of chords, BACK): never reaches the Mac nor the views. */
        data object Consume : KeyResult
        /** Handed to Android (the panel's views: focus navigation, buttons). Never sent to the Mac. */
        data object Pass : KeyResult
    }

    var isOpen = false
        private set

    /** Opens the panel when the stream is visible; false (and nothing happens) when it is already open or not streaming. */
    fun open(via: Via, streaming: Boolean): Boolean {
        if (isOpen) return false
        if (!streaming) {
            onEvent("settings_panel", "action=ignored via=${via.logName} reason=not_streaming")
            return false
        }
        isOpen = true
        onEvent("settings_panel", "action=open via=${via.logName}")
        return true
    }

    /** Closes the panel; false when it was not open. */
    fun close(via: Via): Boolean {
        if (!isOpen) return false
        isOpen = false
        onEvent("settings_panel", "action=close via=${via.logName}")
        return true
    }

    /** Input goes to the Mac only when it would otherwise ([base]) and the panel is closed. */
    fun inputAllowed(base: Boolean): Boolean = base && !isOpen

    companion object {
        /**
         * Physical-keyboard events while the panel is open. Esc (also when it arrives as BACK) and Ctrl+Shift+6 close the
         * panel on their first DOWN; their repeats and UPs, and every BACK, are consumed so neither the Mac nor Android's
         * "back" (which would finish the activity) sees them. The other tablet chords keep working. Everything else goes
         * to the views. The events closing the panel leave nothing pressed on the Mac: after the panel closed, the key
         * tracker has no DOWN for them and drops their UPs.
         */
        fun keyWhileOpen(f: KeyFrame): KeyResult {
            val chord = KeyTracker.localChord(f)
            val esc = f.keyCode == KeyTracker.KEYCODE_ESCAPE || (f.scanCode == SCAN_ESC && f.keyCode == KeyTracker.KEYCODE_BACK)
            val first = f.down && f.repeatCount == 0
            return when {
                chord == LocalAction.SETTINGS -> if (first) KeyResult.Close else KeyResult.Consume
                // Ctrl+Shift+Esc keeps its meaning (back to Android); onPause closes the panel.
                chord != LocalAction.NONE -> if (first) KeyResult.Local(chord) else KeyResult.Consume
                esc -> if (first) KeyResult.Close else KeyResult.Consume
                f.keyCode == KeyTracker.KEYCODE_BACK -> KeyResult.Consume
                else -> KeyResult.Pass
            }
        }

        private const val SCAN_ESC = 1
    }
}
