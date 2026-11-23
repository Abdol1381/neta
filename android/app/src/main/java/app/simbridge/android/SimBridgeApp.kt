package app.simbridge.android

import android.app.Application
import app.simbridge.android.core.BridgeHub
import app.simbridge.android.core.Notifications

class SimBridgeApp : Application() {
    override fun onCreate() {
        super.onCreate()
        BridgeHub.init(this)
        Notifications.createChannels(this)
    }
}
