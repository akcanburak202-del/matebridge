package dev.matebridge.client.files

/**
 * Tunables of the tablet-files WebDAV server (decision 0015, T-135), in one place so the device test can adjust them.
 * The rate cap protects the video stream: file transfers share the USB/adb line with ~7.5 MB/s of video.
 */
data class FilesConfig(
    /** Total transfer rate (request + response bodies of all connections), bytes per second. */
    val rateBytesPerSec: Long = RATE_BYTES_PER_SEC,
    /** Token bucket depth: how much may go out at once after an idle moment. */
    val burstBytes: Long = BURST_BYTES,
    /**
     * Concurrent connections (soft limit). At the limit a truly idle keep-alive connection is closed for a new one;
     * when none is, the new one is taken as overflow, up to [overflowConnections] more (T-139).
     */
    val maxConnections: Int = MAX_CONNECTIONS,
    /** Copy buffer per connection (bounded memory: maxConnections x this). */
    val bufferBytes: Int = BUFFER_BYTES,
    /** An idle keep-alive connection is closed after this long without a request. */
    val idleTimeoutMs: Int = IDLE_TIMEOUT_MS,
    /** A request that stalls mid-transfer is dropped after this long without a byte. */
    val readTimeoutMs: Int = READ_TIMEOUT_MS,
    /** Preferred port on 127.0.0.1; when it is taken the system picks one. */
    val preferredPort: Int = PREFERRED_PORT,
    /**
     * A keep-alive connection may be evicted only after waiting this long for its next request (and only after it
     * completed one, with no unread byte), so fresh connections never evict each other (T-138 livelock).
     */
    val evictIdleMs: Int = EVICT_IDLE_MS,
    /** Connections taken beyond [maxConnections] when nothing is idle; the hard limit is the sum. */
    val overflowConnections: Int = OVERFLOW_CONNECTIONS,
    /** At the hard limit a new connection waits at most this long, then gets `503` + `Retry-After` and is closed. */
    val admitWaitMs: Int = ADMIT_WAIT_MS,
    /** A response write that makes no progress for this long closes the connection (rate-cap waits do not count). */
    val writeTimeoutMs: Int = WRITE_TIMEOUT_MS,
) {
    companion object {
        const val RATE_BYTES_PER_SEC = 20L * 1000 * 1000
        const val BURST_BYTES = 256L * 1024
        const val MAX_CONNECTIONS = 8
        const val BUFFER_BYTES = 64 * 1024
        const val IDLE_TIMEOUT_MS = 30_000
        const val READ_TIMEOUT_MS = 30_000
        const val PREFERRED_PORT = 47010
        const val EVICT_IDLE_MS = 1_000
        const val OVERFLOW_CONNECTIONS = 4
        const val ADMIT_WAIT_MS = 2_000
        const val WRITE_TIMEOUT_MS = 30_000

        /** HTTP auth user name (PROTOCOL.md 0x09); the password is the per-start token. */
        const val USER = "matebridge"
        const val REALM = "MateBridge"

        /** Request head (request line + headers) limit. */
        const val MAX_HEAD_BYTES = 32 * 1024

        /** Largest XML request body we read (PROPFIND / LOCK); bigger ones are refused. */
        const val MAX_XML_BODY_BYTES = 64 * 1024
    }
}
