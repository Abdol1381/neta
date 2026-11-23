package app.simbridge.android.core

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import app.simbridge.android.R
import app.simbridge.android.receivers.PairingActionReceiver
import app.simbridge.android.ui.MainActivity

object Notifications {
    const val CH_SERVICE = "bridge"
    const val CH_PAIRING = "pairing"
    const val ID_SERVICE = 1
    const val ID_PAIRING = 2

    fun createChannels(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CH_SERVICE, "سرویس پل سیم‌کارت", NotificationManager.IMPORTANCE_LOW).apply {
                description = "وضعیت اتصال با آیفون"
                setShowBadge(false)
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_PAIRING, "درخواست اتصال", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "تأیید اتصال آیفون جدید"
            }
        )
    }

    fun openApp(context: Context): PendingIntent = PendingIntent.getActivity(
        context, 0, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    fun service(context: Context, text: String): Notification =
        NotificationCompat.Builder(context, CH_SERVICE)
            .setSmallIcon(R.drawable.ic_stat_bridge)
            .setContentTitle("SIMBridge فعال است")
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(openApp(context))
            .build()

    fun canPost(context: Context) =
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED ||
            android.os.Build.VERSION.SDK_INT < 33
}

object PairingNotifier {
    fun show(context: Context, req: PairRequest) {
        if (!Notifications.canPost(context)) return
        fun action(approve: Boolean) = PendingIntent.getBroadcast(
            context, if (approve) 11 else 12,
            Intent(context, PairingActionReceiver::class.java).putExtra(PairingActionReceiver.EXTRA_APPROVE, approve),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = NotificationCompat.Builder(context, Notifications.CH_PAIRING)
            .setSmallIcon(R.drawable.ic_stat_bridge)
            .setContentTitle("«⁨${req.name}⁩» می‌خواهد متصل شود")
            .setContentText("کد تأیید: ${req.code} — فقط اگر همین کد روی آیفون نمایش داده شده تأیید کنید.")
            .setStyle(NotificationCompat.BigTextStyle().bigText("کد تأیید: ${req.code}\nفقط اگر همین کد روی آیفون نمایش داده شده تأیید کنید."))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_RECOMMENDATION)
            .setAutoCancel(true)
            .setContentIntent(Notifications.openApp(context))
            .addAction(0, "تأیید", action(true))
            .addAction(0, "رد", action(false))
            .build()
        try { NotificationManagerCompat.from(context).notify(Notifications.ID_PAIRING, n) } catch (_: SecurityException) {}
    }

    fun cancel(context: Context) {
        NotificationManagerCompat.from(context).cancel(Notifications.ID_PAIRING)
    }
}
