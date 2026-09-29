package dev.matebridge.client.session

/**
 * Bounded single FIFO for the control connection (PROTOCOL.md section 5, 7): at most [maxBytes] queued
 * or oldest entry older than [maxAgeMs]. Overflow makes [offer] return false; the caller then closes
 * and reconnects (the host releases all input on disconnect), so a state transition is never dropped
 * silently. Coalescing of hover/rel/scroll samples belongs to the input tasks.
 */
class SendQueue(private val maxBytes: Int = 256 * 1024, private val maxAgeMs: Long = 1000) {
    private class Entry(val bytes: ByteArray, val atMs: Long)

    private val lock = Object()
    private val items = ArrayDeque<Entry>()
    private var queuedBytes = 0
    private var closing = false
    private var aborted = false

    /** Returns false when the bound is exceeded (or the queue is closed); nothing is enqueued then. */
    fun offer(bytes: ByteArray, nowMs: Long): Boolean = synchronized(lock) {
        if (closing || aborted) return false
        val oldest = items.firstOrNull()
        if (queuedBytes + bytes.size > maxBytes) return false
        if (oldest != null && nowMs - oldest.atMs > maxAgeMs) return false
        items.addLast(Entry(bytes, nowMs))
        queuedBytes += bytes.size
        lock.notifyAll()
        true
    }

    /** Blocks for the next frame. Returns null once aborted, or closed and drained. */
    fun take(): ByteArray? = synchronized(lock) {
        while (true) {
            if (aborted) return null
            val e = items.removeFirstOrNull()
            if (e != null) {
                queuedBytes -= e.bytes.size
                return e.bytes
            }
            if (closing) return null
            lock.wait()
        }
        @Suppress("UNREACHABLE_CODE")
        null
    }

    /** No more offers; already queued frames (e.g. a final BYE) are still delivered. */
    fun closeGracefully() = synchronized(lock) { closing = true; lock.notifyAll() }

    /** Drop everything; [take] returns null immediately. */
    fun abort() = synchronized(lock) { aborted = true; items.clear(); queuedBytes = 0; lock.notifyAll() }

    fun size(): Int = synchronized(lock) { items.size }
}
