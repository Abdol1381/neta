package app.simbridge.android.core

import org.json.JSONArray
import org.json.JSONObject

data class SimState(
    val subId: Int,
    val slot: Int,
    val carrier: String,
    val displayName: String,
    val number: String,
    val level: Int,        // 0..4
    val dbm: Int?,         // null when unknown
    val net: String,       // e.g. LTE, HSPA, NR
    val gen: String,       // 2G / 3G / 4G / 5G / ""
    val service: String,   // in / out / emergency / off
    val roaming: Boolean,
    val isDefaultSms: Boolean,
    val isDefaultVoice: Boolean,
    val isDefaultData: Boolean,
) {
    fun toJson() = JSONObject().apply {
        put("subId", subId); put("slot", slot); put("carrier", carrier); put("name", displayName)
        put("number", number); put("level", level); put("dbm", dbm ?: JSONObject.NULL)
        put("net", net); put("gen", gen); put("service", service); put("roaming", roaming)
        put("smsSim", isDefaultSms); put("voiceSim", isDefaultVoice); put("dataSim", isDefaultData)
    }
}

data class BatteryState(val level: Int, val charging: Boolean)

data class DeviceStatus(
    val sims: List<SimState>,
    val battery: BatteryState,
    val airplane: Boolean,
    val model: String,
    val android: String,
    val perms: Map<String, Boolean>,
    val devAudio: String = "unsupported",
    val lockSecure: Boolean = false,
) {
    fun toJson() = JSONObject().apply {
        put("sims", JSONArray().apply { sims.forEach { put(it.toJson()) } })
        put("battery", JSONObject().apply { put("level", battery.level); put("charging", battery.charging) })
        put("airplane", airplane)
        put("device", JSONObject().apply { put("model", model); put("android", android) })
        put("perms", JSONObject().apply { perms.forEach { (k, v) -> put(k, v) } })
        put("devAudio", devAudio)
        put("lockSecure", lockSecure)
    }
}

data class CallInfo(
    val state: String,        // idle / ringing / offhook
    val number: String,
    val name: String,
    val direction: String,    // in / out / ""
    val since: Long,
    val subId: Int = -1,      // SIM the call is on, -1 when unknown
) {
    fun toJson() = JSONObject().apply {
        put("state", state); put("number", number); put("name", name)
        put("direction", direction); put("since", since); put("subId", subId)
    }

    companion object {
        val IDLE = CallInfo("idle", "", "", "", 0L)
    }
}

data class ClientInfo(val connId: Long, val deviceId: String, val name: String, val address: String, val since: Long)

data class PairingSession(val key: ByteArray, val expiresAt: Long, val payload: String)

data class PairRequest(val connId: Long, val name: String, val model: String, val code: String)
