package app.simbridge.android.telephony

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import app.simbridge.android.shell.BuiltInAdb
import app.simbridge.android.shell.ShellProc
import kotlinx.coroutines.flow.MutableStateFlow
import rikka.shizuku.Shizuku
import java.io.File
import java.io.InputStream
import kotlin.random.Random

/**
 * "Listen on iPhone" (developer mode, no root). Shell privileges come from the built-in Wireless
 * debugging client ([BuiltInAdb], preferred) or from Shizuku. As the shell user, the bundled scrcpy
 * server (Apache-2.0) captures the call downlink — the other party's voice — as 48 kHz stereo
 * s16le, reduced here to 16 kHz mono s16le in 20 ms chunks (640 bytes) for the iPhone.
 *
 * Android offers no way to inject audio into the call uplink without root, so the user still
 * speaks to the Android phone (or a headset paired with it).
 */
class CallAudioRelay(private val context: Context) {
    /** ready / no_permission (Shizuku) / adb_offline / not_set_up / unsupported */
    val state = MutableStateFlow("not_set_up")
    val adb = BuiltInAdb(context)

    @Volatile private var process: ShellProc? = null
    @Volatile private var scid: String? = null
    private var installedVersion = -1L
    private val lock = Any()

    val running: Boolean get() = process != null

    /** A PIN / pattern / password lock: on Android 11 call audio can't start while locked. */
    val lockSecure: Boolean
        get() = Build.VERSION.SDK_INT == 30 &&
            (context.getSystemService(android.app.KeyguardManager::class.java)?.isDeviceSecure == true)

    var onStateChanged: (() -> Unit)? = null

    private val binderListener = Shizuku.OnBinderReceivedListener { refresh() }
    private val deadListener = Shizuku.OnBinderDeadListener { refresh() }
    private val permListener = Shizuku.OnRequestPermissionResultListener { _, _ -> refresh() }

    fun init() {
        try {
            Shizuku.addBinderReceivedListenerSticky(binderListener)
            Shizuku.addBinderDeadListener(deadListener)
            Shizuku.addRequestPermissionResultListener(permListener)
        } catch (e: Throwable) {
            Log.w(TAG, "shizuku listeners", e)
        }
        adb.onStateChanged = { refresh() }
        refresh()
        adb.connectAsync()
    }

    fun refresh() {
        val s = computeState()
        if (s != state.value) {
            state.value = s
            onStateChanged?.invoke()
        }
    }

    private fun shizukuAlive() = try { Shizuku.pingBinder() } catch (e: Throwable) { false }

    private fun shizukuReady(): Boolean = shizukuAlive() &&
        !(try { Shizuku.isPreV11() } catch (e: Throwable) { true }) &&
        (try { Shizuku.checkSelfPermission() } catch (e: Throwable) { -1 }) == PackageManager.PERMISSION_GRANTED

    private fun computeState(): String = when {
        Build.VERSION.SDK_INT < 30 -> "unsupported"
        adb.state.value == "ready" -> "ready"
        shizukuReady() -> "ready"
        shizukuAlive() -> "no_permission"
        adb.paired -> "adb_offline"
        else -> "not_set_up"
    }

    fun requestShizukuPermission() {
        try {
            if (shizukuAlive() && Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
                Shizuku.requestPermission(REQUEST_CODE)
            }
        } catch (e: Throwable) {
            Log.w(TAG, "request permission", e)
        }
    }

    /** Runs a shell command as the shell user: built-in Wireless debugging first, then Shizuku. */
    private fun exec(cmd: String): ShellProc {
        if (adb.paired && (adb.ready || adb.connectBlocking())) return adb.exec(cmd)
        if (shizukuReady()) {
            val m = Shizuku::class.java.getDeclaredMethod(
                "newProcess", Array<String>::class.java, Array<String>::class.java, String::class.java,
            )
            m.isAccessible = true
            val p = m.invoke(null, arrayOf("sh", "-c", cmd), null, null) as Process
            return object : ShellProc {
                override val input: InputStream = p.inputStream
                override fun destroy() { try { p.destroy() } catch (_: Throwable) {} }
            }
        }
        throw IllegalStateException(state.value)
    }

    private fun runToEnd(cmd: String) {
        val p = exec(cmd)
        val t = Thread { try { p.input.readBytes() } catch (_: Throwable) {} }
        t.start()
        t.join(15_000)
        p.destroy()
    }

    /** Copies the scrcpy server to /data/local/tmp (shell can read the app's external files dir). */
    private fun installServer() {
        val version = try {
            context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime
        } catch (e: Exception) { 0L }
        if (version == installedVersion) return
        val dir = context.getExternalFilesDir(null) ?: throw IllegalStateException("no external files dir")
        val src = File(dir, "scrcpy-server.jar")
        context.assets.open("scrcpy-server.jar").use { input -> src.outputStream().use { input.copyTo(it) } }
        runToEnd("cp '${src.absolutePath}' $JAR && chmod 644 $JAR")
        installedVersion = version
    }

    /**
     * Starts streaming. [onPcm] gets 640-byte chunks (20 ms, 16 kHz mono s16le) on a background
     * thread; [onEnd] is called once when streaming stops (null reason = stopped on request).
     */
    fun start(onPcm: (ByteArray) -> Unit, onEnd: (String?) -> Unit) {
        synchronized(lock) {
            if (process != null) return
            refresh()
            if (state.value != "ready") throw IllegalStateException(state.value)
            installServer()
            val id = "%08x".format(Random.nextInt(0x10000000, 0x7fffffff))
            app.simbridge.android.core.BridgeHub.log("call audio start (adb=${adb.state.value}, lockSecure=$lockSecure)")
            val p = exec(shellScript(id, context.applicationInfo.sourceDir))
            process = p
            scid = id
            Thread({ pump(p, onPcm, onEnd) }, "call-audio").start()
        }
    }

    private fun pump(p: ShellProc, onPcm: (ByteArray) -> Unit, onEnd: (String?) -> Unit) {
        var bytes = 0L
        val mixer = Downmixer { chunk -> bytes += chunk.size; onPcm(chunk) }
        val buf = ByteArray(7680)
        var reason: String? = "ended"
        try {
            while (true) {
                val n = p.input.read(buf, 0, buf.size)
                if (n <= 0) break
                mixer.feed(buf, n)
            }
        } catch (e: Exception) {
            reason = "error"
        }
        val stoppedOnRequest = synchronized(lock) {
            val requested = process !== p
            if (process === p) { process = null; scid = null }
            requested
        }
        p.destroy()
        app.simbridge.android.core.BridgeHub.log("call audio ended: ${if (stoppedOnRequest) "stopped" else reason} after ${bytes / 640 / 50}s")
        onEnd(if (stoppedOnRequest) null else reason)
    }

    fun stop(reason: String? = null) {
        val (p, id) = synchronized(lock) {
            val pair = process to scid
            process = null
            scid = null
            pair
        }
        if (p == null) return
        p.destroy()
        if (id != null) {
            // Make sure the background scrcpy server is gone too.
            Thread { try { runToEnd("pkill -f 'scid=$id'; true") } catch (_: Exception) {} }.start()
        }
        Log.i(TAG, "stopped ${reason ?: ""}")
    }

    /** 48 kHz stereo s16le -> 16 kHz mono s16le: average L/R, then average every 3 frames. */
    class Downmixer(private val onPcm: (ByteArray) -> Unit) {
        private val carry = ByteArray(12)
        private var carryLen = 0
        private val out = ByteArray(OUT_CHUNK)
        private var outLen = 0

        fun feed(buf: ByteArray, n: Int) {
            var i = 0
            while (i < n) {
                val take = minOf(12 - carryLen, n - i)
                System.arraycopy(buf, i, carry, carryLen, take)
                carryLen += take
                i += take
                if (carryLen < 12) continue
                var sum = 0
                var k = 0
                while (k < 12) {
                    sum += ((carry[k].toInt() and 0xff) or (carry[k + 1].toInt() shl 8)).toShort().toInt()
                    k += 2
                }
                val v = (sum / 6).coerceIn(-32768, 32767)
                out[outLen++] = (v and 0xff).toByte()
                out[outLen++] = ((v shr 8) and 0xff).toByte()
                carryLen = 0
                if (outLen == OUT_CHUNK) {
                    onPcm(out.copyOf())
                    outLen = 0
                }
            }
        }
    }

    companion object {
        private const val TAG = "CallAudio"
        const val SCRCPY_VERSION = "3.3.4"
        const val JAR = "/data/local/tmp/simbridge-scrcpy.jar"
        private const val REQUEST_CODE = 4711
        const val OUT_CHUNK = 640

        /** The shell script that runs as the shell user. Also used verbatim by the emulator test. */
        fun shellScript(id: String, apkPath: String): String = buildString {
            // Android 11 only captures audio when the screen is unlocked at start: wake it and dismiss a
            // swipe / none lock screen (a PIN/pattern lock cannot be dismissed — the app warns about it).
            append("input keyevent KEYCODE_WAKEUP 2>/dev/null; wm dismiss-keyguard 2>/dev/null; sleep 0.7\n")
            append("CLASSPATH=$JAR app_process / com.genymobile.scrcpy.Server $SCRCPY_VERSION scid=$id ")
            append("log_level=warn video=false audio=true control=false audio_source=voice-call-downlink ")
            append("audio_codec=raw tunnel_forward=true raw_stream=true cleanup=false ")
            append("</dev/null >/dev/null 2>/data/local/tmp/simbridge-audio.log &\n")
            append("SRV=\$!\n")
            append("trap 'kill \$SRV 2>/dev/null' EXIT INT TERM HUP\n")
            append("CLASSPATH=$apkPath app_process / app.simbridge.android.shell.SocketCat scrcpy_$id\n")
        }
    }
}
