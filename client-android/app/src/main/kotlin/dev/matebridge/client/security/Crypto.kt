package dev.matebridge.client.security

import java.math.BigInteger
import java.security.InvalidKeyException
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECFieldFp
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/*
 * Crypto primitives of PROTOCOL.md section 9. Pure JVM (java.security / javax.crypto only, no new
 * dependencies). Nothing in here logs; never add logging of keys, scalars or the pairing code.
 */

/** A per-connection ephemeral P-256 key pair; [publicBytes] is the uncompressed point (0x04 || X || Y, 65 bytes). */
class EphemeralKeyPair(val privateKey: PrivateKey, val publicBytes: ByteArray)

object P256 {
    const val PUBLIC_BYTES = 65
    const val COORD_BYTES = 32

    /** Curve parameters, taken from a throwaway generated key so no provider-specific AlgorithmParameters lookup is needed. */
    val params: ECParameterSpec by lazy {
        val g = KeyPairGenerator.getInstance("EC")
        g.initialize(ECGenParameterSpec("secp256r1"))
        (g.generateKeyPair().public as ECPublicKey).params
    }

    fun generate(random: SecureRandom = SecureRandom()): EphemeralKeyPair {
        val g = KeyPairGenerator.getInstance("EC")
        g.initialize(ECGenParameterSpec("secp256r1"), random)
        val pair = g.generateKeyPair()
        return EphemeralKeyPair(pair.private, encodePublic(pair.public as ECPublicKey))
    }

    /** Uncompressed SEC1 encoding. */
    fun encodePublic(key: ECPublicKey): ByteArray {
        val out = ByteArray(PUBLIC_BYTES)
        out[0] = 4
        fixed(key.w.affineX).copyInto(out, 1)
        fixed(key.w.affineY).copyInto(out, 1 + COORD_BYTES)
        return out
    }

    /** Decodes an uncompressed point; anything else, or a point not on the curve, is an [InvalidKeyException]. */
    fun decodePublic(bytes: ByteArray): PublicKey {
        if (bytes.size != PUBLIC_BYTES || bytes[0].toInt() != 4) throw InvalidKeyException("not an uncompressed P-256 point")
        val x = BigInteger(1, bytes.copyOfRange(1, 1 + COORD_BYTES))
        val y = BigInteger(1, bytes.copyOfRange(1 + COORD_BYTES, PUBLIC_BYTES))
        val p = (params.curve.field as ECFieldFp).p
        if (x >= p || y >= p) throw InvalidKeyException("coordinate out of range")
        val lhs = y.multiply(y).mod(p)
        val rhs = x.multiply(x).multiply(x).add(params.curve.a.multiply(x)).add(params.curve.b).mod(p)
        if (lhs != rhs) throw InvalidKeyException("point is not on the curve")
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), params))
    }

    /** Private key from a raw big-endian scalar (used by the test vectors). */
    fun privateFromScalar(scalar: ByteArray): PrivateKey =
        KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(BigInteger(1, scalar), params))

    /** ECDH shared secret: the X coordinate, 32 bytes. */
    fun ecdh(privateKey: PrivateKey, peerPublic: PublicKey): ByteArray {
        val ka = KeyAgreement.getInstance("ECDH")
        ka.init(privateKey)
        ka.doPhase(peerPublic, true)
        val secret = ka.generateSecret()
        if (secret.size > COORD_BYTES) throw InvalidKeyException("unexpected ECDH output size")
        return fixed(BigInteger(1, secret))
    }

    /** Big-endian, left-padded to 32 bytes. */
    private fun fixed(v: BigInteger): ByteArray {
        val raw = v.toByteArray() // may carry a leading sign byte
        val out = ByteArray(COORD_BYTES)
        val n = minOf(raw.size, COORD_BYTES)
        System.arraycopy(raw, raw.size - n, out, COORD_BYTES - n, n)
        return out
    }
}

/** HKDF-SHA256 (RFC 5869). */
object Hkdf {
    private const val HASH_LEN = 32

    fun extract(salt: ByteArray, ikm: ByteArray): ByteArray {
        val key = if (salt.isEmpty()) ByteArray(HASH_LEN) else salt
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(ikm)
    }

    fun expand(prk: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length in 1..255 * HASH_LEN) { "bad HKDF length" }
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        val out = ByteArray(length)
        var prev = ByteArray(0)
        var pos = 0
        var counter = 1
        while (pos < length) {
            mac.update(prev)
            mac.update(info)
            mac.update(counter.toByte())
            prev = mac.doFinal()
            val n = minOf(prev.size, length - pos)
            System.arraycopy(prev, 0, out, pos, n)
            pos += n
            counter++
        }
        return out
    }
}

/** Key schedule of PROTOCOL.md section 9. All `info` strings are ASCII without terminator. */
object KeySchedule {
    fun transcriptHash(helloPayload: ByteArray, helloAckPayload: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").run {
            update(helloPayload)
            update(helloAckPayload)
            digest()
        }

    /** `pairKey` is null in PAIRING mode (ikm = ecdh only). */
    fun ikm(pairKey: ByteArray?, ecdh: ByteArray): ByteArray = if (pairKey == null) ecdh.copyOf() else pairKey + ecdh

    fun prk(ikm: ByteArray, transcriptHash: ByteArray): ByteArray = Hkdf.extract(transcriptHash, ikm)

    fun controlC2h(prk: ByteArray) = Hkdf.expand(prk, ascii("MB1 control c2h"), 32)
    fun controlH2c(prk: ByteArray) = Hkdf.expand(prk, ascii("MB1 control h2c"), 32)
    fun videoH2c(prk: ByteArray, videoNonce: ByteArray) = Hkdf.expand(prk, ascii("MB1 video h2c") + videoNonce, 32)
    fun videoC2h(prk: ByteArray, videoNonce: ByteArray) = Hkdf.expand(prk, ascii("MB1 video c2h") + videoNonce, 32)

    fun sasBytes(prk: ByteArray) = Hkdf.expand(prk, ascii("MB1 sas"), 4)

    /** 6-digit pairing code: u32 little-endian of the 4 bytes, mod 1 000 000, zero padded. */
    fun sas(prk: ByteArray): String {
        val b = sasBytes(prk)
        val v = (b[0].toLong() and 0xFF) or ((b[1].toLong() and 0xFF) shl 8) or
            ((b[2].toLong() and 0xFF) shl 16) or ((b[3].toLong() and 0xFF) shl 24)
        return (v % 1_000_000L).toString().padStart(6, '0')
    }

    fun newPairKey(prk: ByteArray) = Hkdf.expand(prk, ascii("MB1 pair"), 32)

    private fun ascii(s: String) = s.toByteArray(Charsets.US_ASCII)
}
