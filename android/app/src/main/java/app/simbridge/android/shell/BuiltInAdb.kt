package app.simbridge.android.shell

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.provider.Settings
import android.util.Log
import app.simbridge.android.net.NetUtil
import kotlinx.coroutines.flow.MutableStateFlow
import java.io.InputStream
import java.util.concurrent.Callable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/** A running shell command: stdout plus a way to stop it. */
interface ShellProc {
    val input: InputStream
    fun destroy()
}

/**
 * Built-in replacement for Shizuku: pairs with and connects to the phone's own Wireless debugging
 * (adbd over TLS) and runs shell commands with ADB privileges.
 *
 * Ports come from mDNS discovery or from the user (the "IP address & Port" / pairing dialog shown by
 * Android). Every attempt has a time limit and the exact error is kept for the setup dialog. After the
 * first connection the app grants itself WRITE_SECURE_SETTINGS, so after a reboot it can switch
 * Wireless debugging back on and reconnect by itself.
 */
class BuiltInAdb(private val context: Context) {
    /** unpaired / connecting / offline / ready */
    val state = MutableStateFlow(if (paired) "offline" else "unpaired")
    var onStateChanged: (() -> Unit)? = null
    /** Last problem to show in the setup dialog (null = none). */
    val message = MutableStateFlow<String?>(null)
    private val prefs = context.getSharedPreferences("adb", Context.MODE_PRIVATE)
    private val worker = Executors.newSingleThreadExecutor()
    private val attempts = Executors.newCachedThreadPool()
    @Volatile private var connecting = false
    @Volatile private var lastError = ""

    val paired: Boolean get() = context.getSharedPreferences("adb", Context.MODE_PRIVATE).getBoolean("paired", false)

    private fun manager() = AdbManager.get(context)

    private fun setState(s: String) {
        if (state.value != s) {
            app.simbridge.android.core.BridgeHub.log("wireless debugging link: $s${if (s == "offline" && lastError.isNotEmpty()) " — $lastError" else ""}")
            state.value = s
            onStateChanged?.invoke()
        }
    }

    val ready: Boolean get() = try { state.value == "ready" && manager().isConnected } catch (e: Throwable) { false }

    /** Loopback first, then the phone's Wi-Fi address (some builds only listen on the Wi-Fi interface). */
    private val hosts: List<String> get() = (listOf("127.0.0.1") + NetUtil.localAddresses()).distinct()

    /** Runs [block] with a time limit; records the error text. */
    private fun limited(ms: Long, block: () -> Boolean): Boolean {
        val f = attempts.submit(Callable { block() })
        return try {
            f.get(ms, TimeUnit.MILLISECONDS)
        } catch (e: TimeoutException) {
            f.cancel(true)
            lastError = "no answer (timeout)"
            false
        } catch (e: ExecutionException) {
            val c = e.cause ?: e
            lastError = "${c.javaClass.simpleName}: ${c.message ?: ""}".trim()
            false
        } catch (e: Exception) {
            lastError = e.message ?: e.javaClass.simpleName
            false
        }
    }

    // ---------------------------------------------------------------- pairing

    /** idle / searching / found / pairing / done — progress of the pairing helper. */
    val pairState = MutableStateFlow("idle")
    /** Port of the "Pair device with pairing code" dialog while it is open (found via mDNS). */
    @Volatile var pairPort: Int? = null
        private set
    var onPairStateChanged: ((String) -> Unit)? = null
    @Volatile private var searchUntil = 0L
    @Volatile private var searchThread: Thread? = null

    private fun setPairState(s: String) {
        if (pairState.value != s) {
            app.simbridge.android.core.BridgeHub.log("pairing helper: $s${pairPort?.let { " (port $it)" } ?: ""}")
            pairState.value = s
            onPairStateChanged?.invoke(s)
        }
    }

    /**
     * Watches (for up to 10 minutes) for the pairing dialog to open, like Shizuku does: the moment the
     * user taps "Pair device with pairing code", its port appears over mDNS and a notification asks for
     * the 6-digit code.
     */
    fun startPairingSearch() {
        searchUntil = System.currentTimeMillis() + 10 * 60_000L
        if (pairState.value != "found" && pairState.value != "pairing") setPairState("searching")
        if (searchThread?.isAlive == true) return
        searchThread = Thread({
            val nsd = context.getSystemService(Context.NSD_SERVICE) as? NsdManager
            if (nsd == null) { setPairState("idle"); return@Thread }
            val listener = pairingListener(nsd)
            try {
                nsd.discoverServices("_adb-tls-pairing._tcp", NsdManager.PROTOCOL_DNS_SD, listener)
                while (System.currentTimeMillis() < searchUntil && pairState.value in ACTIVE) Thread.sleep(500)
            } catch (_: Exception) {
            } finally {
                try { nsd.stopServiceDiscovery(listener) } catch (_: Exception) {}
                if (pairState.value == "searching" || pairState.value == "found") { pairPort = null; setPairState("idle") }
            }
        }, "adb-pair-search").apply { isDaemon = true; start() }
    }

    fun stopPairingSearch() {
        searchUntil = 0
        if (pairState.value != "pairing") { pairPort = null; setPairState("idle") }
    }

    private fun pairingListener(nsd: NsdManager) = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(serviceType: String) {}
        override fun onDiscoveryStopped(serviceType: String) {}
        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
            app.simbridge.android.core.BridgeHub.log("pairing helper: mDNS failed ($errorCode)")
        }
        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
        override fun onServiceLost(info: NsdServiceInfo) {
            if (pairState.value == "found") { pairPort = null; setPairState("searching") }
        }
        override fun onServiceFound(info: NsdServiceInfo) { resolve(nsd, info, 0) }
    }

    @Suppress("DEPRECATION")
    private fun resolve(nsd: NsdManager, info: NsdServiceInfo, attempt: Int) {
        try {
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(i: NsdServiceInfo, errorCode: Int) {
                    // FAILURE_ALREADY_ACTIVE (3): another resolve is running — try again shortly.
                    if (attempt < 5) Thread { Thread.sleep(400); resolve(nsd, info, attempt + 1) }.start()
                }
                override fun onServiceResolved(i: NsdServiceInfo) {
                    if (!NetUtil.isOwnAddress(i.host)) return
                    pairPort = i.port
                    if (pairState.value == "searching") setPairState("found")
                }
            })
        } catch (_: Exception) {}
    }

    /**
     * Pairs using the 6-digit code from "Pair device with pairing code". [port] is the number after ":"
     * in that dialog; when null it is discovered via mDNS. Runs on a background thread; [done] gets an
     * error text or null.
     */
    fun pair(port: Int?, code: String, done: (String?) -> Unit) {
        worker.execute {
            lastError = ""
            setPairState("pairing")
            val p = port ?: pairPort ?: discover("_adb-tls-pairing._tcp", 5000)
            val err = if (p == null) {
                "Couldn't find the pairing dialog. Keep \"Pair device with pairing code\" open, or type the port shown after \":\" in that dialog."
            } else {
                val ok = hosts.any { h -> limited(15_000) { manager().pair(h, p, code) } }
                if (ok) {
                    prefs.edit().putBoolean("paired", true).apply()
                    setState("offline")
                    null
                } else {
                    "Pairing failed (port $p). Check the code — each code works once, and only while that dialog is open.\n$lastError"
                }
            }
            message.value = err
            if (err == null) searchUntil = 0
            pairPort = null
            setPairState(if (err == null) "done" else if (System.currentTimeMillis() < searchUntil) "searching" else "idle")
            if (err == null && !connectBlocking()) {
                message.value = "Paired ✓ but not connected yet. On the Wireless debugging screen, type the number after \":\" under \"IP address & Port\" into Connection port.\n$lastError"
            }
            done(err)
        }
    }

    // ---------------------------------------------------------------- connecting

    /** Connects in the background (no-op if already connected or connecting). */
    fun connectAsync() {
        if (!paired || connecting) return
        worker.execute { connectBlocking() }
    }

    /** Connects to a port typed by the user (Wireless debugging → "IP address & Port"). */
    fun connectToPort(port: Int, done: (Boolean) -> Unit) {
        worker.execute {
            lastError = ""
            setState("connecting")
            val ok = tryPort(port)
            if (ok) onConnected(port) else {
                setState("offline")
                message.value = "Couldn't connect to port $port.\n$lastError"
            }
            done(ok)
        }
    }

    @Synchronized
    fun connectBlocking(): Boolean {
        if (!paired) return false
        try { if (manager().isConnected) { setState("ready"); return true } } catch (_: Throwable) {}
        connecting = true
        setState("connecting")
        try {
            ensureWirelessDebuggingOn()
            val last = prefs.getInt("port", -1)
            if (last > 0 && tryPort(last)) return onConnected(last)
            repeat(3) { attempt ->
                discover("_adb-tls-connect._tcp", 4000)?.let { p -> if (p != last && tryPort(p)) return onConnected(p) }
                if (attempt < 2) Thread.sleep(2000)
            }
            setState("offline")
            message.value = "Couldn't reach Wireless debugging. Make sure Wi-Fi is connected and Wireless debugging is on, " +
                "or type the number after \":\" under \"IP address & Port\" into Connection port." +
                (if (lastError.isNotEmpty()) "\n$lastError" else "")
            return false
        } catch (e: Throwable) {
            Log.w(TAG, "connect", e)
            lastError = e.message ?: e.javaClass.simpleName
            setState("offline")
            return false
        } finally {
            connecting = false
        }
    }

    private fun tryPort(port: Int): Boolean {
        for (h in hosts) {
            if (limited(10_000) { manager().connect(h, port) }) return true
            try { manager().disconnect() } catch (_: Throwable) {}
            Log.i(TAG, "connect $h:$port failed: $lastError")
        }
        return false
    }

    private fun onConnected(port: Int): Boolean {
        prefs.edit().putInt("port", port).apply()
        message.value = null
        setState("ready")
        // Let the app re-enable Wireless debugging by itself after a reboot.
        if (!hasSecureSettings()) {
            try { runToEnd("pm grant ${context.packageName} android.permission.WRITE_SECURE_SETTINGS") } catch (_: Throwable) {}
        }
        return true
    }

    private fun hasSecureSettings() =
        context.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED

    /** With WRITE_SECURE_SETTINGS, switch Wireless debugging on (it goes off after a reboot). */
    private fun ensureWirelessDebuggingOn() {
        if (!hasSecureSettings() || Build.VERSION.SDK_INT < 30) return
        try {
            val r = context.contentResolver
            if (Settings.Global.getInt(r, "adb_wifi_enabled", 0) != 1) {
                Settings.Global.putInt(r, "adb_wifi_enabled", 1)
                Thread.sleep(2500) // adbd needs a moment to open its TLS port
            }
        } catch (e: Exception) {
            Log.w(TAG, "enable wireless debugging", e)
        }
    }

    fun forget() {
        try { manager().disconnect() } catch (_: Throwable) {}
        prefs.edit().clear().apply()
        message.value = null
        setState("unpaired")
    }

    // ---------------------------------------------------------------- shell

    fun exec(cmd: String): ShellProc {
        if (!ready && !connectBlocking()) throw IllegalStateException("adb_offline")
        val stream = manager().openStream("shell:$cmd")
        val input = stream.openInputStream()
        return object : ShellProc {
            override val input: InputStream = input
            override fun destroy() { try { stream.close() } catch (_: Throwable) {} }
        }
    }

    /** Runs a command and waits for it to finish (output discarded). */
    fun runToEnd(cmd: String, timeoutMs: Long = 10_000) {
        val p = exec(cmd)
        val t = Thread { try { p.input.readBytes() } catch (_: Throwable) {} }
        t.start()
        t.join(timeoutMs)
        p.destroy()
    }

    // ---------------------------------------------------------------- discovery

    private fun discover(type: String, timeoutMs: Long): Int? {
        val nsd = context.getSystemService(Context.NSD_SERVICE) as? NsdManager ?: return null
        val latch = CountDownLatch(1)
        var port: Int? = null
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { latch.countDown() }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceLost(info: NsdServiceInfo) {}
            @Suppress("DEPRECATION")
            override fun onServiceFound(info: NsdServiceInfo) {
                try {
                    nsd.resolveService(info, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(i: NsdServiceInfo, errorCode: Int) {}
                        override fun onServiceResolved(i: NsdServiceInfo) {
                            if (NetUtil.isOwnAddress(i.host) && port == null) { port = i.port; latch.countDown() }
                        }
                    })
                } catch (_: Exception) {}
            }
        }
        return try {
            nsd.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, listener)
            latch.await(timeoutMs, TimeUnit.MILLISECONDS)
            port
        } catch (e: Exception) {
            null
        } finally {
            try { nsd.stopServiceDiscovery(listener) } catch (_: Exception) {}
        }
    }

    companion object {
        private const val TAG = "BuiltInAdb"
        private val ACTIVE = setOf("searching", "found", "pairing")
    }
}
