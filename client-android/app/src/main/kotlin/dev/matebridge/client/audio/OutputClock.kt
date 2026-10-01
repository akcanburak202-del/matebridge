package dev.matebridge.client.audio

/**
 * Play position of the current output, the same for AudioTrack and AAudio (T-100). Pure; writer thread only.
 *
 * [written] counts frames handed to the output since it was opened (including the silence written before start), and
 * the output's latest timestamp says frame [framePosition] was presented at [nanoTime] (CLOCK_MONOTONIC, i.e.
 * `System.nanoTime()`). Both outputs count frame positions from their start, so frame `written` is heard at
 * `nanoTime + (written - framePosition) / rate` ([AvSync.presentTimeUs]).
 */
class OutputClock(private val sampleRate: Int = 48_000) {
    var written = 0L
        private set
    /** A timestamp has been read from the current output. */
    var valid = false
        private set
    var framePosition = 0L
        private set
    var nanoTime = 0L
        private set

    /** A new output was opened with [preFrames] already written. */
    fun reset(preFrames: Long) {
        written = preFrames
        valid = false
        framePosition = 0
        nanoTime = 0
    }

    fun onWrite(frames: Int) {
        if (frames > 0) written += frames
    }

    fun onTimestamp(position: Long, timeNs: Long) {
        framePosition = position
        nanoTime = timeNs
        valid = true
    }

    /** Client time (µs, session clock) at which the newest written frame will be heard; null without a timestamp. */
    fun presentTimeUs(): Long? = if (valid) AvSync.presentTimeUs(written, framePosition, nanoTime, sampleRate) else null

    /** Output latency (µs) of the newest written frame at [nowNs]; null without a timestamp. */
    fun latencyUs(nowNs: Long): Long? = presentTimeUs()?.let { it - nowNs / 1000 }
}
