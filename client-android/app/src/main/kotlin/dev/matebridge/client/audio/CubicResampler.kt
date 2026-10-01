package dev.matebridge.client.audio

import kotlin.math.floor
import kotlin.math.roundToInt

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
                out[j * ch + c] = y.roundToInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
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
