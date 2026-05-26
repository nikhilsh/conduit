package sh.nikhil.swekitty.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CallSplit
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import sh.nikhil.swekitty.LocalAppearanceStore
import sh.nikhil.swekitty.SessionStore
import uniffi.swe_kitty_core.ConversationItem
import uniffi.swe_kitty_core.PreviewInfo
import uniffi.swe_kitty_core.ProjectSession

/**
 * Session "Info" screen — opened from the ⓘ button in the chat header.
 * Hero + action row (Appearance / Fork / Rename) + stats grid.
 * Mirrors `apps/ios/Sources/Views/SessionInfoView.swift`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionInfoScreen(store: SessionStore, session: ProjectSession, onDismiss: () -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val statuses by store.statusBySession.collectAsState()
    val conversationLog by store.conversationLog.collectAsState()
    val displayNames by store.displayNames.collectAsState()
    val status = statuses[session.id]
    val events = conversationLog[session.id].orEmpty()
    val stats = remember(events) { SessionStats.compute(events) }
    val name = displayNames[session.id] ?: session.name

    var showRename by remember { mutableStateOf(false) }
    var showFork by remember { mutableStateOf(false) }
    var showAppearance by remember { mutableStateOf(false) }
    var renameDraft by remember { mutableStateOf(name) }
    val appearance = LocalAppearanceStore.current

    // Fork chooser state: default the effort to the session's current
    // effort (status delta wins over the snapshot), falling back to a
    // sensible default for the agent. The model field stays blank = keep
    // the current model.
    val effortOptions = remember(session.assistant) { forkEffortOptions(session.assistant) }
    val currentEffort = status?.reasoningEffort ?: session.reasoningEffort
    var forkEffort by remember(showFork) {
        mutableStateOf(
            currentEffort?.takeIf { effortOptions.contains(it) }
                ?: if (effortOptions.contains("medium")) "medium" else effortOptions.first(),
        )
    }
    var forkModel by remember(showFork) { mutableStateOf("") }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            // Hero
            Surface(
                shape = RoundedCornerShape(SweKittyTheme.cardCornerRadiusDp.dp),
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 14.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        AgentAvatar(assistant = session.assistant, size = 32.dp)
                        Spacer(Modifier.width(10.dp))
                        HealthDot(status?.health ?: "unknown")
                        Spacer(Modifier.width(10.dp))
                        Column {
                            Text(
                                name,
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold,
                            )
                            status?.phase?.takeIf { it.isNotBlank() }?.let { phase ->
                                Text(
                                    phase,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        AgentPill(session.assistant, tint = SweKittyTheme.accent(forAgent = session.assistant))
                        session.branch?.takeIf { it.isNotBlank() }?.let { AgentPill(it, tint = MaterialTheme.colorScheme.surfaceVariant) }
                    }
                    Text(
                        session.id,
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            // Action row
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                ActionTile(Icons.Default.Palette, "Appearance", Modifier.weight(1f)) { showAppearance = true }
                ActionTile(Icons.Default.CallSplit, "Fork", Modifier.weight(1f)) { showFork = true }
                ActionTile(Icons.Default.Edit, "Rename", Modifier.weight(1f)) {
                    renameDraft = name
                    showRename = true
                }
            }

            // Stats grid
            Column {
                Text(
                    "STATS",
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(bottom = 6.dp, start = 4.dp),
                )
                Surface(
                    shape = RoundedCornerShape(SweKittyTheme.cardCornerRadiusDp.dp),
                    color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(modifier = Modifier.padding(14.dp)) {
                        Row(horizontalArrangement = Arrangement.SpaceEvenly, modifier = Modifier.fillMaxWidth()) {
                            StatTile(value = "${stats.messages}", label = "MESSAGES")
                            StatTile(value = "${stats.turns}", label = "TURNS")
                            StatTile(value = "${stats.commands}", label = "COMMANDS")
                        }
                        Spacer(Modifier.height(14.dp))
                        Row(horizontalArrangement = Arrangement.SpaceEvenly, modifier = Modifier.fillMaxWidth()) {
                            StatTile(value = "${stats.filesChanged}", label = "FILES")
                            StatTile(value = "${stats.mcpCalls}", label = "MCP")
                            StatTile(value = stats.execTimeLabel, label = "EXEC TIME")
                        }
                    }
                }
            }

            session.preview?.let { preview ->
                Column {
                    Text(
                        "SERVER USAGE",
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = FontFamily.Monospace,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(bottom = 6.dp, start = 4.dp),
                    )
                    Surface(
                        shape = RoundedCornerShape(SweKittyTheme.cardCornerRadiusDp.dp),
                        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Column(modifier = Modifier.padding(14.dp)) {
                            Text("Preview · port ${preview.port}", style = MaterialTheme.typography.bodyMedium)
                            Text(
                                preview.url,
                                style = MaterialTheme.typography.bodySmall,
                                fontFamily = FontFamily.Monospace,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }

            Spacer(Modifier.height(12.dp))
        }
    }

    if (showRename) {
        AlertDialog(
            onDismissRequest = { showRename = false },
            title = { Text("Rename session") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        "Choose a label for this session. The broker name stays the same — this rename is local to your device.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Surface(
                        shape = RoundedCornerShape(12.dp),
                        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f),
                    ) {
                        BasicTextField(
                            value = renameDraft,
                            onValueChange = { renameDraft = it },
                            textStyle = MaterialTheme.typography.bodyMedium.copy(
                                color = MaterialTheme.colorScheme.onSurface,
                            ),
                            modifier = Modifier.padding(12.dp).fillMaxWidth(),
                        )
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    store.renameSession(session.id, renameDraft)
                    showRename = false
                }) { Text("Save") }
            },
            dismissButton = {
                TextButton(onClick = { showRename = false }) { Text("Cancel") }
            },
        )
    }

    if (showFork) {
        AlertDialog(
            onDismissRequest = { showFork = false },
            title = { Text("Fork session") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        "Creates a new session from this one, seeded with a hand-off note. Reasoning effort can't change mid-session — pick the new effort (and optionally a model) for the fork.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        "REASONING EFFORT",
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        effortOptions.forEach { level ->
                            FilterChip(
                                selected = forkEffort == level,
                                onClick = { forkEffort = level },
                                label = { Text(level.replaceFirstChar { it.uppercase() }) },
                            )
                        }
                    }
                    Text(
                        "MODEL (OPTIONAL)",
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Surface(
                        shape = RoundedCornerShape(12.dp),
                        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f),
                    ) {
                        BasicTextField(
                            value = forkModel,
                            onValueChange = { forkModel = it },
                            singleLine = true,
                            textStyle = MaterialTheme.typography.bodyMedium.copy(
                                color = MaterialTheme.colorScheme.onSurface,
                            ),
                            decorationBox = { inner ->
                                if (forkModel.isEmpty()) {
                                    Text(
                                        forkModelPlaceholder(session.assistant),
                                        style = MaterialTheme.typography.bodyMedium,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                                inner()
                            },
                            modifier = Modifier.padding(12.dp).fillMaxWidth(),
                        )
                    }
                    Text(
                        "Leave blank to keep the current model.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    val model = forkModel.trim().ifEmpty { null }
                    store.forkSession(session.id, reasoningEffort = forkEffort, model = model)
                    showFork = false
                    onDismiss()
                }) { Text("Fork") }
            },
            dismissButton = {
                TextButton(onClick = { showFork = false }) { Text("Cancel") }
            },
        )
    }

    if (showAppearance) {
        AppearanceSheet(appearance = appearance, onDismiss = { showAppearance = false })
    }
}

@Composable
private fun AgentPill(label: String, tint: androidx.compose.ui.graphics.Color) {
    Surface(
        shape = RoundedCornerShape(50),
        color = tint.copy(alpha = 0.30f),
    ) {
        Text(
            label,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

@Composable
private fun ActionTile(icon: ImageVector, title: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(SweKittyTheme.cardCornerRadiusDp.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
        modifier = modifier.clickable(onClick = onClick),
    ) {
        Column(
            modifier = Modifier.padding(vertical = 16.dp).fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(icon, contentDescription = null, tint = SweKittyTheme.accentStrong())
            Text(title, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun StatTile(value: String, label: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            value,
            style = MaterialTheme.typography.titleLarge.copy(
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Bold,
                color = SweKittyTheme.accentStrong(),
            ),
        )
        Text(
            label,
            style = MaterialTheme.typography.labelSmall,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/**
 * Per-assistant reasoning-effort options offered in the fork chooser.
 * Mirrors the broker's validated levels
 * (`broker/internal/session/override.go`) so the UI never offers a level
 * the agent would silently drop.
 */
internal fun forkEffortOptions(assistant: String): List<String> = when (assistant) {
    "claude" -> listOf("low", "medium", "high", "xhigh", "max")
    "codex" -> listOf("low", "medium", "high")
    else -> listOf("low", "medium", "high")
}

/** Placeholder model alias hint for the fork chooser's model field. */
internal fun forkModelPlaceholder(assistant: String): String = when (assistant) {
    "claude" -> "opus"
    "codex" -> "gpt-5-codex"
    else -> "model"
}

/**
 * Client-side stats derived from the conversation log. Mirrors
 * `apps/ios/Sources/Views/SessionInfoView.swift`'s `SessionStats`.
 */
data class SessionStats(
    val messages: Int,
    val turns: Int,
    val commands: Int,
    val filesChanged: Int,
    val mcpCalls: Int,
    val execTimeMs: ULong,
) {
    val execTimeLabel: String
        get() {
            if (execTimeMs == 0UL) return "—"
            val seconds = execTimeMs.toLong() / 1000.0
            if (seconds < 60) return "%.1fs".format(seconds)
            val minutes = seconds / 60.0
            if (minutes < 60) return "%.1fm".format(minutes)
            val hours = minutes / 60.0
            return "%.1fh".format(hours)
        }

    companion object {
        fun compute(events: List<ConversationItem>): SessionStats {
            var turns = 0
            var commands = 0
            var mcp = 0
            val files = mutableSetOf<String>()
            var execTime: ULong = 0UL
            events.forEach { ev ->
                if (ev.role.lowercase() == "user") turns++
                if (ev.kind == "tool") {
                    ev.command?.takeIf { it.isNotBlank() }?.let { commands++ }
                    ev.toolName?.takeIf { it.lowercase().contains("mcp") }?.let { mcp++ }
                }
                ev.durationMs?.let { execTime += it }
                ev.files.forEach { f -> files.add(f.path) }
            }
            return SessionStats(
                messages = events.size,
                turns = turns,
                commands = commands,
                filesChanged = files.size,
                mcpCalls = mcp,
                execTimeMs = execTime,
            )
        }
    }
}
