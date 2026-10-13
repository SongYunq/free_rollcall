package cn.freerollcall.android.ui

import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

val Secondary = Color(0xFF737373)
val Subtle = Color(0xFFF5F5F5)
val Line = Color(0xFFEAEAEA)
val Danger = Color(0xFFC62828)
private val Scheme = lightColorScheme(primary = Color.Black, onPrimary = Color.White,
    secondary = Color.Black, onSecondary = Color.White, background = Color.White, onBackground = Color.Black,
    surface = Color.White, onSurface = Color.Black, surfaceVariant = Subtle, onSurfaceVariant = Secondary,
    outline = Line, error = Danger)
@Composable fun RollcallTheme(content: @Composable () -> Unit) { MaterialTheme(colorScheme = Scheme, content = content) }
