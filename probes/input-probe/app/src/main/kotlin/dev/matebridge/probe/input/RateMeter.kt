package dev.matebridge.probe.input

/**
 * Sliding-window sample rate estimator. Feed it event timestamps (ms, monotonic);
 * batched historical samples count individually so the result is the true digitizer rate.
 */
class RateMeter(private val windowMs: Long = 500) {
    private val times = ArrayDeque<Long>()

    fun add(timeMs: Long) {
        times.addLast(timeMs)
        while (times.isNotEmpty() && timeMs - times.first() > windowMs) times.removeFirst()
    }

    /** Samples per second over the current window, 0 if fewer than 2 samples or no time span. */
    fun hz(): Double {
        if (times.size < 2) return 0.0
        val span = times.last() - times.first()
        if (span <= 0) return 0.0
        return (times.size - 1) * 1000.0 / span
    }

    /** Returns 0 if the last sample is older than the window relative to nowMs (pen lifted). */
    fun hzAt(nowMs: Long): Double =
        if (times.isEmpty() || nowMs - times.last() > windowMs) 0.0 else hz()

    fun clear() = times.clear()
}
