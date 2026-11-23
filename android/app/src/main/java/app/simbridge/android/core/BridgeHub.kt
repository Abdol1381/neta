package app.simbridge.android.core

import android.content.Context
import android.os.Build
import app.simbridge.android.net.BleWake
import app.simbridge.android.net.BridgeServer
import app.simbridge.android.net.NetUtil
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject
import java.net.URLEncoder

/** Process-wide state shared between the foreground service, receivers and UI. */
object BridgeHub {
    const val PORT = 8765
    const val SERVICE_TYPE = "_simbridge._tcp"
    private const val PAIRING_TTL_MS = 5 * 60 * 1000L

    lateinit var appContext: Context
        private set
    val trust: TrustStore by lazy { TrustStore(appContext) }

    val serviceRunning = MutableStateFlow(false)
    val serverError = MutableStateFlow<String?>(null)
    val status = MutableStateFlow<DeviceStatus?>(null)
    val call = MutableStateFlow(CallInfo.IDLE)
    val clients = MutableStateFlow<List<ClientInfo>>(emptyList())
    val bleActive = MutableStateFlow(false)

    private val _pairing = MutableStateFlow<PairingSession?>(null)
    val pairing: StateFlow<PairingSession?> = _pairing.asStateFlow()
    val pendingApproval = MutableStateFlow<PairRequest?>(null)

    private val _devices = MutableStateFlow<List<TrustedDevice>>(emptyList())
    val devices: StateFlow<List<TrustedDevice>> = _devices.asStateFlow()

    @Volatile var server: BridgeServer? = null
    @Volatile var ble: BleWake? = null
    /** Set by the running service: (address, body, subId). */
    @Volatile var incomingSms: ((String, String, Int) -> Unit)? = null
    /** Set by the running service so the UI can re-read telephony after permissions change. */
    @Volatile var refreshTelephony: (() -> Unit)? = null

    fun init(context: Context) {
        appContext = context.applicationContext
        refreshDevices()
    }

    fun refreshDevices() { _devices.value = trust.devices() }

    fun deviceName(): String =
        if (Build.MODEL.startsWith(Build.MANUFACTURER, ignoreCase = true)) Build.MODEL
        else "${Build.MANUFACTURER.replaceFirstChar { it.uppercase() }} ${Build.MODEL}"

    /** Opens a fresh pairing window and returns the QR payload. */
    fun startPairing(): PairingSession {
        val key = Crypto.randomBytes(32)
        val hosts = NetUtil.localAddresses().joinToString(",")
        val payload = "simbridge://pair?v=1" +
            "&sid=" + enc(trust.serverId) +
            "&n=" + enc(deviceName()) +
            "&p=" + PORT +
            "&h=" + enc(hosts) +
            "&k=" + Crypto.b64url(key)
        val s = PairingSession(key, System.currentTimeMillis() + PAIRING_TTL_MS, payload)
        _pairing.value = s
        return s
    }

    fun activePairing(): PairingSession? =
        _pairing.value?.takeIf { it.expiresAt > System.currentTimeMillis() }

    fun stopPairing() { _pairing.value = null }

    fun resolvePairing(approved: Boolean) {
        val req = pendingApproval.value ?: return
        pendingApproval.value = null
        server?.resolvePairing(req.connId, approved)
        PairingNotifier.cancel(appContext)
    }

    fun revoke(id: String) {
        trust.remove(id)
        refreshDevices()
        server?.disconnectDevice(id)
    }

    fun broadcast(event: JSONObject) { server?.broadcast(event) }

    /** Ping the iPhone over Bluetooth LE so iOS wakes the app in the background. */
    fun wakeClients() { ble?.wake() }

    private fun enc(s: String) = URLEncoder.encode(s, "UTF-8")
}
