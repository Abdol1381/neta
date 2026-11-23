package app.simbridge.android.telephony

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat

/** Permission groups the bridge needs, with Persian labels for the onboarding screen. */
object Perms {
    data class Group(val key: String, val title: String, val reason: String, val permissions: List<String>, val required: Boolean)

    val groups: List<Group> = buildList {
        add(Group("sms", "پیامک", "خواندن، دریافت و ارسال پیامک از طرف آیفون",
            listOf(Manifest.permission.READ_SMS, Manifest.permission.RECEIVE_SMS, Manifest.permission.SEND_SMS), true))
        add(Group("phone", "تماس و آنتن", "نمایش آنتن، تشخیص تماس، پاسخ، رد و شماره‌گیری",
            buildList {
                add(Manifest.permission.READ_PHONE_STATE)
                add(Manifest.permission.CALL_PHONE)
                add(Manifest.permission.ANSWER_PHONE_CALLS)
                add(Manifest.permission.READ_PHONE_NUMBERS)
            }, true))
        add(Group("callLog", "تاریخچه تماس", "نمایش شماره تماس‌گیرنده و تماس‌های اخیر روی آیفون",
            listOf(Manifest.permission.READ_CALL_LOG), true))
        add(Group("contacts", "مخاطبین", "نمایش نام افراد به‌جای شماره",
            listOf(Manifest.permission.READ_CONTACTS), false))
        if (Build.VERSION.SDK_INT >= 33) add(Group("notifications", "اعلان‌ها", "نمایش وضعیت سرویس و درخواست اتصال",
            listOf(Manifest.permission.POST_NOTIFICATIONS), false))
        if (Build.VERSION.SDK_INT >= 31) add(Group("bluetooth", "دستگاه‌های نزدیک (بلوتوث)", "بیدار کردن اپ آیفون در پس‌زمینه برای اعلان فوری",
            listOf(Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT), false))
    }

    fun granted(context: Context, p: String) =
        ContextCompat.checkSelfPermission(context, p) == PackageManager.PERMISSION_GRANTED

    fun groupGranted(context: Context, g: Group) = g.permissions.all { granted(context, it) }

    fun summary(context: Context): Map<String, Boolean> =
        groups.filter { it.key in setOf("sms", "phone", "callLog", "contacts") }
            .associate { it.key to groupGranted(context, it) }
}
