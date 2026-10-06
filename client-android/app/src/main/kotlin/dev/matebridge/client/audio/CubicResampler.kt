package dev.matebridge.client.audio

import kotlin.math.floor

/**
 * 4-point cubic Hermite (Catmull-Rom) resampler for interleaved s16 frames, for ratios very close to 1 (clock drift
 * correction, +-0.5 % at most). Pure Kotlin, single-threaded. [step] is input frames per output frame: above 1
 * consumes the input faster (the buffer level falls), below 1 slower.
 *
 * The output lags the input by 3 frames (the window [x-1, x0, x1, x2] is filled from the newest end).
 */
class CubicResampler(private val channels: Int = 2) {
    private val w = FloatArray(4 * channels)
    private var frac = 0.0

    fun reset() {
        w.fill(0f)
        frac = 0.0
    }

    /**
     * T-108: playback (re)starts at [frame] (one interleaved frame, the read head; not consumed). The window is filled
     * with it, so the first outputs hold that value instead of interpolating from stale frames (audio from before the
     * hole, or zeros pulled while the fade-out ran out of input) into it: no step under the fade-in.
     */
    fun prime(frame: ShortArray) {
        for (k in 0 until 4) for (c in 0 until channels) w[k * channels + c] = frame[c].toFloat()
        frac = 0.0
    }

    /** Input frames [process] will pull for [outFrames] at [step] (rounded up; one frame of margin). */
    fun inputNeeded(outFrames: Int, step: Double): Int = floor(frac + outFrames * step).toInt() + 1

    /**
     * Writes [outFrames] frames into [out] (from frame 0), pulling input frames from [input] (from frame 0, at most
     * [inFrames]). If the input runs out, zeros are pulled instead. Returns the number of real input frames consumed.
     */
    fun process(out: ShortArray, outFrames: Int, step: Double, input: ShortArray, inFrames: Int): Int {
        var consumed = 0
        val ch = channels
        for (j in 0 until outFrames) {
            val t = frac.toFloat()
            for (c in 0 until ch) {
                val xm1 = w[c]
                val x0 = w[ch + c]
                val x1 = w[2 * ch + c]
                val x2 = w[3 * ch + c]
                val c1 = 0.5f * (x1 - xm1)
                val c2 = xm1 - 2.5f * x0 + 2f * x1 - 0.5f * x2
                val c3 = 0.5f * (x2 - xm1) + 1.5f * (x0 - x1)
                val y = ((c3 * t + c2) * t + c1) * t + x0
                out[j * ch + c] = toS16(y)
            }
            frac += step
            while (frac >= 1.0) {
                System.arraycopy(w, ch, w, 0, 3 * ch)
                if (consumed < inFrames) {
                    for (c in 0 until ch) w[3 * ch + c] = input[consumed * ch + c].toFloat()
                    consumed++
                } else {
                    for (c in 0 until ch) w[3 * ch + c] = 0f
                }
                frac -= 1.0
            }
        }
        return consumed
    }
}

/**
 * T-284: `y.roundToInt().coerceIn(-32768, 32767).toShort()` without stdlib calls (they fell out of JIT code into the
 * interpreter on the tablet, ~50 % of the audio thread). Bit-identical to it for every finite [y]: `roundToInt` is
 * `Math.round(float)` = floor(y + 0.5) computed exactly (half up), then clamped. Inline, so no call is left in the
 * resampler's inner loop. NaN (never produced: the inputs are finite s16 values) maps to 0 instead of throwing.
 */
@Suppress("NOTHING_TO_INLINE")
internal inline fun toS16(y: Float): Short {
    if (y >= 32766.5f) return 32767
    if (y < -32768.5f) return -32768
    // Here |y| < 2^15 + 1, so t is exact and so is d = y - t (|d| < 1).
    val t = y.toInt()
    val d = y - t
    val r = if (y >= 0f) {
        if (d >= 0.5f) t + 1 else t
    } else {
        if (d < -0.5f) t - 1 else t
    }
    return r.toShort()
}
