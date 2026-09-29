package dev.matebridge.client.protocol

/**
 * Incremental stream decoder: feed arbitrary chunks, pull complete messages.
 *
 * Unknown message types are skipped. A [ProtocolException] is terminal for the connection: after
 * one is thrown every further [next] call rethrows it (the caller closes per PROTOCOL.md section 2).
 * The payload limit is checked on the header, before any payload is buffered.
 */
class FrameDecoder(private val maxPayload: Int) {
    private var buf = ByteArray(4096)
    private var start = 0
    private var end = 0
    private var failure: ProtocolException? = null

    /** Number of unknown-type frames skipped so far. */
    var skippedFrames = 0
        private set

    fun feed(data: ByteArray, offset: Int = 0, length: Int = data.size) {
        if (failure != null) return
        if (start == end) { start = 0; end = 0 }
        if (end + length > buf.size) {
            val live = end - start
            if (live + length <= buf.size) {
                System.arraycopy(buf, start, buf, 0, live)
            } else {
                val bigger = ByteArray(maxOf(buf.size * 2, live + length))
                System.arraycopy(buf, start, bigger, 0, live)
                buf = bigger
            }
            start = 0
            end = live
        }
        System.arraycopy(data, offset, buf, end, length)
        end += length
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

        fun control() = FrameDecoder(Limits.CONTROL_MAX_PAYLOAD)
        fun video() = FrameDecoder(Limits.VIDEO_MAX_PAYLOAD)
    }
}
