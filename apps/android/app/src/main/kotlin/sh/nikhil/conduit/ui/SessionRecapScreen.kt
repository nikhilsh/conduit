package sh.nikhil.conduit.ui

import android.content.Intent
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
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt
import sh.nikhil.conduit.SessionLifecycle
import sh.nikhil.conduit.SessionStore
import uniffi.conduit_core.ConversationItem
import uniffi.conduit_core.ProjectSession

/**
 * Conduit redesign "Session recap" surface (handoff §B.9, image 10):
 * an exportable end-of-session summary. Android mirror of iOS
 * `ConduitUI.SessionRecapView`. Top-to-bottom IA:
 *
 *   • Header   — agent-tinted [ConduitMark] avatar, the real session name,
 *                an OUTCOME chip (PR / merged / ended / failed — derived
 *                from prState/prNumber + lifecycle; honest "session" when
 *                unknown), and a `+added / −removed` mini stat.
 *   • What changed — bulleted list. There is NO server-generated "what
 *                changed" prose, so this is derived HONESTLY from real
 *                signal in priority order: the agent's own
 *                result-summary / diff-summary / task-text from the
 *                conversation log, else the distinct changed-file paths,
 *                else the commit count. Never fabricated prose.
 *   • File stats — `N files` / `+added` / `−removed` tiles from
 *                linesAdded / linesRemoved (ProjectSession/SessionStatus)
 *                and the distinct file-path count from the log.
 *   • Commands run — the recent real `command` fields, mono-styled.
 *   • Duration / tokens — wall-clock (started → last activity) + token
 *                totals from the usage snapshot.
 *   • Actions  — Export markdown (ACTION_SEND of the assembled doc) and
 *                Share link. There is no real shareable URL in the stack,
 *                so "Share text" shares the SAME markdown rather than
 *                faking a URL.
 *
 * HOW TO PRESENT / ENTRY SUGGESTION
 *   Presented as a [ModalBottomSheet] (the default) or — on tablet —
 *   `embedded = true` inside the right pane. Suggested entry points
 *   (wired separately by the host):
 *     · the Session Info "Export" action → Recap instead of a bare
 *       markdown share, so the user previews before sharing;
 *     · a row tap in History (a finished session is exactly a recap);
 *     · an end-of-session prompt after "End session".
 *
 * Reuses the Session Info data idioms ([SessionStats]-style log derivation,
 * `fmtK`, wall-clock duration) without touching SessionInfoScreen
 * (constraint: new files only).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionRecapScreen(
    store: SessionStore,
    session: ProjectSession,
    onDismiss: () -> Unit = {},
    embedded: Boolean = false,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val statuses by store.statusBySession.collectAsState()
    val conversationLog by store.conversationLog.collectAsState()
    val displayNames by store.displayNames.collectAsState()
    val lifecycles by store.sessionLifecycle.collectAsState()
    val neon = LocalNeonTheme.current
    val context = LocalContext.current

    val recap = remember(session, statuses, conversationLog, displayNames, lifecycles) {
        RecapModel.from(
            session = session,
            status = statuses[session.id],
            log = conversationLog[session.id].orEmpty(),
            displayName = displayNames[session.id] ?: session.name,
            lifecycle = lifecycles[session.id],
        )
    }

    val content: @Composable () -> Unit = {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                // Sheet path only: honor the real bottom safe-area inset so
                // the action row clears the gesture pill / 3-button nav bar
                // (handoff §C.1). The embedded (tablet) path skips this — its
                // host already applies window insets.
                .then(if (embedded) Modifier else Modifier.windowInsetsPadding(WindowInsets.navigationBars))
                .padding(horizontal = 16.dp, vertical = 12.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            HeaderCard(recap, neon)
            if (recap.whatChanged.isNotEmpty()) WhatChangedSection(recap.whatChanged, neon)
            if (recap.filesChanged > 0 || recap.linesAdded > 0 || recap.linesRemoved > 0) {
                FileStatsRow(recap, neon)
            }
            if (recap.commands.isNotEmpty()) CommandsSection(recap.commands, neon)
            if (recap.durationLabel != null || recap.totalTokens > 0L) DurationTokensCard(recap, neon)
            ActionRow(
                neon = neon,
                onExport = { shareText(context, recap.markdown, "Export session recap") },
                onShare = { shareText(context, recap.markdown, "Share session recap") },
            )
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
}

@Composable
private fun HeaderCard(recap: RecapModel, neon: NeonTheme) {
    val tint = neonAgentColor(recap.assistant, neon)
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
                    .background(tint.copy(alpha = if (neon.dark) 0.14f else 0.10f), RoundedCornerShape(12.dp))
                    .border(1.dp, tint.copy(alpha = 0.35f), RoundedCornerShape(12.dp)),
                contentAlignment = Alignment.Center,
            ) { ConduitMark(size = 26.dp, color = tint) }
            Spacer(Modifier.width(12.dp))
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                Text(
                    recap.displayName,
                    style = MaterialTheme.typography.titleMedium,
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.Bold,
                    color = neon.text,
                    maxLines = 2,
                )
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(5.dp),
                ) {
                    Text(
                        recap.assistant.lowercase(),
                        style = MaterialTheme.typography.labelMedium,
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.SemiBold,
                        color = tint,
                    )
                    recap.branch?.takeIf { it.isNotBlank() }?.let { b ->
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
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                OutcomeBadge(recap.outcome, neon)
                if (recap.linesAdded > 0 || recap.linesRemoved > 0) {
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text("+${recap.linesAdded}", fontFamily = neon.mono, fontWeight = FontWeight.SemiBold, color = neon.green, style = MaterialTheme.typography.labelMedium)
                        Text("−${recap.linesRemoved}", fontFamily = neon.mono, fontWeight = FontWeight.SemiBold, color = neon.red, style = MaterialTheme.typography.labelMedium)
                    }
                }
            }
        }
    }
}

@Composable
private fun OutcomeBadge(outcome: RecapOutcome, neon: NeonTheme) {
    val color = outcome.color(neon)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        modifier = Modifier
            .background(color.copy(alpha = 0.12f), RoundedCornerShape(50))
            .border(1.dp, color.copy(alpha = 0.30f), RoundedCornerShape(50))
            .padding(horizontal = 9.dp, vertical = 5.dp),
    ) {
        Text(
            outcome.label,
            style = MaterialTheme.typography.labelSmall,
            fontFamily = neon.mono,
            fontWeight = FontWeight.SemiBold,
            color = color,
        )
    }
}

@Composable
private fun WhatChangedSection(bullets: List<String>, neon: NeonTheme) {
    Column {
        Eyebrow("WHAT CHANGED", neon)
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface),
        ) {
            Column(
                modifier = Modifier.padding(14.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                bullets.forEach { line ->
                    Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
                        Box(
                            modifier = Modifier
                                .padding(top = 6.dp)
                                .size(5.dp)
                                .background(neon.green, CircleShape),
                        )
                        Text(
                            line,
                            style = MaterialTheme.typography.bodyMedium,
                            fontFamily = neon.sans,
                            color = neon.text,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun FileStatsRow(recap: RecapModel, neon: NeonTheme) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        StatTile("${recap.filesChanged}", "files", neon.text, neon, Modifier.weight(1f))
        StatTile("+${recap.linesAdded}", "added", neon.green, neon, Modifier.weight(1f))
        StatTile("−${recap.linesRemoved}", "removed", neon.red, neon, Modifier.weight(1f))
    }
}

@Composable
private fun StatTile(value: String, label: String, tint: Color, neon: NeonTheme, modifier: Modifier) {
    Box(
        modifier = modifier.neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface),
    ) {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(value, fontFamily = neon.mono, fontWeight = FontWeight.Bold, color = tint, style = MaterialTheme.typography.titleLarge)
            Text(label.uppercase(), fontFamily = neon.mono, color = neon.textDim, style = MaterialTheme.typography.labelSmall)
        }
    }
}

@Composable
private fun CommandsSection(commands: List<String>, neon: NeonTheme) {
    Column {
        Eyebrow("COMMANDS RUN", neon)
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            commands.forEach { cmd ->
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .neonCardSurface(neon = neon, shape = RoundedCornerShape(12.dp), fill = neon.surface),
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp).fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text("$", fontFamily = neon.mono, fontWeight = FontWeight.SemiBold, color = neon.accent, style = MaterialTheme.typography.bodyMedium)
                        Text(
                            cmd,
                            fontFamily = neon.mono,
                            color = neon.text,
                            maxLines = 1,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun DurationTokensCard(recap: RecapModel, neon: NeonTheme) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface),
    ) {
        Column(modifier = Modifier.padding(horizontal = 14.dp)) {
            recap.durationLabel?.let {
                RecapRow("Duration", it, if (recap.turnsCount > 0) "${recap.turnsCount} turns" else null, neon)
            }
            if (recap.durationLabel != null && recap.totalTokens > 0L) {
                Box(Modifier.fillMaxWidth().height(1.dp).background(neon.border))
            }
            if (recap.totalTokens > 0L) {
                RecapRow("Tokens", fmtKLong(recap.totalTokens), recap.tokenBreakdown, neon)
            }
        }
    }
}

@Composable
private fun RecapRow(title: String, value: String, caption: String?, neon: NeonTheme) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(title, style = MaterialTheme.typography.bodyLarge, fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, color = neon.text)
        Spacer(Modifier.width(12.dp))
        Column(horizontalAlignment = Alignment.End) {
            Text(value, style = MaterialTheme.typography.titleMedium, fontFamily = neon.mono, fontWeight = FontWeight.Bold, color = neon.text, textAlign = TextAlign.End)
            caption?.let {
                Text(it, style = MaterialTheme.typography.labelSmall, fontFamily = neon.mono, color = neon.textFaint, textAlign = TextAlign.End)
            }
        }
    }
}

@Composable
private fun ActionRow(neon: NeonTheme, onExport: () -> Unit, onShare: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        RecapActionPill(Icons.Default.Share, "Export markdown", neon.green, Modifier.weight(1f), onExport)
        // No real shareable URL exists, so "Share text" shares the SAME
        // markdown rather than faking a URL.
        RecapActionPill(Icons.Default.Link, "Share text", neon.accent, Modifier.weight(1f), onShare)
    }
}

@Composable
private fun RecapActionPill(icon: ImageVector, label: String, tint: Color, modifier: Modifier, onClick: () -> Unit) {
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
            Text(label, style = MaterialTheme.typography.labelLarge, fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, color = tint, maxLines = 1)
        }
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

private fun shareText(context: android.content.Context, text: String, title: String) {
    val intent = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_TEXT, text)
    }
    context.startActivity(Intent.createChooser(intent, title))
}

// region Pure logic (unit-testable)

/** The single header outcome chip — see iOS `RecapOutcome`. */
enum class RecapOutcome {
    MERGED,
    PR,
    ENDED,
    FAILED,
    NEUTRAL,
    ;

    val label: String
        get() = when (this) {
            MERGED -> "merged"
            PR -> "PR open"
            ENDED -> "ended"
            FAILED -> "failed"
            NEUTRAL -> "session"
        }

    fun color(neon: NeonTheme): Color = when (this) {
        MERGED -> neon.purple
        PR -> neon.green
        ENDED -> neon.textDim
        FAILED -> neon.red
        NEUTRAL -> neon.textDim
    }
}

/**
 * Pure derivation of every recap section from the live store +
 * [ProjectSession]. Mirror of iOS `ConduitUI.Recap`. Status delta is
 * preferred over the session snapshot (it's refreshed by broker deltas).
 */
data class RecapModel(
    val displayName: String,
    val assistant: String,
    val branch: String?,
    val cwd: String?,
    val outcome: RecapOutcome,
    val linesAdded: Int,
    val linesRemoved: Int,
    val filesChanged: Int,
    val commits: Int,
    val prNumber: Int?,
    val prState: String?,
    val whatChanged: List<String>,
    val commands: List<String>,
    val turnsCount: Int,
    val durationLabel: String?,
    val totalTokens: Long,
    val tokenBreakdown: String?,
    val startedLabel: String?,
) {
    val markdown: String
        get() {
            val lines = mutableListOf<String>()
            lines += "# $displayName"
            lines += if (!branch.isNullOrBlank()) "${assistant.lowercase()} · $branch" else assistant.lowercase()
            lines += ""
            lines += "**Outcome:** ${outcome.label}"
            if (prNumber != null) lines += "**PR:** #$prNumber${prState?.let { " $it" } ?: ""}"
            lines += ""

            if (whatChanged.isNotEmpty()) {
                lines += "## What changed"
                whatChanged.forEach { lines += "- $it" }
                lines += ""
            }
            if (filesChanged > 0 || linesAdded > 0 || linesRemoved > 0) {
                lines += "## File stats"
                lines += "- $filesChanged files · +$linesAdded −$linesRemoved"
                if (commits > 0) lines += "- $commits commit${if (commits == 1) "" else "s"}"
                lines += ""
            }
            if (commands.isNotEmpty()) {
                lines += "## Commands run"
                lines += "```"
                commands.forEach { lines += "$ $it" }
                lines += "```"
                lines += ""
            }
            val meta = mutableListOf<String>()
            durationLabel?.let { meta += "- Duration: $it" }
            if (turnsCount > 0) meta += "- Turns: $turnsCount"
            if (totalTokens > 0L) {
                meta += "- Tokens: ${fmtKLong(totalTokens)}${tokenBreakdown?.let { " ($it)" } ?: ""}"
            }
            if (!cwd.isNullOrBlank()) meta += "- Working dir: $cwd"
            startedLabel?.let { meta += "- Started: $it" }
            if (meta.isNotEmpty()) {
                lines += "## Session"
                lines += meta
            }
            return lines.joinToString("\n")
        }

    companion object {
        fun from(
            session: ProjectSession,
            status: uniffi.conduit_core.SessionStatus?,
            log: List<ConversationItem>,
            displayName: String,
            lifecycle: SessionLifecycle?,
        ): RecapModel {
            val assistant = status?.assistant?.takeIf { it.isNotBlank() } ?: session.assistant
            val added = (status?.linesAdded ?: session.linesAdded)?.toInt() ?: 0
            val removed = (status?.linesRemoved ?: session.linesRemoved)?.toInt() ?: 0
            val commits = (status?.commits ?: session.commits)?.toInt() ?: 0
            val prNumber = (status?.prNumber ?: session.prNumber)?.toInt()
            val prState = status?.prState ?: session.prState

            val filePaths = distinctFiles(log)

            val input = (status?.totalInputTokens ?: session.totalInputTokens)?.toLong() ?: 0L
            val output = (status?.totalOutputTokens ?: session.totalOutputTokens)?.toLong() ?: 0L
            val cached = (status?.totalCachedTokens ?: session.totalCachedTokens)?.toLong() ?: 0L

            val started = parseInstantMs(status?.startedAt ?: session.startedAt)
            val last = parseInstantMs(status?.lastActivityAt ?: session.lastActivityAt) ?: started

            return RecapModel(
                displayName = displayName,
                assistant = assistant,
                branch = session.branch,
                cwd = status?.cwd ?: session.cwd,
                outcome = deriveOutcome(prNumber, prState, lifecycle),
                linesAdded = added,
                linesRemoved = removed,
                filesChanged = filePaths.size,
                commits = commits,
                prNumber = prNumber,
                prState = prState,
                whatChanged = deriveWhatChanged(log, filePaths, commits),
                commands = log.mapNotNull { it.command?.trim()?.takeIf { c -> c.isNotEmpty() } }.takeLast(6),
                turnsCount = log.count { it.role.lowercase() == "user" },
                durationLabel = durationLabel(started, last),
                totalTokens = input + output,
                tokenBreakdown = if (input > 0L || output > 0L) {
                    "↓ ${fmtKLong(input)} ↑ ${fmtKLong(output)} ⛁ ${fmtKLong(cached)}"
                } else {
                    null
                },
                startedLabel = startedLabel(started),
            )
        }

        fun deriveOutcome(prNumber: Int?, prState: String?, lifecycle: SessionLifecycle?): RecapOutcome {
            when (prState?.lowercase()) {
                "merged" -> return RecapOutcome.MERGED
                "open", "draft" -> return RecapOutcome.PR
            }
            if ((prNumber ?: 0) > 0) return RecapOutcome.PR
            return when (lifecycle) {
                is SessionLifecycle.FailedToStart -> RecapOutcome.FAILED
                is SessionLifecycle.Exited -> RecapOutcome.ENDED
                else -> RecapOutcome.NEUTRAL
            }
        }

        /** Distinct changed-file paths in conversation order. */
        fun distinctFiles(log: List<ConversationItem>): List<String> {
            val seen = LinkedHashSet<String>()
            log.forEach { item -> item.files.forEach { f -> if (f.path.isNotEmpty()) seen.add(f.path) } }
            return seen.toList()
        }

        /**
         * HONEST "what changed" bullets. Priority:
         *   1. The agent's own summaries (resultSummary / diffSummary /
         *      taskText) — real prose the agent emitted.
         *   2. Otherwise the distinct changed-file paths (capped).
         *   3. Otherwise a single commit-count line.
         * Empty when no signal at all — never fabricated.
         */
        fun deriveWhatChanged(log: List<ConversationItem>, filePaths: List<String>, commits: Int): List<String> {
            val bullets = LinkedHashSet<String>()
            fun add(raw: String?) {
                val s = raw?.trim().orEmpty()
                if (s.isEmpty()) return
                val first = s.substringBefore('\n').trim()
                if (first.isNotEmpty()) bullets.add(first)
            }
            log.forEach { add(it.resultSummary); add(it.diffSummary) }
            if (bullets.isEmpty()) log.forEach { add(it.taskText) }
            if (bullets.isNotEmpty()) return bullets.take(6)

            if (filePaths.isNotEmpty()) return filePaths.take(8)
            if (commits > 0) return listOf("$commits commit${if (commits == 1) "" else "s"} landed")
            return emptyList()
        }

        fun durationLabel(startMs: Long?, endMs: Long?): String? {
            if (startMs == null) return null
            val secs = (((endMs ?: startMs) - startMs) / 1000L).coerceAtLeast(0L)
            return when {
                secs >= 3600L -> "${secs / 3600L}h ${(secs % 3600L) / 60L}m"
                secs >= 60L -> "${secs / 60L}m"
                secs > 0L -> "${secs}s"
                else -> null
            }
        }

        private fun startedLabel(ms: Long?): String? {
            if (ms == null) return null
            val dt = java.time.Instant.ofEpochMilli(ms).atZone(java.time.ZoneId.systemDefault())
            val today = java.time.LocalDate.now(java.time.ZoneId.systemDefault())
            val pattern = if (dt.toLocalDate() == today) "h:mm a" else "MMM d · h:mm a"
            return dt.format(java.time.format.DateTimeFormatter.ofPattern(pattern, java.util.Locale.getDefault()))
        }

        fun parseInstantMs(raw: String?): Long? {
            val t = raw?.trim().orEmpty()
            if (t.isEmpty()) return null
            return runCatching { java.time.Instant.parse(t).toEpochMilli() }.getOrNull()
                ?: runCatching { java.time.OffsetDateTime.parse(t).toInstant().toEpochMilli() }.getOrNull()
        }
    }
}

/** Mirror of iOS `fmtK` for Long token counts. */
internal fun fmtKLong(n: Long): String = when {
    n >= 1_000_000L -> "%.1fM".format(n / 1_000_000.0)
    n >= 1_000L -> "${(n / 1000.0).roundToInt()}k"
    else -> "$n"
}

// endregion
