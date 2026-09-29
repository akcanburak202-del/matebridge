package dev.matebridge.client.video

/** Allows at most [maxRestarts] codec restarts within any [windowMs] window; then gives up. */
class RestartPolicy(private val maxRestarts: Int = 3, private val windowMs: Long = 10_000) {
    private val times = ArrayDeque<Long>()

    /** Records a restart attempt at [nowMs]; false means the limit is exceeded (give up). */
    fun allow(nowMs: Long): Boolean {
        while (times.isNotEmpty() && nowMs - times.first() >= windowMs) times.removeFirst()
        if (times.size >= maxRestarts) return false
        times.addLast(nowMs)
        return true
    }
}
