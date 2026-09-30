package dev.matebridge.client.input

import dev.matebridge.client.protocol.Pinch
import kotlin.math.abs
import kotlin.math.max

/**
 * Two-finger gesture classification shared by the touchscreen and the touchpad (T-037, PROTOCOL.md section 4 PINCH).
 * Pure Kotlin. All tuning constants of the decision live here.
 *
 * A two-finger motion is a scroll or a pinch, decided once, at the first meaningful movement, and never changed
 * afterwards. Measured against the baseline taken when the second finger arrived (or the gesture was parked):
 *  - the change of the distance between the fingers, relative to the baseline distance, reaching [PINCH_REL] while
 *    the common (centroid) motion is still below the scroll slop: PINCH;
 *  - the common motion exceeding the scroll slop first: SCROLL;
 *  - both in the same frame: PINCH when the distance changed at least twice as much as the centroid moved (each
 *    finger of a pure pinch travels half of the distance change), otherwise SCROLL.
 */
object TwoFingerClassifier {
    enum class Kind { SCROLL, PINCH }

    /** Relative distance change that makes a pinch (6 percent). */
    const val PINCH_REL = 0.06f

    /** The baseline distance is never taken smaller than this fraction of the source's extent (noise guard for close fingers). */
    const val MIN_DIST_FRAC = 0.05f

    /**
     * [baseDist]: finger distance at the baseline, [dist]: distance now, [common]: centroid travel since the
     * baseline, [slop]: scroll slop, [minDist]: floor of the baseline distance; all in the same unit.
     */
    fun classify(baseDist: Float, dist: Float, common: Float, slop: Float, minDist: Float): Kind? {
        val dd = abs(dist - baseDist)
        val pinch = dd / max(baseDist, minDist) >= PINCH_REL
        val scroll = common > slop
        return when {
            pinch && scroll -> if (dd >= 2f * common) Kind.PINCH else Kind.SCROLL
            pinch -> Kind.PINCH
            scroll -> Kind.SCROLL
            else -> null
        }
    }

    /** Relative scale change from the previous distance to [now], clamped to the wire range; 0 when [prev] is unusable. */
    fun scale(prev: Float, now: Float): Float {
        if (prev <= 0f) return 0f
        return (now / prev - 1f).coerceIn(Pinch.MIN_SCALE, Pinch.MAX_SCALE)
    }
}
