package dev.matebridge.client.security

import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.ProtocolException
import java.security.GeneralSecurityException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/*
 * Encrypted records (PROTOCOL.md section 9): u32 length (LE) || AES-256-GCM(type || payload) || 16-byte tag.
 * nonce = 00 00 00 00 || counter (u64 LE), AAD = the 4 length bytes. The counter starts at 0 per connection
 * and direction and increases by one per record.
 */
object Records {
    const val TAG_BYTES = 16
    const val HEADER_BYTES = 4

    /** length = plaintext (type + payload) + tag; 17 is the smallest legal value (empty payload). */
    const val MIN_LENGTH = 1 + TAG_BYTES

    /** Largest legal `length` for a connection whose payload limit is [maxPayload]. */
    fun maxLength(maxPayload: Int): Long = maxPayload.toLong() + MIN_LENGTH

    internal fun nonce(counter: Long): ByteArray {
        val n = ByteArray(12)
        for (i in 0 until 8) n[4 + i] = (counter ushr (8 * i)).toByte()
        return n
    }

    internal fun header(length: Int): ByteArray =
        byteArrayOf(length.toByte(), (length ushr 8).toByte(), (length ushr 16).toByte(), (length ushr 24).toByte())
}

/** Seals outgoing records of one connection direction. The counter order is the call order, so callers must call from one writer. */
class RecordSealer(key: ByteArray, startCounter: Long = 0) {
    private val keySpec = SecretKeySpec(key, "AES")
    private val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    private var counter = startCounter

    /** Returns the full record (length header, ciphertext, tag). The connection closes before the counter reaches 2^63. */
    @Synchronized
    fun seal(type: Int, payload: ByteArray): ByteArray {
        if (counter < 0) throw IllegalStateException("record counter exhausted")
        val length = 1 + payload.size + Records.TAG_BYTES
        val header = Records.header(length)
        cipher.init(Cipher.ENCRYPT_MODE, keySpec, GCMParameterSpec(Records.TAG_BYTES * 8, Records.nonce(counter)))
        cipher.updateAAD(header)
        val plain = ByteArray(1 + payload.size)
        plain[0] = type.toByte()
        System.arraycopy(payload, 0, plain, 1, payload.size)
        val body = cipher.doFinal(plain)
        counter++
        return header + body
    }

    /** Seals a whole plaintext frame as produced by [Codec.encode] (5-byte header, then payload). */
    fun sealFrame(frame: ByteArray): ByteArray = seal(frame[0].toInt() and 0xFF, frame.copyOfRange(5, frame.size))
}

/** Opens incoming records of one connection direction. */
class RecordOpener(key: ByteArray, startCounter: Long = 0) {
    private val keySpec = SecretKeySpec(key, "AES")
    private val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    private var counter = startCounter

    /**
     * [header] is the 4 length bytes (the AAD), [body] is ciphertext plus tag. Returns `type || payload`.
     * Throws [ProtocolException] (AUTH_FAILED) when the tag does not verify or the length is illegal.
     */
    @Synchronized
    fun open(header: ByteArray, body: ByteArray): ByteArray {
        if (body.size < Records.MIN_LENGTH) throw ProtocolException(ProtocolException.Kind.AUTH_FAILED, "record too short")
        if (counter < 0) throw ProtocolException(ProtocolException.Kind.AUTH_FAILED, "record counter exhausted")
        try {
            cipher.init(Cipher.DECRYPT_MODE, keySpec, GCMParameterSpec(Records.TAG_BYTES * 8, Records.nonce(counter)))
            cipher.updateAAD(header)
            val plain = cipher.doFinal(body)
            counter++
            return plain
        } catch (e: GeneralSecurityException) {
            throw ProtocolException(ProtocolException.Kind.AUTH_FAILED, "record authentication failed")
        }
    }
}

/**
 * Incremental decoder for an encrypted connection, same feed/next contract as `FrameDecoder`: feed arbitrary
 * chunks (at most [READ_CHUNK] each), then drain with [next]. The length is checked against
 * `maxPayload + 17` the moment its 4 bytes are at the front of the buffer, before any payload is waited for.
 * A [ProtocolException] is terminal; later calls rethrow it and the caller closes the connection without BYE.
 */
class RecordDecoder(maxPayload: Int, private val opener: RecordOpener) {
    private val maxLength = Records.maxLength(maxPayload)
    val bufferCap: Int = Records.HEADER_BYTES + maxLength.toInt() + READ_CHUNK

    private var buf = ByteArray(4096)
    private var start = 0
    private var end = 0
    private var failure: ProtocolException? = null

    var skippedFrames = 0
        private set

    fun feed(data: ByteArray, offset: Int = 0, length: Int = data.size - offset) {
        require(offset >= 0 && length >= 0 && offset + length <= data.size) { "bad range" }
        require(length <= READ_CHUNK) { "feed() takes at most $READ_CHUNK bytes per call" }
        if (failure != null) return
        if (end - start + length > bufferCap) {
            failure = ProtocolException(ProtocolException.Kind.BUFFER_OVERFLOW, "decoder not drained: buffer cap $bufferCap")
            return
        }
        if (start == end) { start = 0; end = 0 }
        if (end + length > buf.size) {
            val live = end - start
            val target = if (live + length <= buf.size) buf else ByteArray(maxOf(buf.size * 2, live + length))
            System.arraycopy(buf, start, target, 0, live)
            buf = target
            start = 0
            end = live
        }
        System.arraycopy(data, offset, buf, end, length)
        end += length
    }

    /** Next complete known message, or null when more bytes are needed. Unknown types are skipped. */
    fun next(): Message? {
        failure?.let { throw it }
        try {
            while (true) {
                if (end - start < Records.HEADER_BYTES) return null
                val len = (buf[start].toLong() and 0xFF) or
                    ((buf[start + 1].toLong() and 0xFF) shl 8) or
                    ((buf[start + 2].toLong() and 0xFF) shl 16) or
                    ((buf[start + 3].toLong() and 0xFF) shl 24)
                if (len < Records.MIN_LENGTH) {
                    throw ProtocolException(ProtocolException.Kind.AUTH_FAILED, "record length $len < ${Records.MIN_LENGTH}")
                }
                if (len > maxLength) {
                    throw ProtocolException(ProtocolException.Kind.OVERSIZE, "record length $len > $maxLength")
                }
                val total = Records.HEADER_BYTES + len.toInt()
                if (end - start < total) return null
                val header = buf.copyOfRange(start, start + Records.HEADER_BYTES)
                val body = buf.copyOfRange(start + Records.HEADER_BYTES, start + total)
                start += total
                val plain = opener.open(header, body)
                val type = plain[0].toInt() and 0xFF
                val msg = Codec.decodePayload(type, plain.copyOfRange(1, plain.size))
                if (msg != null) return msg
                skippedFrames++
            }
        } catch (e: ProtocolException) {
            failure = e
            throw e
        }
    }

    fun drain(): List<Message> {
        val out = ArrayList<Message>()
        while (true) out += next() ?: return out
    }

    companion object {
        const val READ_CHUNK = 64 * 1024
    }
}
