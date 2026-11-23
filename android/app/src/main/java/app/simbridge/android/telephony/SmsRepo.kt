package app.simbridge.android.telephony

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.Telephony
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import androidx.core.content.ContextCompat
import app.simbridge.android.core.BridgeHub
import app.simbridge.android.net.BridgeError
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

class SmsRepo(private val context: Context, private val contacts: ContactsRepo) {
    private val smsUri: Uri = Telephony.Sms.CONTENT_URI
    private val requestCodes = AtomicInteger(1000)

    /** Incoming messages seen live (the provider write by the default SMS app can lag behind). */
    private val recent = ArrayDeque<JSONObject>()

    private val resultReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            val ref = i.getStringExtra(EXTRA_REF) ?: return
            val ok = resultCode == Activity.RESULT_OK
            val state = when (i.action) {
                ACTION_SENT -> if (ok) "sent" else "failed"
                ACTION_DELIVERED -> if (ok) "delivered" else return
                else -> return
            }
            BridgeHub.broadcast(JSONObject().apply {
                put("t", "sms_status"); put("ref", ref); put("state", state)
                if (!ok) put("error", resultCode)
            })
        }
    }

    fun start() {
        val f = IntentFilter().apply { addAction(ACTION_SENT); addAction(ACTION_DELIVERED) }
        ContextCompat.registerReceiver(context, resultReceiver, f, ContextCompat.RECEIVER_NOT_EXPORTED)
    }

    fun stop() {
        try { context.unregisterReceiver(resultReceiver) } catch (_: Exception) {}
    }

    private fun requireRead() {
        if (!Perms.granted(context, Manifest.permission.READ_SMS)) throw BridgeError("permission_denied")
    }

    /**
     * Conversations, newest first. [readMarks] (threadId -> ms) come from the iPhone: this app is not the
     * default SMS app and cannot mark messages read, so messages up to the mark count as read.
     */
    fun threads(limit: Int, readMarks: Map<Long, Long> = emptyMap()): JSONArray {
        requireRead()
        data class T(val id: Long, val address: String, val snippet: String, val date: Long, val out: Boolean, var unread: Int)
        val threads = LinkedHashMap<Long, T>()
        query(arrayOf("_id", "thread_id", "address", "body", "date", "type", "read"), null, null, "date DESC")?.use { c ->
            var scanned = 0
            while (c.moveToNext() && scanned < 5000) {
                scanned++
                val tid = c.getLong(1)
                val type = c.getInt(5)
                val unread = type == Telephony.Sms.MESSAGE_TYPE_INBOX && c.getInt(6) == 0 &&
                    c.getLong(4) > (readMarks[tid] ?: 0L)
                val t = threads[tid]
                if (t == null) {
                    if (threads.size >= limit) continue
                    threads[tid] = T(tid, c.getString(2) ?: "", c.getString(3) ?: "", c.getLong(4),
                        type != Telephony.Sms.MESSAGE_TYPE_INBOX, if (unread) 1 else 0)
                } else if (unread) t.unread++
            }
        }
        val out = JSONArray()
        threads.values.forEach { t ->
            out.put(JSONObject().apply {
                put("threadId", t.id); put("address", t.address); put("name", contacts.nameFor(t.address))
                put("snippet", t.snippet.take(200)); put("date", t.date); put("out", t.out); put("unread", t.unread)
            })
        }
        return out
    }

    fun messages(threadId: Long, limit: Int, before: Long?): JSONArray {
        requireRead()
        val sel = StringBuilder("thread_id = ?")
        val args = mutableListOf(threadId.toString())
        if (before != null && before > 0) { sel.append(" AND date < ?"); args += before.toString() }
        val list = mutableListOf<JSONObject>()
        query(PROJECTION, sel.toString(), args.toTypedArray(), "date DESC")?.use { c ->
            while (c.moveToNext() && list.size < limit) list += row(c)
        }
        return JSONArray(list.asReversed())
    }

    /** Received messages newer than [after] (ms), oldest first. Used by the iPhone after a background wake. */
    fun inboxSince(after: Long, limit: Int): JSONArray {
        requireRead()
        val list = mutableListOf<JSONObject>()
        query(PROJECTION, "type = ? AND date > ?", arrayOf(Telephony.Sms.MESSAGE_TYPE_INBOX.toString(), after.toString()), "date DESC")?.use { c ->
            while (c.moveToNext() && list.size < limit) list += row(c)
        }
        synchronized(recent) {
            recent.filter { r -> r.getLong("date") > after && list.none { it.optString("address") == r.optString("address") && it.optString("body") == r.optString("body") } }
                .forEach { list += it }
        }
        return JSONArray(list.sortedBy { it.getLong("date") }.takeLast(limit))
    }

    fun onIncoming(address: String, body: String, subId: Int): JSONObject {
        val msg = JSONObject().apply {
            put("id", "rx-" + UUID.randomUUID().toString().take(8))
            put("threadId", JSONObject.NULL)
            put("address", address); put("name", contacts.nameFor(address)); put("body", body)
            put("date", System.currentTimeMillis()); put("out", false); put("status", "ok"); put("read", false)
            put("subId", subId)
        }
        synchronized(recent) {
            recent.addLast(msg)
            while (recent.size > 30) recent.removeFirst()
        }
        return msg
    }

    @SuppressLint("MissingPermission")
    fun send(to: String, body: String, subId: Int?): String {
        if (!Perms.granted(context, Manifest.permission.SEND_SMS)) throw BridgeError("permission_denied")
        val dest = to.trim()
        if (dest.isEmpty() || dest.none { it.isDigit() } || body.isEmpty() || body.length > 5000) throw BridgeError("bad_request")
        val ref = UUID.randomUUID().toString()
        val sm = smsManager(subId)
        val parts = sm.divideMessage(body)
        val sent = pending(ACTION_SENT, ref)
        val delivered = pending(ACTION_DELIVERED, ref)
        if (parts.size <= 1) {
            sm.sendTextMessage(dest, null, body, sent, delivered)
        } else {
            val sentList = ArrayList<PendingIntent?>(parts.size)
            val delList = ArrayList<PendingIntent?>(parts.size)
            for (i in parts.indices) {
                sentList += if (i == parts.lastIndex) sent else null
                delList += if (i == parts.lastIndex) delivered else null
            }
            sm.sendMultipartTextMessage(dest, null, parts, sentList, delList)
        }
        return ref
    }

    @Suppress("DEPRECATION")
    private fun smsManager(subId: Int?): SmsManager {
        val id = subId?.takeIf { it >= 0 } ?: SubscriptionManager.getDefaultSmsSubscriptionId()
        return if (Build.VERSION.SDK_INT >= 31) {
            val base = context.getSystemService(SmsManager::class.java)
            if (id >= 0) base.createForSubscriptionId(id) else base
        } else {
            if (id >= 0) SmsManager.getSmsManagerForSubscriptionId(id) else SmsManager.getDefault()
        }
    }

    private fun pending(action: String, ref: String): PendingIntent {
        val i = Intent(action).setPackage(context.packageName).putExtra(EXTRA_REF, ref)
        return PendingIntent.getBroadcast(
            context, requestCodes.incrementAndGet(), i,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT,
        )
    }

    private var hasSubIdColumn = true

    private fun query(projection: Array<String>, sel: String?, args: Array<String>?, order: String): Cursor? {
        val proj = if (hasSubIdColumn) projection else projection.filter { it != "sub_id" }.toTypedArray()
        return try {
            context.contentResolver.query(smsUri, proj, sel, args, order)
        } catch (e: IllegalArgumentException) {
            if (hasSubIdColumn && projection.contains("sub_id")) {
                hasSubIdColumn = false
                query(projection, sel, args, order)
            } else throw e
        }
    }

    private fun row(c: Cursor): JSONObject {
        val type = c.getInt(c.getColumnIndexOrThrow("type"))
        val address = c.getString(c.getColumnIndexOrThrow("address")) ?: ""
        val subIdx = c.getColumnIndex("sub_id")
        return JSONObject().apply {
            put("id", c.getLong(c.getColumnIndexOrThrow("_id")).toString())
            put("threadId", c.getLong(c.getColumnIndexOrThrow("thread_id")))
            put("address", address)
            put("name", contacts.nameFor(address))
            put("body", c.getString(c.getColumnIndexOrThrow("body")) ?: "")
            put("date", c.getLong(c.getColumnIndexOrThrow("date")))
            put("out", type != Telephony.Sms.MESSAGE_TYPE_INBOX)
            put("status", when (type) {
                Telephony.Sms.MESSAGE_TYPE_FAILED -> "failed"
                Telephony.Sms.MESSAGE_TYPE_OUTBOX, Telephony.Sms.MESSAGE_TYPE_QUEUED -> "sending"
                else -> "ok"
            })
            put("read", c.getInt(c.getColumnIndexOrThrow("read")) != 0)
            put("subId", if (subIdx >= 0) c.getInt(subIdx) else -1)
        }
    }

    companion object {
        private const val ACTION_SENT = "app.simbridge.android.SMS_SENT"
        private const val ACTION_DELIVERED = "app.simbridge.android.SMS_DELIVERED"
        private const val EXTRA_REF = "ref"
        private val PROJECTION = arrayOf("_id", "thread_id", "address", "body", "date", "type", "read", "sub_id")
    }
}
