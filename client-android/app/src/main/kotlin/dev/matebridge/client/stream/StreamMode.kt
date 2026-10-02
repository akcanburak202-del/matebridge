package dev.matebridge.client.stream

import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.StreamPrefs

/**
 * The user-selectable display modes (T-050), the single table of fps / encoded-size pairs. The choice is a request
 * (PROTOCOL.md STREAM_PREFS): the host applies the nearest thing it supports and answers with a STREAM_CONFIG.
 */
enum class StreamMode(val id: String, val label: String, val fps: Int, val scalePermille: Int) {
    CLARITY("clarity", "Netlik", 60, 1000),
    SMOOTH("smooth", "Akıcı", 120, 1000),

    /** Decision 0017: stable 120 fps at near-full sharpness for pen drawing (decoder ceiling ~135 fps at 90 percent). */
    DRAWING("drawing", "Çizim", 120, 900),
    PERFORMANCE("performance", "Performans", 120, 750),

    /** Decision 0014: games; lowest latency (jitter buffer 0) and temporary defaults ([GameModeSettings]). */
    GAME("game", "Oyun 120", 120, 660),

    /** Decision 0016: the same game behaviour at 60 fps and full resolution (keyboard/gamepad games, panel stays 60 Hz). */
    GAME60("game60", "Oyun 60", 60, 1000);

    /** Either game mode: shares all decision 0014 behaviour (jitter buffer 0, [GameModeSettings] layer). */
    val isGame: Boolean get() = this == GAME || this == GAME60

    /** STREAM_PREFS for this mode with the user's bit rate choice (0 = host default, decision 0013). */
    fun toPrefs(bitrateKbps: Long = Bitrate.AUTO_KBPS, drawScale: Int? = null) =
        StreamPrefs(fps, scaleFor(drawScale), bitrateKbps)

    /** The scale this mode sends: [drawScale] (clamped) replaces the table value for [DRAWING] only (decision 0017). */
    fun scaleFor(drawScale: Int?): Int =
        if (this == DRAWING && drawScale != null) clampDrawScale(drawScale) else scalePermille

    /** The next mode in the cycle (wraps around). */
    fun next(): StreamMode = entries[(ordinal + 1) % entries.size]

    /** Connect-panel button text, e.g. "Görüntü modu: Akıcı (120 fps)". */
    fun buttonText() = "Görüntü modu: $label ($fps fps)"

    /** Toast text, e.g. "Performans: 120 fps, %75". */
    fun toastText(drawScale: Int? = null) = "$label: $fps fps, %${scaleFor(drawScale) / 10}"

    companion object {
        val DEFAULT = SMOOTH

        const val DRAW_SCALE_MIN = 500
        const val DRAW_SCALE_MAX = 1000

        /** `--ei draw_scale N` (one launch, not stored): out-of-range values are clamped. */
        fun clampDrawScale(permille: Int): Int = permille.coerceIn(DRAW_SCALE_MIN, DRAW_SCALE_MAX)

        /** Unknown or missing values fall back to [DEFAULT]. */
        fun parse(id: String?): StreamMode =
            if (id == "performance144") PERFORMANCE // removed mode (panel never gets 144 Hz); keep its users in performance
            else entries.firstOrNull { it.id == id } ?: DEFAULT

        /** Overlay line: the chosen mode and what the host actually encodes, e.g. "Mod Akıcı 120 fps | 2800x1840 @120". */
        fun overlayLine(mode: StreamMode, config: StreamConfig?): String =
            "Mod ${mode.label} ${mode.fps} fps" + (if (config != null) " | ${config.widthPx}x${config.heightPx} @${config.fps}" else "")
    }
}

/**
 * Picture shape for layout and the input viewport. The encoded size may be smaller than the virtual display (performance
 * mode) and is rounded to even numbers, so the display's own shape (point size) is preferred: the picture then fills the
 * same rectangle in every mode and normalized coordinates never shift.
 */
object VideoLayout {
    fun aspectSize(c: StreamConfig): Pair<Int, Int> =
        if (c.widthPt > 0 && c.heightPt > 0) c.widthPt to c.heightPt else c.widthPx to c.heightPx
}
