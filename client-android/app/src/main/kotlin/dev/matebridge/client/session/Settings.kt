package dev.matebridge.client.session

import dev.matebridge.client.protocol.Limits
import java.security.SecureRandom

/** Minimal string key-value store so the logic below is JVM-testable (Android impl: SharedPreferences). */
interface KeyValueStore {
    fun getString(key: String): String?
    fun putString(key: String, value: String)
}

/** Persistent settings: the random per-install device id and the last manually entered endpoint. */
class Settings(private val store: KeyValueStore, private val random: java.util.Random = SecureRandom()) {
    /** 16 random bytes generated on first use, then stable (PROTOCOL.md HELLO.device_id). */
    fun deviceId(): ByteArray {
        store.getString(KEY_DEVICE_ID)?.let { hex ->
            val bytes = fromHex(hex)
            if (bytes != null && bytes.size == Limits.DEVICE_ID_BYTES) return bytes
        }
        val fresh = ByteArray(Limits.DEVICE_ID_BYTES).also { random.nextBytes(it) }
        store.putString(KEY_DEVICE_ID, toHex(fresh))
        return fresh
    }

    fun lastEndpoint(): Endpoint? = store.getString(KEY_ENDPOINT)?.let { Endpoint.parse(it) }

    fun saveEndpoint(endpoint: Endpoint) = store.putString(KEY_ENDPOINT, endpoint.toString())

    /** Whether the on-screen statistics overlay is enabled (default off). */
    fun statsOverlay(): Boolean = store.getString(KEY_STATS) == "1"

    fun setStatsOverlay(on: Boolean) = store.putString(KEY_STATS, if (on) "1" else "0")

    /** Display mode (T-050); default Akıcı. */
    fun streamMode(): dev.matebridge.client.stream.StreamMode =
        dev.matebridge.client.stream.StreamMode.parse(store.getString(KEY_STREAM_MODE))

    fun setStreamMode(m: dev.matebridge.client.stream.StreamMode) = store.putString(KEY_STREAM_MODE, m.id)

    /** Clipboard sharing (T-055); default on. */
    fun clipboardShare(): Boolean = store.getString(KEY_CLIPBOARD) != "0"

    fun setClipboardShare(on: Boolean) = store.putString(KEY_CLIPBOARD, if (on) "1" else "0")

    /** Mac audio on the tablet (T-095); default on, only a stored "0" disables. */
    fun audioEnabled(): Boolean = store.getString(KEY_AUDIO) != "0"

    fun setAudioEnabled(on: Boolean) = store.putString(KEY_AUDIO, if (on) "1" else "0")

    /**
     * Audio output ("Ses çıkışı", T-101): AUTO ("Düşük gecikme", AAudio MMAP; the default, also for an unknown stored
     * value) or TRACK ("Uyumlu", AudioTrack). The `--es audio_out` launch extra overrides it and is never stored here.
     */
    fun audioOut(): dev.matebridge.client.audio.AudioOutPref =
        dev.matebridge.client.audio.AudioOutPref.parse(store.getString(KEY_AUDIO_OUT))
            ?: dev.matebridge.client.audio.AudioOutPref.AUTO

    fun setAudioOut(p: dev.matebridge.client.audio.AudioOutPref) = store.putString(KEY_AUDIO_OUT, p.id)

    /** Local pen trail and pen dot (T-056); both default off (T-064); only a stored "1" enables. */
    fun penTrail(): Boolean = store.getString(KEY_PEN_TRAIL) == "1"

    fun setPenTrail(on: Boolean) = store.putString(KEY_PEN_TRAIL, if (on) "1" else "0")

    fun penDot(): Boolean = store.getString(KEY_PEN_DOT) == "1"

    fun setPenDot(on: Boolean) = store.putString(KEY_PEN_DOT, if (on) "1" else "0")

    /** Connection mode (T-096). AUTO when nothing (or nothing valid) is stored. */
    fun transportMode(): TransportMode = TransportMode.fromSetting(store.getString(KEY_TRANSPORT))

    fun setTransportMode(m: TransportMode) = store.putString(KEY_TRANSPORT, m.id)

    /**
     * T-096 one-time migration (orchestrator decision): a `usb`/`wifi` stored before T-096 is reset to AUTO once, because
     * the user asked for automatic switching and had probably tapped a transport button long ago. The flag is set
     * either way, so every later panel choice (including `usb`/`wifi`) is respected. Returns the replaced value, or
     * null when nothing was changed.
     */
    fun migrateTransportToAutoOnce(): String? {
        if (store.getString(KEY_TRANSPORT_AUTO_MIGRATED) == "1") return null
        val old = store.getString(KEY_TRANSPORT)
        if (old != null && old != TransportMode.AUTO.id) store.putString(KEY_TRANSPORT, TransportMode.AUTO.id)
        store.putString(KEY_TRANSPORT_AUTO_MIGRATED, "1")
        return old?.takeIf { it != TransportMode.AUTO.id }
    }

    /**
     * "Parmak dokunmasını tamamen kapat" (decision 0006): when on, finger touches are never sent.
     * Default off, so fingers work unless the user turns them off.
     */
    fun fingerTouchDisabled(): Boolean = store.getString(KEY_FINGER_OFF) == "1"

    fun setFingerTouchDisabled(off: Boolean) = store.putString(KEY_FINGER_OFF, if (off) "1" else "0")

    /** Touchpad / mouse cursor speed multiplier (T-035): default 1.0, always within [SpeedRange]. Scrolling is not affected. */
    fun touchpadSpeed(): Float = readSpeed(KEY_PAD_SPEED)

    fun mouseSpeed(): Float = readSpeed(KEY_MOUSE_SPEED)

    fun setTouchpadSpeed(v: Float) = store.putString(KEY_PAD_SPEED, SpeedRange.clamp(v).toString())

    fun setMouseSpeed(v: Float) = store.putString(KEY_MOUSE_SPEED, SpeedRange.clamp(v).toString())

    /** Multiplies the mouse's or touchpad's speed by [factor], persists it (clamped) and returns the new value. */
    fun adjustSpeed(mouse: Boolean, factor: Float): Float {
        val v = SpeedRange.clamp((if (mouse) mouseSpeed() else touchpadSpeed()) * factor)
        if (mouse) setMouseSpeed(v) else setTouchpadSpeed(v)
        return v
    }

    private fun readSpeed(key: String): Float = store.getString(key)?.toFloatOrNull()?.let { SpeedRange.clamp(it) } ?: 1f

    private fun toHex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }

    private fun fromHex(s: String): ByteArray? {
        if (s.length % 2 != 0) return null
        return try {
            ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        } catch (e: NumberFormatException) {
            null
        }
    }

    private companion object {
        const val KEY_DEVICE_ID = "device_id"
        const val KEY_ENDPOINT = "last_endpoint"
        const val KEY_TRANSPORT = "transport"
        const val KEY_TRANSPORT_AUTO_MIGRATED = "transport_auto_migrated"
        const val KEY_STATS = "stats_overlay"
        const val KEY_STREAM_MODE = "stream_mode"
        const val KEY_PAD_SPEED = "touchpad_speed"
        const val KEY_MOUSE_SPEED = "mouse_speed"
        const val KEY_CLIPBOARD = "clipboard_share"
        const val KEY_AUDIO = "audio_enabled"
        const val KEY_AUDIO_OUT = "audio_out"
        const val KEY_PEN_TRAIL = "pen_trail"
        const val KEY_PEN_DOT = "pen_dot"
        const val KEY_FINGER_OFF = "finger_touch_disabled"
    }
}

/** Allowed range of the user speed multipliers (T-035) and the local shortcut steps. */
object SpeedRange {
    const val MIN = 0.25f
    const val MAX = 3.0f
    const val STEP_DOWN = 0.85f
    const val STEP_UP = 1.15f

    /** NaN and infinities fall back to 1.0. */
    fun clamp(v: Float): Float = if (v.isNaN() || v.isInfinite()) 1f else v.coerceIn(MIN, MAX)

    /** Toast text, e.g. "Touchpad hızı: 0,85" (decimal comma). */
    fun label(mouse: Boolean, v: Float): String =
        (if (mouse) "Fare" else "Touchpad") + " hızı: " + String.format(java.util.Locale.forLanguageTag("tr"), "%.2f", v)
}

/** Truncates to at most [maxBytes] UTF-8 bytes without splitting a code point (str8 limit is 64). */
fun truncateUtf8(s: String, maxBytes: Int = Limits.STR8_MAX_BYTES): String {
    var bytes = 0
    var i = 0
    while (i < s.length) {
        val cp = s.codePointAt(i)
        val n = when {
            cp < 0x80 -> 1
            cp < 0x800 -> 2
            cp < 0x10000 -> 3
            else -> 4
        }
        if (bytes + n > maxBytes) break
        bytes += n
        i += Character.charCount(cp)
    }
    return s.substring(0, i)
}
