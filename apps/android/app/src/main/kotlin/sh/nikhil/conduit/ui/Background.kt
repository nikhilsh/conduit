package sh.nikhil.conduit.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

/**
 * "Neon Terminal" app canvas. Paints the resolved [NeonTheme.appBg]
 * radial-gradient brush and overlays a faint [NeonGrid] of `neon.grid`
 * lines. Apply once at the root of each screen, beneath the content.
 *
 * Same call sites / signature as before — this is a reskin of the old
 * glass wash to the neon canvas; [LocalNeonTheme] drives the colours.
 */
@Composable
fun GlassAppBackground(modifier: Modifier = Modifier) {
    val neon = LocalNeonTheme.current
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(brush = neon.appBg),
    ) {
        NeonGrid(color = neon.grid)
    }
}
