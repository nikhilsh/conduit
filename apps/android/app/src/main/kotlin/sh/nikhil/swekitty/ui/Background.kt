package sh.nikhil.swekitty.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/**
 * Compose mirror of `apps/ios/Sources/Theme/Background.swift`:
 * adaptive base + two radial accent washes so the [glassSurface]
 * overlays have something to refract against. Apply once at the root
 * of each screen, beneath the rest of the content.
 */
@Composable
fun GlassAppBackground(modifier: Modifier = Modifier) {
    val base = SweKittyTheme.background()
    val accent = SweKittyTheme.accentStrong()
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(
                brush = Brush.linearGradient(
                    colors = listOf(
                        base,
                        base.copy(alpha = 0.94f),
                        base.copy(alpha = 0.97f),
                    ),
                ),
            ),
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            // Pools of the copper brand accent positioned *behind the button
            // clusters* — top (header icons) and bottom-center (action bar) —
            // so the glass surfaces over them have warm colour to refract.
            // Kept low-opacity so the dark mood is preserved.
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(accent.copy(alpha = 0.20f), Color.Transparent),
                    center = Offset(size.width * 0.12f, size.height * 0.07f),
                    radius = size.minDimension * 0.60f,
                ),
                center = Offset(size.width * 0.12f, size.height * 0.07f),
                radius = size.minDimension * 0.60f,
            )
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(accent.copy(alpha = 0.16f), Color.Transparent),
                    center = Offset(size.width * 0.5f, size.height * 0.99f),
                    radius = size.minDimension * 0.65f,
                ),
                center = Offset(size.width * 0.5f, size.height * 0.99f),
                radius = size.minDimension * 0.65f,
            )
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(accent.copy(alpha = 0.08f), Color.Transparent),
                    center = Offset(size.width * 0.92f, size.height * 0.12f),
                    radius = size.minDimension * 0.42f,
                ),
                center = Offset(size.width * 0.92f, size.height * 0.12f),
                radius = size.minDimension * 0.42f,
            )
        }
    }
}
