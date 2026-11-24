package app.simbridge.android.ui

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.BatteryAlert
import androidx.compose.material.icons.outlined.Bluetooth
import androidx.compose.material.icons.outlined.BluetoothDisabled
import androidx.compose.material.icons.outlined.Call
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Contacts
import androidx.compose.material.icons.outlined.Hearing
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.LinkOff
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.PhoneIphone
import androidx.compose.material.icons.outlined.PowerSettingsNew
import androidx.compose.material.icons.outlined.QrCode2
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material.icons.outlined.Sms
import androidx.compose.material.icons.outlined.Wifi
import androidx.compose.material.icons.outlined.WifiOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.simbridge.android.core.BridgeHub
import app.simbridge.android.core.SimState
import app.simbridge.android.net.NetUtil
import app.simbridge.android.receivers.AdbPairNotifier
import app.simbridge.android.service.BridgeService
import app.simbridge.android.telephony.Perms
import kotlinx.coroutines.delay

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            SimBridgeTheme {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    HomeScreen()
                }
            }
        }
    }
}

@Composable
private fun rememberResumeTick(): Int {
    var tick by remember { mutableIntStateOf(0) }
    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner) {
        val obs = LifecycleEventObserver { _, e -> if (e == Lifecycle.Event.ON_RESUME) tick++ }
        owner.lifecycle.addObserver(obs)
        onDispose { owner.lifecycle.removeObserver(obs) }
    }
    return tick
}

private fun permIcon(key: String): ImageVector = when (key) {
    "sms" -> Icons.Outlined.Sms
    "phone" -> Icons.Outlined.Call
    "callLog" -> Icons.Outlined.History
    "contacts" -> Icons.Outlined.Contacts
    "notifications" -> Icons.Outlined.Notifications
    else -> Icons.Outlined.Bluetooth
}

private fun Context.open(intent: Intent, fallback: Intent? = null) {
    try {
        startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    } catch (_: Exception) {
        if (fallback != null) try { startActivity(fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } catch (_: Exception) {}
    }
}

@SuppressLint("BatteryLife")
@Composable
fun HomeScreen() {
    val ctx = LocalContext.current
    val running by BridgeHub.serviceRunning.collectAsStateWithLifecycle()
    val status by BridgeHub.status.collectAsStateWithLifecycle()
    val clients by BridgeHub.clients.collectAsStateWithLifecycle()
    val devices by BridgeHub.devices.collectAsStateWithLifecycle()
    val pending by BridgeHub.pendingApproval.collectAsStateWithLifecycle()
    val pairing by BridgeHub.pairing.collectAsStateWithLifecycle()
    val ble by BridgeHub.bleActive.collectAsStateWithLifecycle()
    val call by BridgeHub.call.collectAsStateWithLifecycle()
    val serverError by BridgeHub.serverError.collectAsStateWithLifecycle()
    val devAudio by BridgeHub.audio.state.collectAsStateWithLifecycle()
    val adbState by BridgeHub.audio.adb.state.collectAsStateWithLifecycle()
    var permTick by remember { mutableIntStateOf(0) }
    val resumeTick = rememberResumeTick()
    var showPair by remember { mutableStateOf(false) }
    var confirmRemove by remember { mutableStateOf<String?>(null) }
    // Survives leaving the app for Settings and coming back.
    var showAdbSetup by rememberSaveable { mutableStateOf(false) }

    val missing = remember(permTick, resumeTick) { Perms.groups.filterNot { Perms.groupGranted(ctx, it) } }
    val batteryExempt = remember(resumeTick) {
        ctx.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(ctx.packageName)
    }
    val addresses = remember(resumeTick, running, clients.size, status) { NetUtil.localAddresses() }

    val permLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        permTick++
        BridgeHub.refreshTelephony?.invoke()
    }

    LaunchedEffect(resumeTick) {
        BridgeHub.audio.refresh()
        BridgeHub.refreshDevices()
        BridgeHub.refreshTelephony?.invoke()
        if (BridgeHub.audio.adb.paired && adbState != "ready") BridgeHub.audio.adb.connectAsync()
    }
    // First launch: start the bridge automatically once the essentials are granted.
    val essentialsGranted = missing.none { it.required }
    LaunchedEffect(essentialsGranted) {
        val prefs = ctx.getSharedPreferences("settings", 0)
        if (essentialsGranted && !running && !prefs.getBoolean("started_once", false)) {
            prefs.edit().putBoolean("started_once", true).apply()
            BridgeService.start(ctx)
        }
    }

    LazyColumn(
        modifier = Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item {
            Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("SIMBridge", style = MaterialTheme.typography.headlineSmall)
                    Text("Your SIM, on your iPhone", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                HSpacer(8.dp)
                Switch(
                    checked = running,
                    onCheckedChange = { on -> if (on) BridgeService.start(ctx) else BridgeService.stop(ctx) },
                )
            }
        }

        item {
            StatusCard(
                running = running,
                connected = clients.map { it.name },
                callState = call.state,
                hasNetwork = addresses.isNotEmpty(),
                error = serverError,
                airplane = status?.airplane == true,
            )
        }

        if (missing.isNotEmpty() || !batteryExempt) {
            item { SectionLabel("FINISH SETUP") }
            item {
                Card(padding = 12.dp) {
                    missing.forEachIndexed { i, g ->
                        if (i > 0) RowDivider()
                        InfoRow(
                            icon = permIcon(g.key),
                            title = g.title + if (g.required) "" else "  ·  optional",
                            subtitle = g.reason,
                            tint = if (g.required) MaterialTheme.colorScheme.primary else Brand.Muted,
                            action = "Allow",
                            onAction = { permLauncher.launch(g.permissions.toTypedArray()) },
                        )
                    }
                    if (!batteryExempt) {
                        if (missing.isNotEmpty()) RowDivider()
                        InfoRow(
                            icon = Icons.Outlined.BatteryAlert,
                            title = "Run in the background",
                            subtitle = "Keeps the iPhone connected while the screen is off",
                            tint = Brand.Fair,
                            action = "Turn On",
                            onAction = {
                                ctx.open(
                                    Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + ctx.packageName)),
                                    Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
                                )
                            },
                        )
                    }
                    if (missing.size > 1) {
                        VSpacer(8.dp)
                        Button(
                            onClick = { permLauncher.launch(missing.flatMap { it.permissions }.toTypedArray()) },
                            modifier = Modifier.fillMaxWidth().heightIn(min = 46.dp),
                            shape = RoundedCornerShape(14.dp),
                        ) { Text("Allow All") }
                    }
                    TextButton(
                        onClick = { ctx.open(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + ctx.packageName))) },
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text("No permission prompt? Open app settings", style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Center) }
                }
            }
        }

        item { SectionLabel("SIGNAL") }
        item {
            val sims = status?.sims.orEmpty()
            Card(padding = 12.dp) {
                if (sims.isEmpty()) {
                    Text(
                        if (!running) "Turn the service on to see the signal." else "No SIM found, or the Phone permission isn't granted.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(6.dp),
                    )
                }
                sims.forEachIndexed { i, sim ->
                    if (i > 0) RowDivider()
                    SimRow(sim, multi = sims.size > 1)
                }
            }
        }

        item { SectionLabel("IPHONES") }
        item {
            Card(padding = 12.dp) {
                devices.forEachIndexed { i, d ->
                    if (i > 0) RowDivider()
                    val online = clients.any { it.deviceId == d.id }
                    InfoRow(
                        icon = Icons.Outlined.PhoneIphone,
                        title = d.name,
                        subtitle = if (online) "Connected" else "Last seen " + relativeTime(d.lastSeen),
                        tint = if (online) Brand.Good else Brand.Muted,
                    ) {
                        IconButton(onClick = { confirmRemove = d.id }) {
                            Icon(Icons.Outlined.Close, "Remove", tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
                if (devices.isNotEmpty()) VSpacer(8.dp)
                Button(
                    onClick = { BridgeHub.startPairing(); showPair = true },
                    enabled = running,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                    shape = RoundedCornerShape(14.dp),
                ) {
                    Icon(Icons.Outlined.QrCode2, null, Modifier.size(20.dp))
                    HSpacer(8.dp)
                    Text(if (devices.isEmpty()) "Connect iPhone" else "Connect Another iPhone")
                }
                if (!running) {
                    Text(
                        "Turn the service on first.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.fillMaxWidth().padding(top = 6.dp), textAlign = TextAlign.Center,
                    )
                }
            }
        }

        item { SectionLabel("CONNECTION") }
        item {
            Card(padding = 12.dp) {
                InfoRow(
                    icon = if (addresses.isEmpty()) Icons.Outlined.WifiOff else Icons.Outlined.Wifi,
                    title = if (addresses.isEmpty()) "Not on Wi-Fi or hotspot" else "Local network",
                    subtitle = if (addresses.isEmpty()) "The iPhone must be on the same Wi-Fi, or on this phone's hotspot"
                    else addresses.joinToString("  ·  "),
                    tint = if (addresses.isEmpty()) Brand.Fair else MaterialTheme.colorScheme.primary,
                )
                RowDivider()
                InfoRow(
                    icon = if (ble) Icons.Outlined.Bluetooth else Icons.Outlined.BluetoothDisabled,
                    title = if (ble) "Bluetooth wake-up" else "Bluetooth wake-up is off",
                    subtitle = if (ble) "Wakes the iPhone app even in the background" else "Turn Bluetooth on and allow Nearby devices",
                    tint = if (ble) MaterialTheme.colorScheme.primary else Brand.Muted,
                )
                RowDivider()
                InfoRow(
                    icon = Icons.Outlined.Lock,
                    title = "End-to-end encrypted",
                    subtitle = "Directly between the two phones, no server",
                    tint = Brand.Good,
                )
            }
        }

        item { SectionLabel("HEAR CALLS ON IPHONE") }
        item {
            Card(padding = 12.dp) {
                val lock = BridgeHub.audio.lockSecure
                when (devAudio) {
                    "ready" -> InfoRow(
                        icon = Icons.Outlined.Hearing,
                        title = if (lock) "On · remove the screen lock" else "On",
                        subtitle = if (lock)
                            "On Android 11, call audio can only be captured when the phone has no PIN or pattern. " +
                                "Settings → Security → Screen lock → None or Swipe."
                        else "The other caller's voice plays on the iPhone. Speak into this phone, or a Bluetooth headset paired with it.",
                        tint = if (lock) Brand.Fair else Brand.Good,
                    )
                    "adb_offline" -> InfoRow(
                        icon = Icons.Outlined.Hearing,
                        title = if (adbState == "connecting") "Connecting…" else "Not connected",
                        subtitle = "Connect to Wi-Fi and keep Wireless debugging on. SIMBridge reconnects by itself.",
                        tint = Brand.Fair,
                        action = "Fix",
                        onAction = { showAdbSetup = true; BridgeHub.audio.adb.connectAsync() },
                    )
                    "no_permission" -> InfoRow(
                        icon = Icons.Outlined.Hearing,
                        title = "Shizuku permission needed",
                        subtitle = "Shizuku is running — allow SIMBridge, or use the built-in setup instead.",
                        tint = Brand.Fair,
                        action = "Allow",
                        onAction = { BridgeHub.audio.requestShizukuPermission() },
                    )
                    "unsupported" -> InfoRow(
                        icon = Icons.Outlined.Hearing,
                        title = "Not supported",
                        subtitle = "Needs Android 11 or later.",
                        tint = Brand.Muted,
                    )
                    else -> InfoRow(
                        icon = Icons.Outlined.Hearing,
                        title = "Optional · no root needed",
                        subtitle = "Pair once with Wireless debugging so the other caller's voice plays on the iPhone. After that it's automatic.",
                        tint = Brand.Muted,
                        action = "Set Up",
                        onAction = { showAdbSetup = true },
                    )
                }
            }
        }

        item { SectionLabel("TROUBLESHOOTING") }
        item {
            Card(padding = 12.dp) {
                InfoRow(
                    icon = Icons.Outlined.History,
                    title = "Event log",
                    subtitle = "If the connection or audio misbehaves, copy this log and send it.",
                    tint = MaterialTheme.colorScheme.primary,
                    action = "Copy Log",
                    onAction = {
                        val cm = ctx.getSystemService(android.content.ClipboardManager::class.java)
                        cm.setPrimaryClip(android.content.ClipData.newPlainText("SIMBridge log", BridgeHub.diagText()))
                        android.widget.Toast.makeText(ctx, "Copied", android.widget.Toast.LENGTH_SHORT).show()
                    },
                )
            }
        }

        item {
            Text(
                "Answer, decline, dial, speaker and mute all work from the iPhone. You talk through this phone " +
                    "(or a Bluetooth headset paired with it) — Android doesn't let apps send the iPhone's microphone into a call.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 16.dp),
            )
        }
    }

    if (showPair && pairing != null) {
        PairDialog(onClose = { showPair = false; BridgeHub.stopPairing() })
    } else if (showPair && pairing == null && pending == null) {
        LaunchedEffect(Unit) { showPair = false }
    }

    pending?.let { req ->
        AlertDialog(
            onDismissRequest = {},
            icon = { Icon(Icons.Outlined.PhoneIphone, null) },
            title = { Text("Connect \"${req.name}\"?", textAlign = TextAlign.Center, style = MaterialTheme.typography.titleLarge) },
            text = {
                Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
                    Text(
                        "Approve only if the iPhone shows the same code.",
                        textAlign = TextAlign.Center, style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    VSpacer(16.dp)
                    Text(
                        req.code.toCharArray().joinToString("  "),
                        style = MaterialTheme.typography.displaySmall.copy(letterSpacing = 2.sp),
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
            },
            confirmButton = { Button(onClick = { BridgeHub.resolvePairing(true) }) { Text("Approve") } },
            dismissButton = { TextButton(onClick = { BridgeHub.resolvePairing(false) }) { Text("Decline") } },
        )
    }

    if (showAdbSetup) AdbSetupDialog(onClose = { showAdbSetup = false })

    confirmRemove?.let { id ->
        AlertDialog(
            onDismissRequest = { confirmRemove = null },
            title = { Text("Remove this iPhone?", style = MaterialTheme.typography.titleLarge) },
            text = { Text("It will be disconnected and has to scan a new QR code to connect again.") },
            confirmButton = {
                Button(
                    onClick = { BridgeHub.revoke(id); confirmRemove = null },
                    colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error),
                ) { Text("Remove") }
            },
            dismissButton = { TextButton(onClick = { confirmRemove = null }) { Text("Cancel") } },
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun StatusCard(
    running: Boolean,
    connected: List<String>,
    callState: String,
    hasNetwork: Boolean,
    error: String?,
    airplane: Boolean,
) {
    val color = when {
        !running -> Brand.Muted
        error != null -> Brand.Poor
        connected.isNotEmpty() -> Brand.Good
        else -> Brand.Fair
    }
    val animated by animateColorAsState(color, label = "status")
    val (title, subtitle) = when {
        !running -> "Off" to "Turn the service on to use your iPhone"
        error != null -> "Network error" to error
        connected.isNotEmpty() -> ("Connected to " + connected.joinToString(", ")) to "Messages, calls and signal are on the iPhone"
        !hasNetwork -> "Waiting for a network" to "Join Wi-Fi or turn on the hotspot"
        else -> "Ready" to "Waiting for the iPhone"
    }
    Card(padding = 18.dp) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(52.dp).clip(CircleShape).background(animated.copy(alpha = 0.14f))
                    .border(1.5.dp, animated.copy(alpha = 0.35f), CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    when {
                        !running -> Icons.Outlined.PowerSettingsNew
                        connected.isNotEmpty() -> Icons.Outlined.Link
                        else -> Icons.Outlined.LinkOff
                    },
                    null, tint = animated, modifier = Modifier.size(26.dp),
                )
            }
            HSpacer(14.dp)
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (running && (callState != "idle" || airplane)) {
            VSpacer(12.dp)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                if (callState == "ringing") Chip("Incoming call", Brand.Good)
                if (callState == "offhook") Chip("On a call", Brand.Good)
                if (airplane) Chip("Airplane mode", Brand.Fair)
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SimRow(sim: SimState, multi: Boolean) {
    val inService = sim.service == "in"
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(36.dp), contentAlignment = Alignment.Center) {
            SignalBars(sim.level, inService, height = 20.dp, barWidth = 5.dp)
        }
        HSpacer(12.dp)
        Column(Modifier.weight(1f)) {
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(sim.carrier.ifBlank { sim.displayName }, style = MaterialTheme.typography.titleSmall)
                if (sim.gen.isNotBlank()) Chip(sim.gen)
                if (sim.roaming) Chip("Roaming", Brand.Fair)
                if (multi) {
                    if (sim.isDefaultSms) Chip("SMS")
                    if (sim.isDefaultVoice) Chip("Calls")
                }
            }
            Text(
                buildString {
                    if (multi) append("SIM ${sim.slot + 1}").append("  ·  ")
                    append(
                        when (sim.service) {
                            "in" -> "In service"
                            "out" -> "No service"
                            "emergency" -> "Emergency calls only"
                            "off" -> "Radio off"
                            else -> "Checking…"
                        }
                    )
                    sim.dbm?.let { append("  ·  ").append("$it dBm") }
                },
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun PairDialog(onClose: () -> Unit) {
    val session by BridgeHub.pairing.collectAsStateWithLifecycle()
    val s = session ?: return
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(s) {
        while (true) {
            now = System.currentTimeMillis()
            if (now >= s.expiresAt) BridgeHub.startPairing() // refresh an expired code automatically
            delay(1000)
        }
    }
    val qr = remember(s.payload) { qrBitmap(s.payload) }
    val left = ((s.expiresAt - now) / 1000).coerceAtLeast(0)
    val hosts = remember(s.payload) { NetUtil.localAddresses() }

    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(
            shape = MaterialTheme.shapes.extraLarge,
            color = MaterialTheme.colorScheme.surface,
            modifier = Modifier.padding(24.dp).widthIn(max = 420.dp).fillMaxWidth(),
        ) {
            Column(
                Modifier.verticalScroll(rememberScrollState()).padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text("Connect iPhone", style = MaterialTheme.typography.titleLarge)
                VSpacer(6.dp)
                Text(
                    "In SIMBridge on the iPhone, tap Scan QR Code.",
                    textAlign = TextAlign.Center, style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                VSpacer(20.dp)
                Box(
                    Modifier.fillMaxWidth(0.82f).aspectRatio(1f).clip(RoundedCornerShape(20.dp))
                        .background(Color.White).padding(16.dp)
                ) { Image(qr, "QR code", Modifier.fillMaxSize()) }
                VSpacer(14.dp)
                Text(
                    "Valid for ${left / 60}:${(left % 60).toString().padStart(2, '0')}",
                    style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (hosts.isEmpty()) {
                    VSpacer(8.dp)
                    Text(
                        "This phone isn't on Wi-Fi or hotspot, so the iPhone can't reach it.",
                        color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                VSpacer(16.dp)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    TextButton(onClick = { BridgeHub.startPairing() }) { Text("New Code") }
                    Button(onClick = onClose, shape = RoundedCornerShape(14.dp)) { Text("Done") }
                }
            }
        }
    }
}

// ------------------------------------------------------------------------------------------------
// Hear calls on iPhone: one-time pairing with the phone's own Wireless debugging (no root, no Shizuku)

private fun devOptionsOn(ctx: Context) =
    Settings.Global.getInt(ctx.contentResolver, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 0) == 1

private fun wirelessDebuggingOn(ctx: Context) =
    try { Settings.Global.getInt(ctx.contentResolver, "adb_wifi_enabled", 0) == 1 } catch (_: Exception) { false }

/** Developer options, scrolled to (and highlighting) Wireless debugging. */
private fun openWirelessDebugging(ctx: Context) {
    ctx.open(
        Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
            .putExtra(":settings:fragment_args_key", "toggle_adb_wireless")
            .addFlags(Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS),
        Intent(Settings.ACTION_SETTINGS),
    )
}

@Composable
private fun AdbSetupDialog(onClose: () -> Unit) {
    val ctx = LocalContext.current
    val adb = BridgeHub.audio.adb
    val state by adb.state.collectAsStateWithLifecycle()
    val pairState by adb.pairState.collectAsStateWithLifecycle()
    val message by adb.message.collectAsStateWithLifecycle()
    var code by rememberSaveable { mutableStateOf("") }
    var port by rememberSaveable { mutableStateOf("") }
    var connectPort by rememberSaveable { mutableStateOf("") }
    var manual by rememberSaveable { mutableStateOf(false) }

    // Re-read the system settings every second while open (the user toggles them in Settings).
    var tick by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) { while (true) { delay(1000); tick++ } }
    val resume = rememberResumeTick()
    val dev = remember(tick, resume) { devOptionsOn(ctx) }
    val wifi = remember(tick, resume) { NetUtil.localAddresses().isNotEmpty() }
    val wd = remember(tick, resume) { wirelessDebuggingOn(ctx) }
    val notifOk = remember(tick, resume) { AdbPairNotifier.enabled(ctx) }
    val ready = state == "ready"
    val paired = adb.paired

    Dialog(
        onDismissRequest = onClose,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        Surface(
            shape = MaterialTheme.shapes.extraLarge,
            color = MaterialTheme.colorScheme.surface,
            modifier = Modifier.windowInsetsPadding(WindowInsets.safeDrawing).imePadding()
                .padding(16.dp).widthIn(max = 480.dp).fillMaxWidth(),
        ) {
            Column(Modifier.verticalScroll(rememberScrollState()).padding(20.dp)) {
                Text("Hear Calls on iPhone", style = MaterialTheme.typography.titleLarge)
                VSpacer(4.dp)
                Text(
                    if (ready) "All set. The other caller's voice plays on the iPhone during calls."
                    else "A one-time setup. After a restart SIMBridge turns Wireless debugging back on and reconnects by itself.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                VSpacer(14.dp)

                Step(
                    done = dev, title = "Developer options",
                    detail = "Settings → About phone → tap Build number 7 times.",
                    action = if (!dev) "Open About Phone" else null,
                ) { ctx.open(Intent(Settings.ACTION_DEVICE_INFO_SETTINGS), Intent(Settings.ACTION_SETTINGS)) }
                Step(
                    done = wifi, title = "Wi-Fi connected",
                    detail = "Wireless debugging only works on Wi-Fi (any network, internet not needed).",
                    action = if (!wifi) "Wi-Fi Settings" else null,
                ) { ctx.open(Intent(Settings.ACTION_WIFI_SETTINGS)) }
                Step(
                    done = wd || ready, title = "Wireless debugging on",
                    detail = "Developer options → Wireless debugging → On (tap Allow).",
                    action = if (!wd && !ready && dev) "Open Wireless Debugging" else null,
                ) { openWirelessDebugging(ctx) }

                val pairDone = paired || ready
                Step(
                    done = pairDone, busy = pairState == "searching" || pairState == "pairing" || state == "connecting",
                    title = when {
                        ready -> "Paired and connected"
                        paired -> if (state == "connecting") "Connecting…" else "Paired"
                        pairState == "found" -> "Pairing dialog found — enter the code"
                        pairState == "searching" -> "Waiting for the pairing dialog…"
                        pairState == "pairing" -> "Pairing…"
                        else -> "Pair this app"
                    },
                    detail = when {
                        ready -> null
                        paired -> "If it doesn't connect, open Wireless debugging once, or type the connection port below."
                        pairState == "found" -> "Pull down the notification and type the 6-digit code — or type it here."
                        pairState == "searching" -> "Inside Wireless debugging tap \"Pair device with pairing code\". A notification will ask for the code."
                        else -> "Tap Start Pairing, then \"Pair device with pairing code\". Enter the 6-digit code in the notification."
                    },
                    action = if (!pairDone && pairState == "idle") "Start Pairing" else if (!pairDone && pairState == "searching") "Open Wireless Debugging" else null,
                ) {
                    AdbPairNotifier.start(ctx)
                    openWirelessDebugging(ctx)
                }

                if (!notifOk && !pairDone) {
                    VSpacer(6.dp)
                    InfoRow(
                        icon = Icons.Outlined.Notifications,
                        title = "Notifications are off for SIMBridge",
                        subtitle = "The pairing code is typed into a notification. Turn them on, or enter the code manually below.",
                        tint = Brand.Fair,
                        action = "Turn On",
                        onAction = {
                            ctx.open(
                                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, ctx.packageName),
                                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + ctx.packageName)),
                            )
                        },
                    )
                }

                // In-app code entry: useful in split screen, or when the dialog was found.
                if (!pairDone && (pairState == "found" || manual)) {
                    VSpacer(8.dp)
                    OutlinedTextField(
                        value = code, onValueChange = { code = it.filter { c -> c.isDigit() }.take(6) }, singleLine = true,
                        label = { Text("6-digit pairing code") }, modifier = Modifier.fillMaxWidth(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    )
                    if (manual && pairState != "found") {
                        VSpacer(6.dp)
                        OutlinedTextField(
                            value = port, onValueChange = { port = it.filter { c -> c.isDigit() }.take(5) }, singleLine = true,
                            label = { Text("Pairing port (number after \":\" in the dialog)") }, modifier = Modifier.fillMaxWidth(),
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        )
                    }
                    VSpacer(8.dp)
                    Button(
                        enabled = code.length == 6 && pairState != "pairing",
                        onClick = { adb.pair(port.toIntOrNull(), code) { BridgeHub.audio.refresh() } },
                        modifier = Modifier.fillMaxWidth().heightIn(min = 46.dp),
                        shape = RoundedCornerShape(14.dp),
                    ) { Text("Pair") }
                }

                if (paired && !ready) {
                    VSpacer(10.dp)
                    Text(
                        "Connection port: the number after \":\" under \"IP address & Port\" on the Wireless debugging screen.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    VSpacer(6.dp)
                    OutlinedTextField(
                        value = connectPort, onValueChange = { connectPort = it.filter { c -> c.isDigit() }.take(5) },
                        singleLine = true, label = { Text("Connection port") }, modifier = Modifier.fillMaxWidth(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    )
                    VSpacer(8.dp)
                    FilledTonalButton(
                        enabled = connectPort.length >= 4 && state != "connecting",
                        onClick = { connectPort.toIntOrNull()?.let { p -> adb.connectToPort(p) { BridgeHub.audio.refresh() } } },
                        modifier = Modifier.fillMaxWidth().heightIn(min = 44.dp),
                    ) { Text("Connect") }
                }

                message?.let {
                    VSpacer(10.dp)
                    Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                }

                VSpacer(16.dp)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
                    if (!ready) {
                        TextButton(onClick = { manual = !manual }) { Text(if (manual) "Hide Manual Entry" else "Enter Manually") }
                        androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
                    }
                    if (paired) {
                        TextButton(onClick = { adb.forget(); BridgeHub.audio.refresh() }) {
                            Text("Forget", color = MaterialTheme.colorScheme.error)
                        }
                    }
                    Button(onClick = onClose, shape = RoundedCornerShape(14.dp)) { Text(if (ready) "Done" else "Close") }
                }
            }
        }
    }
}

@Composable
private fun Step(done: Boolean, title: String, detail: String?, action: String?, busy: Boolean = false, onAction: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.Top) {
        Box(Modifier.size(24.dp), contentAlignment = Alignment.Center) {
            when {
                done -> Icon(Icons.Outlined.CheckCircle, null, tint = Brand.Good, modifier = Modifier.size(22.dp))
                busy -> CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                else -> Icon(Icons.Outlined.RadioButtonUnchecked, null, tint = Brand.Muted, modifier = Modifier.size(22.dp))
            }
        }
        HSpacer(12.dp)
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleSmall)
            if (!done && detail != null) {
                Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (action != null) {
                FilledTonalButton(
                    onClick = onAction,
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 6.dp),
                    modifier = Modifier.padding(top = 8.dp).heightIn(min = 36.dp),
                ) { Text(action, style = MaterialTheme.typography.labelLarge) }
            }
        }
    }
}
