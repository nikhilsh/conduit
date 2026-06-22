package sh.nikhil.conduit.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.NetworkCheck
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Science
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.LocalAppearanceStore
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry

/**
 * Staff-only Debug menu. Not reachable from regular Settings UI; the
 * entry-point is a 7-tap unlock on the "Conduit vX" row in Settings > About.
 *
 * Contains:
 *  - SSH-tunnel transport toggle (default ON; flip OFF to fall back to the
 *    legacy public path for one release).
 *  - Subagent panel toggle (show Agents roster in session Info).
 *
 * concurrentMultiBox is not yet implemented on Android; omitted here.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DebugMenuScreen(store: SessionStore, onDismiss: () -> Unit) {
    val neon = LocalNeonTheme.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val appearance = LocalAppearanceStore.current

    val sshTunnelEnabled by store.debugSshTunnelEnabled.collectAsState()
    val showSubagentPanel by appearance.showSubagentPanel.collectAsState()
    val experimentalNativeTerminal by appearance.experimentalNativeTerminal.collectAsState()
    val commandRunBlock by appearance.commandRunBlock.collectAsState()

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = neon.surfaceSolid,
        shape = RoundedCornerShape(topStart = 26.dp, topEnd = 26.dp),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp)
                .verticalScroll(rememberScrollState()),
        ) {
            Text(
                "DEBUG",
                style = MaterialTheme.typography.labelSmall,
                fontFamily = neon.mono,
                fontWeight = FontWeight.Bold,
                color = neon.red,
                modifier = Modifier.padding(start = 4.dp, bottom = 8.dp),
            )

            SettingsSection("Transport") {
                ToggleRow(
                    icon = Icons.Filled.NetworkCheck,
                    title = "SSH tunnel",
                    subtitle = "Route SSH-paired boxes through the held tunnel (default ON). Off = legacy public path. Takes effect on next connect.",
                    isOn = sshTunnelEnabled,
                    onChange = { enabled ->
                        Telemetry.breadcrumb(
                            "debug_menu",
                            "ssh_tunnel toggled",
                            mapOf("enabled" to enabled.toString()),
                        )
                        store.setDebugSshTunnelEnabled(enabled)
                    },
                )
            }

            Spacer(Modifier.height(18.dp))

            // Native-terminal toggle, moved here from the Appearance section to
            // match iOS Settings (iOS keeps this off the main Appearance card).
            SettingsSection("Terminal") {
                ToggleRow(
                    icon = Icons.Filled.Science,
                    title = "Native terminal",
                    subtitle = "On by default. Turn off to use the legacy web terminal.",
                    isOn = experimentalNativeTerminal,
                    onChange = { enabled ->
                        Telemetry.breadcrumb(
                            "debug_menu",
                            "native_terminal toggled",
                            mapOf("enabled" to enabled.toString()),
                        )
                        appearance.setExperimentalNativeTerminal(enabled)
                    },
                )
            }

            Spacer(Modifier.height(18.dp))

            SettingsSection("Session Info") {
                ToggleRow(
                    icon = Icons.Filled.Person,
                    title = "Subagent panel",
                    subtitle = "Show Agents roster in session Info screen",
                    isOn = showSubagentPanel,
                    onChange = { enabled ->
                        Telemetry.breadcrumb(
                            "debug_menu",
                            "subagent_panel toggled",
                            mapOf("enabled" to enabled.toString()),
                        )
                        appearance.setShowSubagentPanel(enabled)
                    },
                )
            }

            Spacer(Modifier.height(18.dp))

            // §10 / §10b command-run Mono block (flag id chat.commandRunBlock).
            SettingsSection("Chat Labs") {
                ToggleRow(
                    icon = Icons.Filled.Code,
                    title = "Command-run Mono block",
                    subtitle = "Render tool clusters as a flat codeBg Mono surface (§10/§10b). Default OFF. Needs on-device verification.",
                    isOn = commandRunBlock,
                    onChange = { enabled ->
                        Telemetry.breadcrumb(
                            "debug_menu",
                            "command_run_block toggled",
                            mapOf("enabled" to enabled.toString()),
                        )
                        appearance.setCommandRunBlock(enabled)
                    },
                )
            }

            Spacer(Modifier.height(18.dp))

            SettingsSection("Notes") {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                ) {
                    Text(
                        "concurrentMultiBox: not yet implemented on Android.",
                        fontFamily = neon.mono,
                        fontSize = 10.5.sp,
                        color = neon.textFaint,
                    )
                }
            }

            Spacer(Modifier.height(24.dp))
        }
    }
}
