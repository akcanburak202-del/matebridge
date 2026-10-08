package dev.matebridge.client.session

import dev.matebridge.client.protocol.Limits
import java.security.SecureRandom

/** Minimal string key-value store so the logic below is JVM-testable (Android impl: SharedPreferences). */
interface KeyValueStore {
    fun getString(key: String): String?
    fun putString(key: String, value: String)

    /**
     * T-191: removes [key] (nothing happens when it is absent). The default body throws so a store that cannot remove
     * fails loudly instead of leaving a value behind; the SharedPreferences adapter implements it.
     */
    fun remove(key: String) {
        throw UnsupportedOperationException("remove not supported")
    }
}

/**
 * T-150: a [KeyValueStore] that can list its keys and apply several writes and removals in one atomic commit. Only the
 * pair-key store needs it (promoting a pending pairing key must never leave a half-written state).
 */
interface AtomicKeyValueStore : KeyValueStore {
    fun keys(): Set<String>

    /**
     * Applies every entry of [changes] (a non-null value is written, null removes the key) in one commit: either all of
     * them hold afterwards or none. Throws [java.io.IOException] when the commit did not persist.
     */
    fun commit(changes: Map<String, String?>)
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

    /** Display mode (T-050, decision 0030); default Günlük, also for an unknown stored value; pre-T-223 ids map via `LegacyModes`. */
    fun streamMode(): dev.matebridge.client.stream.StreamMode =
        dev.matebridge.client.stream.StreamMode.parse(store.getString(KEY_STREAM_MODE))

    fun setStreamMode(m: dev.matebridge.client.stream.StreamMode) = store.putString(KEY_STREAM_MODE, m.id)

    /**
     * "Kare hızı" of [mode] (T-223, decision 0030 §2): each mode remembers its own (Günlük default 120, Oyun default 60);
     * an unknown stored value gives the default; Çizim is always 120 and stores nothing.
     */
    fun modeFps(mode: dev.matebridge.client.stream.StreamMode): Int {
        val key = fpsKey(mode) ?: return mode.resolveFps(null)
        return mode.resolveFps(store.getString(key)?.toIntOrNull())
    }

    /** Stores [fps] for [mode] when it is a selectable rate; Çizim and other values are ignored. */
    fun setModeFps(mode: dev.matebridge.client.stream.StreamMode, fps: Int) {
        val key = fpsKey(mode) ?: return
        if (fps in dev.matebridge.client.stream.StreamMode.FPS_OPTIONS) store.putString(key, fps.toString())
    }

    /** "Oyun çözünürlüğü" (T-215, decision 0029); default 1848×1214, also for an unknown stored value. */
    fun gameResolution(): dev.matebridge.client.stream.GameResolution =
        dev.matebridge.client.stream.GameResolution.parse(store.getString(KEY_GAME_RESOLUTION))

    fun setGameResolution(r: dev.matebridge.client.stream.GameResolution) = store.putString(KEY_GAME_RESOLUTION, r.id)

    /** "HDR" in Oyun (decision 0032, T-238); default off, only a stored "1" enables. */
    fun hdrGame(): Boolean = store.getString(KEY_HDR_GAME) == "1"

    fun setHdrGame(on: Boolean) = store.putString(KEY_HDR_GAME, if (on) "1" else "0")

    /** "HDR" in Günlük (decision 0032 update, T-280): its own setting, apart from Oyun's; default off, only a stored "1" enables. */
    fun hdrDaily(): Boolean = store.getString(KEY_HDR_DAILY) == "1"

    fun setHdrDaily(on: Boolean) = store.putString(KEY_HDR_DAILY, if (on) "1" else "0")

    /** The "HDR" setting of [mode]: Oyun and Günlük each have one; Çizim has none (always SDR, false). */
    fun hdrFor(mode: dev.matebridge.client.stream.StreamMode): Boolean = when {
        mode.isGame -> hdrGame()
        mode.isDrawing -> false
        else -> hdrDaily()
    }

    /** Stores [mode]'s "HDR" setting; ignored for Çizim. */
    fun setHdrFor(mode: dev.matebridge.client.stream.StreamMode, on: Boolean) {
        when {
            mode.isGame -> setHdrGame(on)
            mode.isDrawing -> Unit
            else -> setHdrDaily(on)
        }
    }

    /** Target bit rate (T-105, decision 0013): one of [dev.matebridge.client.stream.Bitrate.OPTIONS_KBPS]; default 0 = Otomatik. */
    fun bitrateKbps(): Long = dev.matebridge.client.stream.Bitrate.sanitize(store.getString(KEY_BITRATE)?.toLongOrNull())

    fun setBitrateKbps(kbps: Long) = store.putString(KEY_BITRATE, dev.matebridge.client.stream.Bitrate.sanitize(kbps).toString())

    /** Clipboard sharing (T-055); default on. */
    fun clipboardShare(): Boolean = store.getString(KEY_CLIPBOARD) != "0"

    fun setClipboardShare(on: Boolean) = store.putString(KEY_CLIPBOARD, if (on) "1" else "0")

    /** "Tablet dosyalarını Mac'te göster" (T-135, decision 0015); default off, only a stored "1" enables. */
    fun filesShare(): Boolean = store.getString(KEY_FILES) == "1"

    fun setFilesShare(on: Boolean) = store.putString(KEY_FILES, if (on) "1" else "0")

    /** Shared folder (T-190, decision 0028); default the MateBridge folder, also for an unknown stored value. */
    fun filesRoot(): dev.matebridge.client.files.FilesRoot = dev.matebridge.client.files.FilesRoot.parse(store.getString(KEY_FILES_ROOT))

    fun setFilesRoot(r: dev.matebridge.client.files.FilesRoot) = store.putString(KEY_FILES_ROOT, r.id)

    /** Read-only file sharing (T-190, decision 0028); default off, only a stored "1" enables. */
    fun filesReadOnly(): Boolean = store.getString(KEY_FILES_RO) == "1"

    fun setFilesReadOnly(on: Boolean) = store.putString(KEY_FILES_RO, if (on) "1" else "0")

    /** The scope the next file server start uses (T-190). */
    fun filesScope(): dev.matebridge.client.files.FilesScope = dev.matebridge.client.files.FilesScope(filesRoot(), filesReadOnly())

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

    /**
     * "İmleç" (T-276, decision 0036): true = "Tablette" (the tablet draws the cursor; the default, also for an unknown stored
     * value), false = "Görüntüde" (the cursor stays in the video). Only a stored "0" means "Görüntüde".
     */
    fun cursorLocal(): Boolean = store.getString(KEY_CURSOR) != "0"

    fun setCursorLocal(on: Boolean) = store.putString(KEY_CURSOR, if (on) "1" else "0")

    /** Connection mode (T-096). AUTO when nothing (or nothing valid) is stored. */
    fun transportMode(): TransportMode = TransportMode.fromSetting(store.getString(KEY_TRANSPORT))

    fun setTransportMode(m: TransportMode) = store.putString(KEY_TRANSPORT, m.id)

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

    /**
     * T-191 "Varsayılanlara dön": removes every user setting ([USER_KEYS]) so each getter returns its default. Only that
     * explicit list goes: the device id (the host's approval of this tablet), the last endpoint, the T-096 migration
     * flag and the learned Wake-on-LAN data share this store and stay. Returns how many keys were present.
     */
    fun resetToDefaults(): Int {
        var removed = 0
        for (k in USER_KEYS) {
            if (store.getString(k) == null) continue
            store.remove(k)
            removed++
        }
        return removed
    }

    private fun fpsKey(mode: dev.matebridge.client.stream.StreamMode): String? = when (mode) {
        dev.matebridge.client.stream.StreamMode.DAILY -> KEY_FPS_DAILY
        dev.matebridge.client.stream.StreamMode.GAME -> KEY_FPS_GAME
        dev.matebridge.client.stream.StreamMode.DRAWING -> null
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
        /** T-191: every user setting [resetToDefaults] removes (and nothing else). */
        val USER_KEYS: List<String> get() = listOf(
            KEY_STATS, KEY_STREAM_MODE, KEY_BITRATE, KEY_PAD_SPEED, KEY_MOUSE_SPEED, KEY_CLIPBOARD, KEY_FILES,
            KEY_FILES_ROOT, KEY_FILES_RO, KEY_AUDIO, KEY_AUDIO_OUT, KEY_PEN_TRAIL, KEY_PEN_DOT, KEY_FINGER_OFF,
            KEY_TRANSPORT, KEY_GAME_RESOLUTION, KEY_FPS_DAILY, KEY_FPS_GAME, KEY_HDR_GAME, KEY_HDR_DAILY, KEY_CURSOR,
        )

        const val KEY_DEVICE_ID = "device_id"
        const val KEY_ENDPOINT = "last_endpoint"
        const val KEY_TRANSPORT = "transport"
        const val KEY_STATS = "stats_overlay"
        const val KEY_STREAM_MODE = "stream_mode"
        const val KEY_BITRATE = "bitrate_kbps"
        const val KEY_GAME_RESOLUTION = "game_resolution"
        const val KEY_FPS_DAILY = "fps_daily"
        const val KEY_FPS_GAME = "fps_game"
        const val KEY_HDR_GAME = "hdr_game"
        const val KEY_HDR_DAILY = "hdr_daily"
        const val KEY_PAD_SPEED = "touchpad_speed"
        const val KEY_MOUSE_SPEED = "mouse_speed"
        const val KEY_CLIPBOARD = "clipboard_share"
        const val KEY_FILES = "files_share"
        const val KEY_FILES_ROOT = "files_root"
        const val KEY_FILES_RO = "files_read_only"
        const val KEY_AUDIO = "audio_enabled"
        const val KEY_AUDIO_OUT = "audio_out"
        const val KEY_PEN_TRAIL = "pen_trail"
        const val KEY_PEN_DOT = "pen_dot"
        const val KEY_FINGER_OFF = "finger_touch_disabled"
        const val KEY_CURSOR = "cursor_local"
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
