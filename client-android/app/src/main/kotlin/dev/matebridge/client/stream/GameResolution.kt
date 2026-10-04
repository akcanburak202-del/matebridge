package dev.matebridge.client.stream

import dev.matebridge.client.protocol.StreamConfig

/**
 * "Oyun çözünürlüğü" (decision 0029, T-215): the 1x virtual display size the game modes ask for in STREAM_PREFS
 * `display_*`. Every size has the panel's 2800×1840 shape (1848×1214 within 0.03%). A persistent user setting, not
 * part of the temporary game layer of decision 0014.
 */
enum class GameResolution(val id: String, val widthPx: Int, val heightPx: Int) {
    R1400("1400x920", 1400, 920),
    R1848("1848x1214", 1848, 1214),
    R2100("2100x1380", 2100, 1380),

    /** Decision 0030 §3 (T-223): exactly the panel shape (80%). */
    R2240("2240x1472", 2240, 1472);

    /** Panel and toast text, e.g. "1848×1214". */
    val label: String get() = "$widthPx×$heightPx"

    /**
     * The host applied this game display (PROTOCOL §0x05): the full geometry, `width_px == width_pt == w` and
     * `height_px == height_pt == h`. The point size alone is not enough: 1400×920 equals the native HiDPI display's
     * point size (2800×1840 px), which an old host keeps. Information only (`ev=profile display_applied`).
     */
    fun appliedIn(c: StreamConfig): Boolean =
        c.widthPx == widthPx && c.widthPt == widthPx && c.heightPx == heightPx && c.heightPt == heightPx

    companion object {
        val DEFAULT = R1848

        /** Unknown or missing values fall back to [DEFAULT]. */
        fun parse(id: String?): GameResolution = entries.firstOrNull { it.id == id } ?: DEFAULT
    }
}
