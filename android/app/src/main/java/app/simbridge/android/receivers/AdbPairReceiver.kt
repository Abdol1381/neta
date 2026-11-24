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
 * Pairing with Wireless debugging without leaving the Settings screen (the same approach as Shizuku):
 * while the helper is looking for the pairing dialog a quiet notification says so; the moment
 * "Pair device with pairing code" opens, a heads-up notification asks for the 6-digit code, which the
 * user types straight into the notification.
 */
object AdbPairNotifier {
    private const val CH_ASK = "adb_pair"
    private const val CH_STATUS = "adb_pair_status"
    private const val ID = 7
    const val KEY = "code"

    private fun channels(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CH_ASK, "Pairing code", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Asks for the Wireless debugging pairing code"
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_STATUS, "Pairing progress", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shows while SIMBridge waits for the pairing dialog"
                setShowBadge(false)
            }
        )
    }

    fun enabled(context: Context): Boolean {
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return false
        val ch = context.getSystemService(NotificationManager::class.java).getNotificationChannel(CH_ASK)
        return ch == null || ch.importance != NotificationManager.IMPORTANCE_NONE
    }

    private fun codeAction(context: Context): NotificationCompat.Action {
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
        val reply = PendingIntent.getBroadcast(context, 21, Intent(context, AdbPairReceiver::class.java), flags)
        val input = RemoteInput.Builder(KEY).setLabel("6-digit pairing code").build()
        return NotificationCompat.Action.Builder(0, "Enter code", reply).addRemoteInput(input).build()
    }

    private fun cancelAction(context: Context): NotificationCompat.Action {
        val pi = PendingIntent.getBroadcast(
            context, 22, Intent(context, AdbPairReceiver::class.java).setAction(ACTION_CANCEL),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Action.Builder(0, "Cancel", pi).build()
    }

    /** Starts the helper: looks for the pairing dialog and keeps the notification up to date. */
    fun start(context: Context) {
        BridgeHub.audio.adb.startPairingSearch()
        onState(context, BridgeHub.audio.adb.pairState.value)
    }

    /** Called whenever the helper's state changes. */
    fun onState(context: Context, state: String) {
        channels(context)
        when (state) {
            "searching" -> post(
                context,
                NotificationCompat.Builder(context, CH_STATUS)
                    .setSmallIcon(R.drawable.ic_stat_bridge)
                    .setContentTitle("Waiting for the pairing dialog")
                    .setContentText("Wireless debugging → Pair device with pairing code")
                    .setStyle(NotificationCompat.BigTextStyle().bigText(
                        "Open Developer options → Wireless debugging and tap \"Pair device with pairing code\". " +
                            "This notification will then ask for the 6-digit code."
                    ))
                    .setOngoing(true)
                    .setOnlyAlertOnce(true)
                    .setProgress(0, 0, true)
                    .addAction(codeAction(context))
                    .addAction(cancelAction(context))
            )
            "found" -> post(
                context,
                NotificationCompat.Builder(context, CH_ASK)
                    .setSmallIcon(R.drawable.ic_stat_bridge)
                    .setContentTitle("Enter the pairing code")
                    .setContentText("Tap \"Enter code\" and type the 6 digits shown in the dialog.")
                    .setPriority(NotificationCompat.PRIORITY_HIGH)
                    .setCategory(NotificationCompat.CATEGORY_CALL)
                    .setOngoing(true)
                    .addAction(codeAction(context))
                    .addAction(cancelAction(context))
            )
            "pairing" -> status(context, "Pairing and connecting…", done = false)
            "done" -> status(
                context,
                if (BridgeHub.audio.adb.state.value == "ready") "✓ Ready. The other caller's voice will play on the iPhone."
                else "Paired ✓ Keep Wireless debugging on; SIMBridge connects by itself.",
                done = true,
            )
            else -> cancel(context)
        }
    }

    fun status(context: Context, text: String, done: Boolean, retry: Boolean = false) {
        channels(context)
        val b = NotificationCompat.Builder(context, CH_STATUS)
            .setSmallIcon(R.drawable.ic_stat_bridge)
            .setContentTitle("SIMBridge pairing")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setOngoing(!done)
            .setAutoCancel(done)
        if (!done) b.setProgress(0, 0, true)
        if (retry) b.addAction(codeAction(context)).addAction(cancelAction(context))
        post(context, b)
    }

    fun cancel(context: Context) {
        try { NotificationManagerCompat.from(context).cancel(ID) } catch (_: Exception) {}
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

    const val ACTION_CANCEL = "app.simbridge.android.ADB_PAIR_CANCEL"
}

class AdbPairReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val adb = BridgeHub.audio.adb
        if (intent.action == AdbPairNotifier.ACTION_CANCEL) {
            adb.stopPairingSearch()
            AdbPairNotifier.cancel(context)
            return
        }
        val text = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(AdbPairNotifier.KEY)?.toString() ?: return
        val parsed = AdbPairNotifier.parse(text)
        if (parsed == null) {
            AdbPairNotifier.status(context, "That wasn't a 6-digit code. Tap \"Pair device with pairing code\" again.", done = true)
            AdbPairNotifier.start(context)
            return
        }
        val app = context.applicationContext
        adb.pair(parsed.first, parsed.second) { err ->
            // On failure keep the code field in the notification so the user can simply try again.
            if (err != null) AdbPairNotifier.status(app, err, done = true, retry = true)
            BridgeHub.audio.refresh()
        }
    }
}
