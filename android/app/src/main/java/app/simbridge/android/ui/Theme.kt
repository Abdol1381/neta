package app.simbridge.android.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

object Brand {
    val Indigo = Color(0xFF3D5AFE)
    val Cyan = Color(0xFF00B8D4)
    val Good = Color(0xFF00C853)
    val Fair = Color(0xFFFFAB00)
    val Poor = Color(0xFFFF5252)
}

private val Light = lightColorScheme(
    primary = Brand.Indigo,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFE3E7FF),
    onPrimaryContainer = Color(0xFF0B1A7A),
    secondary = Brand.Cyan,
    background = Color(0xFFF4F6FB),
    surface = Color.White,
    surfaceVariant = Color(0xFFEEF1F8),
    onSurfaceVariant = Color(0xFF5B6275),
    outline = Color(0xFFD5DAE6),
    error = Color(0xFFE53935),
)

private val Dark = darkColorScheme(
    primary = Color(0xFF8C9EFF),
    onPrimary = Color(0xFF0B1A7A),
    primaryContainer = Color(0xFF26306B),
    onPrimaryContainer = Color(0xFFDDE2FF),
    secondary = Brand.Cyan,
    background = Color(0xFF0E1220),
    surface = Color(0xFF171C2E),
    surfaceVariant = Color(0xFF20263B),
    onSurfaceVariant = Color(0xFFA6AEC4),
    outline = Color(0xFF2E3550),
    error = Color(0xFFFF6E6E),
)

@Composable
fun SimBridgeTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) Dark else Light,
        shapes = Shapes(
            small = RoundedCornerShape(10.dp),
            medium = RoundedCornerShape(16.dp),
            large = RoundedCornerShape(24.dp),
        ),
        content = content,
    )
}
