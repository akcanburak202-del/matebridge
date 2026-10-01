package dev.matebridge.client.video

/**
 * Decoder input buffer taken ahead of the frame (T-077). Pure Kotlin; [dequeue] is `MediaCodec.dequeueInputBuffer`
 * (timeout in microseconds, index or negative). Decoder input thread only.
 *
 * While the input thread waits for the next frame it already holds a free input buffer ([prefetch], non-blocking), so a
 * frame that arrives costs only the copy and `queueInputBuffer`, not a dequeue round trip to the codec's looper. When
 * no buffer was free the frame falls back to a blocking dequeue, exactly as before.
 */
class InputBufferSlot(private val dequeue: (Long) -> Int) {
    /** Held index, or -1. */
    var index = -1
        private set

    /** True when the index returned by the last [take] had been prefetched. */
    var lastPrefetched = false
        private set

    /** Takes a free input buffer now if none is held; never blocks. Returns true when one is held. */
    fun prefetch(): Boolean {
        if (index < 0) index = dequeue(0).coerceAtLeast(-1)
        return index >= 0
    }

    /** Index for a frame: the held one, else a dequeue waiting up to [timeoutUs]. Negative = none (retry later). */
    fun take(timeoutUs: Long): Int {
        val held = index
        index = -1
        lastPrefetched = held >= 0
        return if (held >= 0) held else dequeue(timeoutUs)
    }
}
