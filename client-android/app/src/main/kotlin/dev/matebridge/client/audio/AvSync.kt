package dev.matebridge.client.audio

/**
 * A/V timing arithmetic (pure). All client times are `System.nanoTime()`-based microseconds (the session clock);
 * host times are converted with the ClockSync offset (PROTOCOL.md section 6).
 */
object AvSync {
    /**
     * Client time at which output frame [frameIndex] (counted from the track's start) will be heard, from an
     * AudioTimestamp ([tsFramePosition] presented at [tsNanoTime]).
     */
    fun presentTimeUs(frameIndex: Long, tsFramePosition: Long, tsNanoTime: Long, sampleRate: Int = 48_000): Long =
        tsNanoTime / 1000 + (frameIndex - tsFramePosition) * 1_000_000L / sampleRate

    /** Capture-to-ear latency of a frame captured at host time [captureHostUs] and heard at client time [presentUs]. */
    fun audioLatencyUs(presentUs: Long, captureHostUs: Long, hostMinusClientUs: Long): Long =
        presentUs - (captureHostUs - hostMinusClientUs)

    /**
     * Video capture-to-display estimate: capture to decoder output (measured), plus the pacer's added hold, plus one
     * display period for composition/scan-out (an estimate; SurfaceFlinger does not report it). Null if unknown.
     */
    fun videoLatencyUs(toOutputUs: Long?, paceAddUs: Long?, vsyncPeriodUs: Long): Long? {
        if (toOutputUs == null) return null
        return toOutputUs + (paceAddUs ?: 0L) + vsyncPeriodUs.coerceAtLeast(0L)
    }
}
