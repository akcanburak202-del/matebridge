package dev.matebridge.client.video

/**
 * Decision 0038 section 7 (every session): while the client waits for a keyframe, the STARTUP repeat starts at
 * [START_MS], doubles after each repeat and stops at [MAX_MS] (500, 1000, 2000, 4000, 4000, ...). It starts over when a
 * keyframe arrived or any other keyframe request went out. On a slow link this keeps the repeats from invalidating the
 * keyframe that is still on its way; on a local link the keyframe arrives within the first 500 ms and nothing changes.
 * Not thread-safe; [FrameQueue] calls it under its lock.
 */
class KeyframeRetryBackoff {
    /** How long after the last request the next repeat may go out. */
    var delayMs: Long = START_MS
        private set

    fun reset() { delayMs = START_MS }

    /** Continues the sequence at [ms] (a repeat is also a request, which resets). */
    fun restore(ms: Long) { delayMs = ms.coerceIn(START_MS, MAX_MS) }

    /** A repeat went out after the current delay: the next one waits twice as long (capped). Returns the delay used. */
    fun onRepeat(): Long {
        val used = delayMs
        delayMs = minOf(MAX_MS, used * 2)
        return used
    }

    companion object {
        const val START_MS = 500L
        const val MAX_MS = 4000L
    }
}
