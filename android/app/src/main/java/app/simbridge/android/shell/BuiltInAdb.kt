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
            lastError = "پاسخی نیامد (timeout)"
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

    /**
     * Pairs using the 6-digit code from "Pair device with pairing code". [port] is the number after ":"
     * in that dialog; when null it is discovered via mDNS. Runs on a background thread; [done] gets an
     * error text or null.
     */
    fun pair(port: Int?, code: String, done: (String?) -> Unit) {
        worker.execute {
            lastError = ""
            val p = port ?: discover("_adb-tls-pairing._tcp", 5000)
            val err = if (p == null) {
                "پورت جفت‌سازی پیدا نشد. در «وارد کردن دستی»، عدد بعد از «:» در پنجره «Pair device with pairing code» را هم وارد کنید."
            } else {
                val ok = hosts.any { h -> limited(15_000) { manager().pair(h, p, code) } }
                if (ok) {
                    prefs.edit().putBoolean("paired", true).apply()
                    setState("offline")
                    null
                } else {
                    "جفت‌سازی انجام نشد (پورت ${p}). کد را دوباره بررسی کنید؛ هر کد فقط یک بار و تا وقتی آن پنجره باز است معتبر است.\n$lastError"
                }
            }
            message.value = err
            if (err == null && !connectBlocking()) {
                message.value = "جفت شد ✓ ولی اتصال برقرار نشد. در صفحه «Wireless debugging»، عدد بعد از «:» در «IP address & Port» را در «پورت اتصال» وارد کنید.\n$lastError"
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
                message.value = "به پورت $port وصل نشد.\n$lastError"
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
            message.value = "به «اشکال‌زدایی بی‌سیم» وصل نشد. گوشی روی Wi-Fi باشد و این گزینه روشن باشد؛ " +
                "یا عدد بعد از «:» در «IP address & Port» را در «پورت اتصال» وارد کنید." +
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
                            val host = i.host?.hostAddress ?: ""
                            val mine = host.startsWith("127.") || host in NetUtil.localAddresses()
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

    companion object {
        private const val TAG = "BuiltInAdb"
    }
}
