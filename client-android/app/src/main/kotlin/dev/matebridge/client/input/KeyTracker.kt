package dev.matebridge.client.input

import dev.matebridge.client.protocol.Key

/** One physical-keyboard KeyEvent, reduced to what the tracker needs (T-033). No characters, ever (decision 0003). */
class KeyFrame(
    val deviceId: Int,
    val scanCode: Int,
    val keyCode: Int,
    val down: Boolean,
    val repeatCount: Int,
    val ctrl: Boolean,
    val shift: Boolean,
    /** `metaState & META_CAPS_LOCK_ON` of the event (state after the event). */
    val capsOn: Boolean,
    val timeUs: Long,
)

/** A Ctrl+Shift+key chord handled on the tablet only (T-033, T-035); never reaches the Mac. */
enum class LocalAction { NONE, STATS, SPEED_DOWN, SPEED_UP, BACKGROUND, STREAM_MODE, SETTINGS }

/** What the activity does with the event: [consumed] keeps it from Android; [local] is a tablet-only chord to perform. */
class KeyDecision(val consumed: Boolean, val local: LocalAction = LocalAction.NONE, val out: List<Outgoing> = emptyList()) {
    /** Ctrl+Shift+F3 was pressed: flip the stats overlay. */
    val localToggle get() = local == LocalAction.STATS
}

/**
 * Pressed-key bookkeeping for the physical keyboard (PROTOCOL.md section 4 KEY, section 7). Every DOWN that is sent is
 * remembered by (device, key identity); its UP is sent exactly once and only for remembered keys, so a release-all
 * followed by a late physical UP never produces an UP the host did not expect. Plain Kotlin, UI thread only.
 */
class KeyTracker {
    private class Held(val scanCode: Int, val keyCode: Int)

    private val held = LinkedHashMap<Pair<Int, Int>, Held>()

    /** Local chord presses (Ctrl+Shift+F1/F2/F3/7/Esc): their duplicate DOWNs and their UP stay local until UP, detach or reset. */
    private val localOnly = HashSet<Pair<Int, Int>>()
    private var lastCaps = false

    val heldCount get() = held.size

    /** The wire has no device: the host sees one key identity, so DOWN/UP go out for the first/last holder only. */
    private fun otherHolder(k: Pair<Int, Int>) = held.keys.any { it.second == k.second && it.first != k.first }

    /** Used while the session accepts input. */
    fun onKey(f: KeyFrame): KeyDecision {
        val id = keyId(f.scanCode, f.keyCode)
        if (id == null) return KeyDecision(true)
        val k = f.deviceId to id
        if (k in localOnly) {
            if (!f.down) localOnly.remove(k)
            return KeyDecision(true)
        }
        // A held F-key (DOWN already sent) must still get its UP even if Ctrl+Shift came down meanwhile.
        val chord = localChord(f)
        if (chord != LocalAction.NONE && k !in held) {
            val fire = f.down && f.repeatCount == 0
            if (fire) localOnly += k
            return KeyDecision(consumed = true, local = if (fire) chord else LocalAction.NONE)
        }
        if (f.keyCode == KEYCODE_BACK) return KeyDecision(true) // Esc also produces BACK (scan 1): never sent
        lastCaps = f.capsOn
        if (f.down) {
            if (f.repeatCount > 0 || k in held) return KeyDecision(true)
            val dup = otherHolder(k)
            held[k] = Held(f.scanCode, f.keyCode)
            if (dup) return KeyDecision(true)
            return KeyDecision(true, out = listOf(Outgoing(Key(f.timeUs, f.scanCode, f.keyCode, Key.DOWN, lock(f.capsOn)))))
        }
        val h = held.remove(k) ?: return KeyDecision(true)
        if (otherHolder(k)) return KeyDecision(true)
        return KeyDecision(true, out = listOf(Outgoing(Key(f.timeUs, h.scanCode, h.keyCode, Key.UP, lock(f.capsOn)))))
    }

    /** Keyboard detached: UP for every key identity that only this device still held. */
    fun releaseDevice(deviceId: Int, timeUs: Long): List<Outgoing> {
        localOnly.removeAll { it.first == deviceId }
        val outs = ArrayList<Outgoing>()
        val it = held.entries.iterator()
        while (it.hasNext()) {
            val e = it.next()
            if (e.key.first != deviceId) continue
            it.remove()
            if (otherHolder(e.key)) continue
            outs += Outgoing(Key(timeUs, e.value.scanCode, e.value.keyCode, Key.UP, lock(lastCaps)))
        }
        return outs
    }

    fun holdsDevice(deviceId: Int) = held.keys.any { it.first == deviceId } || localOnly.any { it.first == deviceId }

    /** The host released everything (RELEASE_ALL) or the session is gone: forget without sending. */
    fun reset() {
        held.clear()
        localOnly.clear()
    }

    private fun lock(caps: Boolean) = if (caps) Key.LOCK_CAPS else 0

    companion object {
        const val KEYCODE_BACK = 4
        const val KEYCODE_ESCAPE = 111
        const val KEYCODE_F1 = 131
        const val KEYCODE_F2 = 132
        const val KEYCODE_F3 = 133
        private const val SCAN_ESC = 1
        private const val SCAN_F1 = 59
        private const val SCAN_F2 = 60
        private const val SCAN_F3 = 61
        // Number row by physical position (evdev): 8, 9, 0 mirror F3, F1, F2 for keyboards without F keys (T-038).
        private const val SCAN_6 = 7 // Ctrl+Shift+6 opens/closes the in-stream settings panel (T-105, decision 0013)
        private const val SCAN_7 = 8 // Ctrl+Shift+7 cycles the display mode (T-050)
        private const val SCAN_8 = 9
        private const val SCAN_9 = 10
        private const val SCAN_0 = 11

        /** PROTOCOL.md: `scan_code` if known, else `0x10000 + android_key_code`; null when both are 0 (not sent). */
        fun keyId(scanCode: Int, keyCode: Int): Int? = when {
            scanCode != 0 -> scanCode
            keyCode != 0 -> 0x10000 + keyCode
            else -> null
        }

        /** Ctrl+Shift+F3 toggles the stats overlay locally and never reaches the Mac. */
        fun isStatsToggle(f: KeyFrame) = localChord(f) == LocalAction.STATS

        /**
         * The tablet-only chord this event belongs to, or NONE: Ctrl+Shift+F1 / F2 (pointer speed down / up), F3 (stats), or 9 / 0 / 8 by scan code,
         * 7 (display mode), 6 (settings panel), Esc (back to Android). Matched by key code or the Linux scan code, because Esc may arrive as BACK.
         */
        fun localChord(f: KeyFrame): LocalAction {
            if (!f.ctrl || !f.shift) return LocalAction.NONE
            return when {
                f.keyCode == KEYCODE_F1 || f.scanCode == SCAN_F1 || f.scanCode == SCAN_9 -> LocalAction.SPEED_DOWN
                f.keyCode == KEYCODE_F2 || f.scanCode == SCAN_F2 || f.scanCode == SCAN_0 -> LocalAction.SPEED_UP
                f.keyCode == KEYCODE_F3 || f.scanCode == SCAN_F3 || f.scanCode == SCAN_8 -> LocalAction.STATS
                f.scanCode == SCAN_7 -> LocalAction.STREAM_MODE
                f.scanCode == SCAN_6 -> LocalAction.SETTINGS
                f.keyCode == KEYCODE_ESCAPE || (f.scanCode == SCAN_ESC && f.keyCode == KEYCODE_BACK) -> LocalAction.BACKGROUND
                else -> LocalAction.NONE
            }
        }

        /**
         * A real typing keyboard: not a virtual device, source has SOURCE_KEYBOARD (0x101), and alphabetic key type
         * (2), which keeps the tablet's own volume/power keys out of the KEY stream.
         */
        fun isPhysicalKeyboard(virtual: Boolean, source: Int, keyboardType: Int): Boolean =
            !virtual && (source and SOURCE_KEYBOARD) == SOURCE_KEYBOARD && keyboardType == KEYBOARD_TYPE_ALPHABETIC

        private const val SOURCE_KEYBOARD = 0x101
        private const val KEYBOARD_TYPE_ALPHABETIC = 2
    }
}
