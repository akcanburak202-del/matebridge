package dev.matebridge.client.audio

/**
 * Linear gain ramp for interleaved s16 frames: fade-out before an underrun's silence (3 ms) and fade-in when playback
 * starts again (5 ms), so neither edge clicks. Pure Kotlin, single-threaded. Starts silent.
 */
class AudioRamp(private val channels: Int = 2) {
    var gain = 0f
        private set
    var target = 0f
        private set
    private var stepPerFrame = 0f

    val isSilent: Boolean get() = gain == 0f && target == 0f
    val isRamping: Boolean get() = gain != target

    fun fadeOut(frames: Int) = rampTo(0f, frames)

    fun fadeIn(frames: Int) = rampTo(1f, frames)

    fun setSilent() { gain = 0f; target = 0f; stepPerFrame = 0f }

    private fun rampTo(to: Float, frames: Int) {
        target = to
        if (frames <= 0) { gain = to; stepPerFrame = 0f; return }
        stepPerFrame = (to - gain) / frames
        if (stepPerFrame == 0f) gain = to
    }

    /** Multiplies [frames] frames of [buf] (from frame 0) by the gain, advancing the ramp per frame. */
    fun apply(buf: ShortArray, frames: Int) {
        if (gain == 1f && target == 1f) return
        if (gain == 0f && target == 0f) { buf.fill(0, 0, frames * channels); return }
        for (f in 0 until frames) {
            if (gain != target) {
                gain += stepPerFrame
                if ((stepPerFrame > 0f && gain >= target) || (stepPerFrame < 0f && gain <= target)) gain = target
            }
            val g = gain
            if (g == 1f) continue
            for (c in 0 until channels) {
                val i = f * channels + c
                buf[i] = (buf[i] * g).toInt().toShort()
            }
        }
    }
}
