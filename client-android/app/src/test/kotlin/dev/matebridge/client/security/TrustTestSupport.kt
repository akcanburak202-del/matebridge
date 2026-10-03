package dev.matebridge.client.security

import dev.matebridge.client.session.AtomicKeyValueStore
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** In-memory [AtomicKeyValueStore]; [failCommits] makes every commit throw before anything is applied (all-or-nothing). */
class MapKv : AtomicKeyValueStore {
    val m = HashMap<String, String>()
    var failCommits = false
    var commits = 0

    override fun getString(key: String) = m[key]
    override fun putString(key: String, value: String) = commit(mapOf(key to value))
    override fun keys(): Set<String> = m.keys.toSet()
    override fun commit(changes: Map<String, String?>) {
        if (failCommits) throw java.io.IOException("commit failed")
        commits++
        for ((k, v) in changes) if (v == null) m.remove(k) else m[k] = v
    }
}

/** Software AES-GCM stand-in for the Android Keystore wrapper. */
class FakeWrapper(private val key: ByteArray = ByteArray(32) { 5 }) : KeyWrapper {
    override fun wrap(plain: ByteArray, aad: ByteArray): ByteArray {
        val iv = ByteArray(12).also { java.security.SecureRandom().nextBytes(it) }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        c.updateAAD(aad)
        return iv + c.doFinal(plain)
    }

    override fun unwrap(blob: ByteArray, aad: ByteArray): ByteArray? = try {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, blob, 0, 12))
        c.updateAAD(aad)
        c.doFinal(blob, 12, blob.size - 12)
    } catch (e: java.security.GeneralSecurityException) {
        null
    }
}

/** A real [EncryptedPairKeyStore] over [MapKv] with a settable wall clock, as the production trust layer sees it. */
class TrustFixture(var wallMs: Long = 1_700_000_000_000L) {
    val kv = MapKv()
    val store = EncryptedPairKeyStore(kv, FakeWrapper())
    val logs = ArrayList<String>()
    val trust = PairTrust(store, { wallMs }, log = { ev, fields -> logs += "$ev $fields" })
}

fun hexOf(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
