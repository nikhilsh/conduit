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
import androidx.compose.material.icons.automirrored.filled.CallSplit
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.LinearProgressIndicator
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
fun SessionInfoScreen(store: SessionStore, session: ProjectSession, onDismiss: () -> Unit, embedded: Boolean = false) {
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
    // forkModel is a model alias or "" (inherit = no override). The
    // dropdown is filtered by assistant; the leading "" entry keeps the
    // current model, byte-for-byte identical to the pre-picker fork.
    val modelOptions = remember(session.assistant) { forkModelOptions(session.assistant) }
    var forkModel by remember(showFork) { mutableStateOf(forkModelInherit) }
    var modelMenuExpanded by remember(showFork) { mutableStateOf(false) }

    val neon = LocalNeonTheme.current
    val content: @Composable () -> Unit = {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            // Hero
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface),
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
                                fontFamily = neon.sans,
                                fontWeight = FontWeight.Bold,
                                color = neon.text,
                            )
                            status?.phase?.takeIf { it.isNotBlank() }?.let { phase ->
                                Text(
                                    phase,
                                    style = MaterialTheme.typography.bodySmall,
                                    fontFamily = neon.mono,
                                    color = neon.textDim,
                                )
                            }
                        }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        AgentPill(session.assistant, tint = neonAgentColor(session.assistant, neon))
                        session.branch?.takeIf { it.isNotBlank() }?.let { AgentPill(it, tint = neon.accent2) }
                    }
                    Text(
                        session.id,
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = neon.mono,
                        color = neon.textFaint,
                    )
                }
            }

            // Action row
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                ActionTile(Icons.Default.Palette, "Appearance", Modifier.weight(1f)) { showAppearance = true }
                ActionTile(Icons.AutoMirrored.Filled.CallSplit, "Fork", Modifier.weight(1f)) { showFork = true }
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
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.SemiBold,
                    color = neon.textDim,
                    modifier = Modifier.padding(bottom = 6.dp, start = 4.dp),
                )
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface),
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

            // Details card (iOS #239 parity): model (+effort) / started /
            // last activity / uptime, built from live status (preferred)
            // falling back to the session snapshot — mirroring how the
            // store materializes a session. Sits between the stats grid
            // and the server-usage card.
            val details = remember(status, session) {
                SessionDetails.rows(
                    assistant = status?.assistant?.takeIf { it.isNotBlank() } ?: session.assistant,
                    reasoningEffort = status?.reasoningEffort ?: session.reasoningEffort,
                    startedAt = status?.startedAt ?: session.startedAt,
                    lastActivityAt = status?.lastActivityAt ?: session.lastActivityAt,
                )
            }
            if (details.isNotEmpty()) {
                Column {
                    Text(
                        "DETAILS",
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.SemiBold,
                        color = neon.textDim,
                        modifier = Modifier.padding(bottom = 6.dp, start = 4.dp),
                    )
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface),
                    ) {
                        Column(
                            modifier = Modifier.padding(14.dp),
                            verticalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            details.forEach { detail -> DetailRow(detail) }
                        }
                    }
                }
            }

            // Per-session usage card (context ring + in/out/cache tiles, or
            // the terminal readout) — design bundle parity. Data is the live
            // broker-accumulated status (PR #274); cost + context are
            // claude-only; the card hides until usage lands. Plan limits are
            // omitted (no data source). See NeonUsageCard.
            NeonUsageCard(
                input = status?.totalInputTokens?.toLong() ?: 0L,
                output = status?.totalOutputTokens?.toLong() ?: 0L,
                cached = status?.totalCachedTokens?.toLong() ?: 0L,
                costUsd = status?.totalCostUsd,
                contextUsed = status?.contextUsedTokens?.toLong() ?: 0L,
                contextWindow = status?.contextWindowTokens?.toLong() ?: 0L,
                assistant = status?.assistant ?: session.assistant,
                turns = stats.turns,
                execLabel = stats.execTimeLabel,
            )

            session.preview?.let { preview ->
                Column {
                    Text(
                        "SERVER USAGE",
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.SemiBold,
                        color = neon.textDim,
                        modifier = Modifier.padding(bottom = 6.dp, start = 4.dp),
                    )
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface),
                    ) {
                        Column(modifier = Modifier.padding(14.dp)) {
                            Text("Preview · port ${preview.port}", style = MaterialTheme.typography.bodyMedium, fontFamily = neon.sans, color = neon.text)
                            Text(
                                preview.url,
                                style = MaterialTheme.typography.bodySmall,
                                fontFamily = neon.mono,
                                color = neon.textDim,
                            )
                        }
                    }
                }
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
                                    forkModelLabel(forkModel),
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
                                    text = { Text(forkModelLabel(option)) },
                                    onClick = {
                                        forkModel = option
                                        modelMenuExpanded = false
                                    },
                                )
                            }
                        }
                    }
                    Text(
                        "Default keeps the current model.",
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
    val neon = LocalNeonTheme.current
    Surface(
        shape = RoundedCornerShape(50),
        color = tint.copy(alpha = 0.30f),
    ) {
        Text(
            label,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.SemiBold,
            // Explicit neon text colour: don't lean on Material `onSurface`,
            // which flips to near-black under a light palette and renders the
            // pill label as black-on-dark on the neon Info card.
            color = neon.text,
        )
    }
}

@Composable
private fun ActionTile(icon: ImageVector, title: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val neon = LocalNeonTheme.current
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
            Icon(icon, contentDescription = null, tint = neon.accent)
            // Explicit neon text colour (see AgentPill) so the tile label
            // never collapses to Material near-black on the neon surface.
            Text(title, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold, color = neon.text)
        }
    }
}

@Composable
private fun DetailRow(detail: SessionDetails.Detail) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(
            detail.label,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Column(horizontalAlignment = Alignment.End) {
            Text(
                detail.value,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            detail.caption?.let { caption ->
                Text(
                    caption,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
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
                color = LocalNeonTheme.current.accent,
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

/**
 * Sentinel for the fork chooser's "keep the current model" option. Sent
 * to forkSession as null so the spawn carries no --model override —
 * byte-for-byte identical to the pre-picker untouched fork.
 */
internal const val forkModelInherit = ""

/**
 * Curated per-assistant model aliases offered in the fork chooser's
 * model dropdown. The broker passes the chosen value straight to the
 * agent's --model flag (`broker/internal/session/override.go`), so these
 * are the CLI's accepted aliases. The leading inherit entry maps to "no
 * override". Aliases (opus/sonnet/haiku, gpt-5-codex) avoid pinning a
 * dated full model name in the client. Mirror of iOS
 * `LitterUI.ForkOptions.models(forAssistant:)`.
 */
internal fun forkModelOptions(assistant: String): List<String> = when (assistant) {
    "claude" -> listOf(forkModelInherit, "opus", "sonnet", "haiku")
    "codex" -> listOf(forkModelInherit, "gpt-5-codex")
    else -> listOf(forkModelInherit)
}

/** Display label for a fork model option; the sentinel reads as inherit. */
internal fun forkModelLabel(option: String): String =
    if (option.isEmpty()) "Default (inherit)" else option

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
 * Session "Details" rows — model (+effort) / started / last activity /
 * uptime — built from live status/session fields. Pure (string in,
 * string out, fixed clock injectable) so JUnit can pin the formatting
 * and uptime math. Mirror of iOS
 * `SessionInfoViewModel.details(_:)` / `relative(_:)`.
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

        // Model — the broker exposes only the assistant identifier (no
        // separate model-version field), optionally qualified by effort.
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

    /**
     * Compact relative-time string ("just now", "5m ago", "3h ago",
     * "2d ago"); older than two weeks falls back to a short date.
     */
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

    /** "<n>s" / "<m>m <s>s" / "<h>h <m>m" elapsed-time formatting. */
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
