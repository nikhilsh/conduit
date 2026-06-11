package sh.nikhil.conduit.ui

import android.content.Intent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CallSplit
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.outlined.UnfoldLess
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt
import sh.nikhil.conduit.SessionLifecycle
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.descriptorFor
import uniffi.conduit_core.ConversationItem
import uniffi.conduit_core.ProjectSession
import uniffi.conduit_core.SessionStatus

/**
 * Session "Info" sheet — opened from the ⓘ button in the chat header.
 * Conduit redesign IA (handoff §A.1, images 01/02), mirror of iOS
 * `ConduitUI.SessionInfoView`:
 *
 *   1. Identity — agent avatar, real name (inline rename), agent · branch,
 *      live/idle badge.
 *   2. Usage    — context ring + `used / window` + agent line + a single
 *      mono token line (↓ in ↑ out ⛁ cache).
 *   3. Limits   — this session's agent only, 5h + weekly windows.
 *   4. Activity — one compact line; degrades to "Just started …" on a
 *      fresh session (no grid of zeros).
 *   5. Details  — working dir / box / started.
 *   6. Actions  — Fork · Export · End (End destructive/red).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionInfoScreen(store: SessionStore, session: ProjectSession, onDismiss: () -> Unit, embedded: Boolean = false) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val statuses by store.statusBySession.collectAsState()
    val conversationLog by store.conversationLog.collectAsState()
    val displayNames by store.displayNames.collectAsState()
    val endpoint by store.endpoint.collectAsState()
    val status = statuses[session.id]
    val events = conversationLog[session.id].orEmpty()
    val stats = remember(events) { SessionStats.compute(events) }
    val name = displayNames[session.id] ?: session.name
    val context = LocalContext.current
    val neon = LocalNeonTheme.current

    var showRename by remember { mutableStateOf(false) }
    var showFork by remember { mutableStateOf(false) }
    var showEndConfirm by remember { mutableStateOf(false) }
    var renameDraft by remember { mutableStateOf(name) }

    // Descriptor-driven capability flags (WS-3.2). Collected unconditionally
    // before any conditional state so Compose doesn't see composable call
    // count changes. Falls back to static claude/codex behavior when the
    // broker is old (no agents map).
    val agentDescriptorsMap by store.agentDescriptors.collectAsState()

    val agent = status?.assistant?.takeIf { it.isNotBlank() } ?: session.assistant
    val tint = neonAgentColor(agent, neon)
    val agentDescriptor = descriptorFor(agent, agentDescriptorsMap)

    // Fork chooser state. Model + effort options come from the broker's
    // live per-agent catalog when available (per-model effort ranges, live
    // display names) and fall back to the static lists otherwise.
    val catalogs by store.modelCatalog.collectAsState()
    val catalog = catalogs[session.assistant]
    var forkModel by remember(showFork) { mutableStateOf(forkModelInherit) }
    val modelOptions = forkModelOptions(session.assistant, catalog)
    // Per-model effort options, then gated at the agent level (WS-3.2).
    val modelEffortOptions = forkEffortOptions(session.assistant, forkModel, catalog)
    val effortOptions = if (descriptorFor(session.assistant, agentDescriptorsMap).supportsEffort) modelEffortOptions else emptyList()
    val currentEffort = status?.reasoningEffort ?: session.reasoningEffort
    var forkEffort by remember(showFork) {
        mutableStateOf(
            currentEffort?.takeIf { effortOptions.contains(it) }
                ?: forkDefaultEffort(session.assistant, forkModel, catalog),
        )
    }
    // A model switch can change the supported effort range (catalog is
    // per-model: sonnet lacks xhigh, haiku has none) — snap an
    // out-of-range selection back to the model's default.
    LaunchedEffect(forkModel) {
        if (effortOptions.isNotEmpty() && forkEffort !in effortOptions) {
            forkEffort = forkDefaultEffort(session.assistant, forkModel, catalog)
        }
    }
    var modelMenuExpanded by remember(showFork) { mutableStateOf(false) }
    // Permission mode for the fork. "" = Auto (full-auto default); "plan" =
    // read-only planning. The sentinel "" maps to null into forkSession.
    var forkMode by remember(showFork) { mutableStateOf("") }

    // Refresh the 5h/weekly limits on appear so they don't read stale (they
    // otherwise only refresh on connect + the card's manual button — feedback:
    // "tap refresh to update"). Best-effort: the broker call is a no-op for
    // agents without a usage source and when no client is connected. Gated on
    // the descriptor's supportsUsage flag so third-party agents don't trigger
    // a spurious call. Keyed on session.id so it re-fires if the pane (phone
    // sheet or tablet Info pane) rebinds to a different session.
    LaunchedEffect(session.id) {
        if (agentDescriptor.supportsUsage) {
            store.refreshAccountUsage(session.id)
        }
        // Pull the live model catalog so the fork chooser's model/effort
        // options reflect what the box actually serves. Failure = keep
        // static fallbacks.
        store.refreshModelCatalog()
    }

    val content: @Composable () -> Unit = {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                // Sheet path only: honor the real bottom safe-area inset so the
                // Fork/Export/End action row clears the gesture pill / 3-button
                // nav bar instead of hardcoding a bottom pad (handoff §C.1).
                // ModalBottomSheet already anchors below the status bar, so the
                // top needs no extra inset here. The embedded (tablet right-pane)
                // path skips this — its host already applies window insets.
                .then(if (embedded) Modifier else Modifier.windowInsetsPadding(WindowInsets.navigationBars))
                .padding(horizontal = 16.dp, vertical = 12.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            // 1 · Identity
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface),
            ) {
                Row(
                    modifier = Modifier.padding(14.dp).fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        modifier = Modifier
                            .size(46.dp)
                            .background(
                                tint.copy(alpha = if (neon.dark) 0.14f else 0.10f),
                                RoundedCornerShape(12.dp),
                            )
                            .border(1.dp, tint.copy(alpha = 0.35f), RoundedCornerShape(12.dp)),
                        contentAlignment = Alignment.Center,
                    ) { ConduitMark(size = 26.dp, color = tint) }
                    Spacer(Modifier.width(12.dp))
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(3.dp),
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.clickable { renameDraft = name; showRename = true },
                        ) {
                            Text(
                                name,
                                style = MaterialTheme.typography.titleMedium,
                                fontFamily = neon.sans,
                                fontWeight = FontWeight.Bold,
                                color = neon.text,
                                maxLines = 1,
                            )
                            Spacer(Modifier.width(6.dp))
                            Icon(
                                Icons.Default.Edit,
                                contentDescription = "Rename",
                                tint = neon.textFaint,
                                modifier = Modifier.size(13.dp),
                            )
                        }
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(5.dp),
                        ) {
                            Text(
                                agent.lowercase(),
                                style = MaterialTheme.typography.labelMedium,
                                fontFamily = neon.mono,
                                fontWeight = FontWeight.SemiBold,
                                color = tint,
                            )
                            session.branch?.takeIf { it.isNotBlank() }?.let { b ->
                                Text("·", fontFamily = neon.mono, color = neon.textFaint)
                                Text(
                                    b,
                                    style = MaterialTheme.typography.labelMedium,
                                    fontFamily = neon.mono,
                                    color = neon.textDim,
                                    maxLines = 1,
                                )
                            }
                        }
                    }
                    Spacer(Modifier.width(8.dp))
                    StatusBadge(status, neon)
                }
            }

            // 2 · Usage
            val input = status?.totalInputTokens?.toLong() ?: 0L
            val output = status?.totalOutputTokens?.toLong() ?: 0L
            val cached = status?.totalCachedTokens?.toLong() ?: 0L
            val used = status?.contextUsedTokens?.toLong() ?: 0L
            val window = status?.contextWindowTokens?.toLong() ?: 0L
            val cost = status?.totalCostUsd
            if (window > 0L || input > 0L || output > 0L) {
                Column {
                    Eyebrow("USAGE", neon)
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface),
                    ) {
                        Column(
                            modifier = Modifier.padding(16.dp),
                            verticalArrangement = Arrangement.spacedBy(14.dp),
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(16.dp),
                            ) {
                                ContextRing(used, window, neon)
                                Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                    Text(
                                        "CONTEXT",
                                        style = MaterialTheme.typography.labelSmall,
                                        fontFamily = neon.mono,
                                        color = neon.textFaint,
                                    )
                                    Text(
                                        if (window > 0L) "${fmtK(used)} / ${fmtK(window)}" else fmtK(used),
                                        style = MaterialTheme.typography.titleMedium,
                                        fontFamily = neon.mono,
                                        fontWeight = FontWeight.Bold,
                                        color = neon.text,
                                    )
                                    Text(
                                        modelLine(agent, status?.reasoningEffort ?: session.reasoningEffort),
                                        style = MaterialTheme.typography.bodySmall,
                                        fontFamily = neon.mono,
                                        color = neon.textDim,
                                    )
                                }
                            }
                            Box(Modifier.fillMaxWidth().height(1.dp).background(neon.border))
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(16.dp),
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Text("↓ ${fmtK(input)}", fontFamily = neon.mono, fontWeight = FontWeight.Medium, color = neon.blue, style = MaterialTheme.typography.bodyMedium)
                                Text("↑ ${fmtK(output)}", fontFamily = neon.mono, fontWeight = FontWeight.Medium, color = neon.green, style = MaterialTheme.typography.bodyMedium)
                                Text("⛁ ${fmtK(cached)}", fontFamily = neon.mono, fontWeight = FontWeight.Medium, color = neon.purple, style = MaterialTheme.typography.bodyMedium)
                                Spacer(Modifier.weight(1f))
                                if (cost != null && cost > 0) {
                                    Text("$%.2f".format(cost), fontFamily = neon.mono, color = neon.textDim, style = MaterialTheme.typography.bodyMedium)
                                }
                            }
                            // Compact: free up context in place (parity with
                            // iOS). Claude exposes a user-triggered
                            // `/compact` (pass-through; broker surfaces
                            // progress, gauge drops next turn). Codex has NO
                            // manual compact in `exec` mode — it compacts
                            // AUTOMATICALLY at its token limit — so it shows an
                            // honest auto-compact note instead.
                            val lifecycle = store.sessionLifecycle.collectAsState().value[session.id]
                            val sessionLive = lifecycle !is SessionLifecycle.Exited &&
                                lifecycle !is SessionLifecycle.FailedToStart &&
                                store.harness.collectAsState().value.canIssueCommands
                            if (agentDescriptor.supportsCompact && sessionLive) {
                                Box(Modifier.fillMaxWidth().height(1.dp).background(neon.border))
                                var compacted by remember { mutableStateOf(false) }
                                TextButton(
                                    onClick = {
                                        store.sendChat(session.id, "/compact")
                                        compacted = true
                                        onDismiss()
                                    },
                                    enabled = !compacted,
                                    modifier = Modifier.fillMaxWidth().heightIn(min = 40.dp),
                                ) {
                                    Icon(Icons.Outlined.UnfoldLess, null, tint = neon.accent, modifier = Modifier.size(16.dp))
                                    Spacer(Modifier.width(7.dp))
                                    Text(
                                        if (compacted) "Compacting…" else "Compact context",
                                        fontFamily = neon.sans,
                                        fontWeight = FontWeight.SemiBold,
                                        color = neon.accent,
                                    )
                                }
                            } else if (!agentDescriptor.supportsCompact && sessionLive) {
                                Box(Modifier.fillMaxWidth().height(1.dp).background(neon.border))
                                Text(
                                    "${agentDescriptor.displayName} compacts context automatically",
                                    fontFamily = neon.mono,
                                    color = neon.textFaint,
                                    style = MaterialTheme.typography.bodySmall,
                                    modifier = Modifier.fillMaxWidth(),
                                )
                            }
                        }
                    }
                }
            }

            // 3 · Limits (this session's agent only). Gate on the descriptor's
            // supportsUsage flag — broker tells us which agents have a usage
            // endpoint; static fallback preserves claude/codex today.
            if (agentDescriptor.supportsUsage) {
                NeonAccountUsageCard(
                    fivePct = status?.account5hPct ?: session.account5hPct,
                    fiveResetsAt = status?.account5hResetsAt ?: session.account5hResetsAt,
                    weekPct = status?.account7dPct ?: session.account7dPct,
                    weekResetsAt = status?.account7dResetsAt ?: session.account7dResetsAt,
                    agentTint = tint,
                    onRefresh = { store.refreshAccountUsage(session.id) },
                    heading = "${agent.lowercase()} limits · 5h & weekly",
                )
            }

            // 4 · Activity
            Column {
                Eyebrow("ACTIVITY", neon)
                val hasActivity = stats.turns > 0 || stats.filesChanged > 0 || stats.commands > 0
                val line = activityLine(stats, status?.startedAt ?: session.startedAt, status?.lastActivityAt ?: session.lastActivityAt)
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface),
                ) {
                    Text(
                        if (hasActivity) line else "Just started · no activity yet",
                        modifier = Modifier.padding(14.dp),
                        fontFamily = neon.mono,
                        style = MaterialTheme.typography.bodyMedium,
                        color = if (hasActivity) neon.text else neon.textFaint,
                    )
                }
            }

            // 5 · Details
            Column {
                Eyebrow("DETAILS", neon)
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface),
                ) {
                    Column(modifier = Modifier.padding(14.dp)) {
                        InfoDetailRow("Working dir", session.cwd ?: status?.cwd ?: "—", neon)
                        Hairline(neon)
                        InfoDetailRow(
                            "Box",
                            endpoint.displayHost.takeIf { it.isNotBlank() }?.let { "$it · broker" } ?: "—",
                            neon,
                        )
                        Hairline(neon)
                        InfoDetailRow("Started", startedTimeLabel(status?.startedAt ?: session.startedAt), neon)
                    }
                }
            }

            // 6 · Actions
            Row(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                ActionPill(Icons.AutoMirrored.Filled.CallSplit, "Fork", neon.accent, Modifier.weight(1f)) { showFork = true }
                ActionPill(Icons.Default.Share, "Export", neon.accent, Modifier.weight(1f)) {
                    // Export shares the actual conversation transcript as
                    // markdown — the chat itself, not session metadata.
                    val transcript = buildTranscriptMarkdown(name, agent, session.branch, events)
                    val intent = Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TEXT, transcript)
                    }
                    context.startActivity(Intent.createChooser(intent, "Export transcript"))
                }
                ActionPill(Icons.Default.Stop, "End", neon.red, Modifier.weight(1f)) { showEndConfirm = true }
            }

            Spacer(Modifier.height(12.dp))
        }
    }

    if (embedded) {
        content()
    } else {
        ModalBottomSheet(
            onDismissRequest = onDismiss,
            sheetState = sheetState,
            containerColor = neon.surfaceSolid,
            shape = RoundedCornerShape(topStart = 26.dp, topEnd = 26.dp),
        ) {
            content()
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
                    if (effortOptions.isNotEmpty()) {
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
                                    label = { Text(effortLabel(level)) },
                                )
                            }
                        }
                    }
                    Text(
                        "MODE",
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        FilterChip(
                            selected = forkMode == "",
                            onClick = { forkMode = "" },
                            label = { Text("Auto") },
                        )
                        FilterChip(
                            selected = forkMode == "plan",
                            onClick = { forkMode = "plan" },
                            label = { Text("Plan") },
                        )
                    }
                    Text(
                        "Plan = read-only; agent explores and proposes without editing.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        "MODEL (OPTIONAL)",
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Box {
                        Surface(
                            shape = RoundedCornerShape(12.dp),
                            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f),
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { modelMenuExpanded = true },
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 12.dp).fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween,
                            ) {
                                Text(
                                    forkModelLabel(forkModel, catalog),
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurface,
                                )
                                Icon(
                                    Icons.Default.ArrowDropDown,
                                    contentDescription = "Choose model",
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                        DropdownMenu(
                            expanded = modelMenuExpanded,
                            onDismissRequest = { modelMenuExpanded = false },
                        ) {
                            modelOptions.forEach { option ->
                                DropdownMenuItem(
                                    text = { Text(forkModelLabel(option, catalog)) },
                                    onClick = {
                                        forkModel = option
                                        modelMenuExpanded = false
                                    },
                                )
                            }
                        }
                    }
                    Text(
                        forkModelDetail(forkModel, catalog) ?: "Default keeps the current model.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    val model = forkModel.trim().ifEmpty { null }
                    val mode = forkMode.trim().ifEmpty { null }
                    // No effort control on the chosen model (haiku) → no override.
                    val effort = forkEffort.trim().ifEmpty { null }?.takeIf { effortOptions.isNotEmpty() }
                    store.forkSession(session.id, reasoningEffort = effort, model = model, permissionMode = mode)
                    showFork = false
                    onDismiss()
                }) { Text("Fork") }
            },
            dismissButton = {
                TextButton(onClick = { showFork = false }) { Text("Cancel") }
            },
        )
    }

    if (showEndConfirm) {
        AlertDialog(
            onDismissRequest = { showEndConfirm = false },
            title = { Text("End this session?") },
            text = { Text("The agent stops and the box is released. The transcript stays in History.") },
            confirmButton = {
                TextButton(onClick = {
                    store.archive(session.id)
                    showEndConfirm = false
                    onDismiss()
                }) { Text("End session") }
            },
            dismissButton = {
                TextButton(onClick = { showEndConfirm = false }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun Eyebrow(text: String, neon: NeonTheme) {
    Text(
        text.uppercase(),
        style = MaterialTheme.typography.labelSmall,
        fontFamily = neon.mono,
        fontWeight = FontWeight.SemiBold,
        color = neon.textDim,
        modifier = Modifier.padding(bottom = 6.dp, start = 4.dp),
    )
}

@Composable
private fun StatusBadge(status: SessionStatus?, neon: NeonTheme) {
    val phase = (status?.phase ?: "").lowercase()
    val (label, color) = when {
        phase in setOf("running", "working", "streaming", "thinking") -> "Live" to neon.green
        else -> "Idle" to neon.textDim
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        modifier = Modifier
            .background(color.copy(alpha = 0.12f), RoundedCornerShape(50))
            .border(1.dp, color.copy(alpha = 0.3f), RoundedCornerShape(50))
            .padding(horizontal = 9.dp, vertical = 5.dp),
    ) {
        Box(Modifier.size(6.dp).background(color, CircleShape))
        Text(
            label,
            style = MaterialTheme.typography.labelSmall,
            fontFamily = neon.mono,
            fontWeight = FontWeight.SemiBold,
            color = color,
        )
    }
}

@Composable
private fun ContextRing(used: Long, window: Long, neon: NeonTheme) {
    val pct = if (window > 0L) (used.toDouble() / window).coerceIn(0.0, 1.0) else 0.0
    Box(modifier = Modifier.size(84.dp), contentAlignment = Alignment.Center) {
        Canvas(modifier = Modifier.size(84.dp)) {
            val strokePx = 9.dp.toPx()
            val inset = strokePx / 2f
            val arc = Size(size.width - strokePx, size.height - strokePx)
            drawArc(
                color = neon.border,
                startAngle = 0f,
                sweepAngle = 360f,
                useCenter = false,
                topLeft = Offset(inset, inset),
                size = arc,
                style = Stroke(width = strokePx),
            )
            drawArc(
                color = neon.accentBright,
                startAngle = -90f,
                sweepAngle = (pct * 360.0).toFloat(),
                useCenter = false,
                topLeft = Offset(inset, inset),
                size = arc,
                style = Stroke(width = strokePx, cap = StrokeCap.Round),
            )
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                "${(pct * 100).roundToInt()}",
                style = MaterialTheme.typography.titleLarge,
                fontFamily = neon.mono,
                fontWeight = FontWeight.Bold,
                color = neon.text,
            )
            Text("%", style = MaterialTheme.typography.labelSmall, fontFamily = neon.mono, color = neon.textFaint)
        }
    }
}

@Composable
private fun InfoDetailRow(label: String, value: String, neon: NeonTheme) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, style = MaterialTheme.typography.bodyMedium, fontFamily = neon.sans, color = neon.textDim)
        Spacer(Modifier.width(12.dp))
        Text(
            value,
            style = MaterialTheme.typography.bodyMedium,
            fontFamily = neon.mono,
            color = neon.text,
            modifier = Modifier.weight(1f, fill = false),
            textAlign = androidx.compose.ui.text.style.TextAlign.End,
        )
    }
}

@Composable
private fun Hairline(neon: NeonTheme) {
    Spacer(Modifier.height(9.dp))
    Box(Modifier.fillMaxWidth().height(1.dp).background(neon.border))
    Spacer(Modifier.height(9.dp))
}

@Composable
private fun ActionPill(icon: ImageVector, label: String, tint: Color, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val neon = LocalNeonTheme.current
    Box(
        modifier = modifier
            .neonCardSurface(neon = neon, shape = RoundedCornerShape(13.dp), fill = neon.surface, borderColor = tint.copy(alpha = 0.4f), glowTint = tint)
            .clickable(onClick = onClick),
    ) {
        Row(
            modifier = Modifier.padding(vertical = 12.dp).fillMaxWidth(),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(7.dp))
            Text(label, style = MaterialTheme.typography.labelLarge, fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, color = tint)
        }
    }
}

private fun modelLine(agent: String, effort: String?): String =
    if (!effort.isNullOrBlank()) "${agent.lowercase()} · $effort" else agent.lowercase()

private fun fmtK(n: Long): String = when {
    n >= 1_000_000L -> "%.1fM".format(n / 1_000_000.0)
    n >= 1_000L -> "${(n / 1000.0).roundToInt()}k"
    else -> "$n"
}

private fun activityLine(stats: SessionStats, startedAt: String?, lastActivityAt: String?): String {
    val parts = mutableListOf<String>()
    if (stats.turns > 0) parts += "${stats.turns} turns"
    if (stats.filesChanged > 0) parts += "${stats.filesChanged} files"
    if (stats.commands > 0) parts += "${stats.commands} cmds"
    val dur = durationLabel(startedAt, lastActivityAt)
    if (dur != null) parts += dur else if (stats.execTimeLabel != "—") parts += stats.execTimeLabel
    return parts.joinToString(" · ")
}

private fun durationLabel(startedAt: String?, lastActivityAt: String?): String? {
    val start = parseInstantMs(startedAt) ?: return null
    val end = parseInstantMs(lastActivityAt) ?: start
    val secs = ((end - start) / 1000L).coerceAtLeast(0L)
    return when {
        secs >= 60L -> "${secs / 60L}m"
        secs > 0L -> "${secs}s"
        else -> null
    }
}

private fun parseInstantMs(raw: String?): Long? {
    val t = raw?.trim().orEmpty()
    if (t.isEmpty()) return null
    return runCatching { java.time.Instant.parse(t).toEpochMilli() }.getOrNull()
        ?: runCatching { java.time.OffsetDateTime.parse(t).toInstant().toEpochMilli() }.getOrNull()
}

private fun startedTimeLabel(iso: String?): String {
    val ms = parseInstantMs(iso) ?: return "—"
    val dt = java.time.Instant.ofEpochMilli(ms).atZone(java.time.ZoneId.systemDefault())
    val today = java.time.LocalDate.now(java.time.ZoneId.systemDefault())
    val pattern = if (dt.toLocalDate() == today) "h:mm a" else "MMM d · h:mm a"
    return dt.format(java.time.format.DateTimeFormatter.ofPattern(pattern, java.util.Locale.getDefault()))
}

private fun exportMarkdown(
    name: String,
    agent: String,
    branch: String?,
    used: Long,
    window: Long,
    input: Long,
    output: Long,
    cached: Long,
    activity: String,
    cwd: String?,
    started: String,
): String {
    val lines = mutableListOf<String>()
    lines += "# $name"
    lines += if (!branch.isNullOrBlank()) "${agent.lowercase()} · $branch" else agent.lowercase()
    lines += ""
    if (window > 0L) lines += "- Context: ${fmtK(used)} / ${fmtK(window)}"
    if (input > 0L || output > 0L) lines += "- Tokens: ↓ ${fmtK(input)} ↑ ${fmtK(output)} ⛁ ${fmtK(cached)}"
    if (activity.isNotBlank()) lines += "- Activity: $activity"
    if (!cwd.isNullOrBlank()) lines += "- Working dir: $cwd"
    lines += "- Started: $started"
    return lines.joinToString("\n")
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

/**
 * The actual conversation transcript as markdown — the human / assistant
 * message content, not session metadata. Tool / command items fold in
 * compactly as a `$ <command>` line so the export reads as the real chat.
 * An empty log yields a header + "(no messages yet)". Mirror of iOS
 * `SessionInfoView.transcriptMarkdown`.
 */
internal fun buildTranscriptMarkdown(
    displayName: String,
    agent: String,
    branch: String?,
    events: List<ConversationItem>,
): String {
    val lines = mutableListOf<String>()
    lines.add("# $displayName")
    var meta = agent.lowercase()
    branch?.takeIf { it.isNotBlank() }?.let { meta += " · $it" }
    val msgCount = events.count { it.role.lowercase() == "user" || it.role.lowercase() == "assistant" }
    meta += "   ·  $msgCount message" + if (msgCount == 1) "" else "s"
    lines.add(meta)
    lines.add("")

    if (events.isEmpty()) {
        lines.add("(no messages yet)")
        return lines.joinToString("\n")
    }

    for (item in events) {
        val role = item.role.lowercase()
        val content = item.content.trim()
        val command = item.command
        if (!command.isNullOrEmpty()) {
            lines.add("$ $command")
            if (content.isNotEmpty() && content != command) lines.add(content)
            lines.add("")
            continue
        }
        when (role) {
            "user" -> {
                lines.add("## You")
                lines.add(if (content.isEmpty()) "(empty)" else content)
            }
            "assistant" -> {
                lines.add("## Assistant")
                lines.add(if (content.isEmpty()) "(empty)" else content)
            }
            else -> {
                if (content.isEmpty()) continue
                val tool = item.toolName
                if (!tool.isNullOrEmpty()) lines.add("`$tool` $content") else lines.add(content)
            }
        }
        lines.add("")
    }
    return lines.joinToString("\n").trim()
}

/**
 * Sentinel for the fork chooser's "keep the current model" option. Sent
 * to forkSession as null so the spawn carries no --model override —
 * byte-for-byte identical to the pre-picker untouched fork.
 */
internal const val forkModelInherit = ""

/**
 * Curated per-assistant model aliases offered in the fork chooser's
 * model dropdown. Mirror of iOS `ConduitUI.ForkOptions.models(forAssistant:)`.
 */
internal fun forkModelOptions(assistant: String): List<String> = when (assistant) {
    "claude" -> listOf(forkModelInherit, "opus", "sonnet", "haiku")
    "codex" -> listOf(forkModelInherit, "gpt-5-codex", "gpt-5", "gpt-5.5")
    else -> listOf(forkModelInherit)
}

/** Display label for a fork model option; the sentinel reads as inherit. */
internal fun forkModelLabel(option: String): String =
    if (option.isEmpty()) "Default (inherit)" else option

// --- Catalog-aware overloads -------------------------------------------
//
// Each takes the assistant's broker-discovered catalog
// (`store.modelCatalog.value[assistant]`) and falls back to the static
// lists above whenever it's null/empty (old broker, discovery still
// running, offline). Mirror of iOS `ConduitUI.ForkOptions` catalog
// overloads.

/**
 * The catalog entry a model option resolves to. The inherit sentinel
 * resolves to the agent's default entry so its effort range / description
 * follow the model the session would really run.
 */
internal fun catalogEntryFor(option: String, catalog: List<SessionStore.AgentModel>?): SessionStore.AgentModel? {
    if (catalog.isNullOrEmpty()) return null
    catalog.firstOrNull { it.id == option }?.let { return it }
    if (option != forkModelInherit) return null
    return catalog.firstOrNull { it.isDefault } ?: catalog.firstOrNull()
}

/**
 * Model options from the discovered catalog (inherit sentinel first), or
 * the static list when no catalog is available.
 */
internal fun forkModelOptions(assistant: String, catalog: List<SessionStore.AgentModel>?): List<String> {
    if (catalog.isNullOrEmpty()) return forkModelOptions(assistant)
    val ids = catalog.map { it.id }
    // When the catalog has an explicit non-empty isDefault entry (codex "gpt-5.5"),
    // that entry IS the recommended row — do NOT prepend the "" inherit sentinel.
    val hasExplicitDefault = catalog.any { it.isDefault && it.id.isNotEmpty() }
    if (hasExplicitDefault) return ids
    val mutable = ids.toMutableList()
    if (forkModelInherit !in mutable) mutable.add(0, forkModelInherit)
    return mutable
}

/**
 * Display label for a model option, preferring the agent's own display
 * name ("Fable", "GPT-5.5", "Default (recommended)").
 */
internal fun forkModelLabel(option: String, catalog: List<SessionStore.AgentModel>?): String {
    val entry = catalog?.firstOrNull { it.id == option }
    if (entry != null) {
        val isRecommendedRow = entry.isDefault ||
            entry.displayName.lowercase().startsWith("default") ||
            entry.id == forkModelInherit
        if (isRecommendedRow) {
            val resolved = defaultModelTitle(catalog)
            if (resolved != null) return "$resolved (recommended)"
        }
        return if (entry.displayName.isNotEmpty()) entry.displayName else forkModelLabel(option)
    }
    // No exact match. Inherit sentinel fallback.
    if (option == forkModelInherit) {
        val resolved = defaultModelTitle(catalog)
        if (resolved != null) return "$resolved (recommended)"
    }
    return forkModelLabel(option)
}

/**
 * One-line detail for a model option (the agent's own description, e.g.
 * "Sonnet 4.6 · Efficient for routine tasks"). Null without a catalog —
 * the caller hides the caption.
 */
internal fun forkModelDetail(option: String, catalog: List<SessionStore.AgentModel>?): String? =
    catalogEntryFor(option, catalog)?.description?.takeIf { it.isNotEmpty() }

/**
 * Effort levels for the chosen model from the discovered catalog
 * (per-model: claude sonnet lacks xhigh, haiku has none at all); static
 * per-assistant list when no catalog. An EMPTY result means the model has
 * no effort control — hide the effort UI and send no override.
 */
internal fun forkEffortOptions(assistant: String, model: String, catalog: List<SessionStore.AgentModel>?): List<String> {
    if (catalog.isNullOrEmpty()) return forkEffortOptions(assistant)
    return catalogEntryFor(model, catalog)?.efforts ?: emptyList()
}

/**
 * The effort to preselect for a model: the agent's own default when
 * advertised, else "medium" when offered, else the first level. "" when
 * the model has no effort control.
 */
internal fun forkDefaultEffort(
    assistant: String,
    model: String = forkModelInherit,
    catalog: List<SessionStore.AgentModel>? = null,
): String {
    val options = forkEffortOptions(assistant, model, catalog)
    if (options.isEmpty()) return ""
    val entry = catalogEntryFor(model, catalog)
    if (entry != null && entry.defaultEffort.isNotEmpty() && entry.defaultEffort in options) return entry.defaultEffort
    return if ("medium" in options) "medium" else options.first()
}

/**
 * Friendly dial label for a raw effort level. Unknown levels fall back to
 * their capitalized raw value so a future agent-side addition still renders.
 */
internal fun effortLabel(value: String): String = when (value) {
    "low" -> "Fast"
    "medium" -> "Balanced"
    "high" -> "Deep"
    "xhigh" -> "X-High"
    "max" -> "Max"
    else -> value.replaceFirstChar { it.uppercase() }
}

/** Consequence line shown under the effort dial. */
internal fun effortDescription(value: String): String = when (value) {
    "low" -> "Quick passes, minimal deliberation"
    "medium" -> "Reasons before it acts — the default"
    "high" -> "Plans hard and checks itself, slower"
    "xhigh" -> "Extra-high reasoning depth for hard problems"
    "max" -> "Maximum reasoning depth — slowest, most thorough"
    else -> "Reasoning depth: $value"
}

/**
 * The model name to show on the agent card: the discovered default model's
 * display name ("GPT-5.5"); for claude's "Default (recommended)" alias
 * entry, the resolved model is the first "·"-chunk of its description
 * ("Opus 4.8 with 1M context" → "Opus 4.8"). Null without a catalog — the
 * caller keeps its static label.
 */
internal fun defaultModelTitle(catalog: List<SessionStore.AgentModel>?): String? {
    val entry = catalog?.firstOrNull { it.isDefault } ?: catalog?.firstOrNull() ?: return null
    var name = entry.displayName
    if (name.isEmpty() || name.lowercase().startsWith("default")) {
        name = entry.description.substringBefore('·').trim()
        val withIdx = name.indexOf(" with ")
        if (withIdx >= 0) name = name.substring(0, withIdx)
    }
    return name.ifEmpty { null }
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

/**
 * Session "Details" rows helper — retained for unit tests
 * (`SessionDetailsTest`) and any other callers. Pure (string in, string
 * out, fixed clock injectable). Mirror of iOS `SessionInfoViewModel`.
 */
object SessionDetails {
    data class Detail(val label: String, val value: String, val caption: String? = null)

    fun rows(
        assistant: String,
        reasoningEffort: String?,
        startedAt: String?,
        lastActivityAt: String?,
        nowMs: Long = System.currentTimeMillis(),
    ): List<Detail> {
        val rows = mutableListOf<Detail>()
        val model = assistant.ifBlank { "—" }
        val modelValue = reasoningEffort?.takeIf { it.isNotBlank() }?.let { "$model · $it" } ?: model
        rows += Detail("Model", modelValue)

        val startedMs = parseMs(startedAt)
        if (startedMs != null) {
            rows += Detail("Started", absolute(startedMs), relative(startedMs, nowMs))
        }
        val lastMs = parseMs(lastActivityAt) ?: startedMs
        if (lastMs != null) {
            rows += Detail("Last Activity", relative(lastMs, nowMs))
        }
        if (startedMs != null) {
            val end = parseMs(lastActivityAt) ?: nowMs
            val elapsed = (end - startedMs).coerceAtLeast(0L)
            rows += Detail("Uptime", formatDuration(elapsed))
        }
        return rows
    }

    private fun parseMs(raw: String?): Long? {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return null
        return runCatching { java.time.Instant.parse(trimmed).toEpochMilli() }.getOrNull()
            ?: runCatching { java.time.OffsetDateTime.parse(trimmed).toInstant().toEpochMilli() }.getOrNull()
    }

    private fun absolute(ms: Long): String {
        val dt = java.time.Instant.ofEpochMilli(ms)
            .atZone(java.time.ZoneId.systemDefault())
            .toLocalDateTime()
        return dt.format(
            java.time.format.DateTimeFormatter.ofPattern("MMM d, yyyy · h:mm a", java.util.Locale.getDefault()),
        )
    }

    fun relative(ms: Long, nowMs: Long = System.currentTimeMillis()): String {
        val delta = (nowMs - ms).coerceAtLeast(0L)
        val secs = delta / 1000L
        if (secs < 60L) return "just now"
        val mins = secs / 60L
        if (mins < 60L) return "${mins}m ago"
        val hours = mins / 60L
        if (hours < 24L) return "${hours}h ago"
        val days = hours / 24L
        if (days < 14L) return "${days}d ago"
        val dt = java.time.Instant.ofEpochMilli(ms)
            .atZone(java.time.ZoneId.systemDefault())
            .toLocalDate()
        return dt.format(
            java.time.format.DateTimeFormatter.ofPattern("M/d/yy", java.util.Locale.getDefault()),
        )
    }

    fun formatDuration(ms: Long): String {
        if (ms <= 0L) return "—"
        val s = ms / 1000L
        if (s < 60L) return "${s}s"
        val m = s / 60L
        if (m < 60L) return "${m}m ${s % 60L}s"
        val h = m / 60L
        return "${h}h ${m % 60L}m"
    }
}
