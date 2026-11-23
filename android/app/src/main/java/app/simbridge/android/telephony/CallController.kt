package app.simbridge.android.telephony

import android.Manifest
import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.CallLog
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import app.simbridge.android.core.BridgeHub
import app.simbridge.android.core.CallInfo
import app.simbridge.android.net.BridgeError
import org.json.JSONArray
import org.json.JSONObject

/**
 * Call control without replacing the user's dialer:
 * state via PHONE_STATE broadcasts, answer/end via TelecomManager, dial via placeCall.
 * The voice itself stays on the Android phone (earpiece, speaker or Bluetooth headset).
 */
@SuppressLint("MissingPermission")
class CallController(private val context: Context, private val contacts: ContactsRepo) {
    private val main = Handler(Looper.getMainLooper())
    private val telecom = context.getSystemService(TelecomManager::class.java)
    private val tm = context.getSystemService(TelephonyManager::class.java)
    private val audio = context.getSystemService(AudioManager::class.java)

    private data class Dialed(val number: String, val at: Long, val subId: Int)
    private var lastDialed: Dialed? = null
    private var sawOffhook = false
    private var endedByUs = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            if (i.action != TelephonyManager.ACTION_PHONE_STATE_CHANGED) return
            @Suppress("DEPRECATION")
            val number = i.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)
            // Dual SIM: which subscription the call is on (extra name differs between Android versions/OEMs).
            val subId = i.getIntExtra("android.telephony.extra.SUBSCRIPTION_INDEX", i.getIntExtra("subscription", -1))
            onState(i.getStringExtra(TelephonyManager.EXTRA_STATE), number, subId)
        }
    }

    fun start() {
        ContextCompat.registerReceiver(
            context, receiver, IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED), ContextCompat.RECEIVER_EXPORTED
        )
        // Initial state, in case the service starts during a call.
        @Suppress("DEPRECATION")
        val st = try { tm?.callState } catch (e: Exception) { null }
        when (st) {
            TelephonyManager.CALL_STATE_RINGING -> onState(TelephonyManager.EXTRA_STATE_RINGING, null, -1)
            TelephonyManager.CALL_STATE_OFFHOOK -> onState(TelephonyManager.EXTRA_STATE_OFFHOOK, null, -1)
        }
    }

    fun stop() {
        try { context.unregisterReceiver(receiver) } catch (_: Exception) {}
        BridgeHub.call.value = CallInfo.IDLE
    }

    private fun onState(state: String?, number: String?, subId: Int) {
        val cur = BridgeHub.call.value
        val now = System.currentTimeMillis()
        when (state) {
            TelephonyManager.EXTRA_STATE_RINGING -> {
                if (cur.state == "ringing") {
                    // Second broadcast carries the number once READ_CALL_LOG is granted.
                    if ((cur.number.isEmpty() && !number.isNullOrEmpty()) || (cur.subId < 0 && subId >= 0)) {
                        val n = number?.takeIf { it.isNotEmpty() } ?: cur.number
                        publish(cur.copy(number = n, name = contacts.nameFor(n), subId = if (subId >= 0) subId else cur.subId), wake = false)
                    }
                    return
                }
                sawOffhook = false
                endedByUs = false
                publish(CallInfo("ringing", number.orEmpty(), contacts.nameFor(number), "in", now, subId), wake = true)
            }
            TelephonyManager.EXTRA_STATE_OFFHOOK -> {
                if (cur.state == "offhook") return
                sawOffhook = true
                val next = if (cur.state == "ringing") {
                    cur.copy(state = "offhook", since = now)
                } else {
                    val d = lastDialed?.takeIf { now - it.at < 30_000 }
                    val dialed = d?.number.orEmpty()
                    endedByUs = false
                    CallInfo("offhook", dialed, contacts.nameFor(dialed), "out", now, if (subId >= 0) subId else d?.subId ?: -1)
                }
                publish(next, wake = false)
            }
            TelephonyManager.EXTRA_STATE_IDLE -> {
                if (cur.state == "idle") return
                val missed = cur.state == "ringing" && !sawOffhook
                if (missed) {
                    BridgeHub.broadcast(JSONObject().apply {
                        put("t", "missed"); put("number", cur.number); put("name", cur.name)
                        put("date", cur.since); put("rejected", endedByUs)
                    })
                }
                publish(CallInfo.IDLE, wake = false)
                lastDialed = null
                // Wake a backgrounded iPhone so it clears the "incoming call" notification. For a missed
                // call wait a moment: the dialer writes the call-log entry the iPhone reads on sync.
                main.postDelayed({ BridgeHub.wakeClients() }, if (missed) 2500L else 300L)
            }
        }
    }

    private fun publish(c: CallInfo, wake: Boolean) {
        BridgeHub.call.value = c
        BridgeHub.broadcast(JSONObject().put("t", "call").put("call", c.toJson()))
        if (wake) BridgeHub.wakeClients()
    }

    private fun need(p: String) { if (!Perms.granted(context, p)) throw BridgeError("permission_denied") }

    fun answer(speaker: Boolean) {
        need(Manifest.permission.ANSWER_PHONE_CALLS)
        if (BridgeHub.call.value.state != "ringing") throw BridgeError("no_call")
        telecom?.acceptRingingCall() ?: throw BridgeError("unsupported")
        if (speaker) main.postDelayed({ try { setSpeaker(true) } catch (_: Exception) {} }, 1200)
    }

    /** Rejects a ringing call or hangs up the active one. */
    fun end() {
        need(Manifest.permission.ANSWER_PHONE_CALLS)
        if (Build.VERSION.SDK_INT < 28) throw BridgeError("unsupported")
        if (BridgeHub.call.value.state == "idle") throw BridgeError("no_call")
        endedByUs = true
        @Suppress("DEPRECATION")
        val ok = telecom?.endCall() ?: false
        if (!ok) { endedByUs = false; throw BridgeError("no_call") }
    }

    fun dial(raw: String, subId: Int?) {
        need(Manifest.permission.CALL_PHONE)
        val number = raw.filter { it.isDigit() || it == '+' || it == '*' || it == '#' }
        if (number.isEmpty()) throw BridgeError("bad_request")
        if (BridgeHub.call.value.state != "idle") throw BridgeError("busy")
        val extras = Bundle()
        accountFor(subId)?.let { extras.putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, it) }
        lastDialed = Dialed(number, System.currentTimeMillis(), subId ?: SubscriptionManager.getDefaultVoiceSubscriptionId())
        try {
            telecom?.placeCall(Uri.fromParts("tel", number, null), extras) ?: throw BridgeError("unsupported")
        } catch (e: SecurityException) {
            throw BridgeError("permission_denied")
        }
    }

    @Suppress("DEPRECATION")
    fun setSpeaker(on: Boolean): Boolean {
        val am = audio ?: throw BridgeError("unsupported")
        if (Build.VERSION.SDK_INT >= 31) {
            if (on) {
                am.availableCommunicationDevices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                    ?.let { am.setCommunicationDevice(it) }
            } else {
                am.clearCommunicationDevice()
            }
        }
        am.isSpeakerphoneOn = on
        return speakerOn()
    }

    @Suppress("DEPRECATION")
    fun speakerOn(): Boolean {
        val am = audio ?: return false
        return if (Build.VERSION.SDK_INT >= 31) {
            am.communicationDevice?.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER || am.isSpeakerphoneOn
        } else am.isSpeakerphoneOn
    }

    fun setMute(on: Boolean): Boolean {
        val am = audio ?: throw BridgeError("unsupported")
        am.isMicrophoneMute = on
        return am.isMicrophoneMute
    }

    fun audioState(): JSONObject {
        val am = audio
        @Suppress("DEPRECATION")
        return JSONObject().apply {
            put("speaker", speakerOn())
            put("muted", am?.isMicrophoneMute ?: false)
        }
    }

    fun callLog(limit: Int): JSONArray {
        need(Manifest.permission.READ_CALL_LOG)
        val out = JSONArray()
        context.contentResolver.query(
            CallLog.Calls.CONTENT_URI,
            arrayOf(CallLog.Calls._ID, CallLog.Calls.NUMBER, CallLog.Calls.CACHED_NAME, CallLog.Calls.DATE,
                CallLog.Calls.DURATION, CallLog.Calls.TYPE),
            null, null, CallLog.Calls.DATE + " DESC",
        )?.use { c ->
            while (c.moveToNext() && out.length() < limit) {
                val number = c.getString(1) ?: ""
                val cached = c.getString(2)
                out.put(JSONObject().apply {
                    put("id", c.getLong(0))
                    put("number", number)
                    put("name", if (!cached.isNullOrBlank()) cached else contacts.nameFor(number))
                    put("date", c.getLong(3))
                    put("duration", c.getLong(4))
                    put("type", when (c.getInt(5)) {
                        CallLog.Calls.INCOMING_TYPE -> "in"
                        CallLog.Calls.OUTGOING_TYPE -> "out"
                        CallLog.Calls.MISSED_TYPE -> "missed"
                        CallLog.Calls.REJECTED_TYPE -> "rejected"
                        CallLog.Calls.BLOCKED_TYPE -> "blocked"
                        else -> "other"
                    })
                })
            }
        }
        return out
    }

    /** Missed calls newer than [after] (ms) — lets a woken iPhone catch up on what it missed. */
    fun missedSince(after: Long): JSONArray {
        val out = JSONArray()
        if (!Perms.granted(context, Manifest.permission.READ_CALL_LOG)) return out
        context.contentResolver.query(
            CallLog.Calls.CONTENT_URI,
            arrayOf(CallLog.Calls._ID, CallLog.Calls.NUMBER, CallLog.Calls.CACHED_NAME, CallLog.Calls.DATE, CallLog.Calls.DURATION),
            "${CallLog.Calls.TYPE} = ? AND ${CallLog.Calls.DATE} > ?",
            arrayOf(CallLog.Calls.MISSED_TYPE.toString(), after.toString()),
            CallLog.Calls.DATE + " DESC",
        )?.use { c ->
            while (c.moveToNext() && out.length() < 20) {
                val number = c.getString(1) ?: ""
                val cached = c.getString(2)
                out.put(JSONObject().apply {
                    put("id", c.getLong(0)); put("number", number)
                    put("name", if (!cached.isNullOrBlank()) cached else contacts.nameFor(number))
                    put("date", c.getLong(3)); put("duration", c.getLong(4)); put("type", "missed")
                })
            }
        }
        return out
    }

    private fun accountFor(subId: Int?): PhoneAccountHandle? {
        if (subId == null || subId < 0) return null
        if (!Perms.granted(context, Manifest.permission.READ_PHONE_STATE)) return null
        val accounts = try { telecom?.callCapablePhoneAccounts } catch (e: Exception) { null } ?: return null
        if (accounts.isEmpty()) return null
        if (Build.VERSION.SDK_INT >= 30) {
            accounts.firstOrNull { h ->
                try { tm?.createForPhoneAccountHandle(h)?.subscriptionId == subId } catch (e: Exception) { false }
            }?.let { return it }
        }
        accounts.firstOrNull { it.id == subId.toString() }?.let { return it }
        val info = try {
            context.getSystemService(SubscriptionManager::class.java)?.getActiveSubscriptionInfo(subId)
        } catch (e: Exception) { null } ?: return null
        @Suppress("DEPRECATION")
        val iccId = try { info.iccId } catch (e: Exception) { null }
        if (!iccId.isNullOrEmpty()) accounts.firstOrNull { it.id.isNotEmpty() && (it.id.startsWith(iccId) || iccId.startsWith(it.id)) }?.let { return it }
        return accounts.getOrNull(info.simSlotIndex)
    }
}
