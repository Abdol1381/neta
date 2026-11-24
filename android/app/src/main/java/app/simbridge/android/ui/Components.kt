package app.simbridge.android.ui

import android.graphics.Bitmap
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel

private val BAR_HEIGHTS = floatArrayOf(0.34f, 0.56f, 0.78f, 1f)

fun signalColor(level: Int, inService: Boolean): Color = when {
    !inService || level <= 0 -> Brand.Muted
    level == 1 -> Brand.Poor
    level == 2 -> Brand.Fair
    else -> Brand.Good
}

/** Antenna bars 0..4, always drawn left-to-right like a status bar. */
@Composable
fun SignalBars(level: Int, inService: Boolean, height: Dp = 22.dp, barWidth: Dp = 5.dp) {
    val active = signalColor(level, inService)
    val idle = MaterialTheme.colorScheme.outline
    CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(barWidth * 0.6f),
            verticalAlignment = Alignment.Bottom,
            modifier = Modifier.height(height),
        ) {
            for (i in 1..4) {
                val c by animateColorAsState(if (inService && i <= level) active else idle, label = "bar$i")
                Box(
                    Modifier
                        .width(barWidth)
                        .fillMaxHeight(BAR_HEIGHTS[i - 1])
                        .clip(RoundedCornerShape(2.dp))
                        .background(c)
                )
            }
        }
    }
}

@Composable
fun SectionLabel(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(start = 6.dp, top = 14.dp, bottom = 8.dp),
    )
}

/** Flat card: no shadow, soft corners. */
@Composable
fun Card(modifier: Modifier = Modifier, padding: Dp = 16.dp, content: @Composable ColumnScope.() -> Unit) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = MaterialTheme.shapes.large,
        color = MaterialTheme.colorScheme.surface,
    ) {
        Column(Modifier.padding(padding), content = content)
    }
}

/** A list row with a tinted icon, title/subtitle and an optional trailing slot. */
@Composable
fun InfoRow(
    icon: ImageVector,
    title: String,
    subtitle: String? = null,
    tint: Color = MaterialTheme.colorScheme.primary,
    action: String? = null,
    onAction: (() -> Unit)? = null,
    trailing: (@Composable RowScope.() -> Unit)? = null,
) {
    // The action button sits under the text, so long titles and large font sizes never squeeze it.
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = if (action != null) Alignment.Top else Alignment.CenterVertically) {
        Box(
            Modifier.size(36.dp).clip(RoundedCornerShape(10.dp)).background(tint.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center,
        ) { Icon(icon, null, tint = tint, modifier = Modifier.size(20.dp)) }
        HSpacer(12.dp)
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurface)
            if (!subtitle.isNullOrEmpty()) {
                Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (action != null && onAction != null) {
                androidx.compose.material3.FilledTonalButton(
                    onClick = onAction,
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 6.dp),
                    modifier = Modifier.padding(top = 8.dp).heightIn(min = 36.dp),
                ) { Text(action, style = MaterialTheme.typography.labelLarge) }
            }
        }
        if (trailing != null) { HSpacer(8.dp); trailing() }
    }
}

@Composable
fun RowDivider() {
    HorizontalDivider(Modifier.padding(start = 50.dp, top = 4.dp, bottom = 4.dp), color = MaterialTheme.colorScheme.outlineVariant)
}

@Composable
fun Chip(text: String, color: Color = MaterialTheme.colorScheme.primary) {
    Box(
        Modifier
            .clip(RoundedCornerShape(50))
            .background(color.copy(alpha = 0.12f))
            .padding(horizontal = 8.dp, vertical = 1.dp)
    ) {
        Text(text, color = color, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold, maxLines = 1, softWrap = false)
    }
}

@Composable
fun Dot(color: Color, size: Dp = 8.dp) {
    Box(Modifier.size(size).clip(CircleShape).background(color))
}

fun qrBitmap(text: String, size: Int = 720): ImageBitmap {
    val hints = mapOf(
        EncodeHintType.MARGIN to 0,
        EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M,
        EncodeHintType.CHARACTER_SET to "UTF-8",
    )
    val m = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size, hints)
    val px = IntArray(m.width * m.height)
    for (y in 0 until m.height) for (x in 0 until m.width) {
        px[y * m.width + x] = if (m[x, y]) 0xFF111318.toInt() else 0xFFFFFFFF.toInt()
    }
    return Bitmap.createBitmap(px, m.width, m.height, Bitmap.Config.ARGB_8888).asImageBitmap()
}

fun relativeTime(ms: Long): String {
    if (ms <= 0) return "—"
    val d = (System.currentTimeMillis() - ms) / 1000
    return when {
        d < 60 -> "just now"
        d < 3600 -> "${d / 60} min ago"
        d < 86400 -> "${d / 3600} h ago"
        else -> "${d / 86400} d ago"
    }
}

@Composable
fun VSpacer(h: Dp) = androidx.compose.foundation.layout.Spacer(Modifier.height(h))

@Composable
fun HSpacer(w: Dp) = androidx.compose.foundation.layout.Spacer(Modifier.width(w))
