package dev.matebridge.client.audio

import kotlin.math.abs

/**
 * Keeps the jitter buffer's level floor at a target by nudging the resampling ratio (decision 0011). Pure Kotlin,
 * single-threaded (the audio writer thread). Time is counted in output frames, so it is deterministic in tests.
 *
 * Level = frames left in the buffer right after a burst was read. Per [WINDOW_FRAMES] (1 s) of output the window's
 * minimum (floor) and peak-to-peak span are taken, then:
 *  - floor above target + 120 ms: [Decision.Resync] (crossfade skip down to the target);
 *  - floor below target - 30 ms (the A/V target rose a lot): [Decision.Rebuffer] (fade out, refill, fade in);
 *  - otherwise a PI step: ratio = 1 + (Kp * err + I) ppm, at most +-0.1 %, +-0.5 % while |err| > 20 ms.
 *
 * Target = max(safety, A/V floor). Safety starts at 5 ms, grows by 5 ms per underrun (40 ms at most) and shrinks by
 * 1 ms after every 10 windows without one. After an underrun, playback restarts once the level reaches
 * target + the last window's span, so the next floor lands near the target instead of underrunning again.
 */
class DriftController(private val sampleRate: Int = 48_000) {
    sealed interface Decision {
        data object None : Decision
        data class Resync(val dropFrames: Int) : Decision
        data object Rebuffer : Decision
    }

    private fun ms(v: Int) = v * sampleRate / 1000

    private val windowFrames = sampleRate
    private val safetyMin = ms(SAFETY_MIN_MS)
    private val safetyMax = ms(SAFETY_MAX_MS)
    private val minSpan = ms(PACKET_MS)

    var safetyFrames = safetyMin
        private set

    /** Floor that would put the audio at the A/V target (0 = no A/V constraint). */
    var avFloorFrames = 0
        private set

    val targetFrames: Int get() = maxOf(safetyFrames, avFloorFrames)

    var ratioPpm = 0.0
        private set
    val ratio: Double get() = 1.0 + ratioPpm * 1e-6
    private var integralPpm = 0.0

    /** Floor and span of the last complete window (-1 before the first). */
    var lastFloorFrames = -1
        private set
    var lastSpanFrames = minSpan
        private set

    var underruns = 0L; private set
    var resyncs = 0L; private set
    var rebuffers = 0L; private set

    private var winMin = Int.MAX_VALUE
    private var winMax = Int.MIN_VALUE
    private var winFrames = 0
    private var cleanWindows = 0

    /** Level the buffer must reach before playback (re)starts. */
    fun refillThresholdFrames(): Int = minOf(targetFrames + lastSpanFrames, ms(MAX_REFILL_MS))

    /** Playback (re)started: the next window starts now. */
    fun onPlaybackStart() = startWindow()

    /** An underrun happened (fade-out then silence): more safety. */
    fun onUnderrun() {
        underruns++
        safetyFrames = minOf(safetyFrames + ms(SAFETY_STEP_MS), safetyMax)
        cleanWindows = 0
        startWindow()
    }

    /** Called after every played burst with the frames left in the buffer. */
    fun onBurst(remainingFrames: Int, outFrames: Int): Decision {
        if (remainingFrames < winMin) winMin = remainingFrames
        if (remainingFrames > winMax) winMax = remainingFrames
        winFrames += outFrames
        if (winFrames < windowFrames) return Decision.None
        val floor = winMin
        lastFloorFrames = floor
        lastSpanFrames = (winMax - winMin).coerceIn(minSpan, ms(MAX_SPAN_MS))
        startWindow()
        if (++cleanWindows >= DECAY_WINDOWS) {
            cleanWindows = 0
            safetyFrames = maxOf(safetyMin, safetyFrames - ms(SAFETY_DECAY_MS))
        }
        val err = floor - targetFrames
        if (err > ms(RESYNC_ABOVE_MS)) {
            resyncs++
            lastFloorFrames = targetFrames
            return Decision.Resync(err)
        }
        if (-err > ms(REBUFFER_BELOW_MS)) {
            rebuffers++
            return Decision.Rebuffer
        }
        val errMs = err * 1000.0 / sampleRate
        val fast = abs(errMs) > FAST_ABOVE_MS
        if (!fast) {
            integralPpm = (integralPpm + KI_PPM_PER_MS_S * errMs * windowFrames / sampleRate)
                .coerceIn(-INTEGRAL_LIMIT_PPM, INTEGRAL_LIMIT_PPM)
        }
        val limit = if (fast) FAST_LIMIT_PPM else NORMAL_LIMIT_PPM
        ratioPpm = (KP_PPM_PER_MS * errMs + integralPpm).coerceIn(-limit, limit)
        return Decision.None
    }

    /**
     * One A/V sample: [avOffsetUs] = audio latency - video latency over the last window (positive = audio late).
     * Moves the A/V floor so the audio lands [AV_TARGET_US] late; changes under 5 ms are ignored. Returns true when
     * the target changed.
     */
    fun onAvOffset(avOffsetUs: Long): Boolean {
        if (lastFloorFrames < 0) return false
        val desired = (lastFloorFrames + (AV_TARGET_US - avOffsetUs) * sampleRate / 1_000_000L).toInt()
            .coerceIn(0, ms(AV_MAX_MS))
        if (abs(desired - avFloorFrames) <= ms(AV_DEADBAND_MS)) return false
        avFloorFrames = desired
        return true
    }

    private fun startWindow() {
        winMin = Int.MAX_VALUE
        winMax = Int.MIN_VALUE
        winFrames = 0
    }

    companion object {
        const val SAFETY_MIN_MS = 5
        const val SAFETY_MAX_MS = 40
        const val SAFETY_STEP_MS = 5
        const val SAFETY_DECAY_MS = 1
        const val DECAY_WINDOWS = 10
        const val PACKET_MS = 10
        const val MAX_SPAN_MS = 100
        const val MAX_REFILL_MS = 250
        const val RESYNC_ABOVE_MS = 120
        const val REBUFFER_BELOW_MS = 30
        const val FAST_ABOVE_MS = 20.0
        const val NORMAL_LIMIT_PPM = 1_000.0
        const val FAST_LIMIT_PPM = 5_000.0
        const val KP_PPM_PER_MS = 100.0
        const val KI_PPM_PER_MS_S = 5.0
        const val INTEGRAL_LIMIT_PPM = 1_000.0
        /** Audio may be up to 10 ms early and should be at most 40 ms late: aim slightly late. */
        const val AV_TARGET_US = 5_000L
        const val AV_DEADBAND_MS = 5
        const val AV_MAX_MS = 200
    }
}
