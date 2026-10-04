package dev.matebridge.client.stream

import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.StreamPrefs

/**
 * The user-selectable display modes (decision 0030, T-223): Günlük, Çizim, Oyun. A mode is a client concept; the wire
 * only carries fps, `scale_permille` (always 1000 now), the bit rate and, in Oyun, the game display (STREAM_PREFS). The
 * choice is a request: the host applies the nearest thing it supports and answers with a STREAM_CONFIG.
 *
 * The frame rate is a separate per-mode setting ("Kare hızı", [FPS_OPTIONS]) that Günlük and Oyun remember on their
 * own (`Settings.modeFps`); Çizim is always [DRAWING_FPS]. The mode's temporary defaults (game and drawing layer) are in
 * [GameModeSettings].
 */
enum class StreamMode(val id: String, val label: String) {
    /** 2800×1840 HiDPI, the frame rate setting (default 120), the user's bit rate. */
    DAILY("daily", "Günlük"),

    /** 2800×1840 HiDPI, always 120 fps; temporary defaults: fingers off, 60 Mbps if Otomatik (decision 0030 §1). */
    DRAWING("drawing", "Çizim"),

    /** Decisions 0014/0029: the game display ("Oyun çözünürlüğü"), the frame rate setting (default 60), the game layer. */
    GAME("game", "Oyun");

    /** Oyun: shares all decision 0014 behaviour ([GameModeSettings] game layer, the game display). */
    val isGame: Boolean get() = this == GAME

    /** Çizim: its own temporary layer ([GameModeSettings]). */
    val isDrawing: Boolean get() = this == DRAWING

    /** Whether the user picks the frame rate for this mode (not Çizim: always 120). */
    val hasFpsSetting: Boolean get() = this != DRAWING

    /** Frame rate when nothing is stored: Günlük 120, Çizim 120, Oyun 60. */
    val defaultFps: Int get() = if (this == GAME) 60 else 120

    /** The frame rate this mode runs at for a [requested] (stored) one: Çizim 120, else a valid choice or the default. */
    fun resolveFps(requested: Int?): Int = when {
        this == DRAWING -> DRAWING_FPS
        requested != null && requested in FPS_OPTIONS -> requested
        else -> defaultFps
    }

    /** STREAM_PREFS for this mode at [fps] (resolved) with the user's bit rate choice (0 = host default, decision 0013). */
    fun toPrefs(fps: Int = defaultFps, bitrateKbps: Long = Bitrate.AUTO_KBPS) =
        StreamPrefs(resolveFps(fps), SCALE_PERMILLE, bitrateKbps)

    /** The next mode in the cycle (wraps around). */
    fun next(): StreamMode = entries[(ordinal + 1) % entries.size]

    /** Connect-panel button text, e.g. "Görüntü modu: Günlük (120 fps)". */
    fun buttonText(fps: Int) = "Görüntü modu: $label (${resolveFps(fps)} fps)"

    /** Toast text, e.g. "Günlük: 120 fps"; with a game display (T-215) its size too, e.g. "Oyun: 60 fps, 1848×1214". */
    fun toastText(fps: Int, display: GameResolution? = null) =
        "$label: ${resolveFps(fps)} fps" + (display?.let { ", ${it.label}" } ?: "")

    companion object {
        val DEFAULT = DAILY

        /** The selectable frame rates. */
        val FPS_OPTIONS = listOf(60, 120)

        const val DRAWING_FPS = 120

        /** Every mode asks for the full encoded size now (the Performans scale is gone, decision 0030 §4). */
        const val SCALE_PERMILLE = 1000

        /** Unknown or missing values fall back to [DEFAULT]; a removed (T-223) stored id maps like [LegacyModes]. */
        fun parse(id: String?): StreamMode =
            entries.firstOrNull { it.id == id } ?: LegacyModes.migrate(id)?.mode ?: DEFAULT

        /** Overlay line: the chosen mode and what the host actually encodes, e.g. "Mod Günlük 120 fps | 2800x1840 @120". */
        fun overlayLine(mode: StreamMode, fps: Int, config: StreamConfig?): String =
            "Mod ${mode.label} ${mode.resolveFps(fps)} fps" + (if (config != null) " | ${config.widthPx}x${config.heightPx} @${config.fps}" else "")
    }
}

/**
 * Decision 0030 §5: the five pre-T-223 stored mode ids and what they become (a mode and its frame rate). `game` is also
 * the new Oyun id, so the one-time `Settings.migrateModesOnce` is what writes its 120 fps; [StreamMode.parse] alone maps
 * every old id to a mode.
 */
object LegacyModes {
    data class Migrated(val mode: StreamMode, val fps: Int)

    /** Null for the three new ids (and for unknown or missing values: they become Günlük at its default). */
    fun migrate(id: String?): Migrated? = when (id) {
        "clarity" -> Migrated(StreamMode.DAILY, 60)
        "smooth", "performance", "performance144" -> Migrated(StreamMode.DAILY, 120) // performance144: removed even earlier
        "game60" -> Migrated(StreamMode.GAME, 60)
        else -> null
    }

    /** What the stored [id] means for a first start after the update: the old `game` is Oyun 120 (the new Oyun defaults to 60). */
    fun migrateStored(id: String?): Migrated? = if (id == "game") Migrated(StreamMode.GAME, 120) else migrate(id)
}

/**
 * Picture shape for layout and the input viewport. The encoded size may be smaller than the virtual display (a scaled
 * encode) and is rounded to even numbers, so the display's own shape (point size) is preferred: the picture then fills the
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
