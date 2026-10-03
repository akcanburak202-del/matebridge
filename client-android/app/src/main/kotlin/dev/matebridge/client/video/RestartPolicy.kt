package dev.matebridge.client.video

/**
 * Allows at most [maxRestarts] codec restarts within any [windowMs] window; then gives up.
 *
 * T-161: restarts are spaced by a backoff ([delayMs]: 100 ms before the first restart of the window, 500 ms before the
 * second, 1 s before the third), so a codec that still holds the hardware decoder does not make the next creates fail
 * within milliseconds.
 */
class RestartPolicy(
    private val maxRestarts: Int = 3,
    private val windowMs: Long = 10_000,
    private val delaysMs: LongArray = DELAYS_MS,
) {
    companion object {
        val DELAYS_MS = longArrayOf(100L, 500L, 1_000L)
    }

    private val times = ArrayDeque<Long>()

    /** Records a restart attempt at [nowMs]; false means the limit is exceeded (give up). */
    fun allow(nowMs: Long): Boolean {
        while (times.isNotEmpty() && nowMs - times.first() >= windowMs) times.removeFirst()
        if (times.size >= maxRestarts) return false
        times.addLast(nowMs)
        return true
    }

    /** Wait before the restart just allowed: by its position in the window (the last delay repeats). */
    fun delayMs(): Long {
        if (delaysMs.isEmpty()) return 0
        return delaysMs[(times.size - 1).coerceIn(0, delaysMs.size - 1)]
    }
}
