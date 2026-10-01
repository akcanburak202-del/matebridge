package dev.matebridge.client.audio

/**
 * Everything the audio writer does per burst, minus the AudioTrack (pure Kotlin, JVM-testable): jitter buffer ->
 * drift-controlled cubic resampler -> gain ramps. Single-threaded (the writer thread) except [buffer] (written by the
 * network thread) and [muted] (any thread).
 *
 * States: PRIMING writes silence and consumes nothing until the level reaches the refill threshold, then fades in
 * (5 ms). PLAYING resamples. When a burst would leave less than the fade-out reserve (3 ms), FADING_OUT plays the
 * reserve with a fade to silence, then PRIMING again (one underrun).
 */
class PlayoutCore(
    val buffer: AudioJitterBuffer = AudioJitterBuffer(),
    val drift: DriftController = DriftController(),
    private val channels: Int = 2,
    sampleRate: Int = 48_000,
) {
    enum class State { PRIMING, PLAYING, FADING_OUT }

    var state = State.PRIMING
        private set

    private val resampler = CubicResampler(channels)
    private val ramp = AudioRamp(channels)
    private val muteRamp = AudioRamp(channels).also { it.fadeIn(0) }
    private val fadeOutFrames = FADE_OUT_MS * sampleRate / 1000
    private val fadeInFrames = FADE_IN_MS * sampleRate / 1000
    private var inBuf = ShortArray(0)
    private var underrunPending = false

    /** Output goes silent (with a fade) while true; timing and consumption continue. */
    @Volatile var muted = false

    /** Level after the last played burst (frames), for logs. */
    var lastRemainingFrames = 0
        private set

    /** Renders [frames] output frames into [out] (from frame 0). */
    fun render(out: ShortArray, frames: Int) {
        if (state == State.PRIMING) {
            if (buffer.level >= drift.refillThresholdFrames()) {
                state = State.PLAYING
                ramp.fadeIn(fadeInFrames)
                drift.onPlaybackStart()
            } else {
                out.fill(0, 0, frames * channels)
                return
            }
        }
        val step = drift.ratio
        val remaining: Int
        synchronized(buffer) {
            val need = resampler.inputNeeded(frames, step)
            if (state == State.PLAYING && buffer.level < need + fadeOutFrames) {
                ramp.fadeOut(fadeOutFrames)
                state = State.FADING_OUT
                underrunPending = true
            }
            if (inBuf.size < need * channels) inBuf = ShortArray(need * channels + 64)
            val n = buffer.peek(inBuf, need)
            val used = resampler.process(out, frames, step, inBuf, n)
            buffer.consume(used)
            remaining = buffer.level
        }
        lastRemainingFrames = remaining
        ramp.apply(out, frames)
        if (muted && muteRamp.target != 0f) muteRamp.fadeOut(fadeOutFrames)
        muteRamp.apply(out, frames)

        if (state == State.FADING_OUT) {
            if (ramp.isSilent) {
                state = State.PRIMING
                if (underrunPending) drift.onUnderrun()
                underrunPending = false
            }
            return
        }
        when (val d = drift.onBurst(remaining, frames)) {
            is DriftController.Decision.Resync -> buffer.skipCrossfade(d.dropFrames)
            DriftController.Decision.Rebuffer -> {
                ramp.fadeOut(fadeOutFrames)
                state = State.FADING_OUT
                underrunPending = false
            }
            DriftController.Decision.None -> Unit
        }
    }

    companion object {
        const val FADE_OUT_MS = 3
        const val FADE_IN_MS = 5
    }
}
