package dev.matebridge.client.camera

import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.sin

/** Pure geometry and size picking of the camera pipeline (T-355); no Android types so it is JVM-tested. */
object CameraMath {
    /**
     * Clockwise rotation ([mvp] convention) that turns an image upright for the natural orientation into one upright for
     * a display rotated [displayDegrees] from it (device test 2026-10-18, MatePad portrait-natural, ROTATION_90).
     */
    fun naturalToDisplayDegrees(displayDegrees: Int): Int = (360 - norm(displayDegrees)) % 360

    /** `Surface.ROTATION_0..3` to degrees. */
    fun degreesOfSurfaceRotation(rotation: Int): Int = when (rotation) {
        1 -> 90
        2 -> 180
        3 -> 270
        else -> 0
    }

    private fun norm(deg: Int) = ((deg % 360) + 360) % 360 / 90 * 90

    /**
     * Column-major 4x4 model-view-projection for the unit quad (-1..1) that shows a [srcW]x[srcH] sensor buffer rotated
     * [rotationCw] degrees clockwise, scaled to cover (centre-crop) an [outW]x[outH] frame. The texture matrix of the
     * SurfaceTexture is applied to the texture coordinates separately.
     */
    fun mvp(srcW: Int, srcH: Int, rotationCw: Int, outW: Int, outH: Int): FloatArray {
        val rot = norm(rotationCw)
        val rw = if (rot % 180 == 0) srcW else srcH
        val rh = if (rot % 180 == 0) srcH else srcW
        val s = max(outW.toDouble() / rw, outH.toDouble() / rh)
        val kx = 2.0 * s / outW
        val ky = 2.0 * s / outH
        val sx = srcW / 2.0
        val sy = srcH / 2.0
        val c = cos(Math.toRadians(rot.toDouble()))
        val sn = sin(Math.toRadians(rot.toDouble()))
        // L = diag(kx, ky) * R(cw) * diag(sx, sy), R(cw) = [[c, s], [-s, c]] in y-up coordinates.
        val l00 = kx * c * sx
        val l01 = kx * sn * sy
        val l10 = -ky * sn * sx
        val l11 = ky * c * sy
        return floatArrayOf(
            l00.toFloat(), l10.toFloat(), 0f, 0f,
            l01.toFloat(), l11.toFloat(), 0f, 0f,
            0f, 0f, 1f, 0f,
            0f, 0f, 0f, 1f,
        )
    }

    /** Mirrors an [mvp] horizontally in output space (negates the clip-space x row), in place. */
    fun flipOutputX(m: FloatArray) {
        m[0] = -m[0]; m[4] = -m[4]; m[8] = -m[8]; m[12] = -m[12]
    }

    /** Applies a [mvp] to the quad corner ([x], [y]) (tests). */
    fun apply(m: FloatArray, x: Float, y: Float): Pair<Float, Float> =
        Pair(m[0] * x + m[4] * y + m[12], m[1] * x + m[5] * y + m[13])

    private const val RATIO_16_9 = 16.0 / 9.0

    private fun is169(w: Int, h: Int) = h > 0 && abs(w.toDouble() / h - RATIO_16_9) < 0.02

    /**
     * Encoder size: the requested size when the encoder supports it, else the largest 16:9 size from a fixed ladder that is
     * not larger than the request (even dimensions). Null when nothing fits ([supported] says whether the encoder takes a size).
     */
    fun pickEncoderSize(reqW: Int, reqH: Int, supported: (Int, Int) -> Boolean): Pair<Int, Int>? {
        val w0 = reqW and 1.inv()
        val h0 = reqH and 1.inv()
        if (w0 >= 160 && h0 >= 90 && supported(w0, h0)) return w0 to h0
        for ((w, h) in LADDER) {
            if (w <= w0 && h <= h0 && supported(w, h)) return w to h
        }
        return null
    }

    private val LADDER = listOf(1920 to 1080, 1600 to 900, 1280 to 720, 960 to 540, 854 to 480, 640 to 360)

    /**
     * Camera buffer size for an [outW]x[outH] frame: the smallest 16:9 size at least as wide as the frame (no up-scaling,
     * least GL work); else the largest 16:9 one; else the smallest size at least as wide, else the largest of all.
     */
    fun pickSource(sizes: List<Pair<Int, Int>>, outW: Int): Pair<Int, Int>? {
        if (sizes.isEmpty()) return null
        fun best(c: List<Pair<Int, Int>>): Pair<Int, Int>? {
            val enough = c.filter { it.first >= outW }.minByOrNull { it.first.toLong() * it.second }
            return enough ?: c.maxByOrNull { it.first.toLong() * it.second }
        }
        val wide = sizes.filter { is169(it.first, it.second) }
        return best(wide.ifEmpty { sizes })
    }

    /**
     * AE target fps range: one that contains [fps], preferring upper == [fps] and then the highest lower bound (steady
     * rate); else the range with the highest upper bound below [fps]; null for an empty list.
     */
    fun pickFpsRange(ranges: List<Pair<Int, Int>>, fps: Int): Pair<Int, Int>? {
        if (ranges.isEmpty()) return null
        val containing = ranges.filter { it.first <= fps && it.second >= fps }
        if (containing.isNotEmpty()) {
            return containing.sortedWith(compareBy<Pair<Int, Int>> { if (it.second == fps) 0 else 1 }.thenByDescending { it.first }.thenBy { it.second }).first()
        }
        val below = ranges.filter { it.second < fps }
        if (below.isNotEmpty()) return below.sortedWith(compareByDescending<Pair<Int, Int>> { it.second }.thenByDescending { it.first }).first()
        return ranges.minByOrNull { it.first } // all above: the lowest
    }
}

/**
 * Tags camera open attempts (T-357, Codex): switching facing before the first `onOpened` arrives leaves two opens in
 * flight; only the newest may become the device. Any thread.
 */
class OpenGeneration {
    private val gen = java.util.concurrent.atomic.AtomicInteger()

    /** Starts a new generation (or invalidates the running one) and returns its number. */
    fun next(): Int = gen.incrementAndGet()

    fun isCurrent(g: Int): Boolean = gen.get() == g
}
