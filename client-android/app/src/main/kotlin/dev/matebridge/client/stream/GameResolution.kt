package dev.matebridge.client.stream

import dev.matebridge.client.protocol.StreamConfig
import kotlin.math.abs

/**
 * The tablet's native pixel size, landscape (`HELLO.screen_width_px/height_px`). The one source for the HELLO and for
 * the game resolutions (T-387, decision 0029 addendum 2026-10-28).
 */
data class NativeSize(val widthPx: Int, val heightPx: Int) {
    companion object {
        /** MatePad Pro 12.2: the size the tests and pre-connect defaults assume. */
        val MATEPAD = NativeSize(2800, 1840)

        /** Landscape size of a display of [a]×[b] pixels (the app is landscape-locked). */
        fun landscape(a: Int, b: Int) = NativeSize(maxOf(a, b), minOf(a, b))
    }
}

/**
 * "Oyun çözünürlüğü" (decision 0029, T-215; T-387): a step of the tablet's native size. The pixel size a step asks
 * for is [GameDisplay.of], which satisfies the host rule (`GameDisplayPolicy.accepts`) for every native size. A
 * persistent user setting, not part of the temporary game layer of decision 0014.
 */
enum class GameResolution(val id: String, val percent: Int, val legacyId: String, val experimental: Boolean = false) {
    P50("50", 50, "1400x920"),
    P66("66", 66, "1848x1214"),
    P75("75", 75, "2100x1380"),

    /** Decision 0030 §3 (T-223): the panel shape (80%). */
    P80("80", 80, "2240x1472"),

    /**
     * T-245/T-250 (decision 0030 addendum): the native size at 1x, valid at every Oyun frame rate. Keeps the
     * "(deneysel)" label until the device check removes it.
     */
    P100("100", 100, "2800x1840", experimental = true);

    /** The size this step asks for on [native]. */
    fun on(native: NativeSize): GameDisplay = GameDisplay.of(this, native)

    companion object {
        val DEFAULT = P66

        const val EXPERIMENTAL_TEXT = "deneysel"

        /** A stored step id or a pre-T-387 `WxH` value (mapped to its step); unknown or missing falls back to [DEFAULT]. */
        fun parse(id: String?): GameResolution = entries.firstOrNull { it.id == id || it.legacyId == id } ?: DEFAULT
    }
}

/** A [GameResolution] step resolved against the tablet's native size: the 1x game display size. */
data class GameDisplay(val step: GameResolution, val widthPx: Int, val heightPx: Int) {
    /** Panel and toast text, e.g. "1848×1214". */
    val label: String get() = "$widthPx×$heightPx"

    /** The panel button text: the plain [label], and for the experimental step "2800×1840 (deneysel)". */
    val panelLabel: String get() = if (step.experimental) "$label (${GameResolution.EXPERIMENTAL_TEXT})" else label

    /**
     * The host applied this game display (PROTOCOL §0x05): the full geometry, `width_px == width_pt == w` and
     * `height_px == height_pt == h`. The point size alone is not enough: the half size equals the native HiDPI
     * display's point size, which an old host keeps. Information only (`ev=profile display_applied`).
     */
    fun appliedIn(c: StreamConfig): Boolean =
        c.widthPx == widthPx && c.widthPt == widthPx && c.heightPx == heightPx && c.heightPt == heightPx

    companion object {
        /** Mirror of `GameDisplayPolicy.accepts` (host-mac): even, `native/2 ≤ size ≤ native`, aspect within 0.5%. */
        fun accepts(w: Int, h: Int, native: NativeSize): Boolean {
            val nw = native.widthPx.toLong()
            val nh = native.heightPx.toLong()
            if (w <= 0 || h <= 0 || w % 2 != 0 || h % 2 != 0 || nw <= 0 || nh <= 0) return false
            if (2L * w < nw || w > nw || 2L * h < nh || h > nh) return false
            val diff = abs(w.toLong() * nh - h.toLong() * nw)
            return diff * 1000 <= 5L * h * nw
        }

        /** `w` = `W·percent` and `h` = `w·H/W` rounded to even; moved to the nearest size the host accepts if need be. */
        fun of(step: GameResolution, native: NativeSize): GameDisplay {
            val w0 = evenIn(nearestEven(native.widthPx.toLong() * step.percent, 100), native.widthPx.toLong())
            val (w, h) = nearestAccepted(w0.toInt(), native)
            return GameDisplay(step, w, h)
        }

        /** `num/den` rounded to the nearest even integer. */
        private fun nearestEven(num: Long, den: Long): Long = 2 * ((num + den) / (2 * den))

        /** [v] clamped to the even values in `[n/2, n]`. */
        private fun evenIn(v: Long, n: Long): Long {
            val lo = (n + 1) / 2 + (n + 1) / 2 % 2 // smallest even ≥ ceil(n/2)
            val hi = n - n % 2 // largest even ≤ n
            return v.coerceIn(lo, maxOf(lo, hi))
        }

        private fun heightFor(w: Int, native: NativeSize): Int {
            val nh = native.heightPx.toLong()
            return evenIn(nearestEven(w.toLong() * nh, native.widthPx.toLong()), nh).toInt()
        }

        /** The accepted size nearest to [w0] with the proportional height; the clamped size when none is near. */
        private fun nearestAccepted(w0: Int, native: NativeSize): Pair<Int, Int> {
            for (d in 0..SEARCH_STEPS) {
                for (w in listOf(w0 - 2 * d, w0 + 2 * d).distinct()) {
                    val h = heightFor(w, native)
                    if (accepts(w, h, native)) return w to h
                }
            }
            return w0 to heightFor(w0, native)
        }

        private const val SEARCH_STEPS = 64
    }
}
