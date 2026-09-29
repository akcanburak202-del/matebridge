package dev.matebridge.client.stream

/**
 * Host/client clock offset estimate from PING/PONG (PROTOCOL.md section 6). Pure Kotlin, thread-safe.
 *
 *  rtt = now - echo; offset = responder - (echo + rtt/2); the offset of the lowest-rtt recent sample wins.
 * All client times must come from the same monotonic clock (the session engine's `nanoTime/1000`).
 */
class ClockSync(private val windowSize: Int = 8) {
    private class Sample(val rttUs: Long, val offsetUs: Long)

    private val samples = ArrayDeque<Sample>()

    @Synchronized fun onPong(echoUs: Long, responderUs: Long, nowUs: Long) {
        val rtt = nowUs - echoUs
        if (rtt < 0) return // bogus echo
        samples.addLast(Sample(rtt, responderUs - (echoUs + rtt / 2)))
        while (samples.size > windowSize) samples.removeFirst()
    }

    @Synchronized fun reset() = samples.clear()

    /** host clock minus client clock, or null before the first sample. */
    @Synchronized fun offsetUs(): Long? = samples.minByOrNull { it.rttUs }?.offsetUs

    @Synchronized fun bestRttUs(): Long? = samples.minOfOrNull { it.rttUs }

    /** Capture-to-display latency; [displayUs] is client time. Null when the offset is unknown. */
    fun latencyUs(captureHostUs: Long, displayUs: Long): Long? {
        val off = offsetUs() ?: return null
        return (displayUs - (captureHostUs - off)).coerceAtLeast(0)
    }
}
