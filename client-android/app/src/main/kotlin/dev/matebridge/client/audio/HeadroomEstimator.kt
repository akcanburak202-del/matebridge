package dev.matebridge.client.audio

/**
 * T-114: the AAudio output's headroom (frames written and not yet read by the device), from the output's own counters
 * ([AAudioNative.counters]). Pure; writer thread only; does not allocate.
 *
 * On an MMAP stream `getFramesRead` comes from the client's own clock model, which advances a burst at a time, and the
 * blocking write wakes on that same model; so `written - read` is the full buffer whenever it is sampled unless the
 * writer missed a whole burst (T-110 on the device: always 960 with a 960-frame buffer). The device's real position is
 * only seen through `getTimestamp` (from the HAL): the read position now is estimated as the timestamp's position
 * carried forward at the nominal rate, `tsPos + (now - tsNs) × rate`, and the headroom is `written` minus that
 * ([source] [Source.TIMESTAMP]).
 *
 * The timestamp is used only when it agrees with the read counter as [OutputClock] requires (its lag within
 * [OutputClock.MIN_LAG_US]..[OutputClock.MAX_LAG_US]); otherwise, or without a timestamp, the counter headroom is used
 * ([Source.COUNTER]). If the timestamp is a presentation position, the estimate is high by the device's presentation
 * delay (the cautious side: a late grow rather than a false one); the counter headroom is kept ([counterHeadroom]) so
 * the logs show both.
 */
class HeadroomEstimator(private val sampleRate: Int = 48_000) {
    enum class Source(val logName: String) { TIMESTAMP("ts"), COUNTER("counter") }

    /** Where the last [estimate] came from. */
    var source = Source.COUNTER
        private set

    /** `written - read` at the last [estimate]. */
    var counterHeadroom = 0L
        private set

    /**
     * Headroom from AAudio's frames [written] and [read], and its timestamp ([tsPosition] presented at [tsNanoTime];
     * [tsNanoTime] 0 = no timestamp), all read at [nowNs] (CLOCK_MONOTONIC).
     */
    fun estimate(written: Long, read: Long, tsPosition: Long, tsNanoTime: Long, nowNs: Long): Long {
        counterHeadroom = written - read
        if (tsNanoTime != 0L) {
            val elapsedFrames = (nowNs - tsNanoTime) * sampleRate / 1_000_000_000L
            val readNow = tsPosition + elapsedFrames
            // Same check as OutputClock.timestampLagUs: how far the carried-forward timestamp is behind the read counter.
            val lagUs = (read - readNow) * 1_000_000L / sampleRate
            if (lagUs in OutputClock.MIN_LAG_US..OutputClock.MAX_LAG_US) {
                source = Source.TIMESTAMP
                return written - readNow
            }
        }
        source = Source.COUNTER
        return counterHeadroom
    }
}
