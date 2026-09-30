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
    PERFORMANCE("performance", "Performans", 120, 750);

    fun toPrefs() = StreamPrefs(fps, scalePermille)

    /** The next mode in the cycle (wraps around). */
    fun next(): StreamMode = entries[(ordinal + 1) % entries.size]

    /** Connect-panel button text, e.g. "Görüntü modu: Akıcı (120 fps)". */
    fun buttonText() = "Görüntü modu: $label ($fps fps)"

    /** Toast text, e.g. "Performans: 120 fps, %75". */
    fun toastText() = "$label: $fps fps, %${scalePermille / 10}"

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
    fun aspectSize(c: StreamConfig): Pair<Int, Int> =
        if (c.widthPt > 0 && c.heightPt > 0) c.widthPt to c.heightPt else c.widthPx to c.heightPx
}
