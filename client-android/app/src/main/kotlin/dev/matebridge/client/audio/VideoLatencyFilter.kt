package dev.matebridge.client.audio

/**
 * Median of the last [size] per-second video latency estimates (T-095 review M1): a single Wi-Fi spike must not
 * move the audio's A/V target. Thread-safe: the UI adds, the audio writer reads.
 */
class VideoLatencyFilter(private val size: Int = 5) {
    private val values = LongArray(size)
    private var count = 0
    private var next = 0

    /** A new estimate; null (no video) clears the history. */
    @Synchronized fun add(us: Long?) {
        if (us == null) { count = 0; next = 0; return }
        values[next] = us
        next = (next + 1) % size
        if (count < size) count++
    }

    /** Median of the stored estimates, or null when there are none. */
    @Synchronized fun value(): Long? {
        if (count == 0) return null
        val s = values.copyOf(count).also { it.sort() }
        return if (count % 2 == 1) s[count / 2] else (s[count / 2 - 1] + s[count / 2]) / 2
    }
}
