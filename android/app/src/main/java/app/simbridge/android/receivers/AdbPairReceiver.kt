package app.simbridge.android.receivers

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import app.simbridge.android.R
import app.simbridge.android.core.BridgeHub

/**
 * Pairing with Wireless debugging without leaving the Settings screen: the user opens
 * "Pair device with pairing code", pulls down this notification and types the 6-digit code
 * (optionally followed by the port shown under it, e.g. "482913 37125").
 */
object AdbPairNotifier {
    private const val CHANNEL = "adb_pair"
    private const val ID = 7
    const val KEY = "code"

    private fun channel(context: Context) {
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "جفت‌سازی اشکال‌زدایی بی‌سیم", NotificationManager.IMPORTANCE_HIGH)
        )
    }

    fun show(context: Context) {
        channel(context)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
        val reply = PendingIntent.getBroadcast(context, 21, Intent(context, AdbPairReceiver::class.java), flags)
        val input = RemoteInput.Builder(KEY).setLabel("کد ۶ رقمی (و پورت)").build()
        val action = NotificationCompat.Action.Builder(0, "وارد کردن کد", reply).addRemoteInput(input).build()
        post(
            context,
            NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_bridge)
                .setContentTitle("جفت‌سازی SIMBridge")
                .setContentText("در «Pair device with pairing code» کد ۶ رقمی را ببینید و اینجا وارد کنید.")
                .setStyle(NotificationCompat.BigTextStyle().bigText(
                    "۱. در گزینه‌های توسعه‌دهنده ← اشکال‌زدایی بی‌سیم، «Pair device with pairing code» را بزنید.\n" +
                        "۲. این اعلان را پایین بکشید، «وارد کردن کد» را بزنید و کد ۶ رقمی را بنویسید."
                ))
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setOngoing(true)
                .addAction(action)
        )
    }

    fun status(context: Context, text: String, done: Boolean) {
        channel(context)
        val b = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_bridge)
            .setContentTitle("جفت‌سازی SIMBridge")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setOngoing(!done)
            .setAutoCancel(done)
        if (!done) b.setProgress(0, 0, true)
        post(context, b)
    }

    private fun post(context: Context, b: NotificationCompat.Builder) {
        try { NotificationManagerCompat.from(context).notify(ID, b.build()) } catch (_: SecurityException) {}
    }

    /** "482913", "482913 37125", "192.168.1.5:37125 482913", Persian digits — returns (port?, code). */
    fun parse(raw: String): Pair<Int?, String>? {
        val ascii = raw.map { c ->
            when (c) {
                in '۰'..'۹' -> '0' + (c - '۰')
                in '٠'..'٩' -> '0' + (c - '٠')
                else -> c
            }
        }.joinToString("")
        val groups = Regex("\\d+").findAll(ascii).map { it.value }.toList()
        val code = groups.lastOrNull { it.length == 6 } ?: return null
        val portAfterColon = Regex(":(\\d{4,5})").find(ascii)?.groupValues?.get(1)
        val port = (portAfterColon ?: groups.firstOrNull { it != code && it.length in 4..5 })
            ?.toIntOrNull()?.takeIf { it in 1024..65535 }
        return port to code
    }
}

class AdbPairReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val text = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(AdbPairNotifier.KEY)?.toString() ?: return
        val parsed = AdbPairNotifier.parse(text)
        if (parsed == null) {
            AdbPairNotifier.status(context, "کد ۶ رقمی پیدا نشد. دوباره «Pair device with pairing code» را بزنید.", done = true)
            AdbPairNotifier.show(context)
            return
        }
        AdbPairNotifier.status(context, "در حال جفت‌سازی و اتصال…", done = false)
        val app = context.applicationContext
        BridgeHub.audio.adb.pair(parsed.first, parsed.second) { err ->
            AdbPairNotifier.status(
                app,
                err ?: if (BridgeHub.audio.adb.state.value == "ready") "✓ آماده است. صدای تماس روی آیفون پخش می‌شود." else
                    "جفت شد. برای اتصال، «اشکال‌زدایی بی‌سیم» روشن بماند.",
                done = true,
            )
            BridgeHub.audio.refresh()
        }
    }
}
