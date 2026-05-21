package sh.nikhil.swekitty.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import sh.nikhil.swekitty.SessionStore

/**
 * Compose mirror of `apps/ios/Sources/Views/AgentPickerSheet.swift`.
 * Two big tap targets: Claude (copper) and Codex (green). Shows
 * automatically after a fresh pairing so the user lands on agent
 * choice without hunting the toolbar.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AgentPickerSheet(
    store: SessionStore,
    headerNote: String? = null,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val harness by store.harness.collectAsState()

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                "New session",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            if (!headerNote.isNullOrBlank()) {
                Surface(
                    shape = RoundedCornerShape(SweKittyTheme.cardCornerRadiusDp.dp),
                    color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
                ) {
                    Column(modifier = Modifier.fillMaxWidth().padding(14.dp)) {
                        Text(
                            "Paired with",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(
                            headerNote,
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.SemiBold,
                        )
                    }
                }
            }
            AgentTile(
                assistant = "claude",
                label = "Claude",
                subtitle = "Anthropic — copper accent, headstrong",
                tint = SweKittyTheme.claudeAccent(),
                enabled = harness.canIssueCommands,
                onTap = {
                    store.createSession("claude")
                    onDismiss()
                },
            )
            AgentTile(
                assistant = "codex",
                label = "Codex",
                subtitle = "OpenAI — green accent, codex",
                tint = SweKittyTheme.codexAccent(),
                enabled = harness.canIssueCommands,
                onTap = {
                    store.createSession("codex")
                    onDismiss()
                },
            )
            if (!harness.canIssueCommands) {
                Text(
                    "Connect to a harness first — open Settings to pair.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Spacer(Modifier.height(8.dp))
        }
    }
}

@Composable
private fun AgentTile(
    assistant: String,
    label: String,
    subtitle: String,
    tint: Color,
    enabled: Boolean,
    onTap: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(SweKittyTheme.cardCornerRadiusDp.dp),
        color = tint.copy(alpha = if (enabled) 0.16f else 0.06f),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(SweKittyTheme.cardCornerRadiusDp.dp))
            .clickable(enabled = enabled, onClick = onTap),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            AgentAvatar(assistant = assistant, size = 44.dp)
            Spacer(Modifier.width(14.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(label, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Icon(Icons.Filled.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

