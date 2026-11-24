package app.simbridge.android.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

object Brand {
    val Accent = Color(0xFF4A5CFF)
    val Good = Color(0xFF16A34A)
    val Fair = Color(0xFFF59E0B)
    val Poor = Color(0xFFEF4444)
    val Muted = Color(0xFF9AA1B2)
}

private fun style(size: Int, weight: FontWeight, line: Int) =
    TextStyle(fontFamily = FontFamily.Default, fontWeight = weight, fontSize = size.sp, lineHeight = line.sp)

private val AppTypography = Typography(
    displaySmall = style(34, FontWeight.Bold, 44),
    headlineSmall = style(22, FontWeight.Bold, 32),
    titleLarge = style(20, FontWeight.Bold, 28),
    titleMedium = style(16, FontWeight.SemiBold, 24),
    titleSmall = style(14, FontWeight.SemiBold, 20),
    bodyLarge = style(15, FontWeight.Normal, 24),
    bodyMedium = style(14, FontWeight.Normal, 22),
    bodySmall = style(12, FontWeight.Normal, 19),
    labelLarge = style(14, FontWeight.Medium, 20),
    labelMedium = style(12, FontWeight.Medium, 16),
    labelSmall = style(11, FontWeight.Medium, 16),
)

private val Light = lightColorScheme(
    primary = Brand.Accent,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFE8EBFF),
    onPrimaryContainer = Color(0xFF1B2380),
    secondaryContainer = Color(0xFFEDEFF4),
    onSecondaryContainer = Color(0xFF1C1F26),
    background = Color(0xFFF5F6F8),
    onBackground = Color(0xFF14161B),
    surface = Color.White,
    onSurface = Color(0xFF14161B),
    surfaceVariant = Color(0xFFEFF1F5),
    onSurfaceVariant = Color(0xFF6B7280),
    outline = Color(0xFFE2E5EB),
    outlineVariant = Color(0xFFECEEF2),
    error = Brand.Poor,
)

private val Dark = darkColorScheme(
    primary = Color(0xFF8C98FF),
    onPrimary = Color(0xFF101645),
    primaryContainer = Color(0xFF262D66),
    onPrimaryContainer = Color(0xFFDDE1FF),
    secondaryContainer = Color(0xFF242833),
    onSecondaryContainer = Color(0xFFE6E8EE),
    background = Color(0xFF0D0F14),
    onBackground = Color(0xFFECEEF2),
    surface = Color(0xFF171A21),
    onSurface = Color(0xFFECEEF2),
    surfaceVariant = Color(0xFF1F232C),
    onSurfaceVariant = Color(0xFF9AA1B2),
    outline = Color(0xFF2A2F3A),
    outlineVariant = Color(0xFF23272F),
    error = Color(0xFFFF6B6B),
)

@Composable
fun SimBridgeTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) Dark else Light,
        typography = AppTypography,
        shapes = Shapes(
            small = RoundedCornerShape(12.dp),
            medium = RoundedCornerShape(16.dp),
            large = RoundedCornerShape(22.dp),
            extraLarge = RoundedCornerShape(28.dp),
        ),
        content = content,
    )
}
