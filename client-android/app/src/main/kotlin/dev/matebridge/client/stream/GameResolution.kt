package dev.matebridge.client.stream

import dev.matebridge.client.protocol.StreamConfig

/**
 * "Oyun çözünürlüğü" (decision 0029, T-215): the 1x virtual display size the game modes ask for in STREAM_PREFS
 * `display_*`. Every size has the panel's 2800×1840 shape (1848×1214 within 0.03%). A persistent user setting, not
 * part of the temporary game layer of decision 0014.
 */
enum class GameResolution(val id: String, val widthPx: Int, val heightPx: Int, val experimental: Boolean = false) {
    R1400("1400x920", 1400, 920),
    R1848("1848x1214", 1848, 1214),
    R2100("2100x1380", 2100, 1380),

    /** Decision 0030 §3 (T-223): exactly the panel shape (80%). */
    R2240("2240x1472", 2240, 1472),

    /**
     * T-245 (decision 0030 addendum): the panel size at 1x, experimental and only for Oyun 60 (tablet decode ~14 ms of
     * the 16.7 ms budget). At any other rate it falls back to [EXPERIMENTAL_FALLBACK] ([effectiveAt]); the stored
     * choice stays.
     */
    R2800("2800x1840", 2800, 1840, experimental = true);

    /** Panel and toast text, e.g. "1848×1214". */
    val label: String get() = "$widthPx×$heightPx"

    /** Whether this size applies at Oyun's frame rate [fps]: every size at 60, the experimental one only there. */
    fun availableAt(fps: Int): Boolean = !experimental || fps == EXPERIMENTAL_FPS

    /** The size Oyun at [fps] asks for when this one is stored: itself, or [EXPERIMENTAL_FALLBACK] where unavailable. */
    fun effectiveAt(fps: Int): GameResolution = if (availableAt(fps)) this else EXPERIMENTAL_FALLBACK

    /**
     * The panel button text for Oyun's frame rate [gameFps] (null = not known here, i.e. outside Oyun): the plain
     * [label], and for the experimental size "2800×1840 (deneysel)" at 60, "2800×1840 (yalnız 60 fps)" (grey,
     * [availableAt] false) at 120 and "2800×1840 (deneysel, yalnız 60 fps)" when the rate is not known.
     */
    fun panelLabel(gameFps: Int?): String = when {
        !experimental -> label
        gameFps == null -> "$label ($EXPERIMENTAL_TEXT, $ONLY_60_TEXT)"
        availableAt(gameFps) -> "$label ($EXPERIMENTAL_TEXT)"
        else -> "$label ($ONLY_60_TEXT)"
    }

    /**
     * The host applied this game display (PROTOCOL §0x05): the full geometry, `width_px == width_pt == w` and
     * `height_px == height_pt == h`. The point size alone is not enough: 1400×920 equals the native HiDPI display's
     * point size (2800×1840 px), which an old host keeps. Information only (`ev=profile display_applied`).
     */
    fun appliedIn(c: StreamConfig): Boolean =
        c.widthPx == widthPx && c.widthPt == widthPx && c.heightPx == heightPx && c.heightPt == heightPx

    companion object {
        val DEFAULT = R1848

        /** T-245: the only frame rate the experimental size runs at. */
        const val EXPERIMENTAL_FPS = 60

        /** T-245: what the experimental size becomes at another rate (Oyun 120). */
        val EXPERIMENTAL_FALLBACK = R2240

        const val EXPERIMENTAL_TEXT = "deneysel"
        const val ONLY_60_TEXT = "yalnız 60 fps"

        /** Whether the panel button of [r] can be tapped at Oyun's [gameFps] (null = not known: always). */
        fun panelEnabled(r: GameResolution, gameFps: Int?): Boolean = gameFps == null || r.availableAt(gameFps)

        /**
         * The panel selection for the [stored] choice at Oyun's [gameFps]: the size in effect (Oyun 120 with 2800×1840
         * stored shows 2240×1472), or [stored] when the rate is not known (outside Oyun).
         */
        fun panelSelected(stored: GameResolution, gameFps: Int?): GameResolution =
            if (gameFps == null) stored else stored.effectiveAt(gameFps)

        /** Unknown or missing values fall back to [DEFAULT]. */
        fun parse(id: String?): GameResolution = entries.firstOrNull { it.id == id } ?: DEFAULT
    }
}
