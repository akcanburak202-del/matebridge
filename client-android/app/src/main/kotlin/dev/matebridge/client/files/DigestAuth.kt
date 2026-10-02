package dev.matebridge.client.files

import java.security.MessageDigest
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * HTTP authentication of the WebDAV server (decision 0015, PROTOCOL.md 0x09): user [FilesConfig.USER], password the
 * per-start [token]. Digest (RFC 7616 with MD5 and `qop=auth`, what Finder speaks) and Basic are accepted; a 401 offers
 * Digest only. Nonces are stateless: hex time stamp plus an HMAC under a per-start [secret], valid for
 * [NONCE_LIFETIME_MS]; an old nonce with a correct response yields [Result.STALE] so the client retries silently.
 * Comparisons of secrets are constant-time. Nothing here logs; the token and the header must never be logged.
 */
class DigestAuth(
    private val token: String,
    private val secret: ByteArray,
    private val nowMs: () -> Long = System::currentTimeMillis,
) {
    enum class Result { OK, MISSING, BAD, STALE }

    /** Checks the `Authorization` [header] of a request with [method] and raw request target [target]. */
    fun check(method: String, target: String, header: String?): Result {
        if (header == null) return Result.MISSING
        val h = header.trim()
        return when {
            h.startsWith("Basic ", ignoreCase = true) -> checkBasic(h.substring(6).trim())
            h.startsWith("Digest ", ignoreCase = true) -> checkDigest(method, target, h.substring(7))
            else -> Result.BAD
        }
    }

    /** `WWW-Authenticate` value of a 401. */
    fun challenge(stale: Boolean = false): String =
        "Digest realm=\"${FilesConfig.REALM}\", qop=\"auth\", algorithm=MD5, nonce=\"${mintNonce()}\", " +
            "opaque=\"${OPAQUE}\"" + if (stale) ", stale=true" else ""

    fun mintNonce(atMs: Long = nowMs()): String {
        val ts = java.lang.Long.toHexString(atMs)
        return ts + mac(ts)
    }

    private fun checkBasic(b64: String): Result {
        val decoded = try {
            String(Base64.getDecoder().decode(b64), Charsets.UTF_8)
        } catch (e: IllegalArgumentException) {
            return Result.BAD
        }
        val colon = decoded.indexOf(':')
        if (colon < 0) return Result.BAD
        val userOk = same(decoded.substring(0, colon), FilesConfig.USER)
        val passOk = same(decoded.substring(colon + 1), token)
        return if (userOk and passOk) Result.OK else Result.BAD
    }

    private fun checkDigest(method: String, target: String, params: String): Result {
        val p = parseParams(params) ?: return Result.BAD
        val user = p["username"] ?: return Result.BAD
        val realm = p["realm"] ?: return Result.BAD
        val nonce = p["nonce"] ?: return Result.BAD
        val uri = p["uri"] ?: return Result.BAD
        val response = p["response"] ?: return Result.BAD
        val qop = p["qop"] ?: return Result.BAD // we offer qop="auth"; the legacy form without qop is not accepted
        val nc = p["nc"] ?: return Result.BAD
        val cnonce = p["cnonce"] ?: return Result.BAD
        val alg = p["algorithm"]
        if (alg != null && !alg.equals("MD5", ignoreCase = true)) return Result.BAD
        if (!qop.equals("auth", ignoreCase = true)) return Result.BAD
        if (user != FilesConfig.USER || realm != FilesConfig.REALM) return Result.BAD
        if (!sameRequest(uri, target)) return Result.BAD
        val age = nonceAge(nonce) ?: return Result.BAD
        val expected = response(user, realm, token, method, uri, nonce, nc, cnonce, qop)
        if (!same(response.lowercase(), expected)) return Result.BAD
        return if (age > NONCE_LIFETIME_MS || age < -NONCE_FUTURE_SLACK_MS) Result.STALE else Result.OK
    }

    /** The digest `uri` must name the requested resource: same string, or the same decoded path. */
    private fun sameRequest(uri: String, target: String): Boolean {
        if (uri == target) return true
        val a = DavPath.parseTarget(uri) ?: return false
        val b = DavPath.parseTarget(target) ?: return false
        return a == b
    }

    /** Age in ms of a nonce we minted, or null when it is not ours. */
    private fun nonceAge(nonce: String): Long? {
        if (nonce.length <= MAC_HEX || nonce.length > MAC_HEX + 16) return null
        val ts = nonce.substring(0, nonce.length - MAC_HEX)
        if (!same(nonce.substring(ts.length), mac(ts))) return null
        val at = ts.toLongOrNull(16) ?: return null
        return nowMs() - at
    }

    private fun mac(ts: String): String {
        val m = Mac.getInstance("HmacSHA256")
        m.init(SecretKeySpec(secret, "HmacSHA256"))
        return hex(m.doFinal(ts.toByteArray(Charsets.US_ASCII))).substring(0, MAC_HEX)
    }

    companion object {
        const val NONCE_LIFETIME_MS = 60L * 60 * 1000
        private const val NONCE_FUTURE_SLACK_MS = 60_000L
        private const val MAC_HEX = 32
        private const val OPAQUE = "6d6174656272696467652d66696c6573"

        /** RFC 7616 / 2617 response for MD5 with `qop=auth`. */
        fun response(
            user: String, realm: String, password: String, method: String, uri: String,
            nonce: String, nc: String, cnonce: String, qop: String,
        ): String {
            val ha1 = md5Hex("$user:$realm:$password")
            val ha2 = md5Hex("$method:$uri")
            return md5Hex("$ha1:$nonce:$nc:$cnonce:$qop:$ha2")
        }

        fun md5Hex(s: String): String = hex(MessageDigest.getInstance("MD5").digest(s.toByteArray(Charsets.UTF_8)))

        /**
         * Parses `k=v, k="quoted, with \"escapes\""` auth parameters; keys lowercased. Null when malformed or a key
         * repeats.
         */
        fun parseParams(s: String): Map<String, String>? {
            val out = HashMap<String, String>()
            var i = 0
            val n = s.length
            while (i < n) {
                while (i < n && (s[i] == ' ' || s[i] == '\t' || s[i] == ',')) i++
                if (i >= n) break
                val eq = s.indexOf('=', i)
                if (eq < 0) return null
                val key = s.substring(i, eq).trim().lowercase()
                if (key.isEmpty() || key.any { it == ' ' || it == '"' || it == ',' }) return null
                i = eq + 1
                while (i < n && s[i] == ' ') i++
                val value: String
                if (i < n && s[i] == '"') {
                    val sb = StringBuilder()
                    i++
                    var closed = false
                    while (i < n) {
                        val c = s[i]
                        if (c == '\\' && i + 1 < n) {
                            sb.append(s[i + 1]); i += 2; continue
                        }
                        if (c == '"') { closed = true; i++; break }
                        sb.append(c); i++
                    }
                    if (!closed) return null
                    value = sb.toString()
                } else {
                    val end = s.indexOf(',', i).let { if (it < 0) n else it }
                    value = s.substring(i, end).trim()
                    i = end
                }
                if (out.put(key, value) != null) return null
            }
            return out
        }

        /** Constant-time string comparison (length is not secret here: tokens and digests have fixed lengths). */
        fun same(a: String, b: String): Boolean =
            MessageDigest.isEqual(a.toByteArray(Charsets.UTF_8), b.toByteArray(Charsets.UTF_8))

        private fun hex(b: ByteArray): String {
            val sb = StringBuilder(b.size * 2)
            for (x in b) {
                val v = x.toInt() and 0xFF
                sb.append(HEX[v shr 4]).append(HEX[v and 15])
            }
            return sb.toString()
        }

        private val HEX = "0123456789abcdef".toCharArray()
    }
}
