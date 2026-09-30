package dev.matebridge.client.security

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.GeneralSecurityException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * [KeyWrapper] backed by a non-exportable AES-256-GCM key generated inside the Android Keystore. This is the
 * only class that touches the Keystore. Blob layout: 12-byte IV || ciphertext || tag. Not covered by JVM
 * tests (the Keystore needs a device); the logic around it is tested with a fake [KeyWrapper].
 */
class AndroidKeystoreWrapper(private val alias: String = "matebridge.pairkeys.v1") : KeyWrapper {
    private fun secretKey(): SecretKey {
        val ks = KeyStore.getInstance(PROVIDER).apply { load(null) }
        (ks.getKey(alias, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        gen.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return gen.generateKey()
    }

    override fun wrap(plain: ByteArray, aad: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey()) // the Keystore picks a fresh random IV
        cipher.updateAAD(aad)
        val ct = cipher.doFinal(plain)
        return cipher.iv + ct
    }

    override fun unwrap(blob: ByteArray, aad: ByteArray): ByteArray? {
        if (blob.size < IV_BYTES + TAG_BYTES) return null
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(TAG_BYTES * 8, blob, 0, IV_BYTES))
            cipher.updateAAD(aad)
            cipher.doFinal(blob, IV_BYTES, blob.size - IV_BYTES)
        } catch (e: GeneralSecurityException) {
            null
        }
    }

    private companion object {
        const val PROVIDER = "AndroidKeyStore"
        const val IV_BYTES = 12
        const val TAG_BYTES = 16
    }
}
