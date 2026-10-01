package dev.matebridge.client.audio

/**
 * Audio output preference. The panel's "Ses çıkışı" setting (T-101) is [AUTO] ("Düşük gecikme", the default) or
 * [TRACK] ("Uyumlu"); the `--es audio_out aaudio|track|auto` launch switch (T-100) overrides it without saving it.
 */
enum class AudioOutPref {
    /** Decision 0012 order: AAudio EXCLUSIVE, then AAudio SHARED if its measured latency is reasonable, then AudioTrack. */
    AUTO,
    /** AAudio MMAP (exclusive, else shared) without the shared latency check; AudioTrack if AAudio MMAP cannot be used. */
    AAUDIO,
    /** AudioTrack only (the pre-T-100 path). */
    TRACK;

    /** Stored and logged value (`auto`, `aaudio`, `track`); [parse] reads it back. */
    val id: String get() = name.lowercase()

    /** The preference in effect, and whether it came from the stored setting or the launch extra. */
    data class Resolved(val pref: AudioOutPref, val fromExtra: Boolean, val unknownExtra: Boolean) {
        val source: String get() = if (fromExtra) "extra" else "setting"
    }

    companion object {
        const val EXTRA = "audio_out"

        /** [AUTO] for null; null for an unknown value (the caller warns and uses [AUTO]). */
        fun parse(raw: String?): AudioOutPref? = when (raw?.trim()?.lowercase()) {
            null, "", "auto" -> AUTO
            "aaudio" -> AAUDIO
            "track", "audiotrack" -> TRACK
            else -> null
        }

        /**
         * T-101: a launch extra [extraRaw] (null = absent) overrides the [stored] setting; an unknown extra is ignored
         * (the caller warns) and the setting is used. The extra is never saved.
         */
        fun resolve(extraRaw: String?, stored: AudioOutPref): Resolved {
            if (extraRaw == null) return Resolved(stored, fromExtra = false, unknownExtra = false)
            val p = parse(extraRaw) ?: return Resolved(stored, fromExtra = false, unknownExtra = true)
            return Resolved(p, fromExtra = true, unknownExtra = false)
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
 *    (an exclusive request granted a shared stream), is skipped until [reset].
 *  - Only MMAP AAudio streams are used (T-100 review M1): a legacy (non-MMAP or unknown) stream is AudioTrack inside
 *    AAudio, whose write ignores the timeout, so a stop could hang. It is [Verdict.REJECT]ed, in every preference,
 *    and both AAudio steps are skipped until [reset].
 *  - A shared MMAP stream (asked for, or granted instead of exclusive) is on probation in [AudioOutPref.AUTO]: the
 *    writer measures its latency ([SharedLatencyProbe]) and calls [onProbationFailed] if it is too high.
 *  - [reset]: a new host stream, or the output device changed (disconnect, routing): the chain starts from the top.
 *  - [onAaudioFailure]: an AAudio stream failed while running (disconnected, write error, stall). [MAX_FAILURES]
 *    within [WINDOW_MS] disable AAudio for this policy's lifetime: AudioTrack from then on, the session is unaffected.
 *    [disableAaudio] does so at once (the native library is unusable).
 *  - [setPref] (T-101, the panel's "Ses çıkışı"): a new preference starts the chain from the top and forgets the
 *    failure count (the user asked again); an unusable library stays disabled.
 */
class SinkPolicy(
    pref: AudioOutPref,
    aaudioAvailable: Boolean,
    private val maxFailures: Int = MAX_FAILURES,
    private val windowMs: Long = WINDOW_MS,
) {
    enum class Verdict { ACCEPT, PROBATION, REJECT }

    @get:Synchronized var pref: AudioOutPref = pref
        private set
    /** The native library is missing or failed: never again in this policy. */
    private var libraryUnusable = !aaudioAvailable
    /** Too many AAudio failures: AudioTrack until [setPref]. */
    private var failedOut = false

    /** AAudio is not used any more (library missing or too many failures). */
    val aaudioDisabled: Boolean @Synchronized get() = libraryUnusable || failedOut

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
     * [choice] opened with sharing [exclusive] and MMAP state [mmap] (1 yes, 0 no, -1 unknown). A non-MMAP AAudio stream
     * is rejected (the caller closes it and asks [next] again). An exclusive request granted a shared MMAP stream is
     * kept: it is the shared candidate, the next step anyway.
     */
    @Synchronized fun onOpened(choice: OutChoice, exclusive: Boolean, mmap: Int): Verdict {
        if (choice == OutChoice.TRACK) return Verdict.ACCEPT
        if (mmap != 1) {
            exclusiveOut = true
            sharedOut = true
            return Verdict.REJECT
        }
        if (choice == OutChoice.AAUDIO_EXCLUSIVE && exclusive) return Verdict.ACCEPT
        exclusiveOut = true
        return if (pref == AudioOutPref.AAUDIO) Verdict.ACCEPT else Verdict.PROBATION
    }

    /** The shared stream's latency was not reasonable: skip SHARED until [reset]. */
    @Synchronized fun onProbationFailed() {
        sharedOut = true
    }

    /** AAudio cannot be used at all (e.g. a LinkageError from the native library): AudioTrack from now on. */
    @Synchronized fun disableAaudio() {
        libraryUnusable = true
        failures.clear()
    }

    /** An AAudio stream failed at [nowMs]; true if this failure disabled AAudio. */
    @Synchronized fun onAaudioFailure(nowMs: Long): Boolean {
        if (aaudioDisabled) return false
        while (failures.isNotEmpty() && nowMs - failures.first() > windowMs) failures.removeFirst()
        failures.addLast(nowMs)
        if (failures.size < maxFailures) return false
        failedOut = true
        failures.clear()
        return true
    }

    /** T-101: the user picked [p]; true if it changed (the chain starts again and the failure count is forgotten). */
    @Synchronized fun setPref(p: AudioOutPref): Boolean {
        if (p == pref) return false
        pref = p
        failedOut = false
        failures.clear()
        reset()
        return true
    }

    companion object {
        const val MAX_FAILURES = 3
        const val WINDOW_MS = 10_000L
    }
}
