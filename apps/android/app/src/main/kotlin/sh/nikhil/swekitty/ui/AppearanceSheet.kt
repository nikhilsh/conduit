package sh.nikhil.swekitty.ui

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
import androidx.compose.material.icons.filled.Palette
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
import sh.nikhil.swekitty.AppearanceStore

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
    val bodyPointSize by appearance.bodyPointSize.collectAsState()
    val neonPalette by appearance.neonPalette.collectAsState()
    val neonGlow by appearance.neonGlow.collectAsState()

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

            // Neon Terminal theme controls — palette picker + glow
            // toggle. Mode is already handled by the Theme section above
            // (Neon reuses themeMode for its light/dark resolution).
            // Mirrors the iOS LitterAppearanceSheet "Neon Terminal"
            // section.
            SettingsSection("Neon Terminal") {
                AppearanceStore.NeonPalette.values().forEachIndexed { idx, choice ->
                    PickerRow(
                        icon = Icons.Filled.Palette,
                        title = choice.label,
                        isSelected = neonPalette == choice,
                        onClick = { appearance.setNeonPalette(choice) },
                    )
                    if (idx < AppearanceStore.NeonPalette.values().lastIndex) {
                        HorizontalDivider(
                            modifier = Modifier.padding(horizontal = 16.dp),
                            color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f),
                        )
                    }
                }
                HorizontalDivider(
                    modifier = Modifier.padding(horizontal = 16.dp),
                    color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f),
                )
                ToggleRow(
                    icon = Icons.Filled.Star,
                    title = "Glow",
                    subtitle = "Neon glow on cards & text",
                    isOn = neonGlow,
                    onChange = { appearance.setNeonGlow(it) },
                )
            }

            SettingsSection("Chat Body Font") {
                AppearanceStore.FontFamily.values().forEachIndexed { idx, choice ->
                    PickerRow(
                        icon = if (choice == AppearanceStore.FontFamily.Monospaced) Icons.Filled.Code else Icons.Filled.TextFields,
                        title = choice.label,
                        isSelected = fontFamily == choice,
                        onClick = { appearance.setFontFamily(choice) },
                    )
                    if (idx < AppearanceStore.FontFamily.values().lastIndex) {
                        HorizontalDivider(
                            modifier = Modifier.padding(horizontal = 16.dp),
                            color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f),
                        )
                    }
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
                            thumbColor = SweKittyTheme.accentStrong(),
                            activeTrackColor = SweKittyTheme.accentStrong(),
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
