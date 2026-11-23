package app.simbridge.android.telephony

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import rikka.shizuku.Shizuku
import java.io.InputStream
import kotlin.random.Random

/**
 * "Listen on iPhone" (developer mode). With Shizuku running (ADB / wireless-debugging privileges,
 * no root) the bundled scrcpy server captures the call downlink — the other party's voice — as the
 * shell user. Audio arrives as 48 kHz stereo s16le and is reduced here to 16 kHz mono s16le in
 * 20 ms chunks (640 bytes) before going to the iPhone.
 *
 * Android offers no way to inject audio into the call uplink without root, so the user still
 * speaks to the Android phone (or a headset paired with it).
 */
class CallAudioRelay(private val context: Context) {
    /** unsupported / no_shizuku / no_permission / ready */
    val state = MutableStateFlow("no_shizuku")

    @Volatile private var process: Process? = null
    @Volatile private var scid: String? = null
    private var installedVersion = -1L
    private val lock = Any()

    val running: Boolean get() = process != null

    var onStateChanged: (() -> Unit)? = null

    private val binderListener = Shizuku.OnBinderReceivedListener { refresh() }
    private val deadListener = Shizuku.OnBinderDeadListener { refresh(); stop("shizuku_stopped") }
    private val permListener = Shizuku.OnRequestPermissionResultListener { _, _ -> refresh() }

    fun init() {
        try {
            Shizuku.addBinderReceivedListenerSticky(binderListener)
            Shizuku.addBinderDeadListener(deadListener)
            Shizuku.addRequestPermissionResultListener(permListener)
        } catch (e: Throwable) {
            Log.w(TAG, "shizuku listeners", e)
        }
        refresh()
    }

    fun refresh() {
        val s = computeState()
        if (s != state.value) {
            state.value = s
            onStateChanged?.invoke()
        }
    }

    private fun binderAlive() = try { Shizuku.pingBinder() } catch (e: Throwable) { false }

    private fun computeState(): String = when {
        Build.VERSION.SDK_INT < 30 -> "unsupported"
        !binderAlive() -> "no_shizuku"
        try { Shizuku.isPreV11() } catch (e: Throwable) { true } -> "unsupported"
        (try { Shizuku.checkSelfPermission() } catch (e: Throwable) { -1 }) != PackageManager.PERMISSION_GRANTED -> "no_permission"
        else -> "ready"
    }

    fun requestPermission() {
        try {
            if (binderAlive() && Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
                Shizuku.requestPermission(REQUEST_CODE)
            }
        } catch (e: Throwable) {
            Log.w(TAG, "request permission", e)
        }
    }

    /** Runs a shell command as the shell user through Shizuku. */
    private fun exec(cmd: String): Process {
        val m = Shizuku::class.java.getDeclaredMethod(
            "newProcess", Array<String>::class.java, Array<String>::class.java, String::class.java,
        )
        m.isAccessible = true
        return m.invoke(null, arrayOf("sh", "-c", cmd), null, null) as Process
    }

    private fun installServer() {
        val version = try {
            context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime
        } catch (e: Exception) { 0L }
        if (version == installedVersion) return
        val p = exec("cat > $JAR && chmod 644 $JAR")
        p.outputStream.use { out -> context.assets.open("scrcpy-server.jar").use { it.copyTo(out) } }
        if (p.waitFor() != 0) throw IllegalStateException("install failed")
        installedVersion = version
    }

    /**
     * Starts streaming. [onPcm] gets 640-byte chunks (20 ms, 16 kHz mono s16le) on a background
     * thread; [onEnd] is called once when streaming stops (null reason = stopped on request).
     */
    fun start(onPcm: (ByteArray) -> Unit, onEnd: (String?) -> Unit) {
        synchronized(lock) {
            if (process != null) return
            if (state.value != "ready") throw IllegalStateException(state.value)
            installServer()
            val id = "%08x".format(Random.nextInt(0x10000000, 0x7fffffff))
            val p = exec(shellScript(id, context.applicationInfo.sourceDir))
            process = p
            scid = id
            Thread({ pump(p, p.inputStream, onPcm, onEnd) }, "call-audio").start()
        }
    }

    private fun pump(p: Process, input: InputStream, onPcm: (ByteArray) -> Unit, onEnd: (String?) -> Unit) {
        val reader = Downmixer(onPcm)
        val inBuf = ByteArray(7680)
        var reason: String? = "ended"
        try {
            while (true) {
                val n = input.read(inBuf, 0, inBuf.size)
                if (n <= 0) break
                reader.feed(inBuf, n)
            }
        } catch (e: Exception) {
            reason = "error"
        }
        val stoppedOnRequest = synchronized(lock) {
            val requested = process !== p
            if (process === p) { process = null; scid = null }
            requested
        }
        try { p.destroy() } catch (_: Exception) {}
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
        try { p.destroy() } catch (_: Exception) {}
        if (id != null) {
            // Make sure the background scrcpy server is gone too.
            Thread {
                try { exec("pkill -f 'scid=$id' 2>/dev/null; true").waitFor() } catch (_: Exception) {}
            }.start()
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
