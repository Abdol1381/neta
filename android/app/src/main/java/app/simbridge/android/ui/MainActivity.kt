package app.simbridge.android.ui

import android.annotation.SuppressLint
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
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.BatteryAlert
import androidx.compose.material.icons.outlined.Bluetooth
import androidx.compose.material.icons.outlined.BluetoothDisabled
import androidx.compose.material.icons.outlined.Call
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
import androidx.compose.material.icons.outlined.Sms
import androidx.compose.material.icons.outlined.Wifi
import androidx.compose.material.icons.outlined.WifiOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.LayoutDirection
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
import app.simbridge.android.service.BridgeService
import app.simbridge.android.telephony.Perms
import kotlinx.coroutines.delay

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            SimBridgeTheme {
                CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Rtl) {
                    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                        HomeScreen()
                    }
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
    var permTick by remember { mutableIntStateOf(0) }
    val resumeTick = rememberResumeTick()
    var showPair by remember { mutableStateOf(false) }
    var confirmRemove by remember { mutableStateOf<String?>(null) }
    var showAdbSetup by remember { mutableStateOf(false) }

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
                    Text("پل سیم‌کارت به آیفون", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
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
            item { SectionLabel("تکمیل راه‌اندازی") }
            item {
                Card(padding = 12.dp) {
                    missing.forEachIndexed { i, g ->
                        if (i > 0) RowDivider()
                        InfoRow(
                            icon = permIcon(g.key),
                            title = g.title + if (g.required) "" else "  ·  اختیاری",
                            subtitle = g.reason,
                            tint = if (g.required) MaterialTheme.colorScheme.primary else Brand.Muted,
                        ) {
                            FilledTonalButton(
                                onClick = { permLauncher.launch(g.permissions.toTypedArray()) },
                                contentPadding = PaddingValues(horizontal = 14.dp),
                                modifier = Modifier.height(34.dp),
                            ) { Text("اجازه", style = MaterialTheme.typography.labelLarge) }
                        }
                    }
                    if (!batteryExempt) {
                        if (missing.isNotEmpty()) RowDivider()
                        InfoRow(
                            icon = Icons.Outlined.BatteryAlert,
                            title = "اجرای دائمی در پس‌زمینه",
                            subtitle = "تا اتصال هنگام خاموش بودن صفحه قطع نشود",
                            tint = Brand.Fair,
                        ) {
                            FilledTonalButton(
                                onClick = {
                                    try {
                                        ctx.startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + ctx.packageName)))
                                    } catch (e: Exception) {
                                        ctx.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                                    }
                                },
                                contentPadding = PaddingValues(horizontal = 14.dp),
                                modifier = Modifier.height(34.dp),
                            ) { Text("فعال‌سازی", style = MaterialTheme.typography.labelLarge) }
                        }
                    }
                    if (missing.size > 1) {
                        VSpacer(8.dp)
                        Button(
                            onClick = { permLauncher.launch(missing.flatMap { it.permissions }.toTypedArray()) },
                            modifier = Modifier.fillMaxWidth().height(46.dp),
                            shape = RoundedCornerShape(14.dp),
                        ) { Text("اجازه همه") }
                    }
                    TextButton(
                        onClick = { ctx.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + ctx.packageName))) },
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text("اگر پنجره اجازه باز نشد: تنظیمات برنامه", style = MaterialTheme.typography.bodySmall) }
                }
            }
        }

        item { SectionLabel("آنتن") }
        item {
            val sims = status?.sims.orEmpty()
            Card(padding = 12.dp) {
                if (sims.isEmpty()) {
                    Text(
                        if (!running) "برای نمایش آنتن، سرویس را روشن کنید." else "سیم‌کارتی پیدا نشد یا دسترسی «تماس و آنتن» داده نشده است.",
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

        item { SectionLabel("آیفون‌ها") }
        item {
            Card(padding = 12.dp) {
                devices.forEachIndexed { i, d ->
                    if (i > 0) RowDivider()
                    val online = clients.any { it.deviceId == d.id }
                    InfoRow(
                        icon = Icons.Outlined.PhoneIphone,
                        title = d.name,
                        subtitle = if (online) "متصل" else "آخرین اتصال: " + relativeTime(d.lastSeen),
                        tint = if (online) Brand.Good else Brand.Muted,
                    ) {
                        IconButton(onClick = { confirmRemove = d.id }) {
                            Icon(Icons.Outlined.Close, "حذف", tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
                if (devices.isNotEmpty()) VSpacer(8.dp)
                Button(
                    onClick = { BridgeHub.startPairing(); showPair = true },
                    enabled = running,
                    modifier = Modifier.fillMaxWidth().height(48.dp),
                    shape = RoundedCornerShape(14.dp),
                ) {
                    Icon(Icons.Outlined.QrCode2, null, Modifier.size(20.dp))
                    HSpacer(8.dp)
                    Text(if (devices.isEmpty()) "اتصال آیفون" else "اتصال آیفون دیگر")
                }
                if (!running) {
                    Text(
                        "ابتدا سرویس را روشن کنید.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.fillMaxWidth().padding(top = 6.dp), textAlign = TextAlign.Center,
                    )
                }
            }
        }

        item { SectionLabel("ارتباط") }
        item {
            Card(padding = 12.dp) {
                InfoRow(
                    icon = if (addresses.isEmpty()) Icons.Outlined.WifiOff else Icons.Outlined.Wifi,
                    title = if (addresses.isEmpty()) "به Wi-Fi یا هات‌اسپات وصل نیست" else "شبکه محلی",
                    subtitle = if (addresses.isEmpty()) "آیفون باید روی همان Wi-Fi یا هات‌اسپات این گوشی باشد"
                    else "‎" + addresses.joinToString("  ·  "),
                    tint = if (addresses.isEmpty()) Brand.Fair else MaterialTheme.colorScheme.primary,
                )
                RowDivider()
                InfoRow(
                    icon = if (ble) Icons.Outlined.Bluetooth else Icons.Outlined.BluetoothDisabled,
                    title = if (ble) "اعلان فوری بلوتوث" else "اعلان فوری بلوتوث خاموش",
                    subtitle = if (ble) "آیفون حتی در پس‌زمینه باخبر می‌شود" else "بلوتوث را روشن کنید و دسترسی «دستگاه‌های نزدیک» را بدهید",
                    tint = if (ble) MaterialTheme.colorScheme.primary else Brand.Muted,
                )
                RowDivider()
                InfoRow(
                    icon = Icons.Outlined.Lock,
                    title = "رمزنگاری سرتاسری",
                    subtitle = "مستقیم بین دو گوشی، بدون سرور",
                    tint = Brand.Good,
                )
            }
        }

        item { SectionLabel("شنیدن تماس روی آیفون") }
        item {
            Card(padding = 12.dp) {
                val adbState by BridgeHub.audio.adb.state.collectAsStateWithLifecycle()
                when (devAudio) {
                    "ready" -> InfoRow(
                        icon = Icons.Outlined.Hearing,
                        title = "فعال",
                        subtitle = "صدای طرف مقابل روی آیفون پخش می‌شود. برای صحبت، با همین گوشی یا هدست بلوتوثِ وصل به آن صحبت کنید.",
                        tint = Brand.Good,
                    )
                    "adb_offline" -> InfoRow(
                        icon = Icons.Outlined.Hearing,
                        title = if (adbState == "connecting") "در حال اتصال…" else "اتصال برقرار نیست",
                        subtitle = "گوشی را به Wi-Fi وصل کنید و «اشکال‌زدایی بی‌سیم» روشن باشد. اتصال خودکار انجام می‌شود.",
                        tint = Brand.Fair,
                    ) {
                        FilledTonalButton(
                            onClick = { showAdbSetup = true; BridgeHub.audio.adb.connectAsync() },
                            contentPadding = PaddingValues(horizontal = 14.dp),
                            modifier = Modifier.height(34.dp),
                        ) { Text("اتصال", style = MaterialTheme.typography.labelLarge) }
                    }
                    "no_permission" -> InfoRow(
                        icon = Icons.Outlined.Hearing,
                        title = "اجازه Shizuku لازم است",
                        subtitle = "Shizuku فعال است؛ به SIMBridge اجازه بدهید (یا از «راه‌اندازی» داخلی استفاده کنید).",
                        tint = Brand.Fair,
                    ) {
                        FilledTonalButton(
                            onClick = { BridgeHub.audio.requestShizukuPermission() },
                            contentPadding = PaddingValues(horizontal = 14.dp),
                            modifier = Modifier.height(34.dp),
                        ) { Text("اجازه", style = MaterialTheme.typography.labelLarge) }
                    }
                    "unsupported" -> InfoRow(
                        icon = Icons.Outlined.Hearing,
                        title = "پشتیبانی نمی‌شود",
                        subtitle = "این قابلیت به اندروید ۱۱ یا جدیدتر نیاز دارد.",
                        tint = Brand.Muted,
                    )
                    else -> InfoRow(
                        icon = Icons.Outlined.Hearing,
                        title = "اختیاری · بدون روت",
                        subtitle = "یک بار با «اشکال‌زدایی بی‌سیم» جفت کنید تا صدای طرف مقابل تماس روی آیفون پخش شود. بعد از آن خودکار است.",
                        tint = Brand.Muted,
                    ) {
                        FilledTonalButton(
                            onClick = { showAdbSetup = true },
                            contentPadding = PaddingValues(horizontal = 14.dp),
                            modifier = Modifier.height(34.dp),
                        ) { Text("راه‌اندازی", style = MaterialTheme.typography.labelLarge) }
                    }
                }
            }
        }

        item {
            Text(
                "پاسخ، رد، شماره‌گیری، بلندگو و بی‌صدا از آیفون کار می‌کند. صحبت کردن با همین گوشی (یا هدست بلوتوثِ وصل به آن) است؛ اندروید اجازه ارسال صدای آیفون به داخل تماس را نمی‌دهد.",
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
            title = { Text("اتصال «⁨${req.name}⁩»", textAlign = TextAlign.Center, style = MaterialTheme.typography.titleLarge) },
            text = {
                Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
                    Text(
                        "اگر همین کد روی آیفون نمایش داده می‌شود، تأیید کنید.",
                        textAlign = TextAlign.Center, style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    VSpacer(16.dp)
                    Text(
                        req.code.toCharArray().joinToString("  "),
                        style = MaterialTheme.typography.displaySmall.copy(textDirection = TextDirection.Ltr, letterSpacing = 2.sp),
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
            },
            confirmButton = { Button(onClick = { BridgeHub.resolvePairing(true) }) { Text("تأیید") } },
            dismissButton = { TextButton(onClick = { BridgeHub.resolvePairing(false) }) { Text("رد") } },
        )
    }

    if (showAdbSetup) AdbSetupDialog(onClose = { showAdbSetup = false })

    confirmRemove?.let { id ->
        AlertDialog(
            onDismissRequest = { confirmRemove = null },
            title = { Text("حذف این آیفون؟", style = MaterialTheme.typography.titleLarge) },
            text = { Text("اتصال این آیفون قطع می‌شود و برای اتصال دوباره باید QR جدید اسکن شود.") },
            confirmButton = {
                Button(
                    onClick = { BridgeHub.revoke(id); confirmRemove = null },
                    colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error),
                ) { Text("حذف") }
            },
            dismissButton = { TextButton(onClick = { confirmRemove = null }) { Text("انصراف") } },
        )
    }
}

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
        !running -> "خاموش" to "برای استفاده از آیفون، سرویس را روشن کنید"
        error != null -> "خطای شبکه" to error
        connected.isNotEmpty() -> ("متصل به " + connected.joinToString("، ") { "⁨$it⁩" }) to "پیامک، تماس و آنتن روی آیفون در دسترس است"
        !hasNetwork -> "در انتظار شبکه" to "به Wi-Fi وصل شوید یا هات‌اسپات را روشن کنید"
        else -> "آماده" to "در انتظار اتصال آیفون"
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
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (callState == "ringing") Chip("تماس ورودی", Brand.Good)
                if (callState == "offhook") Chip("در حال مکالمه", Brand.Good)
                if (airplane) Chip("حالت پرواز", Brand.Fair)
            }
        }
    }
}

@Composable
private fun SimRow(sim: SimState, multi: Boolean) {
    val inService = sim.service == "in"
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(38.dp), contentAlignment = Alignment.Center) {
            SignalBars(sim.level, inService, height = 20.dp, barWidth = 5.dp)
        }
        HSpacer(12.dp)
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(sim.carrier.ifBlank { sim.displayName }, style = MaterialTheme.typography.titleSmall)
                if (sim.gen.isNotBlank()) Chip(sim.gen)
                if (sim.roaming) Chip("رومینگ", Brand.Fair)
            }
            Text(
                buildString {
                    if (multi) append("سیم ${sim.slot + 1}".fa()).append("  ·  ")
                    append(
                        when (sim.service) {
                            "in" -> "در سرویس"
                            "out" -> "بدون آنتن"
                            "emergency" -> "فقط تماس اضطراری"
                            "off" -> "رادیو خاموش"
                            else -> "در حال بررسی"
                        }
                    )
                    sim.dbm?.let { append("  ·  ").append("‎$it dBm‏") }
                },
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (multi) {
            val roles = listOfNotNull("پیامک".takeIf { sim.isDefaultSms }, "تماس".takeIf { sim.isDefaultVoice })
            if (roles.isNotEmpty()) Text(roles.joinToString("، "), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
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
            modifier = Modifier.padding(24.dp).fillMaxWidth(),
        ) {
            Column(Modifier.padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text("اتصال آیفون", style = MaterialTheme.typography.titleLarge)
                VSpacer(6.dp)
                Text(
                    "در اپ SIMBridge آیفون «اسکن QR» را بزنید.",
                    textAlign = TextAlign.Center, style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                VSpacer(20.dp)
                Box(
                    Modifier.fillMaxWidth(0.82f).aspectRatio(1f).clip(RoundedCornerShape(20.dp))
                        .background(Color.White).padding(16.dp)
                ) { Image(qr, "QR", Modifier.fillMaxSize()) }
                VSpacer(14.dp)
                Text(
                    "اعتبار ${left / 60}:${(left % 60).toString().padStart(2, '0')}".fa(),
                    style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (hosts.isEmpty()) {
                    VSpacer(8.dp)
                    Text(
                        "این گوشی به Wi-Fi یا هات‌اسپات وصل نیست؛ آیفون به آن نمی‌رسد.",
                        color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                VSpacer(16.dp)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    TextButton(onClick = { BridgeHub.startPairing() }) { Text("کد جدید") }
                    Button(onClick = onClose, shape = RoundedCornerShape(14.dp)) { Text("بستن") }
                }
            }
        }
    }
}

/** One-time pairing with the phone's own Wireless debugging (built-in replacement for Shizuku). */
@Composable
private fun AdbSetupDialog(onClose: () -> Unit) {
    val ctx = LocalContext.current
    val adb = BridgeHub.audio.adb
    val state by adb.state.collectAsStateWithLifecycle()
    val message by adb.message.collectAsStateWithLifecycle()
    var port by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    var manual by remember { mutableStateOf(false) }

    fun openDevSettings() {
        try {
            ctx.startActivity(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: Exception) {
            ctx.startActivity(Intent(Settings.ACTION_DEVICE_INFO_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    AlertDialog(
        onDismissRequest = onClose,
        title = { Text("راه‌اندازی شنیدن تماس", style = MaterialTheme.typography.titleLarge) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (state == "ready") {
                    Text("✓ آماده است. صدای طرف مقابل در تماس‌ها روی آیفون پخش می‌شود.", color = Brand.Good)
                } else {
                    Text(
                        "۱. حالت توسعه‌دهنده: تنظیمات ← درباره تلفن ← ۷ بار روی «Build number».\n" +
                            "۲. گوشی به Wi-Fi وصل باشد. در «گزینه‌های توسعه‌دهنده»، «اشکال‌زدایی بی‌سیم» (Wireless debugging) را روشن کنید.\n" +
                            "۳. داخل آن، «Pair device with pairing code» را بزنید.\n" +
                            "۴. اعلان «جفت‌سازی SIMBridge» را پایین بکشید و کد ۶ رقمی را وارد کنید.",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    Text(
                        "فقط یک بار لازم است؛ بعد از خاموش و روشن شدن گوشی، SIMBridge خودش دوباره وصل می‌شود.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    if (manual) {
                        androidx.compose.material3.OutlinedTextField(
                            value = code, onValueChange = { code = it.filter { c -> c.isDigit() }.take(6) }, singleLine = true,
                            label = { Text("کد ۶ رقمی") },
                            keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Number),
                        )
                        androidx.compose.material3.OutlinedTextField(
                            value = port, onValueChange = { port = it.filter { c -> c.isDigit() }.take(5) }, singleLine = true,
                            label = { Text("پورت (اختیاری، عدد بعد از «:»)") },
                            keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Number),
                        )
                    }
                    if (state == "connecting") Text("در حال اتصال…", color = MaterialTheme.colorScheme.primary)
                    message?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                }
            }
        },
        confirmButton = {
            if (state == "ready") {
                Button(onClick = onClose) { Text("بستن") }
            } else if (manual) {
                Button(
                    enabled = code.length == 6,
                    onClick = { adb.pair(port.toIntOrNull(), code) { BridgeHub.audio.refresh() } },
                ) { Text("جفت کردن") }
            } else {
                Button(onClick = {
                    app.simbridge.android.receivers.AdbPairNotifier.show(ctx)
                    openDevSettings()
                }) { Text("شروع") }
            }
        },
        dismissButton = {
            if (state != "ready") {
                TextButton(onClick = { manual = !manual }) { Text(if (manual) "با اعلان" else "وارد کردن دستی") }
            }
        },
    )
}
