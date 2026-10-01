package dev.matebridge.aaudioprobe

import kotlin.math.PI
import kotlin.math.roundToInt
import kotlin.math.sin

/** Interleaved s16 sine, same signal as the native side (1 kHz, amplitude as a fraction of full scale). */
class ToneGen(private val rate: Int, amplitude: Float, private val hz: Double = 1000.0) {
    private val amp = amplitude * 32767.0
    private val step = 2.0 * PI * hz / rate
    private var phase = 0.0

    fun fill(out: ShortArray, frames: Int, channels: Int) {
        require(out.size >= frames * channels) { "buffer too small" }
        for (f in 0 until frames) {
            val v = (amp * sin(phase)).roundToInt().toShort()
            phase += step
            if (phase > 2.0 * PI) phase -= 2.0 * PI
            for (c in 0 until channels) out[f * channels + c] = v
        }
    }

    companion object {
        /** -40 dBFS. */
        const val AMPLITUDE_M40_DBFS = 0.01f
    }
}
