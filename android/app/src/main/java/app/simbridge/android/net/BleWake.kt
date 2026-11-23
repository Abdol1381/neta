package app.simbridge.android.net

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import androidx.core.content.ContextCompat
import app.simbridge.android.core.BridgeHub
import app.simbridge.android.core.Crypto
import java.util.UUID
import java.util.concurrent.CopyOnWriteArraySet

/**
 * Bluetooth LE "doorbell" for the iPhone app. iOS lets an app with the bluetooth-central
 * background mode keep a BLE subscription while suspended and wakes it on each notification,
 * so a ring here makes the iPhone fetch new SMS / calls over Wi-Fi even when it is in the background.
 * No message content ever travels over BLE.
 */
@SuppressLint("MissingPermission")
class BleWake(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private var server: BluetoothGattServer? = null
    private var wakeChar: BluetoothGattCharacteristic? = null
    private val subscribers = CopyOnWriteArraySet<BluetoothDevice>()
    private var advertising = false
    private var counter: Byte = 0
    private var started = false

    private val stateReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            when (i.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1)) {
                BluetoothAdapter.STATE_ON -> main.postDelayed({ if (started) bringUp() }, 500)
                BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> tearDown()
            }
        }
    }

    fun start() {
        if (started) return
        started = true
        ContextCompat.registerReceiver(
            context, stateReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED
        )
        bringUp()
    }

    fun stop() {
        if (!started) return
        started = false
        try { context.unregisterReceiver(stateReceiver) } catch (_: Exception) {}
        tearDown()
    }

    fun wake() = main.post {
        val srv = server ?: return@post
        val ch = wakeChar ?: return@post
        counter++
        val value = byteArrayOf(counter)
        for (d in subscribers) {
            try {
                if (Build.VERSION.SDK_INT >= 33) {
                    srv.notifyCharacteristicChanged(d, ch, false, value)
                } else {
                    @Suppress("DEPRECATION")
                    ch.value = value
                    @Suppress("DEPRECATION")
                    srv.notifyCharacteristicChanged(d, ch, false)
                }
            } catch (e: Exception) {
                Log.w(TAG, "notify failed", e)
            }
        }
    }

    private fun hasPermission(): Boolean =
        Build.VERSION.SDK_INT < 31 || (
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
            )

    private fun bringUp() {
        if (server != null) return
        val adapter = manager?.adapter ?: return
        if (!hasPermission() || !adapter.isEnabled) return
        if (!adapter.isMultipleAdvertisementSupported) { Log.w(TAG, "BLE peripheral mode not supported"); return }
        try {
            val srv = manager.openGattServer(context, gattCallback) ?: return
            server = srv
            val ch = BluetoothGattCharacteristic(
                WAKE_CHAR,
                BluetoothGattCharacteristic.PROPERTY_NOTIFY or BluetoothGattCharacteristic.PROPERTY_READ,
                BluetoothGattCharacteristic.PERMISSION_READ,
            )
            ch.addDescriptor(
                BluetoothGattDescriptor(CCCD, BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE)
            )
            val idChar = BluetoothGattCharacteristic(
                ID_CHAR, BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ
            )
            val svc = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            svc.addCharacteristic(ch)
            svc.addCharacteristic(idChar)
            wakeChar = ch
            srv.addService(svc) // advertising starts in onServiceAdded
        } catch (e: Exception) {
            Log.w(TAG, "gatt server", e)
            tearDown()
        }
    }

    private fun startAdvertising() {
        val adv = manager?.adapter?.bluetoothLeAdvertiser ?: return
        if (advertising) return
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .setTimeout(0)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()
        try {
            adv.startAdvertising(settings, data, advertiseCallback)
            advertising = true
        } catch (e: Exception) {
            Log.w(TAG, "advertise", e)
        }
    }

    private fun stopAdvertising() {
        if (!advertising) return
        advertising = false
        try { manager?.adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback) } catch (_: Exception) {}
    }

    private fun tearDown() {
        stopAdvertising()
        try { server?.close() } catch (_: Exception) {}
        server = null
        wakeChar = null
        subscribers.clear()
        BridgeHub.bleActive.value = false
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            BridgeHub.bleActive.value = true
        }

        override fun onStartFailure(errorCode: Int) {
            Log.w(TAG, "advertise failed $errorCode")
            advertising = errorCode == ADVERTISE_FAILED_ALREADY_STARTED
            BridgeHub.bleActive.value = advertising
        }
    }

    private val gattCallback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            main.post { if (status == BluetoothGatt.GATT_SUCCESS) startAdvertising() }
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                subscribers.remove(device)
                // Some stacks stop advertising once a central connects; make sure we are discoverable again.
                main.postDelayed({ if (server != null) { stopAdvertising(); startAdvertising() } }, 300)
            }
        }

        override fun onCharacteristicReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, characteristic: BluetoothGattCharacteristic) {
            val full = if (characteristic.uuid == ID_CHAR) idBytes() else byteArrayOf(counter)
            val value = if (offset < full.size) full.copyOfRange(offset, full.size) else ByteArray(0)
            server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?,
        ) {
            if (descriptor.uuid == CCCD && value != null) {
                if (value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) ||
                    value.contentEquals(BluetoothGattDescriptor.ENABLE_INDICATION_VALUE)
                ) subscribers.add(device) else subscribers.remove(device)
            }
            if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
        }

        override fun onDescriptorReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, descriptor: BluetoothGattDescriptor) {
            val v = if (subscribers.contains(device)) BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            else BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
            server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, v)
        }
    }

    /** First 8 bytes of SHA-256(serverId): lets the iPhone recognise *its* Android phone. */
    private fun idBytes(): ByteArray = Crypto.sha256(BridgeHub.trust.serverId.toByteArray()).copyOf(8)

    companion object {
        private const val TAG = "BleWake"
        val SERVICE_UUID: UUID = UUID.fromString("5b1e0001-7a1c-4f5e-9d2a-51b8b1d6e0a1")
        val WAKE_CHAR: UUID = UUID.fromString("5b1e0002-7a1c-4f5e-9d2a-51b8b1d6e0a1")
        val ID_CHAR: UUID = UUID.fromString("5b1e0003-7a1c-4f5e-9d2a-51b8b1d6e0a1")
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
