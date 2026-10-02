package dev.matebridge.client.files

/**
 * Shared byte-rate cap of the file server (T-135): every request and response byte of every connection passes through
 * one bucket of [rateBytesPerSec] with depth [burstBytes]. A taker that finds the bucket short goes into debt and sleeps
 * for exactly that debt, so concurrent takers share the rate and the total never exceeds it (plus one burst).
 * Thread-safe; the sleeping happens outside the lock.
 */
class TokenBucket(
    private val rateBytesPerSec: Long,
    private val burstBytes: Long,
    private val nanoTime: () -> Long = System::nanoTime,
    private val sleepNs: (Long) -> Unit = ::defaultSleep,
) {
    init {
        require(rateBytesPerSec > 0 && burstBytes > 0)
    }

    private val lock = Any()
    private var tokens = burstBytes.toDouble()
    private var lastNs = nanoTime()

    /** Books [n] bytes and returns how long (ns) the caller has to wait before using them; 0 when within budget. */
    fun reserve(n: Long): Long = synchronized(lock) {
        val now = nanoTime()
        val elapsed = (now - lastNs).coerceAtLeast(0)
        lastNs = now
        tokens = minOf(burstBytes.toDouble(), tokens + elapsed * rateBytesPerSec / 1e9)
        tokens -= n
        if (tokens >= 0) 0L else (-tokens * 1e9 / rateBytesPerSec).toLong()
    }

    /** [reserve]s [n] bytes and sleeps the required time. Returns the ns slept (the stats' throttled time). */
    fun acquire(n: Long): Long {
        val wait = reserve(n)
        if (wait > 0) sleepNs(wait)
        return wait
    }

    private companion object {
        fun defaultSleep(ns: Long) = Thread.sleep(ns / 1_000_000, (ns % 1_000_000).toInt())
    }
}

/**
 * Per-second summary of the file server (docs/LOGGING.md style key=value): requests, bytes each way, bytes copied on the
 * tablet (server-side COPY), time spent waiting on the rate cap. Never paths or names. [poll] returns a line at most
 * every [intervalMs] and only after activity, so an idle server writes nothing; `force` is for the final line at stop.
 * Thread-safe.
 */
class FilesStats(private val intervalMs: Long = 1000) {
    private var reqs = 0L
    private var bytesOut = 0L
    private var bytesIn = 0L
    private var bytesCopied = 0L
    private var throttledNs = 0L
    private var lastEmitMs = Long.MIN_VALUE / 2

    @Synchronized fun request() { reqs++ }
    @Synchronized fun bytesOut(n: Long) { bytesOut += n }
    @Synchronized fun bytesIn(n: Long) { bytesIn += n }
    @Synchronized fun bytesCopied(n: Long) { bytesCopied += n }
    @Synchronized fun throttled(ns: Long) { throttledNs += ns }

    /** The summary line (fields only) when [intervalMs] passed since the last one and anything happened; else null. */
    @Synchronized fun poll(nowMs: Long, force: Boolean = false): String? {
        if (reqs == 0L && bytesOut == 0L && bytesIn == 0L && bytesCopied == 0L && throttledNs == 0L) return null
        if (!force && nowMs - lastEmitMs < intervalMs) return null
        val line = "reqs=$reqs bytes_out=$bytesOut bytes_in=$bytesIn bytes_copied=$bytesCopied " +
            "throttled_ms=${throttledNs / 1_000_000}"
        reqs = 0; bytesOut = 0; bytesIn = 0; bytesCopied = 0; throttledNs = 0
        lastEmitMs = nowMs
        return line
    }
}
