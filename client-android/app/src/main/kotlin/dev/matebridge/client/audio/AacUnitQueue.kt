package dev.matebridge.client.audio

/** One AAC access unit with the metadata of its `AUDIO_FRAME`. */
class AacUnit(val sampleIndex: Long, val captureUs: Long, val data: ByteArray)

/**
 * Bounded hand-off from the control reader thread to the AAC decode thread. [offer] never blocks; when full the
 * oldest unit is dropped (counted), so a slow decoder costs old audio, never the reader thread.
 */
class AacUnitQueue(private val capacity: Int = CAPACITY) {
    private val lock = Object()
    private val items = ArrayDeque<AacUnit>()
    private var closed = false

    @Volatile var dropped = 0L
        private set

    /** Reader thread. False once closed. */
    fun offer(u: AacUnit): Boolean = synchronized(lock) {
        if (closed) return false
        if (items.size >= capacity) {
            items.removeFirst()
            dropped++
        }
        items.addLast(u)
        lock.notifyAll()
        true
    }

    /** Decode thread: next unit, or null after [timeoutMs] or when closed. */
    fun poll(timeoutMs: Long): AacUnit? = synchronized(lock) {
        if (items.isEmpty() && !closed && timeoutMs > 0) {
            try { lock.wait(timeoutMs) } catch (_: InterruptedException) { Thread.currentThread().interrupt() }
        }
        if (closed) null else items.removeFirstOrNull()
    }

    fun close() = synchronized(lock) {
        closed = true
        items.clear()
        lock.notifyAll()
    }

    val size: Int get() = synchronized(lock) { items.size }

    companion object {
        /** 32 units = about 680 ms of audio. */
        const val CAPACITY = 32
    }
}
