package sh.nikhil.conduit.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Brightness6
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.DarkMode
import androidx.compose.material.icons.filled.LightMode
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.TextFields
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import sh.nikhil.conduit.AppearanceStore

/**
 * Modal sheet for the Theme + Font controls, opened from
 * Settings → Appearance → Theme. Mirrors `AppearanceSheet.swift`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppearanceSheet(appearance: AppearanceStore, onDismiss: () -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val themeMode by appearance.themeMode.collectAsState()
    val fontFamily by appearance.fontFamily.collectAsState()
    val terminalFont by appearance.terminalFont.collectAsState()
    val bodyPointSize by appearance.bodyPointSize.collectAsState()
    val neonGlow by appearance.neonGlow.collectAsState()
    val neon = LocalNeonTheme.current

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(22.dp),
        ) {
            Text(
                "Appearance",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.SemiBold,
            )

            SettingsSection("Theme") {
                AppearanceStore.ThemeMode.values().forEachIndexed { idx, choice ->
                    PickerRow(
                        icon = iconFor(choice),
                        title = choice.label,
                        isSelected = themeMode == choice,
                        onClick = { appearance.setThemeMode(choice) },
                    )
                    if (idx < AppearanceStore.ThemeMode.values().lastIndex) {
                        HorizontalDivider(
                            modifier = Modifier.padding(horizontal = 16.dp),
                            color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f),
                        )
                    }
                }
            }

            // Neon Terminal theme controls — accent-palette swatch picker
            // + glow toggle, then a live preview chip. Mode is handled by
            // the Theme section above (Neon reuses themeMode for its
            // light/dark resolution). Mirrors the iOS
            // ConduitUI.NeonPalettePickerContent + NeonThemePreviewChip.
            SettingsSection("Neon Terminal") {
                NeonAccentPalettePicker(appearance)
                HorizontalDivider(
                    modifier = Modifier.padding(horizontal = 16.dp),
                    color = neon.border,
                )
                ToggleRow(
                    icon = Icons.Filled.Star,
                    title = "Glow & scanlines",
                    subtitle = if (neon.dark) "neon halos · on dark" else "neon halos · dimmed in light",
                    isOn = neonGlow,
                    onChange = { appearance.setNeonGlow(it) },
                )
            }
            NeonThemePreviewChip(appearance)

            // Chat font — type-forward preview-card strip (handoff Part A),
            // shared with the full Settings screen via [ChatFontStrip].
            SettingsSection("Chat font") {
                Column(modifier = Modifier.padding(horizontal = 14.dp, vertical = 13.dp)) {
                    ChatFontStrip(current = fontFamily, onSelect = { appearance.setFontFamily(it) })
                }
            }

            // Terminal font face — separate from the chat pairing above
            // (mirrors iOS GhosttyFont). Shares [TerminalFontStrip] with the
            // full Settings screen.
            SettingsSection("Terminal font") {
                Column(modifier = Modifier.padding(horizontal = 14.dp, vertical = 13.dp)) {
                    TerminalFontStrip(current = terminalFont, onSelect = { appearance.setTerminalFont(it) })
                }
            }

            // Body font-size slider — matches iOS #239's AppearanceSheet
            // so the Session Info → Appearance entry point carries the
            // full theme / font / font-size trio (not just theme + font).
            // Backed by the same AppearanceStore.bodyPointSize the
            // Settings slider drives.
            SettingsSection("Font Size") {
                Column(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    androidx.compose.foundation.layout.Row(
                        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                    ) {
                        Text(
                            "Body",
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                        Spacer(Modifier.weight(1f))
                        Text(
                            "${bodyPointSize.toInt()}pt",
                            style = MaterialTheme.typography.labelLarge,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                        )
                    }
                    androidx.compose.material3.Slider(
                        value = bodyPointSize,
                        onValueChange = { appearance.setBodyPointSize(it) },
                        valueRange = AppearanceStore.BODY_POINT_SIZE_RANGE,
                        steps = (AppearanceStore.BODY_POINT_SIZE_RANGE.endInclusive
                            - AppearanceStore.BODY_POINT_SIZE_RANGE.start).toInt() - 1,
                        colors = androidx.compose.material3.SliderDefaults.colors(
                            thumbColor = neon.accent,
                            activeTrackColor = neon.accent,
                        ),
                    )
                    Text(
                        "The quick brown fox jumps over the lazy dog.",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontSize = androidx.compose.ui.unit.TextUnit(
                            bodyPointSize,
                            androidx.compose.ui.unit.TextUnitType.Sp,
                        ),
                    )
                }
            }

            Spacer(Modifier.height(12.dp))
        }
    }
}

private fun iconFor(mode: AppearanceStore.ThemeMode): ImageVector = when (mode) {
    AppearanceStore.ThemeMode.System -> Icons.Filled.Brightness6
    AppearanceStore.ThemeMode.Light -> Icons.Filled.LightMode
    AppearanceStore.ThemeMode.Dark -> Icons.Filled.DarkMode
}
