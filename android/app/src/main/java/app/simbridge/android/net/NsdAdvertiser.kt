package app.simbridge.android.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import app.simbridge.android.core.BridgeHub

/** Advertises the bridge on the local network as _simbridge._tcp so the iPhone finds it even if the IP changes. */
class NsdAdvertiser(context: Context) {
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var listener: NsdManager.RegistrationListener? = null

    @Synchronized
    fun register() {
        unregister()
        val info = NsdServiceInfo().apply {
            serviceName = "SIMBridge-" + BridgeHub.trust.serverId.take(8)
            serviceType = BridgeHub.SERVICE_TYPE
            port = BridgeHub.PORT
            setAttribute("sid", BridgeHub.trust.serverId)
            setAttribute("v", "1")
            // Current LAN addresses, so the iPhone can reconnect after the phone's IP changes.
            setAttribute("h", NetUtil.localAddresses().take(4).joinToString(","))
        }
        val l = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) { Log.i(TAG, "registered ${info.serviceName}") }
            override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) { Log.w(TAG, "register failed $code") }
            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) {}
        }
        try {
            nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, l)
            listener = l
        } catch (e: Exception) {
            Log.w(TAG, "nsd register", e)
        }
    }

    @Synchronized
    fun unregister() {
        listener?.let { try { nsd.unregisterService(it) } catch (_: Exception) {} }
        listener = null
    }

    companion object { private const val TAG = "Nsd" }
}
