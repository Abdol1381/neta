package app.simbridge.android.receivers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import app.simbridge.android.core.BridgeHub
import app.simbridge.android.service.BridgeService

class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val msgs = try { Telephony.Sms.Intents.getMessagesFromIntent(intent) } catch (e: Exception) { null } ?: return
        if (msgs.isEmpty()) return
        val subId = intent.getIntExtra("android.telephony.extra.SUBSCRIPTION_INDEX", intent.getIntExtra("subscription", -1))
        // A long SMS arrives as several PDUs; group them per sender.
        msgs.filterNotNull().groupBy { it.displayOriginatingAddress ?: it.originatingAddress ?: "" }
            .forEach { (address, parts) ->
                val body = parts.joinToString("") { it.displayMessageBody ?: it.messageBody ?: "" }
                val listener = BridgeHub.incomingSms
                if (listener != null) listener(address, body, subId)
            }
        if (BridgeHub.incomingSms == null && BridgeService.isEnabled(context)) BridgeService.start(context)
    }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            if (BridgeService.isEnabled(context)) BridgeService.start(context)
        }
    }
}

class PairingActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        BridgeHub.resolvePairing(intent.getBooleanExtra(EXTRA_APPROVE, false))
    }

    companion object { const val EXTRA_APPROVE = "approve" }
}
