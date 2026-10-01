package dev.matebridge.client.audio

/**
 * One opened audio output (T-100): [TrackSink] (AudioTrack) or [AAudioSink] (AAudio via NDK, decision 0012).
 *
 * Owned by the audio writer thread: [write], [timestamp], [xruns], [grow] and [close] are called only from it.
 * [interrupt] may be called from any thread to make a blocked [write] return soon; [close] runs exactly once.
 * The output plays 48 kHz s16 interleaved stereo.
 */
interface AudioSink {
    /** "aaudio" or "track" (logs). */
    val api: String
    /** Frames per write (the output's burst). */
    val burst: Int
    /** Current buffer size in frames. */
    val bufFrames: Int
    /** Frames of silence written before the output was started (counted in [OutputClock.written]). */
    val preFrames: Long
    /** Granted sharing is exclusive (AAudio only; false for AudioTrack). */
    val exclusive: Boolean
    /** MMAP in use: 1 yes, 0 no, -1 unknown (AAudio only; -1 for AudioTrack). */
    val mmap: Int
    /** Performance mode name (logs). */
    val perfName: String
    /** Why the last [write] returned [WRITE_DEAD] (logs and rebuild reason). */
    val deadReason: String
    /** The raw error code behind the last failed [write] (logs). */
    val lastError: Int

    /** `api= sharing= mmap= burst= buf= ...` for the `audio_out` log line. */
    fun logFields(): String

    /** Writes [frames] frames from [pcm] (offset 0), paced by the device. Frames written, [WRITE_DEAD] or [WRITE_FAILED]. */
    fun write(pcm: ShortArray, frames: Int): Int

    /** Reads the latest CLOCK_MONOTONIC timestamp into `out[0]` (frame position) and `out[1]` (ns); false if none. */
    fun timestamp(out: LongArray): Boolean

    /**
     * T-101: the output's own counters ([AAudioNative.counters] layout: frames written, frames read, timestamp position
     * and ns, now) into `out`; `out[C_TS_NS]` is 0 when the timestamp failed. False if the output has no such counters
     * (AudioTrack: then [timestamp] is used, as before).
     */
    fun counters(out: LongArray): Boolean = false

    /** Output underruns since open. */
    fun xruns(): Int

    /** Grows the buffer by one burst (up to the output's maximum); true if it grew. */
    fun grow(): Boolean

    /** Any thread: makes a blocked [write] return soon. */
    fun interrupt()

    /** Releases the output (idempotent). */
    fun close()

    companion object {
        /** The output is gone (dead object, disconnected, stalled): rebuild. */
        const val WRITE_DEAD = -1
        /** Any other write error. */
        const val WRITE_FAILED = -2
    }
}

/**
 * An output could not be opened; [message] is a short `key=value` reason for the log. [aaudioUnusable]: the AAudio
 * native library itself failed (missing or a LinkageError), so AAudio must not be tried again.
 */
class SinkOpenException(message: String, val aaudioUnusable: Boolean = false) : Exception(message)
