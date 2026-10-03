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

    /**
     * T-168: signed time from a host capture stamp to the client event at [clientUs] (same monotonic clock as the PONG
     * times). Negative when the offset estimate is off by more than the real latency; null when the offset is unknown.
     */
    fun latencySignedUs(captureHostUs: Long, clientUs: Long): Long? {
        val off = offsetUs() ?: return null
        return clientUs - (captureHostUs - off)
    }

    /** [latencySignedUs] clamped at 0 (for u32 fields such as STATS `latency_avg_us`). */
    fun latencyUs(captureHostUs: Long, clientUs: Long): Long? = latencySignedUs(captureHostUs, clientUs)?.coerceAtLeast(0)

    /** T-168: uncertainty of the offset (best RTT / 2), or null before the first sample. */
    fun uncertaintyUs(): Long? = bestRttUs()?.let { it / 2 }
}
