package app.simbridge.android.net

import android.util.Log
import app.simbridge.android.BuildConfig
import app.simbridge.android.core.BridgeHub
import app.simbridge.android.core.ClientInfo
import app.simbridge.android.core.Crypto
import app.simbridge.android.core.PairRequest
import app.simbridge.android.core.PairingNotifier
import org.java_websocket.WebSocket
import org.java_websocket.handshake.ClientHandshake
import org.java_websocket.server.WebSocketServer
import org.json.JSONArray
import org.json.JSONObject
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

class BridgeError(val code: String, message: String = code) : Exception(message)

fun interface RequestHandler {
    /** Runs on a worker thread. Return the response data, or throw [BridgeError]. */
    fun handle(type: String, req: JSONObject, deviceId: String): JSONObject
}

/**
 * Local WebSocket server. Handshake:
 *  1. client -> plaintext {"t":"hello","mode":"pair"|"dev","id":?}
 *  2. server -> E({"t":"challenge","n":nonce,"sid":...})
 *  3. client -> E({"t":"auth","n":nonce,"name":...,"model":...})
 *  4a. dev:  server -> E({"t":"ready",...})
 *  4b. pair: user approves on Android -> E({"t":"paired","id":...,"key":...}) (with pairing key)
 * Every frame after step 1 is AES-256-GCM (see [Crypto]).
 */
class BridgeServer(port: Int, private val handler: RequestHandler) :
    WebSocketServer(InetSocketAddress(port)) {

    private enum class Phase { HELLO, AUTH, APPROVAL, READY, CLOSED }

    private class Session(val connId: Long) {
        @Volatile var phase = Phase.HELLO
        @Volatile var key: ByteArray? = null
        @Volatile var pairing = false
        @Volatile var deviceId = ""
        @Volatile var name = ""
        @Volatile var model = ""
        @Volatile var nonce = ByteArray(0)
        val openedAt = System.currentTimeMillis()
    }

    private val ids = AtomicLong(1)
    private val sessions = ConcurrentHashMap<WebSocket, Session>()
    private val workers = Executors.newFixedThreadPool(3)
    private val timer = Executors.newSingleThreadScheduledExecutor()

    @Volatile var onClientsChanged: (() -> Unit)? = null

    init {
        isReuseAddr = true
        connectionLostTimeout = 25
        isTcpNoDelay = true
    }

    override fun onStart() {
        Log.i(TAG, "listening on ${address.port}")
        BridgeHub.serverError.value = null
    }

    override fun onOpen(conn: WebSocket, handshake: ClientHandshake) {
        val s = Session(ids.getAndIncrement())
        sessions[conn] = s
        // Drop connections that never finish the handshake.
        schedule(15_000) {
            if (s.phase == Phase.HELLO || s.phase == Phase.AUTH) conn.close(4008, "handshake timeout")
        }
    }

    override fun onClose(conn: WebSocket, code: Int, reason: String?, remote: Boolean) {
        val s = sessions.remove(conn) ?: return
        val wasApproval = s.phase == Phase.APPROVAL
        s.phase = Phase.CLOSED
        if (wasApproval && BridgeHub.pendingApproval.value?.connId == s.connId) {
            BridgeHub.pendingApproval.value = null
            PairingNotifier.cancel(BridgeHub.appContext)
        }
        publishClients()
    }

    override fun onError(conn: WebSocket?, ex: Exception) {
        Log.w(TAG, "ws error", ex)
        if (conn == null) BridgeHub.serverError.value = ex.message ?: "server error"
    }

    override fun onMessage(conn: WebSocket, message: String) {
        val s = sessions[conn] ?: return
        if (s.phase != Phase.HELLO) { conn.close(4002, "unexpected text"); return }
        val o = try { JSONObject(message) } catch (e: Exception) { conn.close(4002, "bad hello"); return }
        if (o.optString("t") != "hello") { conn.close(4002, "bad hello"); return }

        when (o.optString("mode")) {
            "pair" -> {
                val p = BridgeHub.activePairing()
                if (p == null) { plainError(conn, "pairing_closed", 4003); return }
                s.key = p.key
                s.pairing = true
            }
            "dev" -> {
                val dev = BridgeHub.trust.find(o.optString("id"))
                if (dev == null) { plainError(conn, "unknown_device", 4001); return }
                s.key = dev.key
                s.deviceId = dev.id
            }
            else -> { conn.close(4002, "bad mode"); return }
        }
        s.nonce = Crypto.randomBytes(16)
        s.phase = Phase.AUTH
        send(conn, s, JSONObject().apply {
            put("t", "challenge"); put("n", Crypto.b64(s.nonce)); put("sid", BridgeHub.trust.serverId); put("v", 1)
        })
    }

    override fun onMessage(conn: WebSocket, message: ByteBuffer) {
        val s = sessions[conn] ?: return
        val key = s.key ?: run { conn.close(4002, "no key"); return }
        val bytes = ByteArray(message.remaining()).also { message.get(it) }
        val plain = Crypto.open(key, bytes, Crypto.AAD_CLIENT_TO_SERVER)
        if (plain == null) { conn.close(4002, "auth failed"); return }
        val o = try { JSONObject(String(plain, Charsets.UTF_8)) } catch (e: Exception) { return }

        when (s.phase) {
            Phase.AUTH -> onAuth(conn, s, o)
            Phase.READY -> onRequest(conn, s, o)
            else -> Unit
        }
    }

    private fun onAuth(conn: WebSocket, s: Session, o: JSONObject) {
        if (o.optString("t") != "auth" || o.optString("n") != Crypto.b64(s.nonce)) {
            conn.close(4002, "bad auth"); return
        }
        s.name = o.optString("name", "iPhone").take(64)
        s.model = o.optString("model", "").take(64)
        if (s.pairing) {
            s.phase = Phase.APPROVAL
            val code = Crypto.verificationCode(s.key!!, s.nonce)
            val req = PairRequest(s.connId, s.name, s.model, code)
            BridgeHub.pendingApproval.value = req
            if (BuildConfig.DEBUG) Log.i("SIMBridgeTest", "APPROVAL $code")
            PairingNotifier.show(BridgeHub.appContext, req)
        } else {
            s.phase = Phase.READY
            BridgeHub.trust.touch(s.deviceId, s.name)
            BridgeHub.refreshDevices()
            send(conn, s, JSONObject().apply {
                put("t", "ready")
                put("sid", BridgeHub.trust.serverId)
                put("name", BridgeHub.deviceName())
                put("hosts", JSONArray(NetUtil.localAddresses()))
                put("port", address.port)
            })
            publishClients()
        }
    }

    fun resolvePairing(connId: Long, approved: Boolean) {
        val entry = sessions.entries.firstOrNull { it.value.connId == connId } ?: return
        val conn = entry.key
        val s = entry.value
        if (s.phase != Phase.APPROVAL) return
        if (!approved) {
            send(conn, s, JSONObject().put("t", "denied"))
            schedule(500) { conn.close(1000, "denied") }
            return
        }
        val dev = BridgeHub.trust.add(s.name, s.model)
        BridgeHub.refreshDevices()
        BridgeHub.stopPairing() // one QR = one device
        send(conn, s, JSONObject().apply {
            put("t", "paired")
            put("id", dev.id)
            put("key", Crypto.b64(dev.key))
            put("sid", BridgeHub.trust.serverId)
            put("name", BridgeHub.deviceName())
        })
        // Client reconnects with its new device key.
        schedule(1500) { conn.close(1000, "paired") }
    }

    private fun onRequest(conn: WebSocket, s: Session, o: JSONObject) {
        val type = o.optString("t")
        val rid = o.optString("rid", "")
        if (type == "ping") {
            send(conn, s, JSONObject().apply { put("t", "pong"); put("rid", rid); put("ts", o.optLong("ts")) })
            return
        }
        try {
            workers.execute {
                val res = JSONObject().put("t", "res").put("rid", rid)
                try {
                    res.put("ok", true).put("data", handler.handle(type, o, s.deviceId))
                } catch (e: BridgeError) {
                    res.put("ok", false).put("err", e.code)
                } catch (e: SecurityException) {
                    res.put("ok", false).put("err", "permission_denied")
                } catch (e: Exception) {
                    Log.w(TAG, "request $type failed", e)
                    res.put("ok", false).put("err", "internal").put("msg", e.message ?: "")
                }
                send(conn, s, res)
            }
        } catch (e: Exception) {
            Log.w(TAG, "executor rejected", e)
        }
    }

    fun broadcast(event: JSONObject) {
        sessions.forEach { (conn, s) -> if (s.phase == Phase.READY) send(conn, s, event) }
    }

    fun disconnectDevice(deviceId: String) {
        sessions.forEach { (conn, s) -> if (s.deviceId == deviceId) conn.close(4001, "revoked") }
    }

    fun hasReadyClients() = sessions.values.any { it.phase == Phase.READY }

    private fun send(conn: WebSocket, s: Session, o: JSONObject) {
        val key = s.key ?: return
        try {
            if (conn.isOpen) conn.send(Crypto.seal(key, o.toString().toByteArray(Charsets.UTF_8), Crypto.AAD_SERVER_TO_CLIENT))
        } catch (e: Exception) {
            Log.w(TAG, "send failed", e)
        }
    }

    private fun plainError(conn: WebSocket, code: String, closeCode: Int) {
        try { conn.send(JSONObject().put("t", "error").put("code", code).toString()) } catch (_: Exception) {}
        schedule(300) { conn.close(closeCode, code) }
    }

    private fun schedule(delayMs: Long, block: () -> Unit) {
        try { timer.schedule({ try { block() } catch (_: Exception) {} }, delayMs, TimeUnit.MILLISECONDS) } catch (_: Exception) {}
    }

    private fun publishClients() {
        BridgeHub.clients.value = sessions.entries
            .filter { it.value.phase == Phase.READY }
            .map { (conn, s) ->
                ClientInfo(s.connId, s.deviceId, s.name, conn.remoteSocketAddress?.address?.hostAddress ?: "", s.openedAt)
            }
        onClientsChanged?.invoke()
    }

    fun shutdown() {
        try { stop(1000) } catch (_: Exception) {}
        workers.shutdownNow()
        timer.shutdownNow()
        sessions.clear()
        BridgeHub.clients.value = emptyList()
        BridgeHub.pendingApproval.value = null
    }

    companion object { private const val TAG = "BridgeServer" }
}
