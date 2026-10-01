package dev.matebridge.client.audio

/**
 * Play position of the current output, the same for AudioTrack and AAudio (T-100). Pure; writer thread only.
 *
 * [written] counts frames handed to the output since it was opened (including the silence written before start), and
 * the output's latest timestamp says frame [framePosition] was presented at [nanoTime] (CLOCK_MONOTONIC, i.e.
 * `System.nanoTime()`). Frame `written` is heard at `nanoTime + (written - framePosition) / rate`
 * ([AvSync.presentTimeUs]).
 *
 * AudioTrack counts its timestamp position from its start, like [written], so it uses [onTimestamp] (unchanged).
 * AAudio (T-101): our own count and AAudio's frame counters need not be the same domain (an MMAP stream's write counter
 * is advanced at start to catch up with a reader that is already running, and its timestamp need not count from our
 * first frame); mixing them gave a latency ~430 ms too high on the device (NOTES 2026-10-01). So an AAudio output
 * reports its own counters
 * ([onDeviceCounters]): [domainOffset] = AAudio frames written - [written], the play position is taken in AAudio's
 * domain and shifted into ours.
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
    /** AAudio frames written minus [written] at the last [onDeviceCounters] (0 for AudioTrack). */
    var domainOffset = 0L
        private set
    /** Where the last [onDeviceCounters] position came from (logs). */
    var source = Source.NONE
        private set

    enum class Source(val logName: String) {
        NONE("-"),
        /** The output's timestamp, consistent with its read counter. */
        TIMESTAMP("ts"),
        /** The output's read counter, taken as presented now (no or inconsistent timestamp). */
        READ("read"),
    }

    /** A new output was opened with [preFrames] already written. */
    fun reset(preFrames: Long) {
        written = preFrames
        valid = false
        framePosition = 0
        nanoTime = 0
        domainOffset = 0
        source = Source.NONE
    }

    fun onWrite(frames: Int) {
        if (frames > 0) written += frames
    }

    /** AudioTrack: frame [position] (counted like [written]) was presented at [timeNs]. */
    fun onTimestamp(position: Long, timeNs: Long) {
        framePosition = position
        nanoTime = timeNs
        valid = true
    }

    /**
     * AAudio's own counters, read together at [nowNs] (CLOCK_MONOTONIC): [deviceWritten] (getFramesWritten),
     * [deviceRead] (getFramesRead) and the timestamp ([tsPosition] presented at [tsNanoTime]; null if getTimestamp
     * failed). The timestamp is used if its position, carried forward to [nowNs], is [MIN_LAG_US]..[MAX_LAG_US] behind
     * [deviceRead] (the device presents what it read a little earlier); otherwise the frame at [deviceRead] is taken as
     * presented now. Either way the position is in AAudio's domain, so the latency of the newest frame is
     * (frames written - frames read) plus the device's own delay, whatever our count says. Returns the source used.
     */
    fun onDeviceCounters(deviceWritten: Long, deviceRead: Long, tsPosition: Long?, tsNanoTime: Long, nowNs: Long): Source {
        domainOffset = deviceWritten - written
        if (tsPosition != null && timestampLagUs(deviceRead, tsPosition, tsNanoTime, nowNs) in MIN_LAG_US..MAX_LAG_US) {
            framePosition = tsPosition - domainOffset
            nanoTime = tsNanoTime
            source = Source.TIMESTAMP
        } else {
            framePosition = deviceRead - domainOffset
            nanoTime = nowNs
            source = Source.READ
        }
        valid = true
        return source
    }

    /** How far (µs) the timestamp's position, carried forward to [nowNs], is behind [deviceRead]. */
    fun timestampLagUs(deviceRead: Long, tsPosition: Long, tsNanoTime: Long, nowNs: Long): Long =
        (deviceRead - tsPosition) * 1_000_000L / sampleRate - (nowNs - tsNanoTime) / 1000

    /** Client time (µs, session clock) at which the newest written frame will be heard; null without a timestamp. */
    fun presentTimeUs(): Long? = if (valid) AvSync.presentTimeUs(written, framePosition, nanoTime, sampleRate) else null

    /** Output latency (µs) of the newest written frame at [nowNs]; null without a timestamp. */
    fun latencyUs(nowNs: Long): Long? = presentTimeUs()?.let { it - nowNs / 1000 }

    companion object {
        /** A timestamp may run this far ahead of the read counter (jitter between the two)... */
        const val MIN_LAG_US = -20_000L
        /** ...and at most this far behind it (the device's own presentation delay). */
        const val MAX_LAG_US = 100_000L
    }
}
