package dev.matebridge.client.session

import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.Message

/**
 * Bounded single FIFO for the control connection (PROTOCOL.md section 5, 7): at most [maxBytes] queued
 * or oldest entry older than [maxAgeMs]. The first failed [offer] because of the bound marks the queue
 * [isOverflowed] and every later offer is refused too, so once one message was lost no later message
 * can slip through (an UP after a dropped DOWN would be worse than nothing). The owner must then close
 * and reconnect (the host releases all input on disconnect). Coalescing of hover/rel/scroll samples
 * belongs to the input tasks.
 */
class SendQueue(private val maxBytes: Int = 256 * 1024, private val maxAgeMs: Long = 1000) {
    private class Entry(val bytes: ByteArray, val atMs: Long)

    private val lock = Object()
    private val items = ArrayDeque<Entry>()
    private var queuedBytes = 0
    private var closing = false
    private var aborted = false
    private var overflowed = false

    /** Returns false when the bound is exceeded (or the queue is closed); nothing is enqueued then. */
    fun offer(bytes: ByteArray, nowMs: Long): Boolean = synchronized(lock) {
        if (closing || aborted || overflowed) return false
        val oldest = items.firstOrNull()
        if (queuedBytes + bytes.size > maxBytes || (oldest != null && nowMs - oldest.atMs > maxAgeMs)) {
            overflowed = true
            return false
        }
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

    fun isOverflowed(): Boolean = synchronized(lock) { overflowed }

    fun size(): Int = synchronized(lock) { items.size }

    /** Bytes currently queued (backpressure signal for the input layer). */
    fun queuedBytes(): Int = synchronized(lock) { queuedBytes }

    /** Age of the oldest queued frame at [nowMs], 0 when empty (backpressure signal for the input layer). */
    fun oldestAgeMs(nowMs: Long): Long = synchronized(lock) { items.firstOrNull()?.let { nowMs - it.atMs } ?: 0L }
}

/**
 * Sender side of one control connection. A failed send caused by overflow invokes [onOverflow]
 * exactly once, and the owner must abort the connection and report it closed so the session reconnects.
 */
class ControlLink(
    private val queue: SendQueue,
    private val clockMs: () -> Long,
    private val onOverflow: () -> Unit,
) {
    private var reported = false

    fun send(msg: Message): Boolean {
        if (queue.offer(Codec.encode(msg), clockMs())) return true
        if (queue.isOverflowed()) {
            val first = synchronized(this) { !reported.also { reported = true } }
            if (first) onOverflow()
        }
        return false
    }

    /**
     * True while the writer is falling behind: at least [CONGESTED_BYTES] queued or the oldest frame waiting
     * [CONGESTED_AGE_MS]. The input layer then holds and merges plain hover samples and scroll deltas
     * (PROTOCOL.md section 5) instead of adding to the backlog; the hard bound (256 KiB / 1 s) stays with [SendQueue].
     */
    fun congested(): Boolean = queue.queuedBytes() >= CONGESTED_BYTES || queue.oldestAgeMs(clockMs()) >= CONGESTED_AGE_MS

    companion object {
        const val CONGESTED_BYTES = 8 * 1024
        const val CONGESTED_AGE_MS = 50L
    }
}
