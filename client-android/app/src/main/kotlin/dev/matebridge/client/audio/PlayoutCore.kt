package dev.matebridge.client.audio

/**
 * Everything the audio writer does per burst, minus the AudioTrack (pure Kotlin, JVM-testable): jitter buffer ->
 * drift-controlled cubic resampler -> gain ramps. Single-threaded (the writer thread) except [buffer] (written by the
 * network thread) and [muted] (any thread).
 *
 * States: PRIMING writes silence and consumes nothing until the level reaches the refill threshold, then fades in
 * (5 ms). PLAYING resamples. When a burst would leave less than the fade-out reserve (3 ms), FADING_OUT plays the
 * reserve with a fade to silence, then PRIMING again (an underrun or an idle gap, see below).
 *
 * Running dry (T-098): when the buffer runs out, the fade-out and silence happen at once, but whether it was an
 * underrun is decided later ("starve pending"):
 *  - a packet after it follows a capture-time/index jump ([AudioJitterBuffer.discontinuities]): the host captured
 *    nothing in between, so the source was silent (Mac audio IO stops when nothing plays) -> [idleGaps], no underrun,
 *    no extra safety;
 *  - [CONFIRM_PACKETS] packets arrive without a jump: the audio was late (network stall, jitter) -> a real underrun;
 *  - no packet at all: nothing is counted.
 * The jump may show only in the second packet: the host completes the packet it was filling when its IO stopped with
 * the first frames after the restart, under the old capture time.
 *
 * Restart after silence: once the buffer ran dry and no packet came for [IDLE_AFTER_MS] (or the gap was classified
 * idle), playback restarts as soon as the floor rule holds instead of waiting for the full refill level: the level is
 * playable (target + one burst + the fade-out reserve) and level + time since the last packet >= target + arrival
 * span, i.e. the next packet will find the level at the target. With 10 ms packets and short bursts the first frame
 * of a sound is heard about `target` after its packet arrived.
 *
 * A/V while priming: [primingHoldUs] > 0 means "starting now would put the audio that much ahead of its A/V target";
 * playback then waits (up to the buffer's max refill level) and the level it starts at becomes the A/V floor, so the
 * first A/V target needs no rebuffer later.
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
    private val idleAfterFrames = IDLE_AFTER_MS * sampleRate / 1000
    private var inBuf = ShortArray(0)
    private var heldThisPriming = false

    private var seenPackets = 0L
    /** Output frames rendered since the last packet arrived (counted per burst). */
    var framesSinceLastPacket = 0L
        private set
    private var hasPlayed = false
    private var starvePending = false
    private var starvePackets = 0L
    private var starveDiscontinuities = 0L
    /** This priming follows silence: restart at the minimum playable level. */
    private var quickRestart = false

    /** Times the buffer ran dry because the source went silent (not underruns). */
    var idleGaps = 0L
        private set

    /** Priming after the source went quiet (for logs). */
    val idle: Boolean get() = state == State.PRIMING && hasPlayed && framesSinceLastPacket >= idleAfterFrames

    /** Set by the writer before each burst while priming (see the class comment); 0 = no hold. */
    var primingHoldUs = 0L

    /** Output goes silent (with a fade) while true; timing and consumption continue. */
    @Volatile var muted = false

    /** Level after the last played burst (frames), for logs. */
    var lastRemainingFrames = 0
        private set

    /** Renders [frames] output frames into [out] (from frame 0). */
    fun render(out: ShortArray, frames: Int) {
        trackArrivals(frames)
        classifyStarve()
        if (state == State.PRIMING) {
            if (starvePending && framesSinceLastPacket >= idleAfterFrames) quickRestart = true
            val level = buffer.level
            val filled = if (quickRestart) {
                // Playable (target + burst + reserve), and the next packet, due one arrival span after the last,
                // will find the level at the target: level - (span - sinceLast) >= target.
                val max = drift.maxRefillFrames
                level >= minOf(drift.targetFrames + frames + fadeOutFrames, max) &&
                    level + framesSinceLastPacket >= minOf(drift.targetFrames + drift.lastSpanFrames, max)
            } else {
                level >= drift.refillThresholdFrames(frames, fadeOutFrames)
            }
            val hold = primingHoldUs > 0 && level < drift.maxRefillFrames
            if (filled && hold) heldThisPriming = true
            if (filled && !hold) {
                state = State.PLAYING
                ramp.fadeIn(fadeInFrames)
                drift.onPlaybackStart()
                // Held for A/V: the floor about to follow (the level minus half the arrival sawtooth) is the A/V floor.
                if (heldThisPriming) drift.seedAvFloor(level - drift.lastSpanFrames / 2)
                heldThisPriming = false
                quickRestart = false
                hasPlayed = true
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
                if (!starvePending) {
                    starvePending = true
                    starvePackets = buffer.packets
                    starveDiscontinuities = buffer.discontinuities
                }
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
            if (ramp.isSilent) state = State.PRIMING
            return
        }
        when (val d = drift.onBurst(remaining, frames)) {
            is DriftController.Decision.Resync -> buffer.skipCrossfade(d.dropFrames)
            DriftController.Decision.Rebuffer -> {
                ramp.fadeOut(fadeOutFrames)
                state = State.FADING_OUT
            }
            DriftController.Decision.None -> Unit
        }
    }

    private fun trackArrivals(frames: Int) {
        val p = buffer.packets
        if (p != seenPackets) {
            seenPackets = p
            framesSinceLastPacket = 0
        } else {
            framesSinceLastPacket += frames
        }
    }

    /** Settles a pending run-dry as idle (the host captured nothing) or as an underrun (the audio was late). */
    private fun classifyStarve() {
        if (!starvePending) return
        if (buffer.discontinuities != starveDiscontinuities) {
            starvePending = false
            idleGaps++
            if (state == State.PRIMING) quickRestart = true
        } else if (buffer.packets - starvePackets >= CONFIRM_PACKETS) {
            starvePending = false
            drift.onUnderrun()
        }
    }

    companion object {
        const val FADE_OUT_MS = 3
        const val FADE_IN_MS = 5
        /** No packet for this long after running dry: the source is probably silent (two packets). */
        const val IDLE_AFTER_MS = 20
        /** Packets without a capture jump after running dry that confirm a real underrun. */
        const val CONFIRM_PACKETS = 3L
    }
}
