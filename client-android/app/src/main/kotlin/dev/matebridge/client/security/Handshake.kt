package dev.matebridge.client.security

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.Limits
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.Ping
import dev.matebridge.client.protocol.VideoHello
import dev.matebridge.client.protocol.MsgType
import dev.matebridge.client.protocol.ProtocolException
import java.io.EOFException
import java.io.InputStream
import java.security.InvalidKeyException
import java.security.SecureRandom

/**
 * Key material of one control connection. Holds `prk` for the video connections of the same session
 * (PROTOCOL.md section 9) until [wipe]. Secrets are never logged.
 */
class SessionSecrets(prk: ByteArray, val pairing: Boolean, val hostId: ByteArray) {
    @Volatile private var prk: ByteArray? = prk

    private fun prkOrThrow(): ByteArray = prk ?: throw IllegalStateException("session secrets wiped")

    /** Six-digit pairing code (PAIRING only). */
    fun sas(): String = KeySchedule.sas(prkOrThrow())

    /** The key to store for [hostId] after the Mac accepted (PAIRING only). */
    fun newPairKey(): ByteArray = KeySchedule.newPairKey(prkOrThrow())

    fun videoKeys(videoNonce: ByteArray): VideoKeys {
        val p = prkOrThrow()
        return VideoKeys(KeySchedule.videoC2h(p, videoNonce), KeySchedule.videoH2c(p, videoNonce))
    }

    fun wipe() {
        prk?.fill(0)
        prk = null
    }
}

class VideoKeys(val c2h: ByteArray, val h2c: ByteArray)

/** Everything the control connection needs after a valid encrypted first HELLO_ACK. */
class SecureSession(
    val ack: HelloAck,
    val secrets: SessionSecrets,
    /** Client-to-host sealer: starts at counter 0, used by the single writer only. */
    val sealer: RecordSealer,
    /** Host-to-client opener, used by the single reader only. */
    val opener: RecordOpener,
    /** Pairing code to show next to the Mac's; null in PAIRED mode. Never log. */
    val sas: String?,
    /** PAIRING although a key for this host_id is stored: the Mac forgot this tablet. */
    val rePairing: Boolean,
) {
    private var committed = false

    /**
     * PAIRING only: persists the new key under `host_id` (replacing any old one), once. Call right after the first
     * HELLO_ACK was validated, not at ACCEPTED: the user may leave for the Mac's approval dialog and the connection may
     * drop before the approval; the Mac keeps this handshake's key on approval (PROTOCOL.md section 9). Returns true
     * when a key was stored; throws when it could not be persisted (the session must then fail).
     */
    fun storePairKey(store: PairKeyStore): Boolean {
        if (!secrets.pairing || committed) return false
        committed = true
        val key = secrets.newPairKey()
        try {
            store.put(secrets.hostId, key)
        } finally {
            key.fill(0)
        }
        return true
    }
}

/** Result of validating the first HELLO_ACK. */
sealed interface HandshakeOutcome {
    /** Terminal plaintext answer (REJECTED / VERSION_MISMATCH / BUSY with key_mode NONE); the connection closes. */
    data class Plain(val ack: HelloAck) : HandshakeOutcome

    class Secure(val session: SecureSession) : HandshakeOutcome

    /** PAIRED, but this tablet holds no key for that host_id: re-pairing is needed (Mac: "Onaylı cihazları unut"). */
    data object KeyMissing : HandshakeOutcome
}

/**
 * Client side of the handshake for ONE control connection (PROTOCOL.md sections 3 and 9): create it per
 * connection (it generates the ephemeral key and nonce), send [hello], then pass the raw first HELLO_ACK
 * to [complete]. Not thread-safe.
 */
class ClientHandshake internal constructor(private val eph: EphemeralKeyPair, private val nonce: ByteArray) {
    constructor(random: SecureRandom = SecureRandom()) :
        this(P256.generate(random), ByteArray(Limits.NONCE_BYTES).also { random.nextBytes(it) })

    private var helloPayload: ByteArray? = null

    /** The HELLO to send: [template] with this connection's nonce and ephemeral public key. */
    fun hello(template: Hello): Hello {
        val h = template.copy(clientNonce = Bytes(nonce.copyOf()), clientEphPub = Bytes(eph.publicBytes.copyOf()))
        helloPayload = Codec.encodePayload(h)
        return h
    }

    /**
     * Validates [ack] (decoded from [ackPayload], the exact wire bytes) against the mode/status matrix and derives keys.
     * Any inconsistency (a NONE answer that would leave us unencrypted while pending/accepted, a PAIRED answer that is
     * not ACCEPTED, an invalid host key...) throws [ProtocolException]: the connection closes without BYE.
     */
    fun complete(ack: HelloAck, ackPayload: ByteArray, keys: PairKeyStore): HandshakeOutcome {
        val hello = helloPayload ?: throw IllegalStateException("hello() not called")
        when (ack.keyMode) {
            HelloAck.KEY_NONE -> {
                if (ack.status != HelloAck.REJECTED && ack.status != HelloAck.VERSION_MISMATCH && ack.status != HelloAck.BUSY) {
                    throw ProtocolException(ProtocolException.Kind.AUTH_FAILED, "unencrypted non-terminal HELLO_ACK")
                }
                return HandshakeOutcome.Plain(ack)
            }
            HelloAck.KEY_PAIRED -> if (ack.status != HelloAck.ACCEPTED) {
                throw ProtocolException(ProtocolException.Kind.AUTH_FAILED, "PAIRED HELLO_ACK must be ACCEPTED")
            }
            HelloAck.KEY_PAIRING -> if (ack.status != HelloAck.PENDING_APPROVAL) {
                throw ProtocolException(ProtocolException.Kind.AUTH_FAILED, "PAIRING HELLO_ACK must be PENDING_APPROVAL")
            }
            else -> throw ProtocolException(ProtocolException.Kind.INVALID_VALUE, "unknown key_mode ${ack.keyMode}")
        }
        val pairing = ack.keyMode == HelloAck.KEY_PAIRING
        val hostId = ack.hostId.value.copyOf()
        val stored = keys.get(hostId)
        if (!pairing && stored == null) return HandshakeOutcome.KeyMissing

        val ecdh = try {
            P256.ecdh(eph.privateKey, P256.decodePublic(ack.hostEphPub.value))
        } catch (e: InvalidKeyException) {
            throw ProtocolException(ProtocolException.Kind.AUTH_FAILED, "invalid host public key")
        }
        val rePairing = pairing && stored != null
        val ikm = KeySchedule.ikm(if (pairing) null else stored, ecdh)
        val prk = KeySchedule.prk(ikm, KeySchedule.transcriptHash(hello, ackPayload))
        ikm.fill(0); ecdh.fill(0); stored?.fill(0)
        val secrets = SessionSecrets(prk, pairing, hostId)
        val sealer = RecordSealer(KeySchedule.controlC2h(prk))
        val opener = RecordOpener(KeySchedule.controlH2c(prk))
        val sas = if (pairing) secrets.sas() else null
        return HandshakeOutcome.Secure(SecureSession(ack, secrets, sealer, opener, sas, rePairing))
    }
}

/** Reads the very first host message: a plaintext frame (5-byte header), exactly its bytes and nothing beyond. */
object PlainFrames {
    class Frame(val type: Int, val payload: ByteArray)

    /** Throws [ProtocolException] (OVERSIZE) on a length above [maxPayload] before reading any payload, [EOFException] on EOF. */
    fun read(input: InputStream, maxPayload: Int = Limits.CONTROL_MAX_PAYLOAD): Frame {
        val h = readFully(input, 5)
        val len = (h[1].toLong() and 0xFF) or ((h[2].toLong() and 0xFF) shl 8) or
            ((h[3].toLong() and 0xFF) shl 16) or ((h[4].toLong() and 0xFF) shl 24)
        if (len > maxPayload) throw ProtocolException(ProtocolException.Kind.OVERSIZE, "payload $len > $maxPayload")
        return Frame(h[0].toInt() and 0xFF, readFully(input, len.toInt()))
    }

    /** Reads the first HELLO_ACK; any other first message is a protocol error. */
    fun readHelloAck(input: InputStream): Pair<HelloAck, ByteArray> {
        val f = read(input)
        if (f.type != MsgType.HELLO_ACK) throw ProtocolException(ProtocolException.Kind.INVALID_VALUE, "first message is not HELLO_ACK")
        val ack = Codec.decodePayload(f.type, f.payload) as HelloAck
        return ack to f.payload
    }

    private fun readFully(input: InputStream, n: Int): ByteArray {
        val out = ByteArray(n)
        var pos = 0
        while (pos < n) {
            val r = input.read(out, pos, n - pos)
            if (r < 0) throw EOFException()
            pos += r
        }
        return out
    }
}

/** Client side of one video connection's crypto (PROTOCOL.md sections 3 step 5 and 9). */
class VideoChannel(keys: VideoKeys) {
    private val sealer = RecordSealer(keys.c2h)
    val decoder = RecordDecoder(Limits.VIDEO_MAX_PAYLOAD, RecordOpener(keys.h2c))

    init {
        keys.c2h.fill(0) // the sealer holds its own copy
    }

    /**
     * Bytes to write first: the plaintext VIDEO_HELLO carrying [nonce], then one sealed PING (counter 0, video c2h key)
     * that proves key possession. The host answers no PING on the video connection.
     */
    fun opening(hello: VideoHello, nonce: ByteArray, nowUs: Long): ByteArray =
        Codec.encode(hello.copy(videoNonce = Bytes(nonce))) +
            sealer.sealFrame(Codec.encode(Ping(0, nowUs)))
}
