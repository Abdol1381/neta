package app.simbridge.android.ui

import android.graphics.Bitmap
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel

fun signalColor(level: Int, inService: Boolean): Color = when {
    !inService || level <= 0 -> Color(0xFF9AA0B4)
    level == 1 -> Brand.Poor
    level == 2 -> Brand.Fair
    else -> Brand.Good
}

/** Antenna bars, 0..4. Always drawn left-to-right like a real status bar. */
@Composable
fun SignalBars(level: Int, inService: Boolean, height: Dp = 28.dp, barWidth: Dp = 7.dp) {
    val active = signalColor(level, inService)
    val idle = MaterialTheme.colorScheme.outline
    androidx.compose.runtime.CompositionLocalProvider(
        androidx.compose.ui.platform.LocalLayoutDirection provides androidx.compose.ui.unit.LayoutDirection.Ltr
    ) { SignalBarsRow(level, inService, height, barWidth, active, idle) }
}

@Composable
private fun SignalBarsRow(level: Int, inService: Boolean, height: Dp, barWidth: Dp, active: Color, idle: Color) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(barWidth / 2),
        verticalAlignment = Alignment.Bottom,
        modifier = Modifier.height(height),
    ) {
        for (i in 1..4) {
            val c by animateColorAsState(if (inService && i <= level) active else idle, label = "bar$i")
            Box(
                Modifier
                    .width(barWidth)
                    .fillMaxHeight(i / 4f)
                    .clip(RoundedCornerShape(3.dp))
                    .background(c)
            )
        }
    }
}

@Composable
fun SectionTitle(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(start = 4.dp, top = 12.dp, bottom = 6.dp),
    )
}

@Composable
fun Card(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = MaterialTheme.shapes.large,
        color = MaterialTheme.colorScheme.surface,
        tonalElevation = 1.dp,
        shadowElevation = 1.dp,
    ) {
        Column(Modifier.padding(16.dp), content = content)
    }
}

@Composable
fun Chip(text: String, color: Color = MaterialTheme.colorScheme.primary) {
    Box(
        Modifier
            .clip(RoundedCornerShape(50))
            .background(color.copy(alpha = 0.14f))
            .padding(horizontal = 10.dp, vertical = 3.dp)
    ) {
        Text(text, color = color, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
fun Dot(color: Color, size: Dp = 10.dp) {
    Box(Modifier.size(size).clip(CircleShape).background(color))
}

fun qrBitmap(text: String, size: Int = 720): ImageBitmap {
    val hints = mapOf(EncodeHintType.MARGIN to 1, EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.CHARACTER_SET to "UTF-8")
    val m = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size, hints)
    val px = IntArray(m.width * m.height)
    for (y in 0 until m.height) for (x in 0 until m.width) {
        px[y * m.width + x] = if (m[x, y]) 0xFF0B1230.toInt() else 0xFFFFFFFF.toInt()
    }
    return Bitmap.createBitmap(px, m.width, m.height, Bitmap.Config.ARGB_8888).asImageBitmap()
}

fun relativeTime(ms: Long): String {
    if (ms <= 0) return "—"
    val d = (System.currentTimeMillis() - ms) / 1000
    return when {
        d < 60 -> "همین الان"
        d < 3600 -> "${d / 60} دقیقه پیش"
        d < 86400 -> "${d / 3600} ساعت پیش"
        else -> "${d / 86400} روز پیش"
    }
}

@Composable
fun Spacer8() = androidx.compose.foundation.layout.Spacer(Modifier.height(8.dp))

@Composable
fun HSpacer(w: Dp) = androidx.compose.foundation.layout.Spacer(Modifier.width(w))
