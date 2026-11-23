package app.simbridge.android.core

import android.util.Base64
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Wire encryption shared with the iOS app (CryptoKit AES.GCM):
 * frame = nonce(12) || ciphertext || tag(16), AES-256-GCM, AAD = direction label.
 */
object Crypto {
    const val AAD_SERVER_TO_CLIENT = "simbridge-s2c"
    const val AAD_CLIENT_TO_SERVER = "simbridge-c2s"

    private val random = SecureRandom()

    fun randomBytes(n: Int): ByteArray = ByteArray(n).also { random.nextBytes(it) }

    fun seal(key: ByteArray, plain: ByteArray, aad: String): ByteArray {
        val nonce = randomBytes(12)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(aad.toByteArray(Charsets.UTF_8))
        val ct = cipher.doFinal(plain)
        return nonce + ct
    }

    /** Returns null when the frame is malformed or fails authentication. */
    fun open(key: ByteArray, frame: ByteArray, aad: String): ByteArray? {
        if (frame.size < 12 + 16) return null
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, frame, 0, 12))
            cipher.updateAAD(aad.toByteArray(Charsets.UTF_8))
            cipher.doFinal(frame, 12, frame.size - 12)
        } catch (e: Exception) {
            null
        }
    }

    fun sha256(vararg parts: ByteArray): ByteArray {
        val md = MessageDigest.getInstance("SHA-256")
        parts.forEach { md.update(it) }
        return md.digest()
    }

    /** 4-digit code shown on both phones while pairing so the user can confirm the match. */
    fun verificationCode(pairingKey: ByteArray, nonce: ByteArray): String {
        val h = sha256("simbridge-verify".toByteArray(), pairingKey, nonce)
        val v = ((h[0].toLong() and 0xff) shl 24) or ((h[1].toLong() and 0xff) shl 16) or
            ((h[2].toLong() and 0xff) shl 8) or (h[3].toLong() and 0xff)
        return (v % 10000).toString().padStart(4, '0')
    }

    fun b64(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.NO_WRAP)
    fun b64url(bytes: ByteArray): String =
        Base64.encodeToString(bytes, Base64.NO_WRAP or Base64.URL_SAFE or Base64.NO_PADDING)
    fun unb64(s: String): ByteArray? = try { Base64.decode(s, Base64.NO_WRAP) } catch (e: Exception) { null }
}
