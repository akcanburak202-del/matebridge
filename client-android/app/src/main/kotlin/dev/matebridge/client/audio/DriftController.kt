package dev.matebridge.client.audio

import kotlin.math.abs

/**
 * Keeps the jitter buffer's level floor at a target by nudging the resampling ratio (decision 0011). Pure Kotlin,
 * single-threaded (the audio writer thread). Time is counted in output frames, so it is deterministic in tests.
 *
 * Level = frames left in the buffer right after a burst was read. Per [WINDOW_FRAMES] (1 s) of output the window's
 * minimum (floor) and peak-to-peak span are taken, then:
 *  - floor above target + 120 ms: [Decision.Resync] (crossfade skip down to the target);
 *  - floor below target - 60 ms: [Decision.Rebuffer] (fade out, refill, fade in);
 *  - otherwise a PI step: ratio = 1 + (Kp * err + I) ppm, at most +-0.1 %, +-0.5 % while |err| > 20 ms.
 *
 * Target = max(safety, A/V floor). Safety starts at 5 ms (or what [resetSafety] sets: T-108, 20 ms or the remembered
 * value on AAudio, see [SafetyMemory]) and grows by 5 ms per underrun (40 ms at most; T-123: the transport's ceiling,
 * 70 ms on Wi-Fi). [retarget] moves to another transport's rules without a reset. T-118: it shrinks by 1 ms per
 * [DECAY_WINDOWS] (5) windows without an underrun, down to its floor: 40 -> 20 ms in 100 s of clean playback, one
 * underrun's 5 ms in 25 s (rare stalls cost a short faded gap instead of a permanently larger delay).
 * After an underrun, playback restarts once the level reaches
 * max(target + the last window's span (at most [REFILL_SPAN_MAX_MS]), target + burst + fade-out), so the next floor
 * lands near the target; [PlayoutCore] drops a bunched arrival's excess above that level before it fades in.
 *
 * The A/V floor ([onAvOffset]) falls at once but rises by at most 10 ms per window, so the PI slews instead of
 * rebuffering; the first A/V target is applied while priming ([seedAvFloor]).
 */
class DriftController(private val sampleRate: Int = 48_000) {
    sealed interface Decision {
        data object None : Decision
        data class Resync(val dropFrames: Int) : Decision
        data object Rebuffer : Decision
    }

    private fun ms(v: Int) = v * sampleRate / 1000

    private val windowFrames = sampleRate
    /** Lowest value the slow decay reaches ([resetSafety]). */
    private var safetyMin = ms(SAFETY_MIN_MS)
    /** In-session ceiling of the underrun steps ([resetSafety], [retarget]). */
    private var safetyMax = ms(SAFETY_MAX_MS)
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

    /** Level the buffer must reach before playback (re)starts with bursts of [burstFrames] and a [fadeOutFrames] reserve. */
    fun refillThresholdFrames(burstFrames: Int = 0, fadeOutFrames: Int = 0): Int =
        minOf(maxOf(targetFrames + refillSpanFrames, targetFrames + burstFrames + fadeOutFrames), maxRefillFrames)

    /**
     * T-118: the span a refill allows for, [lastSpanFrames] capped at [REFILL_SPAN_MAX_MS]: the window before an
     * underrun often holds the stall's own descent, which is not the arrival sawtooth the refill has to cover.
     */
    val refillSpanFrames: Int get() = minOf(lastSpanFrames, ms(REFILL_SPAN_MAX_MS))

    /** One underrun's safety step, in frames. */
    val safetyStepFrames: Int get() = ms(SAFETY_STEP_MS)

    /** Highest refill level: playback starts at this level even if a hold (A/V priming) is still asking to wait. */
    val maxRefillFrames: Int get() = ms(MAX_REFILL_MS)

    /**
     * T-108: the output changed (or the first one opened): safety starts at [initialMs], decays no lower than
     * [floorMs] and underruns raise it to at most [maxMs] (T-123: per transport). [maxMs] is clamped to
     * [SAFETY_MIN_MS]..[SAFETY_CEILING_MS], the others to [SAFETY_MIN_MS]..[maxMs]; the start is at least the floor.
     */
    fun resetSafety(initialMs: Int, floorMs: Int = SAFETY_MIN_MS, maxMs: Int = SAFETY_MAX_MS) {
        val max = maxMs.coerceIn(SAFETY_MIN_MS, SAFETY_CEILING_MS)
        safetyMax = ms(max)
        safetyMin = ms(floorMs.coerceIn(SAFETY_MIN_MS, max))
        safetyFrames = maxOf(ms(initialMs.coerceIn(SAFETY_MIN_MS, max)), safetyMin)
        cleanWindows = 0
    }

    /**
     * T-123: the transport changed under a playing output: the new transport's [floorMs] and [maxMs] apply from now
     * on. Safety rises to [initialMs] at once if it is lower (the level follows through the PI, no refill gap); a higher
     * value is kept and shrinks to the new floor by the normal decay (never dropped at once, even above [maxMs]).
     * Returns true if safety rose.
     */
    fun retarget(initialMs: Int, floorMs: Int, maxMs: Int): Boolean {
        val max = maxMs.coerceIn(SAFETY_MIN_MS, SAFETY_CEILING_MS)
        safetyMax = ms(max)
        safetyMin = ms(floorMs.coerceIn(SAFETY_MIN_MS, max))
        val start = maxOf(ms(initialMs.coerceIn(SAFETY_MIN_MS, max)), safetyMin)
        if (start <= safetyFrames) return false
        safetyFrames = start
        cleanWindows = 0
        return true
    }

    /** Playback (re)started: the next window starts now. */
    fun onPlaybackStart() = startWindow()

    /** An underrun happened (fade-out then silence): more safety. */
    fun onUnderrun() {
        underruns++
        // never lower: after a [retarget] the value may sit above the new ceiling until it decays
        safetyFrames = maxOf(safetyFrames, minOf(safetyFrames + ms(SAFETY_STEP_MS), safetyMax))
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
        decaySafety()
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

    private fun decaySafety() {
        if (safetyFrames <= safetyMin) { cleanWindows = 0; return }
        if (++cleanWindows >= DECAY_WINDOWS) {
            cleanWindows = 0
            safetyFrames = maxOf(safetyMin, safetyFrames - ms(SAFETY_DECAY_MS))
        }
    }

    /**
     * One A/V sample: [avOffsetUs] = audio latency - video latency over the last window (positive = audio late).
     * Moves the A/V floor so the audio lands [AV_TARGET_US] late: down at once, up by at most [AV_MAX_RISE_MS] per
     * call (one call per window). Changes under 5 ms are ignored. Returns true when the target changed.
     */
    fun onAvOffset(avOffsetUs: Long): Boolean {
        if (lastFloorFrames < 0) return false
        val desired = (lastFloorFrames + (AV_TARGET_US - avOffsetUs) * sampleRate / 1_000_000L).toInt()
            .coerceIn(0, ms(AV_MAX_MS))
        if (abs(desired - avFloorFrames) <= ms(AV_DEADBAND_MS)) return false
        avFloorFrames = minOf(desired, avFloorFrames + ms(AV_MAX_RISE_MS))
        return true
    }

    /** Playback started after an A/V hold while priming: [floorFrames] is the expected floor, taken as the A/V floor. */
    fun seedAvFloor(floorFrames: Int) {
        avFloorFrames = floorFrames.coerceIn(0, ms(AV_MAX_MS))
    }

    private fun startWindow() {
        winMin = Int.MAX_VALUE
        winMax = Int.MIN_VALUE
        winFrames = 0
    }

    companion object {
        const val SAFETY_MIN_MS = 5
        /** Default (USB) in-session ceiling; [resetSafety] and [retarget] take the transport's own. */
        const val SAFETY_MAX_MS = 40
        /** Highest ceiling any transport may set (T-123; Wi-Fi uses 70). */
        const val SAFETY_CEILING_MS = 100
        const val SAFETY_STEP_MS = 5
        const val SAFETY_DECAY_MS = 1
        /**
         * T-118 ("balanced", user decision 2026-10-02): 1 ms per 5 clean windows. Was 60 (review L4: never walk back
         * into the underrun); on USB a learned 35-40 ms cost ~20 ms of delay for one underrun per ~6 minutes.
         */
        const val DECAY_WINDOWS = 5
        const val PACKET_MS = 10
        const val MAX_SPAN_MS = 100
        /** T-118: refills allow for at most two packets of arrival sawtooth. */
        const val REFILL_SPAN_MAX_MS = 20
        const val MAX_REFILL_MS = 250
        const val RESYNC_ABOVE_MS = 120
        const val REBUFFER_BELOW_MS = 60
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
        const val AV_MAX_RISE_MS = 10
    }
}
