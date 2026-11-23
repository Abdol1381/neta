package app.simbridge.android.telephony

import android.Manifest
import android.content.Context
import android.net.Uri
import android.provider.ContactsContract
import org.json.JSONArray
import org.json.JSONObject

class ContactsRepo(private val context: Context) {
    private val cache = object : LinkedHashMap<String, String>(256, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>?) = size > 500
    }

    /** Display name for a phone number, or "" if unknown / no permission. */
    fun nameFor(number: String?): String {
        if (number.isNullOrBlank()) return ""
        if (!Perms.granted(context, Manifest.permission.READ_CONTACTS)) return ""
        synchronized(cache) { cache[number]?.let { return it } }
        val name = try {
            val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number))
            context.contentResolver.query(uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) ?: "" else ""
            } ?: ""
        } catch (e: Exception) {
            ""
        }
        synchronized(cache) { cache[number] = name }
        return name
    }

    fun clearCache() = synchronized(cache) { cache.clear() }

    fun all(): JSONArray {
        val out = JSONArray()
        if (!Perms.granted(context, Manifest.permission.READ_CONTACTS)) throw SecurityException("contacts")
        val byId = LinkedHashMap<Long, Pair<String, MutableList<String>>>()
        context.contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(
                ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Phone.NUMBER,
            ),
            null, null,
            ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME + " COLLATE LOCALIZED ASC",
        )?.use { c ->
            while (c.moveToNext()) {
                val id = c.getLong(0)
                val name = c.getString(1) ?: continue
                val num = c.getString(2)?.trim() ?: continue
                val entry = byId.getOrPut(id) { name to mutableListOf() }
                val normalized = num.filter { it.isDigit() || it == '+' }
                if (entry.second.none { it.filter { ch -> ch.isDigit() || ch == '+' } == normalized }) entry.second += num
            }
        }
        byId.forEach { (id, v) ->
            out.put(JSONObject().apply {
                put("id", id); put("name", v.first); put("numbers", JSONArray(v.second))
            })
        }
        return out
    }
}
