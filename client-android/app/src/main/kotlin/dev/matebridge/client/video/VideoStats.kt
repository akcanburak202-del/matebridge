package dev.matebridge.client.video

/** Decoder-side counters for STATS (PROTOCOL.md 0x22). Pure Kotlin, thread-safe. */
class VideoStats {
    data class Snapshot(
        val received: Long,
        val decoded: Long,
        val rendered: Long,
        val dropped: Long,
        val decodeTimeAvgUs: Long,
        val bytesReceived: Long,
    )

    private var received = 0L
    private var decoded = 0L
    private var rendered = 0L
    private var dropped = 0L
    private var bytes = 0L
    private var decodeSumUs = 0L
    private var decodeCount = 0L
    private val inputTimes = HashMap<Long, Long>() // pts -> input time (us)

    @Synchronized fun onReceived(size: Int) { received++; bytes += size }
    @Synchronized fun onDropped(n: Int) { dropped += n }
    @Synchronized fun onRendered() { rendered++ }

    /** Frame handed to the decoder. Bounded: stale entries are evicted. */
    @Synchronized fun onInput(ptsUs: Long, nowUs: Long) {
        inputTimes[ptsUs] = nowUs
        if (inputTimes.size > 64) inputTimes.remove(inputTimes.keys.min())
    }

    /** Decoder produced an output for [ptsUs]. */
    @Synchronized fun onOutput(ptsUs: Long, nowUs: Long) {
        decoded++
        inputTimes.remove(ptsUs)?.let { decodeSumUs += (nowUs - it).coerceAtLeast(0); decodeCount++ }
    }

    /** Current window; with [reset] a new window starts (per-second STATS). */
    @Synchronized fun snapshot(reset: Boolean = false): Snapshot {
        val s = Snapshot(received, decoded, rendered, dropped,
            if (decodeCount > 0) decodeSumUs / decodeCount else 0, bytes)
        if (reset) {
            received = 0; decoded = 0; rendered = 0; dropped = 0; bytes = 0
            decodeSumUs = 0; decodeCount = 0
        }
        return s
    }
}
