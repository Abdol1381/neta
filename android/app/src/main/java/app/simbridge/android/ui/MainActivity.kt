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
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.BatteryChargingFull
import androidx.compose.material.icons.outlined.BatteryStd
import androidx.compose.material.icons.outlined.Bluetooth
import androidx.compose.material.icons.outlined.BluetoothDisabled
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.PhoneIphone
import androidx.compose.material.icons.outlined.QrCode2
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material.icons.outlined.Wifi
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
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
    var permTick by remember { mutableIntStateOf(0) }
    val resumeTick = rememberResumeTick()
    var showPair by remember { mutableStateOf(false) }
    var confirmRemove by remember { mutableStateOf<String?>(null) }

    val missing = remember(permTick, resumeTick) { Perms.groups.filterNot { Perms.groupGranted(ctx, it) } }
    val batteryExempt = remember(resumeTick) {
        ctx.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(ctx.packageName)
    }
    val addresses = remember(resumeTick, running, clients.size) { NetUtil.localAddresses() }

    val permLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        permTick++
        BridgeHub.refreshTelephony?.invoke()
    }

    LaunchedEffect(resumeTick) { BridgeHub.refreshDevices() }
    // First launch: start the bridge automatically once the essentials are granted.
    LaunchedEffect(missing.none { it.required }) {
        if (missing.none { it.required } && !running && !BridgeService.isEnabled(ctx) &&
            !ctx.getSharedPreferences("settings", 0).getBoolean("started_once", false)
        ) {
            ctx.getSharedPreferences("settings", 0).edit().putBoolean("started_once", true).apply()
            BridgeService.start(ctx)
        }
    }

    LazyColumn(
        modifier = Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            HeaderCard(
                running = running,
                connected = clients.map { it.name },
                callState = call.state,
                error = serverError,
                onToggle = { on -> if (on) BridgeService.start(ctx) else BridgeService.stop(ctx) },
            )
        }

        if (missing.isNotEmpty()) {
            item {
                Card {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Outlined.Shield, null, tint = MaterialTheme.colorScheme.primary)
                        HSpacer(8.dp)
                        Text("دسترسی‌های لازم", fontWeight = FontWeight.Bold, style = MaterialTheme.typography.titleMedium)
                    }
                    Spacer8()
                    Text(
                        "این دسترسی‌ها فقط برای پل بین این گوشی و آیفون خودتان استفاده می‌شوند؛ هیچ داده‌ای به سرور یا شخص ثالث ارسال نمی‌شود.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    missing.forEach { g ->
                        Spacer8()
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(g.title + if (g.required) "" else " (اختیاری)", fontWeight = FontWeight.SemiBold)
                                Text(g.reason, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            FilledTonalButton(onClick = { permLauncher.launch(g.permissions.toTypedArray()) }) { Text("اجازه") }
                        }
                    }
                    Spacer8()
                    Button(
                        onClick = { permLauncher.launch(missing.flatMap { it.permissions }.toTypedArray()) },
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text("اجازه همه") }
                    TextButton(onClick = {
                        ctx.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + ctx.packageName)))
                    }) { Text("اگر دکمه کار نکرد: باز کردن تنظیمات برنامه") }
                }
            }
        }

        if (!batteryExempt) {
            item {
                Card {
                    Text("پایداری در حالت قفل", fontWeight = FontWeight.Bold)
                    Text(
                        "برای اینکه اتصال هنگام خاموش بودن صفحه قطع نشود، بهینه‌سازی باتری را برای SIMBridge غیرفعال کنید.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer8()
                    FilledTonalButton(onClick = {
                        try {
                            ctx.startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + ctx.packageName)))
                        } catch (e: Exception) {
                            ctx.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                        }
                    }) { Text("غیرفعال کردن بهینه‌سازی باتری") }
                }
            }
        }

        item { SectionTitle("آنتن و سیم‌کارت") }
        val sims = status?.sims.orEmpty()
        if (sims.isEmpty()) {
            item {
                Card {
                    Text(
                        if (!running) "برای نمایش آنتن، سرویس را روشن کنید." else "سیم‌کارتی پیدا نشد یا دسترسی «تماس و آنتن» داده نشده است.",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        } else {
            items(sims, key = { it.subId }) { SimCard(it, multi = sims.size > 1) }
        }
        status?.let { s ->
            item {
                Card {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(if (s.battery.charging) Icons.Outlined.BatteryChargingFull else Icons.Outlined.BatteryStd, null,
                            tint = if (s.battery.level <= 15 && !s.battery.charging) Brand.Poor else Brand.Good)
                        HSpacer(8.dp)
                        Text("باتری ${s.battery.level}٪" + if (s.battery.charging) " — در حال شارژ" else "")
                        Spacer(Modifier.weight(1f))
                        if (s.airplane) Chip("حالت پرواز", Brand.Fair)
                    }
                }
            }
        }

        item { SectionTitle("آیفون‌ها") }
        item {
            Card {
                Button(
                    onClick = { BridgeHub.startPairing(); showPair = true },
                    enabled = running,
                    modifier = Modifier.fillMaxWidth().height(52.dp),
                    shape = RoundedCornerShape(16.dp),
                ) {
                    Icon(Icons.Outlined.QrCode2, null)
                    HSpacer(8.dp)
                    Text("اتصال آیفون جدید", fontSize = 16.sp)
                }
                if (!running) {
                    Spacer8()
                    Text("ابتدا سرویس را روشن کنید.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (devices.isNotEmpty()) Spacer8()
                devices.forEach { d ->
                    val online = clients.any { it.deviceId == d.id }
                    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Box(
                            Modifier.size(40.dp).clip(CircleShape).background(MaterialTheme.colorScheme.primaryContainer),
                            contentAlignment = Alignment.Center,
                        ) { Icon(Icons.Outlined.PhoneIphone, null, tint = MaterialTheme.colorScheme.onPrimaryContainer) }
                        HSpacer(12.dp)
                        Column(Modifier.weight(1f)) {
                            Text(d.name, fontWeight = FontWeight.SemiBold)
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Dot(if (online) Brand.Good else MaterialTheme.colorScheme.outline, 8.dp)
                                HSpacer(6.dp)
                                Text(
                                    if (online) "متصل" else "آخرین اتصال: " + relativeTime(d.lastSeen),
                                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                        IconButton(onClick = { confirmRemove = d.id }) {
                            Icon(Icons.Outlined.Delete, "حذف", tint = MaterialTheme.colorScheme.error)
                        }
                    }
                }
            }
        }

        item { SectionTitle("اتصال") }
        item {
            Card {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.Wifi, null, tint = MaterialTheme.colorScheme.primary)
                    HSpacer(8.dp)
                    Column {
                        Text(if (addresses.isEmpty()) "به Wi-Fi وصل نیست" else "در شبکه محلی قابل دسترس است", fontWeight = FontWeight.SemiBold)
                        if (addresses.isNotEmpty()) Text(
                            addresses.joinToString("  ·  ") + " : " + BridgeHub.PORT,
                            style = MaterialTheme.typography.bodySmall.copy(textDirection = TextDirection.Ltr),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                Spacer8()
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(if (ble) Icons.Outlined.Bluetooth else Icons.Outlined.BluetoothDisabled, null,
                        tint = if (ble) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                    HSpacer(8.dp)
                    Column {
                        Text(if (ble) "اعلان فوری بلوتوث فعال است" else "اعلان فوری بلوتوث غیرفعال", fontWeight = FontWeight.SemiBold)
                        Text(
                            if (ble) "آیفون حتی وقتی اپ در پس‌زمینه است از پیامک و تماس باخبر می‌شود."
                            else "بلوتوث را روشن کنید تا وقتی اپ آیفون بسته است هم اعلان برسد.",
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                Spacer8()
                Text(
                    "نکته: هر دو گوشی باید روی یک Wi-Fi باشند، یا آیفون به هات‌اسپات همین گوشی وصل شود (در این حالت آیفون اینترنت هم می‌گیرد).",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        item {
            Card {
                Row(verticalAlignment = Alignment.Top) {
                    Icon(Icons.Outlined.Info, null, tint = Brand.Fair)
                    HSpacer(8.dp)
                    Text(
                        "صدای مکالمه: اندروید به برنامه‌ها اجازه انتقال صدای تماس سیم‌کارت را نمی‌دهد. از آیفون می‌توانید تماس را ببینید، پاسخ دهید، رد کنید، شماره بگیرید و بلندگو را روشن کنید؛ خود صحبت روی همین گوشی (یا هدست بلوتوثِ وصل به آن) انجام می‌شود.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
        item { Spacer(Modifier.height(24.dp)) }
    }

    if (showPair && pairing != null) {
        PairDialog(onClose = { showPair = false; BridgeHub.stopPairing() })
    } else if (showPair && pairing == null && pending == null) {
        // Pairing finished (QR consumed) or expired.
        LaunchedEffect(Unit) { showPair = false }
    }

    pending?.let { req ->
        AlertDialog(
            onDismissRequest = {},
            icon = { Icon(Icons.Outlined.PhoneIphone, null) },
            title = { Text("اتصال «${req.name}»؟", textAlign = TextAlign.Center) },
            text = {
                Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
                    Text("فقط اگر همین کد روی آیفون نمایش داده می‌شود تأیید کنید:", textAlign = TextAlign.Center)
                    Spacer(Modifier.height(12.dp))
                    Text(
                        req.code.toCharArray().joinToString(" "),
                        fontSize = 36.sp, fontWeight = FontWeight.Black, letterSpacing = 4.sp,
                        color = MaterialTheme.colorScheme.primary,
                        style = MaterialTheme.typography.displaySmall.copy(textDirection = TextDirection.Ltr),
                    )
                }
            },
            confirmButton = { Button(onClick = { BridgeHub.resolvePairing(true) }) { Text("تأیید و اتصال") } },
            dismissButton = { TextButton(onClick = { BridgeHub.resolvePairing(false) }) { Text("رد") } },
        )
    }

    confirmRemove?.let { id ->
        AlertDialog(
            onDismissRequest = { confirmRemove = null },
            title = { Text("حذف این آیفون؟") },
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
private fun HeaderCard(running: Boolean, connected: List<String>, callState: String, error: String?, onToggle: (Boolean) -> Unit) {
    val gradient = Brush.linearGradient(listOf(Color(0xFF3D5AFE), Color(0xFF00B8D4)))
    Box(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(28.dp)).background(gradient).padding(20.dp)
    ) {
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("SIMBridge", color = Color.White, fontSize = 26.sp, fontWeight = FontWeight.Black)
                    Text("پل سیم‌کارت به آیفون", color = Color.White.copy(alpha = 0.85f), fontSize = 14.sp)
                }
                Switch(checked = running, onCheckedChange = onToggle)
            }
            Spacer(Modifier.height(18.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Dot(
                    when {
                        !running -> Color.White.copy(alpha = 0.5f)
                        connected.isNotEmpty() -> Color(0xFF69F0AE)
                        else -> Color(0xFFFFE57F)
                    }, 12.dp
                )
                HSpacer(8.dp)
                Text(
                    when {
                        !running -> "سرویس خاموش است"
                        connected.isNotEmpty() -> "متصل به " + connected.joinToString("، ")
                        else -> "روشن — در انتظار آیفون"
                    },
                    color = Color.White, fontWeight = FontWeight.SemiBold,
                )
            }
            if (callState != "idle") {
                Spacer(Modifier.height(6.dp))
                Text(if (callState == "ringing") "📞 تماس ورودی" else "📞 در حال مکالمه", color = Color.White)
            }
            if (running && error != null) {
                Spacer(Modifier.height(6.dp))
                Text("خطای شبکه: $error", color = Color(0xFFFFCDD2), fontSize = 12.sp)
            }
        }
    }
}

@Composable
private fun SimCard(sim: SimState, multi: Boolean) {
    val inService = sim.service == "in"
    Card {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SignalBars(sim.level, inService, height = 34.dp, barWidth = 8.dp)
            HSpacer(16.dp)
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(sim.carrier.ifBlank { sim.displayName }, fontWeight = FontWeight.Bold, fontSize = 17.sp)
                    if (sim.gen.isNotBlank()) { HSpacer(8.dp); Chip(sim.gen) }
                    if (sim.roaming) { HSpacer(6.dp); Chip("رومینگ", Brand.Fair) }
                }
                Text(
                    buildString {
                        if (multi) append("سیم ${sim.slot + 1} · ")
                        append(
                            when (sim.service) {
                                "in" -> "در سرویس"
                                "out" -> "بدون آنتن"
                                "emergency" -> "فقط تماس اضطراری"
                                "off" -> "رادیو خاموش"
                                else -> "در حال بررسی"
                            }
                        )
                        sim.dbm?.let { append(" · ").append("‎$it dBm") }
                        if (sim.net.isNotBlank()) append(" · ").append(sim.net)
                    },
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (multi) {
                    val roles = listOfNotNull(
                        "پیامک".takeIf { sim.isDefaultSms }, "تماس".takeIf { sim.isDefaultVoice }, "اینترنت".takeIf { sim.isDefaultData },
                    )
                    if (roles.isNotEmpty()) Text(
                        "پیش‌فرض: " + roles.joinToString("، "),
                        style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary,
                    )
                }
            }
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
            if (now >= s.expiresAt) BridgeHub.startPairing() // refresh expired code automatically
            delay(1000)
        }
    }
    val qr = remember(s.payload) { qrBitmap(s.payload) }
    val left = ((s.expiresAt - now) / 1000).coerceAtLeast(0)
    val hosts = remember(s.payload) { NetUtil.localAddresses() }

    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(
            shape = RoundedCornerShape(28.dp),
            color = MaterialTheme.colorScheme.surface,
            modifier = Modifier.padding(20.dp).fillMaxWidth(),
        ) {
            Column(Modifier.padding(22.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text("اتصال آیفون", fontWeight = FontWeight.Black, fontSize = 22.sp)
                Spacer(Modifier.height(6.dp))
                Text(
                    "در اپ SIMBridge آیفون «اسکن QR» را بزنید و این کد را اسکن کنید.",
                    textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(16.dp))
                Box(
                    Modifier.fillMaxWidth(0.85f).aspectRatio(1f).clip(RoundedCornerShape(20.dp)).background(Color.White).padding(12.dp)
                ) {
                    Image(qr, "QR", Modifier.fillMaxSize())
                }
                Spacer(Modifier.height(12.dp))
                Text("اعتبار: ${left / 60}:${(left % 60).toString().padStart(2, '0')}", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp)
                if (hosts.isEmpty()) {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "این گوشی به هیچ Wi-Fi یا هات‌اسپاتی وصل نیست؛ آیفون نمی‌تواند به آن برسد.",
                        color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center, fontSize = 13.sp,
                    )
                }
                Spacer(Modifier.height(14.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedButton(onClick = { BridgeHub.startPairing() }) { Text("کد جدید") }
                    Button(onClick = onClose) { Text("بستن") }
                }
                Spacer(Modifier.height(6.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.CheckCircle, null, tint = Brand.Good, modifier = Modifier.size(16.dp))
                    HSpacer(6.dp)
                    Text("رمزنگاری سرتاسری AES-256 · هر کد فقط یک‌بار", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}
