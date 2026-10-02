package dev.matebridge.client.audio

/**
 * Everything the audio writer does per burst, minus the AudioTrack (pure Kotlin, JVM-testable): jitter buffer ->
 * drift-controlled cubic resampler -> gain ramps. Single-threaded (the writer thread) except [buffer] (written by the
 * network thread) and [muted] (any thread).
 *
 * States: PRIMING writes silence and consumes nothing until the level reaches the refill threshold, then fades in
 * (5 ms) from the read head (the resampler is primed with it, T-108). PLAYING resamples. When a burst would leave less than the fade-out reserve (3 ms), FADING_OUT plays the
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
 * Bunched refill (T-118): packets held up in transport arrive together, so the level can jump far past the refill
 * threshold in one step (seen: target 40 ms, start level 75 ms, and the PI needed >10 s to bring it back). When a
 * priming ends more than [TRIM_SLACK_MS] above the refill threshold, the oldest frames above it are dropped before the
 * fade-in. The output is silent at that moment, so the drop shortens what follows the gap rather than adding a skip
 * of its own: no click, no pitch change. A stall longer than [IDLE_AFTER_MS] takes the quick-restart path, and its
 * bunch (no capture jump, so already confirmed as an underrun) is trimmed too. If the run-dry is not yet classified,
 * one safety step is kept for the underrun it probably was. No trim after an A/V hold (that level is meant) nor
 * after a run-dry classified idle (the start of a new sound must not be cut).
 *
 * Late bunch (T-125): the held packets may also come at catch-up speed, so a quick restart starts on the first few
 * and the rest arrive while playing (seen on Wi-Fi: level 85-134 ms against a 45 ms target, the PI needed ~20 s).
 *  - For [SKIP_WINDOW_MS] after a restart (not the first start, not after an A/V hold, not after a run-dry classified
 *    idle; closed if the run-dry is classified idle later), the level floor is taken per [SKIP_PROBE_MS]. When one
 *    is more than [SKIP_ABOVE_MS] above the target, the excess down to the target (one safety step kept while the
 *    run-dry is unclassified) is dropped with the buffer's 3 ms crossfade. At most one skip per window.
 *  - Any time: [SUSTAINED_WINDOWS] drift windows in a row whose floor is more than [SUSTAINED_ABOVE_MS] above the
 *    target drop the excess once. The count starts at each playback start, so the first seconds of a sound (after
 *    silence or not) are never cut. Smaller deviations stay with the PI.
 * The target includes the A/V floor, so a skip never drops below it.
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
    private val trimSlackFrames = TRIM_SLACK_MS * sampleRate / 1000
    private var inBuf = ShortArray(0)
    private val headFrame = ShortArray(channels)
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
    /** T-118: this priming follows a run-dry classified idle (the source went silent): no trim at its start. */
    private var idleRestart = false

    /** T-118: playback starts whose bunched excess was dropped, and the frames dropped. */
    var refillTrims = 0L
        private set
    var refillTrimFrames = 0L
        private set

    /** T-125: skips of excess while playing (late bunch or sustained high level), and the frames dropped. */
    var skipTrims = 0L
        private set
    var skipTrimFrames = 0L
        private set

    private val skipWindowFrames = SKIP_WINDOW_MS * sampleRate / 1000
    private val skipProbeFrames = SKIP_PROBE_MS * sampleRate / 1000
    private val skipAboveFrames = SKIP_ABOVE_MS * sampleRate / 1000
    private val sustainedAboveFrames = SUSTAINED_ABOVE_MS * sampleRate / 1000
    /** Output frames left in the post-underrun skip window (0 = closed). */
    private var skipWindowLeft = 0
    private var probeMin = Int.MAX_VALUE
    private var probeFrames = 0
    private var seenWindows = 0L
    private var highWindows = 0

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
                if (!heldThisPriming && !idleRestart) trimExcess(frames)
                state = State.PLAYING
                if (buffer.peek(headFrame, 1) == 1) resampler.prime(headFrame)
                ramp.fadeIn(fadeInFrames)
                drift.onPlaybackStart()
                // Held for A/V: the floor about to follow (the level minus half the arrival sawtooth) is the A/V floor.
                if (heldThisPriming) drift.seedAvFloor(level - drift.lastSpanFrames / 2)
                skipWindowLeft = if (hasPlayed && !heldThisPriming && !idleRestart) skipWindowFrames else 0
                probeMin = Int.MAX_VALUE
                probeFrames = 0
                seenWindows = drift.windows
                highWindows = 0
                heldThisPriming = false
                quickRestart = false
                idleRestart = false
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
            DriftController.Decision.None -> checkSkip(remaining, frames)
        }
    }

    /** T-125: the post-underrun skip window and the sustained-excess rule (see the class comment). */
    private fun checkSkip(level: Int, frames: Int) {
        if (skipWindowLeft > 0) {
            if (level < probeMin) probeMin = level
            probeFrames += frames
            skipWindowLeft -= frames
            if (probeFrames >= skipProbeFrames) {
                val excess = probeMin - drift.targetFrames - if (starvePending) drift.safetyStepFrames else 0
                probeMin = Int.MAX_VALUE
                probeFrames = 0
                if (excess > skipAboveFrames) {
                    skip(excess)
                    skipWindowLeft = 0
                }
            }
        }
        val w = drift.windows
        if (w != seenWindows) {
            seenWindows = w
            val excess = drift.lastFloorFrames - drift.targetFrames
            highWindows = if (excess > sustainedAboveFrames) highWindows + 1 else 0
            if (highWindows >= SUSTAINED_WINDOWS) {
                highWindows = 0
                skip(excess)
            }
        }
    }

    private fun skip(frames: Int) {
        buffer.skipCrossfade(frames)
        skipTrims++
        skipTrimFrames += frames
        drift.onSkip(frames)
    }

    /** Drops the level's excess above the refill threshold (see the class comment); called just before the fade-in. */
    private fun trimExcess(frames: Int) {
        val keep = drift.refillThresholdFrames(frames, fadeOutFrames) + if (starvePending) drift.safetyStepFrames else 0
        val excess = buffer.level - keep
        if (excess <= trimSlackFrames) return
        buffer.consume(excess)
        refillTrims++
        refillTrimFrames += excess
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
            skipWindowLeft = 0 // T-125: what follows is a new sound, not a late bunch
            if (state == State.PRIMING) {
                quickRestart = true
                idleRestart = true
            }
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
        /** T-118: a start more than this above the refill threshold drops the excess down to the threshold. */
        const val TRIM_SLACK_MS = 5
        /** T-125: after a restart a late bunch is looked for this long (a stall's bunch arrives within ~0.3 s). */
        const val SKIP_WINDOW_MS = 2_000
        /** T-125: floor probe inside the skip window (at least four Wi-Fi arrival gaps of 41-50 ms). */
        const val SKIP_PROBE_MS = 200
        /** T-125: a probe floor more than this above the target is a late bunch's excess. */
        const val SKIP_ABOVE_MS = 20
        /** T-125: outside the window, a floor this far above the target ... */
        const val SUSTAINED_ABOVE_MS = 60
        /** ... for this many drift windows (1 s each) in a row is dropped once. */
        const val SUSTAINED_WINDOWS = 3
    }
}
