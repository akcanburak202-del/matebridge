package dev.matebridge.client.security

import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.ProtocolException
import dev.matebridge.client.session.MbLog
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

    /** Provider asked for first; Conscrypt (BoringSSL, ARMv8 crypto extensions) on Android. Falls back to the default. */
    const val PREFERRED_PROVIDER = "AndroidOpenSSL"

    const val TRANSFORMATION = "AES/GCM/NoPadding"

    @Volatile private var providerLogged = false

    /** AES-GCM cipher from [provider] (null = platform default). Throws if the provider is unavailable. */
    fun newCipher(provider: String?): Cipher =
        if (provider == null) Cipher.getInstance(TRANSFORMATION) else Cipher.getInstance(TRANSFORMATION, provider)

    /** Fast path: the preferred provider when present, otherwise the default. The chosen provider is logged once per process. */
    fun newCipher(): Cipher {
        val c = try { newCipher(PREFERRED_PROVIDER) } catch (e: GeneralSecurityException) { newCipher(null) }
        if (!providerLogged) {
            providerLogged = true
            try { MbLog.i("crypto_provider", "provider=${c.provider.name}") } catch (_: Throwable) {}
        }
        return c
    }

    /**
     * T-077 diagnostics: when true every [RecordOpener] open stamps [OpenStamps.current] of the calling thread (the
     * video connection thread reads them back right after `next()` for the pace trace). Off = one volatile read.
     */
    @Volatile var stampOpens = false

    /**
     * Output buffer for a decrypt of [inLen] bytes on an initialised [cipher]: at least `getOutputSize(inLen)` and never
     * smaller than [inLen] (some Conscrypt versions demand room for the tag too). Reuses [cur] when big enough.
     */
    internal fun ensureOutput(cur: ByteArray, cipher: Cipher, inLen: Int): ByteArray {
        val need = maxOf(inLen, cipher.getOutputSize(inLen))
        return if (cur.size >= need) cur else ByteArray(maxOf(need, cur.size * 2))
    }

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
    private val cipher = Records.newCipher()
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
    private val cipher = Records.newCipher()
    private var counter = startCounter
    private var scratch = ByteArray(0)

    /**
     * [header] is the 4 length bytes (the AAD), [body] is ciphertext plus tag. Returns `type || payload`.
     * Throws [ProtocolException] (AUTH_FAILED) when the tag does not verify or the length is illegal.
     */
    @Synchronized
    fun open(header: ByteArray, body: ByteArray): ByteArray = openAt(header, 0, body, 0, body.size)

    /**
     * Same as [open] but reads the 4 AAD bytes at [hOff] of [hdr] and the ciphertext+tag at [bOff]..[bOff]+[bLen] of [src]
     * in place (no copies). Returns `type || payload` as a fresh array.
     */
    @Synchronized
    fun openAt(hdr: ByteArray, hOff: Int, src: ByteArray, bOff: Int, bLen: Int): ByteArray {
        val n = openPlain(hdr, hOff, src, bOff, bLen) // first: it may replace the scratch buffer
        return scratch.copyOf(n)
    }

    /**
     * Opens in place like [openAt] and leaves `type || payload` in [plain] (valid until the next open on this opener);
     * returns its length. Callers copy out what they keep.
     */
    @Synchronized
    internal fun openPlain(hdr: ByteArray, hOff: Int, src: ByteArray, bOff: Int, bLen: Int): Int {
        if (bLen < Records.MIN_LENGTH) throw ProtocolException(ProtocolException.Kind.AUTH_FAILED, "record too short")
        if (counter < 0) throw ProtocolException(ProtocolException.Kind.AUTH_FAILED, "record counter exhausted")
        val stamps = if (Records.stampOpens) OpenStamps.current() else null
        stamps?.startNs = System.nanoTime()
        try {
            cipher.init(Cipher.DECRYPT_MODE, keySpec, GCMParameterSpec(Records.TAG_BYTES * 8, Records.nonce(counter)))
            cipher.updateAAD(hdr, hOff, Records.HEADER_BYTES)
            stamps?.initNs = System.nanoTime()
            scratch = Records.ensureOutput(scratch, cipher, bLen)
            val n = cipher.doFinal(src, bOff, bLen, scratch, 0)
            stamps?.finalNs = System.nanoTime()
            counter++
            return n
        } catch (e: GeneralSecurityException) {
            throw ProtocolException(ProtocolException.Kind.AUTH_FAILED, "record authentication failed")
        }
    }

    /** Plaintext of the last [openPlain]. */
    internal val plain: ByteArray get() = scratch
}

/**
 * T-077 diagnostics: when [Records.stampOpens] is on, [RecordOpener] writes the System.nanoTime stamps of the last record
 * it opened on this thread: start, after `init` + AAD, after `doFinal`. Thread-local, so the control connection never
 * overwrites the video thread's values.
 */
class OpenStamps {
    var startNs = 0L
    var initNs = 0L
    var finalNs = 0L

    companion object {
        private val local = object : ThreadLocal<OpenStamps>() {
            override fun initialValue() = OpenStamps()
        }

        fun current(): OpenStamps = local.get()!!
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
                val at = start
                start += total
                val n = opener.openPlain(buf, at, buf, at + Records.HEADER_BYTES, len.toInt())
                val plain = opener.plain
                val type = plain[0].toInt() and 0xFF
                // In place: the only full-size copy of a video record is VideoFrame.data (T-285).
                val msg = Codec.decodePayload(type, plain, 1, n - 1)
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
