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
    PERFORMANCE("performance", "Performans", 120, 750),

    /** Decision 0014: games; lowest latency (jitter buffer 0) and temporary defaults ([GameModeSettings]). */
    GAME("game", "Oyun 120", 120, 660),

    /** Decision 0016: the same game behaviour at 60 fps and full resolution (keyboard/gamepad games, panel stays 60 Hz). */
    GAME60("game60", "Oyun 60", 60, 1000);

    /** Either game mode: shares all decision 0014 behaviour (jitter buffer 0, [GameModeSettings] layer). */
    val isGame: Boolean get() = this == GAME || this == GAME60

    /** STREAM_PREFS for this mode with the user's bit rate choice (0 = host default, decision 0013). */
    fun toPrefs(bitrateKbps: Long = Bitrate.AUTO_KBPS) = StreamPrefs(fps, scalePermille, bitrateKbps)

    /** The next mode in the cycle (wraps around). */
    fun next(): StreamMode = entries[(ordinal + 1) % entries.size]

    /** Connect-panel button text, e.g. "Görüntü modu: Akıcı (120 fps)". */
    fun buttonText() = "Görüntü modu: $label ($fps fps)"

    /**
     * Toast text, e.g. "Performans: 120 fps, %75"; with a game display (T-215) its size instead of the scale, e.g.
     * "Oyun 120: 120 fps, 1848×1214".
     */
    fun toastText(display: GameResolution? = null) =
        "$label: $fps fps, " + (display?.label ?: "%${scalePermille / 10}")

    companion object {
        val DEFAULT = SMOOTH

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
    /** T-215: a fitted rectangle within this many pixels of the root on both axes fills the root instead. */
    const val FILL_TOLERANCE_PX = 2

    fun aspectSize(c: StreamConfig): Pair<Int, Int> =
        if (c.widthPt > 0 && c.heightPt > 0) c.widthPt to c.heightPt else c.widthPx to c.heightPx

    /**
     * The SurfaceView size in a [rootW]×[rootH] root: the picture fitted to its aspect ([aspectSize]), or null = fill the
     * root (MATCH_PARENT) when there is no config or root yet, or when the fitted rectangle is within
     * [FILL_TOLERANCE_PX] of the root on both axes. The game display 1848×1214 (decision 0029) is not exactly 35:23 and
     * would otherwise leave a 1 px band (2800×1839); a really different aspect still letterboxes.
     */
    fun surfaceSize(rootW: Int, rootH: Int, c: StreamConfig?): Pair<Int, Int>? {
        if (c == null) return null
        val (aw, ah) = aspectSize(c)
        val vp = VideoViewport(rootW, rootH, aw, ah)
        if (vp.isEmpty) return null
        val w = Math.round(vp.width)
        val h = Math.round(vp.height)
        return if (rootW - w <= FILL_TOLERANCE_PX && rootH - h <= FILL_TOLERANCE_PX) null else w to h
    }
}
