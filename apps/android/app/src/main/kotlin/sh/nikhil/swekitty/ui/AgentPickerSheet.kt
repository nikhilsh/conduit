package sh.nikhil.swekitty.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowOutward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.History
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import sh.nikhil.swekitty.RemoteDirectoryListing
import sh.nikhil.swekitty.SessionStore

/**
 * Compose mirror of `apps/ios/Sources/LitterUI/Views/LitterAgentPickerSheet.swift`.
 * Two-step new-session flow:
 *   1. Pick an agent (Claude / Codex).
 *   2. Pick a working directory — a "Recent" shortcut list plus a live
 *      browser over `store.listDirectories(path:)` (tap a folder to
 *      descend, the up button to go back). "Use this folder" cd's into
 *      the current path; "Start without a folder" preserves the old
 *      no-cwd behavior. (litter parity, task #36.)
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
    var pickedAgent by remember { mutableStateOf<String?>(null) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        val agent = pickedAgent
        if (agent == null) {
            AgentStep(
                store = store,
                headerNote = headerNote,
                canIssue = harness.canIssueCommands,
                onPick = { pickedAgent = it },
            )
        } else {
            DirectoryStep(
                store = store,
                onCreate = { cwd ->
                    store.createSession(assistant = agent, startupCwd = cwd)
                    onDismiss()
                },
            )
        }
    }
}

@Composable
private fun AgentStep(
    store: SessionStore,
    headerNote: String?,
    canIssue: Boolean,
    onPick: (String) -> Unit,
) {
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
            enabled = canIssue,
            onTap = { onPick("claude") },
        )
        AgentTile(
            assistant = "codex",
            label = "Codex",
            subtitle = "OpenAI — green accent, codex",
            tint = SweKittyTheme.codexAccent(),
            enabled = canIssue,
            onTap = { onPick("codex") },
        )
        if (!canIssue) {
            Text(
                "Connect to a harness first — open Settings to pair.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Spacer(Modifier.height(8.dp))
    }
}

@Composable
private fun DirectoryStep(
    store: SessionStore,
    onCreate: (String?) -> Unit,
) {
    val recent by store.recentDirectories.collectAsState()
    var currentPath by remember { mutableStateOf<String?>(null) }
    var listing by remember { mutableStateOf<RemoteDirectoryListing?>(null) }
    var isLoading by remember { mutableStateOf(false) }
    var loadError by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(currentPath) {
        isLoading = true
        loadError = null
        runCatching { store.listDirectories(currentPath) }
            .onSuccess { listing = it }
            .onFailure { loadError = "Couldn't list this folder." }
        isLoading = false
    }

    // Bound the sheet height so the scrollable browse list takes the
    // available space and the action bar stays pinned to the bottom.
    Column(modifier = Modifier.fillMaxWidth().fillMaxHeight(0.92f)) {
        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                "Working directory",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )

            if (recent.isNotEmpty()) {
                SectionLabel("Recent")
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    recent.forEach { path ->
                        RecentRow(path = path, onTap = { onCreate(path) })
                    }
                }
            }

            SectionLabel("Browse")
            Breadcrumb(
                listing = listing,
                onUp = { parent -> currentPath = parent },
            )

            when {
                isLoading -> Box(
                    modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
                    contentAlignment = Alignment.Center,
                ) { CircularProgressIndicator(modifier = Modifier.size(22.dp)) }

                loadError != null -> Text(
                    loadError!!,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 16.dp),
                )

                else -> {
                    val folders = listing?.entries.orEmpty().filter { it.isDir }
                    if (folders.isEmpty()) {
                        Text(
                            "No sub-folders here.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.fillMaxWidth().padding(vertical = 16.dp),
                        )
                    } else {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            folders.forEach { entry ->
                                FolderRow(name = entry.name, onTap = { currentPath = entry.path })
                            }
                        }
                    }
                }
            }
        }

        Column(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Button(
                onClick = { onCreate(listing?.path) },
                enabled = listing != null,
                shape = RoundedCornerShape(SweKittyTheme.cardCornerRadiusDp.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Filled.CheckCircle, null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("Use this folder", fontWeight = FontWeight.SemiBold)
            }
            TextButton(onClick = { onCreate(null) }) {
                Text(
                    "Start without a folder",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text.uppercase(),
        style = MaterialTheme.typography.labelSmall,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
private fun Breadcrumb(
    listing: RemoteDirectoryListing?,
    onUp: (String) -> Unit,
) {
    val canGoUp = listing != null &&
        listing.parent.isNotEmpty() &&
        listing.parent != listing.path
    Row(verticalAlignment = Alignment.CenterVertically) {
        Surface(
            shape = CircleShape,
            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = if (canGoUp) 0.45f else 0.18f),
            modifier = Modifier
                .size(30.dp)
                .clip(CircleShape)
                .clickable(enabled = canGoUp) { listing?.parent?.let(onUp) },
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    Icons.Filled.ArrowUpward,
                    contentDescription = "Up one folder",
                    modifier = Modifier.size(16.dp),
                    tint = if (canGoUp) MaterialTheme.colorScheme.primary
                    else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Spacer(Modifier.width(8.dp))
        Text(
            listing?.path ?: "…",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun RecentRow(path: String, onTap: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(SweKittyTheme.cardCornerRadiusDp.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(SweKittyTheme.cardCornerRadiusDp.dp))
            .clickable(onClick = onTap),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.History, null, modifier = Modifier.size(20.dp), tint = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    displayName(path),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    path,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Icon(Icons.Filled.ArrowOutward, null, modifier = Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun FolderRow(name: String, onTap: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(SweKittyTheme.cardCornerRadiusDp.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(SweKittyTheme.cardCornerRadiusDp.dp))
            .clickable(onClick = onTap),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.Folder, null, modifier = Modifier.size(20.dp), tint = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.width(12.dp))
            Text(name, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            Icon(Icons.Filled.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

private fun displayName(path: String): String {
    val trimmed = path.trimEnd('/')
    val last = trimmed.substringAfterLast('/', "")
    return last.ifEmpty { trimmed }
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
