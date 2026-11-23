package app.simbridge.android.core

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class TrustedDevice(
    val id: String,
    val name: String,
    val model: String,
    val key: ByteArray,
    val pairedAt: Long,
    val lastSeen: Long,
)

/**
 * Stores this phone's server identity and the iPhones it trusts.
 * Per-device keys are wrapped with a non-exportable Android Keystore key.
 */
class TrustStore(context: Context) {
    private val prefs = context.getSharedPreferences("trust", Context.MODE_PRIVATE)
    private val lock = Any()

    val serverId: String = prefs.getString("server_id", null) ?: UUID.randomUUID().toString().also {
        prefs.edit().putString("server_id", it).apply()
    }

    fun devices(): List<TrustedDevice> = synchronized(lock) {
        val arr = JSONArray(prefs.getString("devices", "[]"))
        (0 until arr.length()).mapNotNull { i ->
            val o = arr.getJSONObject(i)
            val key = unwrap(o.getString("key")) ?: return@mapNotNull null
            TrustedDevice(
                id = o.getString("id"),
                name = o.optString("name", "iPhone"),
                model = o.optString("model", ""),
                key = key,
                pairedAt = o.optLong("pairedAt"),
                lastSeen = o.optLong("lastSeen"),
            )
        }
    }

    fun find(id: String): TrustedDevice? = devices().firstOrNull { it.id == id }

    fun add(name: String, model: String): TrustedDevice = synchronized(lock) {
        val dev = TrustedDevice(
            id = UUID.randomUUID().toString(),
            name = name, model = model,
            key = Crypto.randomBytes(32),
            pairedAt = System.currentTimeMillis(),
            lastSeen = System.currentTimeMillis(),
        )
        save(devices() + dev)
        dev
    }

    fun touch(id: String, name: String?) = synchronized(lock) {
        save(devices().map {
            if (it.id == id) it.copy(lastSeen = System.currentTimeMillis(), name = name?.takeIf { n -> n.isNotBlank() } ?: it.name)
            else it
        })
    }

    fun remove(id: String) = synchronized(lock) { save(devices().filterNot { it.id == id }) }

    private fun save(list: List<TrustedDevice>) {
        val arr = JSONArray()
        list.forEach {
            arr.put(JSONObject().apply {
                put("id", it.id); put("name", it.name); put("model", it.model)
                put("key", wrap(it.key)); put("pairedAt", it.pairedAt); put("lastSeen", it.lastSeen)
            })
        }
        prefs.edit().putString("devices", arr.toString()).commit()
    }

    // --- Android Keystore wrapping ---
    private fun masterKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    private fun wrap(raw: ByteArray): String {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, masterKey())
        return Crypto.b64(c.iv + c.doFinal(raw))
    }

    private fun unwrap(s: String): ByteArray? = try {
        val all = Crypto.unb64(s) ?: return null
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, masterKey(), GCMParameterSpec(128, all, 0, 12))
        c.doFinal(all, 12, all.size - 12)
    } catch (e: Exception) {
        null
    }

    companion object { private const val ALIAS = "simbridge_trust_v1" }
}
