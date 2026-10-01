package dev.matebridge.client.audio

/** The `--es audio_out aaudio|track` experiment switch (T-100); absent = [AUTO]. */
enum class AudioOutPref {
    /** Decision 0012 order: AAudio EXCLUSIVE, then AAudio SHARED if its measured latency is reasonable, then AudioTrack. */
    AUTO,
    /** AAudio (exclusive, else shared) without the shared latency check; AudioTrack only if AAudio cannot be used. */
    AAUDIO,
    /** AudioTrack only (the pre-T-100 path). */
    TRACK;

    companion object {
        const val EXTRA = "audio_out"

        /** [AUTO] for null; null for an unknown value (the caller warns and uses [AUTO]). */
        fun parse(raw: String?): AudioOutPref? = when (raw?.trim()?.lowercase()) {
            null, "", "auto" -> AUTO
            "aaudio" -> AAUDIO
            "track", "audiotrack" -> TRACK
            else -> null
        }
    }
}

/** The output to try next. */
enum class OutChoice(val logName: String) {
    AAUDIO_EXCLUSIVE("exclusive"),
    AAUDIO_SHARED("shared"),
    TRACK("track"),
}

/**
 * Which output to open (decision 0012 point 2), and when to give up on AAudio. Pure; called by the audio writer
 * threads (synchronized because a new stream's writer can overlap a slow previous one).
 *
 *  - The chain is EXCLUSIVE -> SHARED -> TRACK. A step that cannot be opened, or that turns out to be something else
 *    (an exclusive request granted a shared or non-MMAP stream), is skipped until [reset].
 *  - A shared stream (asked for, or granted instead of exclusive) is on probation in [AudioOutPref.AUTO]: the writer
 *    measures its latency ([SharedLatencyProbe]) and calls [onProbationFailed] if it is too high.
 *  - [reset]: a new host stream, or the output device changed (disconnect, routing): the chain starts from the top.
 *  - [onAaudioFailure]: an AAudio stream failed while running (disconnected, write error, stall). [MAX_FAILURES]
 *    within [WINDOW_MS] disable AAudio for this policy's lifetime: AudioTrack from then on, the session is unaffected.
 */
class SinkPolicy(
    val pref: AudioOutPref,
    aaudioAvailable: Boolean,
    private val maxFailures: Int = MAX_FAILURES,
    private val windowMs: Long = WINDOW_MS,
) {
    enum class Verdict { ACCEPT, PROBATION }

    /** AAudio is not used any more (library missing or too many failures). */
    @get:Synchronized var aaudioDisabled = !aaudioAvailable
        private set
    private var exclusiveOut = false
    private var sharedOut = false
    private val failures = ArrayDeque<Long>()

    @Synchronized fun next(): OutChoice = when {
        pref == AudioOutPref.TRACK || aaudioDisabled -> OutChoice.TRACK
        !exclusiveOut -> OutChoice.AAUDIO_EXCLUSIVE
        !sharedOut -> OutChoice.AAUDIO_SHARED
        else -> OutChoice.TRACK
    }

    /** New stream or new output device: try the whole chain again (a disabled AAudio stays disabled). */
    @Synchronized fun reset() {
        exclusiveOut = false
        sharedOut = false
    }

    @Synchronized fun onOpenFailed(choice: OutChoice) {
        when (choice) {
            OutChoice.AAUDIO_EXCLUSIVE -> exclusiveOut = true
            OutChoice.AAUDIO_SHARED -> sharedOut = true
            OutChoice.TRACK -> Unit
        }
    }

    /**
     * [choice] opened with sharing [exclusive] and MMAP state [mmap] (1 yes, 0 no, -1 unknown). An exclusive request
     * granted something else is kept: it is the shared candidate, the next step anyway.
     */
    @Synchronized fun onOpened(choice: OutChoice, exclusive: Boolean, mmap: Int): Verdict {
        if (choice == OutChoice.TRACK) return Verdict.ACCEPT
        if (choice == OutChoice.AAUDIO_EXCLUSIVE && exclusive && mmap != 0) return Verdict.ACCEPT
        exclusiveOut = true
        return if (pref == AudioOutPref.AAUDIO) Verdict.ACCEPT else Verdict.PROBATION
    }

    /** The shared stream's latency was not reasonable: skip SHARED until [reset]. */
    @Synchronized fun onProbationFailed() {
        sharedOut = true
    }

    /** An AAudio stream failed at [nowMs]; true if this failure disabled AAudio. */
    @Synchronized fun onAaudioFailure(nowMs: Long): Boolean {
        if (aaudioDisabled) return false
        while (failures.isNotEmpty() && nowMs - failures.first() > windowMs) failures.removeFirst()
        failures.addLast(nowMs)
        if (failures.size < maxFailures) return false
        aaudioDisabled = true
        failures.clear()
        return true
    }

    companion object {
        const val MAX_FAILURES = 3
        const val WINDOW_MS = 10_000L
    }
}
