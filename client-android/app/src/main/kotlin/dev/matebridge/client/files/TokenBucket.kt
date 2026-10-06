package dev.matebridge.client.files

/** Something that makes a caller wait for [n] bytes of budget; returns the ns slept (the stats' throttled time). */
fun interface ByteBudget {
    fun acquire(n: Long): Long
}

/**
 * Shared byte-rate cap of the file server (T-135): every request and response byte of every connection passes through
 * one bucket of [rateBytesPerSec] with depth [burstBytes]. A taker that finds the bucket short goes into debt and sleeps
 * for exactly that debt, so concurrent takers share the rate and the total never exceeds it (plus one burst).
 * Thread-safe; the sleeping happens outside the lock.
 *
 * T-266: the rate can change while running ([setRate], the Wi-Fi cap follows the video bit rate, decision 0035). Bytes
 * already booked are a debt in bytes, not in time: after a change the debt is paid at the new rate, and a taker that is
 * asleep notices within [SLICE_NS] (a raise ends its wait early, a cut extends it), so a raise never oversleeps.
 */
class TokenBucket(
    rateBytesPerSec: Long,
    private val burstBytes: Long,
    private val nanoTime: () -> Long = System::nanoTime,
    private val sleepNs: (Long) -> Unit = ::defaultSleep,
) : ByteBudget {
    init {
        require(rateBytesPerSec > 0 && burstBytes > 0)
    }

    private val lock = Any()
    private var rate = rateBytesPerSec
    private var rateGen = 0L
    private var tokens = burstBytes.toDouble()
    private var lastNs = nanoTime()

    /** Everything ever added by refilling (bytes); a sleeper measures its debt payment against it. Under [lock]. */
    private var refilled = 0.0

    /** The current rate, bytes per second. */
    val rateBytesPerSec: Long get() = synchronized(lock) { rate }

    /** Adds the refill of the time since the last call, at the current rate. Under [lock]. */
    private fun settle() {
        val now = nanoTime()
        val elapsed = (now - lastNs).coerceAtLeast(0)
        lastNs = now
        // In Double: elapsed (ns) x rate overflows a Long after minutes of idle time (T-137).
        val add = elapsed.toDouble() * rate / 1e9
        refilled += add
        tokens = minOf(burstBytes.toDouble(), tokens + add)
    }

    /**
     * Changes the rate to [bytesPerSec] (> 0) from now on. Time before the call is credited at the old rate; the
     * burst depth and the debt in bytes stay. Thread-safe.
     */
    fun setRate(bytesPerSec: Long) {
        require(bytesPerSec > 0)
        synchronized(lock) {
            settle()
            rate = bytesPerSec
            rateGen++
        }
    }

    /** Books [n] bytes and returns how long (ns) the caller has to wait before using them; 0 when within budget. */
    fun reserve(n: Long): Long = synchronized(lock) { book(n).waitNs }

    private class Ticket(val waitNs: Long, val debt: Double, val refilledAtBooking: Double, val gen: Long)

    private fun book(n: Long): Ticket {
        settle()
        tokens -= n
        return if (tokens >= 0) Ticket(0L, 0.0, refilled, rateGen)
        else Ticket((-tokens * 1e9 / rate).toLong(), -tokens, refilled, rateGen)
    }

    /** What is left of [t]'s debt, as ns at the current rate (0 once paid). Under [lock]. */
    private fun remainingNs(t: Ticket): Long {
        settle()
        val left = t.debt - (refilled - t.refilledAtBooking)
        return if (left <= 0) 0L else (left * 1e9 / rate).toLong()
    }

    /** [reserve]s [n] bytes and sleeps the required time. Returns the ns slept (the stats' throttled time). */
    override fun acquire(n: Long): Long {
        val t = synchronized(lock) { book(n) }
        if (t.waitNs <= 0) return 0L
        var wait = t.waitNs
        var gen = t.gen
        var slept = 0L
        while (wait > 0) {
            val step = minOf(wait, SLICE_NS)
            sleepNs(step)
            slept += step
            wait -= step
            // Only a rate change makes the original wait wrong; then the rest is worked out again from the debt.
            synchronized(lock) {
                if (rateGen != gen) {
                    gen = rateGen
                    wait = remainingNs(t)
                }
            }
        }
        return slept
    }

    companion object {
        /** A sleeper looks at the rate again at least this often. */
        const val SLICE_NS = 100_000_000L

        private fun defaultSleep(ns: Long) = Thread.sleep(ns / 1_000_000, (ns % 1_000_000).toInt())
    }
}

/**
 * The two lanes of the file server's rate cap (T-266, decision 0035): a [main] bucket for bulk transfer and a small
 * [small] bucket for the start of every request and response, so a small PROPFIND does not queue behind a big
 * transfer's debt (at 2 MB/s, eight connections of 64 KiB bursts are ~250 ms). Per connection and direction a
 * [Lane] sends the first [smallBytes] bytes of an exchange through [small] and the rest through [main]; [Lane.reset]
 * starts the next exchange. The overall ceiling is therefore main + small (the small lane's rate is added on top of the
 * main one; ~256 KB/s next to the 0,5-3 MB/s of the Wi-Fi cap), documented in FilesConfig. Without [small] (the USB
 * profile) a lane is just [main]: today's behaviour.
 */
class LaneBudget(private val main: ByteBudget, private val small: ByteBudget?, private val smallBytes: Long) {
    fun newLane(): Lane = Lane()

    inner class Lane : ByteBudget {
        private var used = 0L // bytes of the current exchange, this direction; the connection thread only

        override fun acquire(n: Long): Long {
            val s = small ?: return main.acquire(n)
            val inSmall = minOf(n, (smallBytes - used).coerceAtLeast(0))
            used += n
            var slept = 0L
            if (inSmall > 0) slept += s.acquire(inSmall)
            if (n > inSmall) slept += main.acquire(n - inSmall)
            return slept
        }

        /** The next exchange starts: its first bytes are "small" again. */
        fun reset() { used = 0 }
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
