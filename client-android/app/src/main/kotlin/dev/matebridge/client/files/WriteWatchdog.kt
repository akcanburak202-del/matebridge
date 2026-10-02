package dev.matebridge.client.files

/**
 * Write-stall timeout of the file server (T-139). Java sockets have no write timeout: a peer (or a tunnel) that stops
 * reading leaves the writer blocked for ever, holding its connection slot (T-138 run12). Every raw socket write is
 * bracketed with [Watch.begin]/[Watch.end]; a write still running [timeoutMs] after it began fires its watch's
 * `onStall` (the server closes the socket, which unblocks the write). Waiting on the rate cap happens outside the
 * bracket, so it never counts as a stall.
 *
 * [runLoop] is the single watchdog thread: it waits without a timeout while no write is running (an idle server does
 * not poll) and otherwise sleeps until the earliest deadline. Deadlines are begin time + timeout, so a new one is never
 * earlier than a running one and [Watch.begin] only has to wake the thread when nothing was running. Thread-safe.
 */
class WriteWatchdog(timeoutMs: Long, private val nanoTime: () -> Long = System::nanoTime) {
    private val timeoutNs = timeoutMs * 1_000_000
    private val lock = Object()
    private val running = LinkedHashMap<Watch, Long>() // watch -> deadline (ns), in begin order = deadline order
    private var stopped = false

    /** One connection's writes; [onStall] runs on the watchdog thread, outside the watchdog's lock. */
    inner class Watch(private val onStall: () -> Unit) {
        fun begin() {
            synchronized(lock) {
                val wasEmpty = running.isEmpty()
                running.remove(this) // keeps the map in deadline order
                running[this] = nanoTime() + timeoutNs
                if (wasEmpty) lock.notifyAll()
            }
        }

        fun end() {
            synchronized(lock) { running.remove(this) }
        }

        internal fun fire() = onStall()
    }

    /** Removes and returns the watches whose write began at least the timeout before [now]. */
    internal fun expire(now: Long): List<Watch> = synchronized(lock) {
        val due = ArrayList<Watch>()
        val it = running.entries.iterator()
        while (it.hasNext()) {
            val e = it.next()
            if (e.value - now > 0) break
            due += e.key
            it.remove()
        }
        due
    }

    /** Number of writes in progress (tests). */
    internal fun runningCount(): Int = synchronized(lock) { running.size }

    /** The watchdog thread's body; returns after [stop]. */
    fun runLoop() {
        while (true) {
            synchronized(lock) {
                while (true) {
                    if (stopped) return
                    val first = running.values.firstOrNull()
                    if (first == null) {
                        lock.wait()
                        continue
                    }
                    val left = first - nanoTime()
                    if (left <= 0) break
                    lock.wait(left / 1_000_000, (left % 1_000_000).toInt())
                }
            }
            for (w in expire(nanoTime())) w.fire()
        }
    }

    /** Ends [runLoop]. Any thread, idempotent. */
    fun stop() {
        synchronized(lock) {
            stopped = true
            lock.notifyAll()
        }
    }
}
