package sh.nikhil.conduit.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.AppearanceStore

// Shared Neon "Appearance" controls — Android mirror of the iOS
// LitterUI.NeonPalettePickerContent / NeonThemePreviewChip. Matches the
// design's NeonSettingsScreen Appearance card: a row of gradient swatches
// (each palette's accent → accent2) labelled with the active palette,
// then a glow row (caller-supplied), with a terminal-styled
// `$ conduit --theme <id>` preview chip beneath the card.

/**
 * Accent-palette swatch picker. Goes inside the "Neon Terminal"
 * [SettingsSection] in place of the old per-palette radio list.
 */
@Composable
fun NeonAccentPalettePicker(appearance: AppearanceStore) {
    val neon = LocalNeonTheme.current
    val current by appearance.neonPalette.collectAsState()
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 13.dp),
        verticalArrangement = Arrangement.spacedBy(11.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "Accent palette",
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.SemiBold,
                color = neon.text,
                fontFamily = neon.sans,
            )
            Spacer(Modifier.weight(1f))
            Text(
                current.label,
                fontFamily = neon.mono,
                fontSize = 11.5.sp,
                color = neon.accent,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(9.dp)) {
            AppearanceStore.NeonPalette.values().forEach { choice ->
                NeonPaletteSwatch(
                    choice = choice,
                    selected = choice == current,
                    onClick = { appearance.setNeonPalette(choice) },
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

@Composable
private fun NeonPaletteSwatch(
    choice: AppearanceStore.NeonPalette,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val neon = LocalNeonTheme.current
    val resolved = NeonTheme.resolve(
        palette = NeonPalette.fromId(choice.id),
        dark = neon.dark,
        glow = neon.glow,
    )
    val shape = RoundedCornerShape(11.dp)
    Column(
        modifier = modifier.clickable(onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(
            modifier = Modifier
                .size(38.dp)
                .then(
                    if (selected && neon.glow) {
                        Modifier.shadow(
                            elevation = 8.dp,
                            shape = shape,
                            ambientColor = resolved.accentBright,
                            spotColor = resolved.accentBright,
                        )
                    } else {
                        Modifier
                    },
                )
                .clip(shape)
                .background(
                    Brush.linearGradient(listOf(resolved.accentBright, resolved.accent2)),
                )
                .border(
                    width = if (selected) 2.dp else 1.dp,
                    color = if (selected) neon.text else neon.border,
                    shape = shape,
                ),
        )
        Text(
            choice.label,
            fontFamily = neon.mono,
            fontSize = 9.5.sp,
            fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
            color = if (selected) neon.text else neon.textFaint,
            maxLines = 1,
        )
    }
}

/**
 * Live `$ conduit --theme <id>` preview chip — sits beneath the Neon
 * Terminal section card and re-tints with the active palette/glow.
 */
@Composable
fun NeonThemePreviewChip(appearance: AppearanceStore) {
    val neon = LocalNeonTheme.current
    val current by appearance.neonPalette.collectAsState()
    val shape = RoundedCornerShape(12.dp)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(neon.codeBg)
            .border(1.dp, neon.borderStrong, shape)
            .padding(horizontal = 13.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text("$", fontFamily = neon.mono, fontSize = 13.sp, color = neon.accentBright)
        Text(
            "conduit --theme ${current.id}",
            fontFamily = neon.mono,
            fontSize = 12.5.sp,
            color = neon.codeText,
        )
        Spacer(Modifier.weight(1f))
        Text("preview", fontFamily = neon.mono, fontSize = 11.sp, color = neon.green)
    }
}
