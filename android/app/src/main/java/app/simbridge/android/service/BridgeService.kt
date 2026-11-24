package app.simbridge.android.service

import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import app.simbridge.android.core.BridgeHub
import app.simbridge.android.core.Notifications
import app.simbridge.android.net.BleWake
import app.simbridge.android.net.BridgeError
import app.simbridge.android.net.BridgeServer
import app.simbridge.android.net.NsdAdvertiser
import app.simbridge.android.net.RequestHandler
import app.simbridge.android.telephony.CallController
import app.simbridge.android.telephony.ContactsRepo
import app.simbridge.android.telephony.SmsRepo
import app.simbridge.android.telephony.TelephonyMonitor
import org.json.JSONObject

/** Foreground service that keeps the bridge alive while the screen is off. */
class BridgeService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private lateinit var contacts: ContactsRepo
    private lateinit var sms: SmsRepo
    private lateinit var calls: CallController
    private lateinit var monitor: TelephonyMonitor
    private lateinit var nsd: NsdAdvertiser
    private var ble: BleWake? = null
    private var server: BridgeServer? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var netCallback: ConnectivityManager.NetworkCallback? = null
    private var restartAttempts = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        BridgeHub.init(this)
        val notif = Notifications.service(this, "Waiting for the iPhone")
        ServiceCompat.startForeground(
            this, Notifications.ID_SERVICE, notif,
            if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else 0,
        )

        contacts = ContactsRepo(this)
        sms = SmsRepo(this, contacts).also { it.start() }
        calls = CallController(this, contacts).also { it.start() }
        monitor = TelephonyMonitor(this) { status ->
            BridgeHub.status.value = status
            BridgeHub.broadcast(status.toJson().put("t", "status"))
        }.also { it.start() }

        BridgeHub.incomingSms = { address, body, subId ->
            val msg = sms.onIncoming(address, body, subId)
            BridgeHub.broadcast(JSONObject().put("t", "sms").put("msg", msg))
            BridgeHub.wakeClients()
        }
        BridgeHub.audio.onStateChanged = { main.post { monitor.rebuild() } }
        BridgeHub.onCallEnded = { BridgeHub.audio.stop("call_ended") }
        BridgeHub.refreshTelephony = {
            main.post {
                contacts.clearCache()
                monitor.rebuild()
                // Only restart BLE when it is not already advertising (restarting drops the iPhone's link).
                if (!BridgeHub.bleActive.value) ble?.let { it.stop(); it.start() }
            }
        }

        startServer()
        nsd = NsdAdvertiser(this).also { it.register() }
        ble = BleWake(this).also { BridgeHub.ble = it; it.start() }

        val wm = applicationContext.getSystemService(WifiManager::class.java)
        @Suppress("DEPRECATION")
        wifiLock = wm?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "SIMBridge:wifi")?.apply {
            setReferenceCounted(false); acquire()
        }
        watchNetwork()
        BridgeHub.serviceRunning.value = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            setEnabled(this, false)
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    private fun startServer() {
        val s = BridgeServer(BridgeHub.PORT, router)
        s.onClientsChanged = { main.post { onClientsChanged() } }
        server = s
        BridgeHub.server = s
        try {
            s.start()
        } catch (e: Exception) {
            Log.w(TAG, "server start", e)
        }
        // If the port was still held by a previous instance, retry a few times.
        main.postDelayed({
            if (BridgeHub.serverError.value != null && restartAttempts < 5 && server === s) {
                restartAttempts++
                s.shutdown()
                startServer()
            }
        }, 3000)
    }

    private fun onClientsChanged() {
        val clients = BridgeHub.clients.value
        val text = if (clients.isEmpty()) "Waiting for the iPhone"
        else "Connected to " + clients.joinToString(", ") { it.name }
        getSystemService(NotificationManager::class.java)
            .notify(Notifications.ID_SERVICE, Notifications.service(this, text))
        // Keep the CPU responsive while an iPhone is actively connected.
        if (clients.isNotEmpty()) {
            if (wakeLock == null) {
                wakeLock = getSystemService(PowerManager::class.java)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SIMBridge:client").apply {
                        setReferenceCounted(false); acquire(6 * 60 * 60 * 1000L)
                    }
            }
        } else {
            wakeLock?.let { if (it.isHeld) it.release() }
            wakeLock = null
        }
    }

    private fun watchNetwork() {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                main.postDelayed({ nsd.register() }, 1500)
                // Wi-Fi back: re-attach the built-in Wireless debugging link for call audio.
                main.postDelayed({ BridgeHub.audio.adb.connectAsync() }, 4000)
            }
            override fun onLost(network: Network) { main.postDelayed({ nsd.register() }, 1500) }
        }
        try {
            cm.registerNetworkCallback(
                NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), cb
            )
            netCallback = cb
        } catch (e: Exception) {
            Log.w(TAG, "network callback", e)
        }
    }

    private val router = RequestHandler { type, req, _ ->
        when (type) {
            "sync" -> JSONObject().apply {
                put("status", (BridgeHub.status.value ?: monitor.snapshot()).toJson())
                put("call", BridgeHub.call.value.toJson())
                put("audio", calls.audioState())
                val after = req.optLong("smsAfter", 0L)
                if (after > 0) {
                    put("sms", try { sms.inboxSince(after, 30) } catch (e: Exception) { org.json.JSONArray() })
                }
                val missedAfter = req.optLong("missedAfter", 0L)
                if (missedAfter > 0) {
                    put("missed", try { calls.missedSince(missedAfter) } catch (e: Exception) { org.json.JSONArray() })
                }
                put("time", System.currentTimeMillis())
            }
            "status" -> monitor.snapshot().toJson()
            "threads" -> {
                val marks = HashMap<Long, Long>()
                req.optJSONObject("readMarks")?.let { o ->
                    o.keys().forEach { k -> k.toLongOrNull()?.let { marks[it] = o.optLong(k) } }
                }
                JSONObject().put("threads", sms.threads(req.optInt("limit", 60).coerceIn(1, 200), marks))
            }
            "messages" -> {
                val tid = req.optLong("threadId", -1L)
                if (tid < 0) throw BridgeError("bad_request")
                JSONObject().put(
                    "messages",
                    sms.messages(tid, req.optInt("limit", 80).coerceIn(1, 300), req.optLong("before", 0L).takeIf { it > 0 }),
                )
            }
            "send_sms" -> JSONObject().put(
                "ref", sms.send(req.optString("to"), req.optString("body"), req.optInt("subId", -1).takeIf { it >= 0 })
            )
            "dial" -> { calls.dial(req.optString("number"), req.optInt("subId", -1).takeIf { it >= 0 }); JSONObject() }
            "answer" -> { calls.answer(req.optBoolean("speaker", false)); JSONObject() }
            "reject", "hangup" -> { calls.end(); JSONObject() }
            "speaker" -> {
                onMain { calls.setSpeaker(req.optBoolean("on")) }
                // Audio routing is applied asynchronously; report the state once it has settled.
                Thread.sleep(400)
                JSONObject().put("on", onMain { calls.speakerOn() })
            }
            "mute" -> JSONObject().put("on", onMain { calls.setMute(req.optBoolean("on")) })
            "calls" -> JSONObject().put("calls", calls.callLog(req.optInt("limit", 100).coerceIn(1, 500)))
            "listen" -> {
                if (!req.optBoolean("on")) {
                    BridgeHub.audio.stop()
                    JSONObject().put("on", false)
                } else {
                    BridgeHub.audio.refresh()
                    val st = BridgeHub.audio.state.value
                    if (st != "ready") throw BridgeError("dev_$st")
                    if (BridgeHub.call.value.state != "offhook") throw BridgeError("no_call")
                    if (BridgeHub.audio.running) BridgeHub.audio.stop("restart")
                    audioRestarts = 0
                    try {
                        startRelay()
                    } catch (e: Exception) {
                        Log.w(TAG, "listen start", e)
                        BridgeHub.log("call audio failed to start: ${e.message}")
                        throw BridgeError("audio_failed")
                    }
                    JSONObject().put("on", true).put("lockSecure", BridgeHub.audio.lockSecure)
                }
            }
            "ussd" -> JSONObject().put("text", calls.ussd(req.optString("code"), req.optInt("subId", -1).takeIf { it >= 0 }))
            "forward" -> {
                calls.forward(req.optString("mode"), req.optString("number"), req.optInt("subId", -1).takeIf { it >= 0 })
                JSONObject().put("forwarding", calls.forwardingState())
            }
            "forward_state" -> JSONObject().put("forwarding", calls.forwardingState())
            "diag" -> JSONObject().put("text", BridgeHub.diagText())
            "contacts" -> JSONObject().put("contacts", contacts.all())
            else -> throw BridgeError("unknown_request")
        }
    }

    @Volatile private var audioRestarts = 0

    /** Streams call audio; if capture stops on its own during the call, restarts it (up to 4 times). */
    private fun startRelay() {
        BridgeHub.audio.start(
            onPcm = { pcm ->
                BridgeHub.broadcast(JSONObject().put("t", "audio").put("d", android.util.Base64.encodeToString(pcm, android.util.Base64.NO_WRAP)))
            },
            onEnd = { reason ->
                val inCall = BridgeHub.call.value.state == "offhook"
                if (reason != null && inCall && audioRestarts < 4) {
                    audioRestarts++
                    BridgeHub.log("call audio restarting ($audioRestarts)")
                    main.postDelayed({
                        Thread {
                            try { if (BridgeHub.call.value.state == "offhook") startRelay() } catch (e: Exception) {
                                BridgeHub.log("call audio restart failed: ${e.message}")
                                BridgeHub.broadcast(JSONObject().put("t", "listen").put("on", false).put("reason", "failed"))
                            }
                        }.start()
                    }, 800)
                } else {
                    BridgeHub.broadcast(JSONObject().put("t", "listen").put("on", false).put("reason", reason ?: "stopped"))
                }
            },
        )
    }

    /** Audio routing calls are safest on the main thread. */
    private fun <T> onMain(block: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return block()
        val latch = java.util.concurrent.CountDownLatch(1)
        var result: Result<T>? = null
        main.post { result = runCatching(block); latch.countDown() }
        latch.await(3, java.util.concurrent.TimeUnit.SECONDS)
        return result?.getOrThrow() ?: throw BridgeError("timeout")
    }

    override fun onDestroy() {
        BridgeHub.serviceRunning.value = false
        BridgeHub.incomingSms = null
        BridgeHub.refreshTelephony = null
        BridgeHub.onCallEnded = null
        BridgeHub.audio.onStateChanged = null
        BridgeHub.audio.stop()
        BridgeHub.server = null
        BridgeHub.ble = null
        BridgeHub.stopPairing()
        server?.shutdown()
        server = null
        nsd.unregister()
        ble?.stop()
        monitor.stop()
        calls.stop()
        sms.stop()
        netCallback?.let { try { getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(it) } catch (_: Exception) {} }
        wifiLock?.let { if (it.isHeld) it.release() }
        wakeLock?.let { if (it.isHeld) it.release() }
        main.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    companion object {
        private const val TAG = "BridgeService"
        const val ACTION_STOP = "app.simbridge.android.STOP"

        fun start(context: Context) {
            setEnabled(context, true)
            try {
                ContextCompat.startForegroundService(context, Intent(context, BridgeService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "start failed", e)
            }
        }

        fun stop(context: Context) {
            setEnabled(context, false)
            context.stopService(Intent(context, BridgeService::class.java))
        }

        fun isEnabled(context: Context) =
            context.getSharedPreferences("settings", Context.MODE_PRIVATE).getBoolean("enabled", false)

        fun setEnabled(context: Context, on: Boolean) =
            context.getSharedPreferences("settings", Context.MODE_PRIVATE).edit().putBoolean("enabled", on).apply()
    }
}
