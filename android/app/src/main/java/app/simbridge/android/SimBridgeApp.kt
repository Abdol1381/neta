package app.simbridge.android

import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.core.content.ContextCompat
import app.simbridge.android.core.BridgeHub
import app.simbridge.android.core.Notifications
import app.simbridge.android.service.BridgeService

class SimBridgeApp : Application() {
    override fun onCreate() {
        super.onCreate()
        BridgeHub.init(this)
        Notifications.createChannels(this)
        if (BuildConfig.DEBUG) registerTestHooks()
    }

    /**
     * Debug builds only: lets the automated end-to-end test (adb shell am broadcast) start the
     * bridge, open a pairing window and approve a pairing request. Never compiled into release logic.
     */
    private fun registerTestHooks() {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                when (i.action) {
                    ACTION_TEST_START -> BridgeService.start(c)
                    ACTION_TEST_PAIR -> BridgeHub.startPairing()
                    ACTION_TEST_APPROVE -> BridgeHub.resolvePairing(i.getBooleanExtra("approve", true))
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(ACTION_TEST_START); addAction(ACTION_TEST_PAIR); addAction(ACTION_TEST_APPROVE)
        }
        ContextCompat.registerReceiver(this, receiver, filter, ContextCompat.RECEIVER_EXPORTED)
    }

    companion object {
        private const val ACTION_TEST_START = "app.simbridge.android.TEST_START"
        private const val ACTION_TEST_PAIR = "app.simbridge.android.TEST_PAIR"
        private const val ACTION_TEST_APPROVE = "app.simbridge.android.TEST_APPROVE"
    }
}
