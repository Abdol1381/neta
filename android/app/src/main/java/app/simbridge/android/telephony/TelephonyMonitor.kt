package app.simbridge.android.telephony

import android.Manifest
import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.telephony.CellInfo
import android.telephony.PhoneStateListener
import android.telephony.ServiceState
import android.telephony.SignalStrength
import android.telephony.SubscriptionInfo
import android.telephony.SubscriptionManager
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import app.simbridge.android.core.BatteryState
import app.simbridge.android.core.DeviceStatus
import app.simbridge.android.core.SimState
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executor

/** Tracks per-SIM antenna (signal level, dBm, network type, operator), battery and airplane mode. */
@SuppressLint("MissingPermission")
class TelephonyMonitor(private val context: Context, private val onChange: (DeviceStatus) -> Unit) {
    private val main = Handler(Looper.getMainLooper())
    private val mainExecutor = Executor { main.post(it) }
    private val tm = context.getSystemService(TelephonyManager::class.java)
    private val sm = context.getSystemService(SubscriptionManager::class.java)

    private class Live(val subId: Int, val info: SubscriptionInfo?, val tm: TelephonyManager) {
        @Volatile var signal: SignalStrength? = null
        @Volatile var service: ServiceState? = null
        var unregister: () -> Unit = {}
    }

    // Read from request worker threads (snapshot) while the main thread rebuilds it.
    private val lives = CopyOnWriteArrayList<Live>()
    private var battery = BatteryState(0, false)
    private var running = false
    private var pending = false
    private var last: DeviceStatus? = null

    private val subListener = object : SubscriptionManager.OnSubscriptionsChangedListener() {
        override fun onSubscriptionsChanged() { if (running) main.post { rebuild() } }
    }

    private val sysReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            if (i.action == Intent.ACTION_BATTERY_CHANGED) readBattery(i)
            changed()
        }
    }

    fun start() {
        if (running) return
        running = true
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_BATTERY_CHANGED)
            addAction(Intent.ACTION_AIRPLANE_MODE_CHANGED)
        }
        ContextCompat.registerReceiver(context, sysReceiver, filter, ContextCompat.RECEIVER_EXPORTED)?.let { readBattery(it) }
        try { sm?.addOnSubscriptionsChangedListener(subListener) } catch (_: Exception) {}
        rebuild()
    }

    fun stop() {
        if (!running) return
        running = false
        try { context.unregisterReceiver(sysReceiver) } catch (_: Exception) {}
        try { sm?.removeOnSubscriptionsChangedListener(subListener) } catch (_: Exception) {}
        lives.forEach { it.unregister() }
        lives.clear()
    }

    /** Re-subscribe after permissions were granted or SIMs changed. */
    fun rebuild() {
        val old = lives.toList()
        val base = tm ?: run { lives.clear(); old.forEach { it.unregister() }; return }
        val subs = activeSubs()
        val next = if (subs.isEmpty()) {
            // No READ_PHONE_STATE yet (or no SIM): still show the default modem's signal.
            listOf(Live(SubscriptionManager.INVALID_SUBSCRIPTION_ID, null, base))
        } else {
            subs.map { info ->
                val subTm = try { base.createForSubscriptionId(info.subscriptionId) } catch (e: Exception) { base }
                Live(info.subscriptionId, info, subTm)
            }
        }
        old.forEach { it.unregister() }
        next.forEach { listen(it) }
        lives.clear()
        lives.addAll(next)
        last = null
        changed()
    }

    fun snapshot(): DeviceStatus {
        val defSms = SubscriptionManager.getDefaultSmsSubscriptionId()
        val defVoice = SubscriptionManager.getDefaultVoiceSubscriptionId()
        val defData = SubscriptionManager.getDefaultDataSubscriptionId()
        val sims = lives.toList().map { l ->
            val ss = l.service
            val level = l.signal?.level ?: 0
            val inService = ss?.state == ServiceState.STATE_IN_SERVICE
            val type = networkType(l.tm)
            SimState(
                subId = l.subId,
                slot = (l.info?.simSlotIndex ?: 0).coerceAtLeast(0),
                carrier = listOfNotNull(ss?.operatorAlphaShort, ss?.operatorAlphaLong, l.info?.carrierName?.toString(), safe { l.tm.networkOperatorName })
                    .firstOrNull { it.isNotBlank() } ?: "",
                displayName = l.info?.displayName?.toString() ?: "SIM",
                number = phoneNumber(l),
                level = if (ss != null && !inService) 0 else level,
                dbm = dbm(l.signal),
                net = netName(type),
                gen = netGen(type),
                service = when (ss?.state) {
                    ServiceState.STATE_IN_SERVICE -> "in"
                    ServiceState.STATE_OUT_OF_SERVICE -> "out"
                    ServiceState.STATE_EMERGENCY_ONLY -> "emergency"
                    ServiceState.STATE_POWER_OFF -> "off"
                    else -> if (level > 0) "in" else "unknown"
                },
                roaming = ss?.roaming ?: false,
                isDefaultSms = l.subId == defSms,
                isDefaultVoice = l.subId == defVoice,
                isDefaultData = l.subId == defData,
            )
        }.sortedBy { it.slot }
        return DeviceStatus(
            sims = sims,
            battery = battery,
            airplane = Settings.Global.getInt(context.contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0) != 0,
            model = Build.MODEL,
            android = Build.VERSION.RELEASE,
            perms = Perms.summary(context),
            devAudio = app.simbridge.android.core.BridgeHub.audio.state.value,
        )
    }

    private fun changed() {
        if (pending || !running) return
        pending = true
        main.postDelayed({
            pending = false
            val s = snapshot()
            if (s != last) { last = s; onChange(s) }
        }, 600)
    }

    @Suppress("DEPRECATION")
    private fun listen(l: Live) {
        try {
            if (Build.VERSION.SDK_INT >= 31) {
                val cb = object : TelephonyCallback(), TelephonyCallback.SignalStrengthsListener, TelephonyCallback.ServiceStateListener {
                    override fun onSignalStrengthsChanged(signalStrength: SignalStrength) { l.signal = signalStrength; changed() }
                    override fun onServiceStateChanged(serviceState: ServiceState) { l.service = serviceState; changed() }
                }
                l.tm.registerTelephonyCallback(mainExecutor, cb)
                l.unregister = { try { l.tm.unregisterTelephonyCallback(cb) } catch (_: Exception) {} }
            } else {
                val psl = if (Build.VERSION.SDK_INT >= 29) LegacyListener(l, mainExecutor) else LegacyListener(l)
                l.tm.listen(psl, PhoneStateListener.LISTEN_SIGNAL_STRENGTHS or PhoneStateListener.LISTEN_SERVICE_STATE)
                l.unregister = { try { l.tm.listen(psl, PhoneStateListener.LISTEN_NONE) } catch (_: Exception) {} }
            }
        } catch (e: Exception) {
            // Missing permission or no telephony: status will show what is available.
        }
        // Prime with current values where the API allows it.
        if (Build.VERSION.SDK_INT >= 28) l.signal = l.signal ?: safe { l.tm.signalStrength }
        if (Build.VERSION.SDK_INT >= 26 && granted(Manifest.permission.READ_PHONE_STATE)) l.service = l.service ?: safe { l.tm.serviceState }
    }

    @Suppress("DEPRECATION")
    private inner class LegacyListener : PhoneStateListener {
        private val live: Live
        constructor(l: Live) : super() { live = l }
        @androidx.annotation.RequiresApi(29)
        constructor(l: Live, e: Executor) : super(e) { live = l }

        override fun onSignalStrengthsChanged(signalStrength: SignalStrength) { live.signal = signalStrength; changed() }
        override fun onServiceStateChanged(serviceState: ServiceState) { live.service = serviceState; changed() }
    }

    private fun activeSubs(): List<SubscriptionInfo> =
        if (!granted(Manifest.permission.READ_PHONE_STATE)) emptyList()
        else safe { sm?.activeSubscriptionInfoList } ?: emptyList()

    @Suppress("DEPRECATION")
    private fun phoneNumber(l: Live): String {
        val info = l.info ?: return ""
        return safe {
            if (Build.VERSION.SDK_INT >= 33) sm?.getPhoneNumber(info.subscriptionId) else info.number
        }.orEmpty()
    }

    private fun networkType(t: TelephonyManager): Int =
        if (!granted(Manifest.permission.READ_PHONE_STATE)) TelephonyManager.NETWORK_TYPE_UNKNOWN
        else safe { t.dataNetworkType.takeIf { it != TelephonyManager.NETWORK_TYPE_UNKNOWN } ?: t.voiceNetworkType }
            ?: TelephonyManager.NETWORK_TYPE_UNKNOWN

    @Suppress("DEPRECATION")
    private fun dbm(s: SignalStrength?): Int? {
        s ?: return null
        if (Build.VERSION.SDK_INT >= 29) {
            return s.cellSignalStrengths.map { it.dbm }
                .firstOrNull { it != CellInfo.UNAVAILABLE && it != Int.MAX_VALUE && it < 0 && it > -150 }
        }
        val asu = s.gsmSignalStrength
        return if (asu in 0..31) -113 + 2 * asu else null
    }

    private fun readBattery(i: Intent) {
        val level = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = i.getIntExtra(BatteryManager.EXTRA_SCALE, 100).coerceAtLeast(1)
        val status = i.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        battery = BatteryState(
            level = if (level >= 0) level * 100 / scale else battery.level,
            charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL,
        )
    }

    private fun granted(p: String) = ContextCompat.checkSelfPermission(context, p) == PackageManager.PERMISSION_GRANTED

    private inline fun <T> safe(block: () -> T): T? = try { block() } catch (e: Exception) { null }

    companion object {
        fun netName(type: Int): String = when (type) {
            TelephonyManager.NETWORK_TYPE_GPRS -> "GPRS"
            TelephonyManager.NETWORK_TYPE_EDGE -> "EDGE"
            TelephonyManager.NETWORK_TYPE_GSM -> "GSM"
            TelephonyManager.NETWORK_TYPE_CDMA, TelephonyManager.NETWORK_TYPE_1xRTT -> "CDMA"
            TelephonyManager.NETWORK_TYPE_UMTS -> "UMTS"
            TelephonyManager.NETWORK_TYPE_HSDPA, TelephonyManager.NETWORK_TYPE_HSUPA, TelephonyManager.NETWORK_TYPE_HSPA -> "HSPA"
            TelephonyManager.NETWORK_TYPE_HSPAP -> "HSPA+"
            TelephonyManager.NETWORK_TYPE_EVDO_0, TelephonyManager.NETWORK_TYPE_EVDO_A, TelephonyManager.NETWORK_TYPE_EVDO_B,
            TelephonyManager.NETWORK_TYPE_EHRPD -> "EVDO"
            TelephonyManager.NETWORK_TYPE_TD_SCDMA -> "TD-SCDMA"
            TelephonyManager.NETWORK_TYPE_LTE, 19 -> "LTE"
            TelephonyManager.NETWORK_TYPE_IWLAN -> "Wi-Fi Calling"
            TelephonyManager.NETWORK_TYPE_NR -> "NR"
            else -> ""
        }

        fun netGen(type: Int): String = when (type) {
            TelephonyManager.NETWORK_TYPE_GPRS, TelephonyManager.NETWORK_TYPE_EDGE, TelephonyManager.NETWORK_TYPE_GSM,
            TelephonyManager.NETWORK_TYPE_CDMA, TelephonyManager.NETWORK_TYPE_1xRTT, TelephonyManager.NETWORK_TYPE_IDEN -> "2G"
            TelephonyManager.NETWORK_TYPE_UMTS, TelephonyManager.NETWORK_TYPE_HSDPA, TelephonyManager.NETWORK_TYPE_HSUPA,
            TelephonyManager.NETWORK_TYPE_HSPA, TelephonyManager.NETWORK_TYPE_HSPAP, TelephonyManager.NETWORK_TYPE_EVDO_0,
            TelephonyManager.NETWORK_TYPE_EVDO_A, TelephonyManager.NETWORK_TYPE_EVDO_B, TelephonyManager.NETWORK_TYPE_EHRPD,
            TelephonyManager.NETWORK_TYPE_TD_SCDMA -> "3G"
            TelephonyManager.NETWORK_TYPE_LTE, 19 -> "4G"
            TelephonyManager.NETWORK_TYPE_NR -> "5G"
            else -> ""
        }
    }
}
