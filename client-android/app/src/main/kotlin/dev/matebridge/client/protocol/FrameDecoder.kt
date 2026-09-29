package dev.matebridge.client.protocol

/**
 * Incremental stream decoder: feed arbitrary chunks, pull complete messages.
 *
 * Unknown message types are skipped. A [ProtocolException] is terminal for the connection: after
 * one is thrown every further [next] call rethrows it (the caller closes per PROTOCOL.md section 2).
 * The payload limit is checked on the header, before any payload is buffered.
 */
class FrameDecoder(private val maxPayload: Int) {
    /** Hard cap on buffered bytes: one maximal frame plus one read chunk. */
    val bufferCap: Int = HEADER + maxPayload + READ_CHUNK

    private var buf = ByteArray(4096)
    private var start = 0
    private var end = 0
    private var scanPos = 0 // start of the next header not yet validated (may lie beyond end)
    private var failure: ProtocolException? = null

    /** Number of unknown-type frames skipped so far. */
    var skippedFrames = 0
        private set

    /**
     * Appends bytes. Each 5-byte header is validated the moment it is complete, before any of its
     * payload is buffered, so an oversized length fails immediately and buffered data stays bounded
     * by header + [maxPayload] per frame. Bytes after a failure are discarded.
     *
     * At most [READ_CHUNK] bytes per call (larger input is a caller bug: IllegalArgumentException).
     * The cap counts only bytes not yet returned by [next]. Callers MUST call [next] (or [drain]) until it returns null after every feed. Total buffered
     * bytes are hard-capped at [bufferCap] (header + max payload + [READ_CHUNK]); feeding past it
     * without draining fails with [ProtocolException.Kind.BUFFER_OVERFLOW] instead of exhausting memory.
     */
    fun feed(data: ByteArray, offset: Int = 0, length: Int = data.size - offset) {
        require(offset >= 0 && length >= 0 && offset + length <= data.size) { "bad range" }
        require(length <= READ_CHUNK) { "feed() takes at most $READ_CHUNK bytes per call; split larger reads" }
        var pos = offset
        var left = length
        while (left > 0 && failure == null) {
            val have = end - scanPos
            val take = if (have < 0) minOf(left, -have) // payload of an already validated frame
            else minOf(left, HEADER - have) // rest of the next header (have < HEADER always here)
            if (end - start + take > bufferCap) {
                failure = ProtocolException(ProtocolException.Kind.BUFFER_OVERFLOW, "decoder not drained: buffer cap $bufferCap")
                return
            }
            append(data, pos, take)
            pos += take
            left -= take
            if (end - scanPos >= HEADER) {
                val len = readLength(scanPos)
                if (len > maxPayload) {
                    failure = ProtocolException(ProtocolException.Kind.OVERSIZE, "payload $len > $maxPayload")
                    return
                }
                scanPos += HEADER + len.toInt()
            }
        }
    }

    internal fun bufferedBytes(): Int = end - start

    private fun readLength(at: Int): Long =
        (buf[at + 1].toLong() and 0xFF) or
            ((buf[at + 2].toLong() and 0xFF) shl 8) or
            ((buf[at + 3].toLong() and 0xFF) shl 16) or
            ((buf[at + 4].toLong() and 0xFF) shl 24)

    private fun append(data: ByteArray, off: Int, n: Int) {
        if (start == end) { scanPos -= start; start = 0; end = 0 }
        if (end + n > buf.size) {
            val live = end - start
            val target = if (live + n <= buf.size) buf else ByteArray(maxOf(buf.size * 2, live + n))
            System.arraycopy(buf, start, target, 0, live)
            buf = target
            scanPos -= start
            start = 0
            end = live
        }
        System.arraycopy(data, off, buf, end, n)
        end += n
    }

    /** Returns the next complete known message, or null when more bytes are needed. */
    fun next(): Message? {
        failure?.let { throw it }
        try {
            while (true) {
                if (end - start < HEADER) return null
                val type = buf[start].toInt() and 0xFF
                val len = (buf[start + 1].toLong() and 0xFF) or
                    ((buf[start + 2].toLong() and 0xFF) shl 8) or
                    ((buf[start + 3].toLong() and 0xFF) shl 16) or
                    ((buf[start + 4].toLong() and 0xFF) shl 24)
                if (len > maxPayload) {
                    throw ProtocolException(ProtocolException.Kind.OVERSIZE, "payload $len > $maxPayload")
                }
                val total = HEADER + len.toInt()
                if (end - start < total) return null
                val payload = buf.copyOfRange(start + HEADER, start + total)
                start += total
                val msg = Codec.decodePayload(type, payload)
                if (msg != null) return msg
                skippedFrames++
            }
        } catch (e: ProtocolException) {
            failure = e
            throw e
        }
    }

    /** Drains every message currently available. Throws on the first violation. */
    fun drain(): List<Message> {
        val out = ArrayList<Message>()
        while (true) out += next() ?: return out
    }

    companion object {
        const val HEADER = 5

        /** Largest single socket read the caller is expected to feed at once. */
        const val READ_CHUNK = 64 * 1024

        fun control() = FrameDecoder(Limits.CONTROL_MAX_PAYLOAD)
        fun video() = FrameDecoder(Limits.VIDEO_MAX_PAYLOAD)
    }
}
