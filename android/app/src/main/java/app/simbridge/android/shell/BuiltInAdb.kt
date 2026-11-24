package app.simbridge.android.shell

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.provider.Settings
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** A running shell command: stdout plus a way to stop it. */
interface ShellProc {
    val input: InputStream
    fun destroy()
}

/**
 * Built-in replacement for Shizuku: pairs with and connects to the phone's own Wireless debugging
 * (adbd over TLS on 127.0.0.1) and runs shell commands with ADB privileges.
 *
 * Robust port finding: mDNS discovery first, then a quick scan of the phone's own local ports (works
 * where mDNS discovery fails). After the first connection the app grants itself
 * WRITE_SECURE_SETTINGS, so after a reboot it can switch Wireless debugging back on and reconnect
 * without the user doing anything.
 */
class BuiltInAdb(private val context: Context) {
    /** unpaired / connecting / offline / ready */
    val state = MutableStateFlow(if (paired) "offline" else "unpaired")
    var onStateChanged: (() -> Unit)? = null
    /** Last problem to show in the setup dialog (null = none). */
    val message = MutableStateFlow<String?>(null)
    private val prefs = context.getSharedPreferences("adb", Context.MODE_PRIVATE)
    private val worker = Executors.newSingleThreadExecutor()
    @Volatile private var connecting = false

    val paired: Boolean get() = context.getSharedPreferences("adb", Context.MODE_PRIVATE).getBoolean("paired", false)

    private fun manager() = AdbManager.get(context)

    private fun setState(s: String) {
        if (state.value != s) {
            state.value = s
            onStateChanged?.invoke()
        }
    }

    val ready: Boolean get() = try { state.value == "ready" && manager().isConnected } catch (e: Throwable) { false }

    // ---------------------------------------------------------------- pairing

    /**
     * Pairs using the 6-digit code from "Pair device with pairing code". [port] may be null: it is then
     * discovered (mDNS, then local port scan). Runs on a background thread; [done] gets an error text or null.
     */
    fun pair(port: Int?, code: String, done: (String?) -> Unit) {
        worker.execute {
            val err = try {
                val candidates = if (port != null) listOf(port) else pairingPortCandidates()
                if (candidates.isEmpty()) {
                    "پورت جفت‌سازی پیدا نشد. پنجره «Pair device with pairing code» باید باز باشد."
                } else {
                    var ok = false
                    for (p in candidates) {
                        ok = try { manager().pair("127.0.0.1", p, code) } catch (e: Exception) {
                            Log.w(TAG, "pair on $p failed: ${e.message}")
                            false
                        }
                        if (ok) break
                    }
                    if (!ok) "جفت‌سازی انجام نشد. کد را دوباره بررسی کنید (هر کد فقط یک بار و برای مدت کوتاهی معتبر است)." else {
                        prefs.edit().putBoolean("paired", true).apply()
                        setState("offline")
                        null
                    }
                }
            } catch (e: Throwable) {
                Log.w(TAG, "pair", e)
                "خطا در جفت‌سازی: ${e.message}"
            }
            message.value = err
            if (err == null && !connectBlocking()) {
                message.value = "جفت شد، ولی اتصال برقرار نشد. «اشکال‌زدایی بی‌سیم» روشن بماند؛ دوباره تلاش می‌شود."
            }
            done(err)
        }
    }

    private fun pairingPortCandidates(): List<Int> {
        val found = discover("_adb-tls-pairing._tcp", 4000)
        if (found != null) return listOf(found)
        val connectPort = prefs.getInt("port", -1)
        return scanLocalPorts().filter { it != connectPort && it != SELF_PORT }
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
            val ok = tryPort(port)
            if (ok) onConnected(port) else setState("offline")
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
            // 1) last known port, 2) mDNS, 3) local port scan (adbd may need a few seconds after enabling)
            val last = prefs.getInt("port", -1)
            if (last > 0 && tryPort(last)) return onConnected(last)
            repeat(3) { attempt ->
                discover("_adb-tls-connect._tcp", 3000)?.let { p -> if (tryPort(p)) return onConnected(p) }
                for (p in scanLocalPorts()) {
                    if (p != last && tryPort(p)) return onConnected(p)
                }
                if (attempt < 2) Thread.sleep(2500)
            }
            setState("offline")
            message.value = "به «اشکال‌زدایی بی‌سیم» وصل نشد. گوشی روی Wi-Fi باشد و این گزینه روشن باشد."
            return false
        } catch (e: Throwable) {
            Log.w(TAG, "connect", e)
            setState("offline")
            return false
        } finally {
            connecting = false
        }
    }

    private fun tryPort(port: Int): Boolean = try {
        manager().connect("127.0.0.1", port)
    } catch (e: Throwable) {
        Log.i(TAG, "port $port: ${e.message}")
        try { manager().disconnect() } catch (_: Throwable) {}
        false
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
                            val host = i.host?.hostAddress ?: ""
                            val mine = host.startsWith("127.") || host in app.simbridge.android.net.NetUtil.localAddresses()
                            if (mine && port == null) { port = i.port; latch.countDown() }
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

    /** Open TCP ports on 127.0.0.1 in the range adbd picks from (fast: closed ports refuse instantly). */
    private fun scanLocalPorts(): List<Int> {
        val open = java.util.Collections.synchronizedList(mutableListOf<Int>())
        val next = AtomicInteger(30000)
        val pool = Executors.newFixedThreadPool(64)
        repeat(64) {
            pool.execute {
                while (true) {
                    val p = next.getAndIncrement()
                    if (p > 60999) break
                    if (p == SELF_PORT) continue
                    try {
                        Socket().use { s -> s.connect(InetSocketAddress("127.0.0.1", p), 150) }
                        open += p
                    } catch (_: Exception) {}
                }
            }
        }
        pool.shutdown()
        pool.awaitTermination(25, TimeUnit.SECONDS)
        return open.sorted()
    }

    companion object {
        private const val TAG = "BuiltInAdb"
        private const val SELF_PORT = 8765
    }
}
