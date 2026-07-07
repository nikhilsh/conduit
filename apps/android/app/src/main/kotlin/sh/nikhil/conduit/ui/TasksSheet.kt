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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import sh.nikhil.conduit.SubagentEntry
import sh.nikhil.conduit.tsEpochMillis
import sh.nikhil.conduit.ui.components.ActionPillVariant
import sh.nikhil.conduit.ui.components.ConduitActionPill
import sh.nikhil.conduit.ui.components.ConduitCard
import sh.nikhil.conduit.ui.components.ConduitChip
import sh.nikhil.conduit.ui.components.ConduitTaskSpinner
import sh.nikhil.conduit.ui.components.ConduitTaskStatus

// ---------------------------------------------------------------------------
// TaskSheetRow / TaskSheetGroups -- pure data, Android mirror of iOS
// `ConduitTaskSheetRow` / `ConduitTaskSheetGroups`.
// ---------------------------------------------------------------------------

/**
 * One row in the Tasks sheet, derived from a [SubagentEntry]. Design handoff
 * session_tasks "3. Tasks sheet". See [TasksSheetLogic.groups] for the
 * mapping/grouping/sorting rules.
 */
data class TaskSheetRow(
    val id: String,
    val title: String,
    val status: ConduitTaskStatus,
    val agent: String,
    val meta: String,
    val canStop: Boolean,
    val startedEpochMs: Long,
    val endedEpochMs: Long,
)

/** The sheet's three ordered groups (gate rows, then running, then finished). */
data class TaskSheetGroups(
    val needsYou: List<TaskSheetRow>,
    val running: List<TaskSheetRow>,
    val finished: List<TaskSheetRow>,
) {
    val isEmpty: Boolean get() = needsYou.isEmpty() && running.isEmpty() && finished.isEmpty()
}

/**
 * Pure mapping/grouping/formatting logic behind [TasksSheet]. No Compose
 * runtime dependency -- unit-tested in [sh.nikhil.conduit.ui.TasksSheetLogicTest],
 * mirroring the [sh.nikhil.conduit.ui.ConduitRunningPillLogicTest] precedent.
 *
 * Two real data gaps, both intentional (see also the iOS
 * `ConduitTasksSheet.swift` file header):
 *   - No "gate" status exists in the live roster today -- `statusFromRaw`
 *     maps it defensively for when the broker adds one, but "NEEDS YOU" is
 *     always empty in production.
 *   - No broker verb exists to stop an individual subagent -- [groups]
 *     always maps real entries to `canStop = false`.
 */
object TasksSheetLogic {
    /** Roster `status` string -> [ConduitTaskStatus]. "working" is the only
     * value the broker sends today; unrecognized values fall back to running
     * rather than silently dropping the row. */
    fun statusFromRaw(raw: String): ConduitTaskStatus = when (raw.lowercase()) {
        "done" -> ConduitTaskStatus.Done
        "failed", "error" -> ConduitTaskStatus.Error
        "gate" -> ConduitTaskStatus.Gate
        else -> ConduitTaskStatus.Running
    }

    /** "4m 02s" -- zero-padded seconds, ticking display for running/gated rows. */
    fun elapsedLabel(seconds: Long): String {
        val total = seconds.coerceAtLeast(0)
        val minutes = total / 60
        val secs = total % 60
        return String.format("%dm %02ds", minutes, secs)
    }

    /** Coarse "12m" / "1h 05m" duration for a FINISHED row's meta line. */
    fun finishedDurationLabel(ms: Long): String {
        val totalSeconds = ms.coerceAtLeast(0) / 1000
        if (totalSeconds < 60) return "${totalSeconds}s"
        val minutes = totalSeconds / 60
        if (minutes < 60) return "${minutes}m"
        val hours = minutes / 60
        val remMinutes = minutes % 60
        return if (remMinutes == 0L) "${hours}h" else "${hours}h ${remMinutes}m"
    }

    fun metaFor(entry: SubagentEntry, status: ConduitTaskStatus, elapsedSeconds: Long?): String = when (status) {
        ConduitTaskStatus.Running -> {
            val tool = entry.lastTool.trim()
            val elapsed = elapsedLabel(elapsedSeconds ?: 0L)
            if (tool.isEmpty()) elapsed else "$elapsed · $tool"
        }
        ConduitTaskStatus.Gate -> {
            val description = entry.description.trim()
            description.ifEmpty { "gate - review before merge" }
        }
        ConduitTaskStatus.Done -> "completed · ${finishedDurationLabel(entry.durationMs)}"
        ConduitTaskStatus.Error -> "failed · ${finishedDurationLabel(entry.durationMs)}"
    }

    /**
     * Map + group + sort the live roster into the sheet's three sections.
     * [nowMs] is injectable so tests/previews can pin a stable elapsed value.
     */
    fun groups(roster: List<SubagentEntry>, sessionAgent: String, nowMs: Long = System.currentTimeMillis()): TaskSheetGroups {
        val rows = roster.map { entry ->
            val status = statusFromRaw(entry.status)
            val startedEpochMs = if (entry.startedAt.isEmpty()) Long.MAX_VALUE else tsEpochMillis(entry.startedAt)
            val endedEpochMs = if (entry.endedAt.isEmpty()) Long.MAX_VALUE else tsEpochMillis(entry.endedAt)
            val elapsedSeconds = if (
                (status == ConduitTaskStatus.Running || status == ConduitTaskStatus.Gate) &&
                startedEpochMs != Long.MAX_VALUE
            ) {
                ((nowMs - startedEpochMs) / 1000).coerceAtLeast(0)
            } else {
                null
            }
            val title = entry.name.ifEmpty { entry.description.ifEmpty { "Task" } }
            TaskSheetRow(
                id = entry.taskId,
                title = title,
                status = status,
                agent = sessionAgent,
                meta = metaFor(entry, status, elapsedSeconds),
                // No broker verb exists to stop an individual subagent yet --
                // real rows never offer the control (see object doc).
                canStop = false,
                startedEpochMs = startedEpochMs,
                endedEpochMs = endedEpochMs,
            )
        }
        val needsYou = rows.filter { it.status == ConduitTaskStatus.Gate }
            .sortedByDescending { it.startedEpochMs }
        val running = rows.filter { it.status == ConduitTaskStatus.Running }
            .sortedByDescending { it.startedEpochMs }
        val finished = rows.filter { it.status == ConduitTaskStatus.Done || it.status == ConduitTaskStatus.Error }
            .sortedByDescending { it.endedEpochMs }
        return TaskSheetGroups(needsYou = needsYou, running = running, finished = finished)
    }
}

// ---------------------------------------------------------------------------
// TasksSheet -- Compose UI
// ---------------------------------------------------------------------------

/**
 * Bottom sheet grouping a session's background tasks (design handoff
 * session_tasks "3. Tasks sheet"), opened from [sh.nikhil.conduit.ui.components.ConduitRunningPill]'s
 * tap (PR2). Follows [ComposerAttachSheet]'s chrome conventions
 * ([ModalBottomSheet] + [rememberModalBottomSheetState]).
 *
 * "View transcript" is intentionally omitted: there is no per-task
 * transcript surface yet (design handoff session_tasks PR4 -- the inline
 * `ConduitTaskRow` in the chat transcript, `InlineTaskRow` in
 * [ChatPage] -- opens this same sheet, not a transcript), so there's no
 * destination to link to yet -- a follow-up.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TasksSheet(
    roster: List<SubagentEntry>,
    sessionAgent: String,
    onDismiss: () -> Unit,
    onReview: (TaskSheetRow) -> Unit = {},
    onStop: (TaskSheetRow) -> Unit = {},
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false)
    val neon = LocalNeonTheme.current

    // Elapsed on running/gated rows ticks every second while the sheet is
    // visible.
    var nowMs by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(1000)
            nowMs = System.currentTimeMillis()
        }
    }

    var stopCandidate by remember { mutableStateOf<TaskSheetRow?>(null) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = neon.surfaceSolid,
        shape = RoundedCornerShape(topStart = 26.dp, topEnd = 26.dp),
    ) {
        Column(modifier = Modifier.fillMaxWidth().heightIn(max = 640.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "Tasks",
                    style = MaterialTheme.typography.titleMedium,
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.SemiBold,
                    color = neon.text,
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = onDismiss) {
                    Icon(Icons.Filled.Close, contentDescription = "Close", tint = neon.textDim)
                }
            }
            HorizontalDivider(color = neon.border, thickness = 1.dp)

            if (roster.isEmpty()) {
                Box(
                    modifier = Modifier.fillMaxWidth().padding(32.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        "No background tasks",
                        fontFamily = neon.sans,
                        fontSize = 14.sp,
                        color = neon.textFaint.copy(alpha = 0.7f),
                    )
                }
            } else {
                val groups = remember(roster, sessionAgent, nowMs) {
                    TasksSheetLogic.groups(roster, sessionAgent, nowMs)
                }
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .verticalScroll(rememberScrollState())
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    if (groups.needsYou.isNotEmpty()) {
                        TaskGroupSection(
                            title = "NEEDS YOU",
                            rows = groups.needsYou,
                            labelTint = neon.yellow,
                            glowCard = true,
                            onReview = onReview,
                            onRequestStop = { stopCandidate = it },
                        )
                    }
                    if (groups.running.isNotEmpty()) {
                        TaskGroupSection(
                            title = "RUNNING",
                            rows = groups.running,
                            labelTint = null,
                            glowCard = false,
                            onReview = onReview,
                            onRequestStop = { stopCandidate = it },
                        )
                    }
                    if (groups.finished.isNotEmpty()) {
                        TaskGroupSection(
                            title = "FINISHED",
                            rows = groups.finished,
                            labelTint = null,
                            glowCard = false,
                            onReview = onReview,
                            onRequestStop = { stopCandidate = it },
                        )
                    }
                    Spacer(Modifier.height(8.dp))
                }
            }
        }
    }

    stopCandidate?.let { row ->
        AlertDialog(
            onDismissRequest = { stopCandidate = null },
            title = { Text("Stop this task?") },
            confirmButton = {
                TextButton(onClick = { onStop(row); stopCandidate = null }) {
                    Text("Stop", color = neon.red)
                }
            },
            dismissButton = {
                TextButton(onClick = { stopCandidate = null }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun TaskGroupSection(
    title: String,
    rows: List<TaskSheetRow>,
    labelTint: Color?,
    glowCard: Boolean,
    onReview: (TaskSheetRow) -> Unit,
    onRequestStop: (TaskSheetRow) -> Unit,
) {
    val neon = LocalNeonTheme.current
    val shape = RoundedCornerShape(14.dp)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            "$title · ${rows.size}",
            fontFamily = neon.mono,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 0.6.sp,
            color = labelTint ?: neon.textFaint,
        )
        ConduitCard(
            pad = 0.dp,
            modifier = Modifier
                .then(
                    if (glowCard) {
                        Modifier
                            .then(
                                if (neon.glow) {
                                    Modifier.shadow(
                                        elevation = 10.dp,
                                        shape = shape,
                                        ambientColor = neon.yellow.copy(alpha = 0.35f),
                                        spotColor = neon.yellow.copy(alpha = 0.35f),
                                    )
                                } else {
                                    Modifier
                                },
                            )
                            .border(1.dp, neon.yellow.copy(alpha = 0.27f), shape)
                    } else {
                        Modifier
                    },
                ),
        ) {
            rows.forEachIndexed { index, row ->
                TaskSheetRowView(
                    row = row,
                    isLast = index == rows.lastIndex,
                    onReview = { onReview(row) },
                    onRequestStop = { onRequestStop(row) },
                )
            }
        }
    }
}

/**
 * One row inside a Tasks-sheet group card. Anatomy: leading spinner-or-dot,
 * title + (agent Chip + mono meta) second line, trailing stop-ring
 * (running + canStop) or Review pill (gate).
 */
@Composable
private fun TaskSheetRowView(
    row: TaskSheetRow,
    isLast: Boolean,
    onReview: () -> Unit,
    onRequestStop: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    val dotTint = when (row.status) {
        ConduitTaskStatus.Running, ConduitTaskStatus.Gate -> neon.yellow
        ConduitTaskStatus.Done -> neon.green
        ConduitTaskStatus.Error -> neon.red
    }
    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 13.dp, horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(11.dp),
        ) {
            if (row.status == ConduitTaskStatus.Running) {
                ConduitTaskSpinner(size = 16.dp, tint = neon.yellow)
            } else {
                val glowing = row.status == ConduitTaskStatus.Gate && neon.glow
                Box(
                    Modifier
                        .size(8.dp)
                        .then(
                            if (glowing) {
                                Modifier.shadow(
                                    elevation = 4.dp,
                                    shape = CircleShape,
                                    ambientColor = dotTint,
                                    spotColor = dotTint,
                                )
                            } else {
                                Modifier
                            },
                        )
                        .clip(CircleShape)
                        .background(dotTint),
                )
            }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    row.title,
                    fontFamily = neon.sans,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = neon.text,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    ConduitChip(label = row.agent, tint = neonAgentColor(row.agent, neon))
                    Text(
                        row.meta,
                        fontFamily = neon.mono,
                        fontSize = 11.sp,
                        color = if (row.status == ConduitTaskStatus.Gate) neon.yellow else neon.textFaint,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            when {
                row.status == ConduitTaskStatus.Gate -> {
                    ConduitActionPill(
                        label = "Review",
                        leadingIcon = Icons.Filled.Warning,
                        variant = ActionPillVariant.Solid,
                        tint = neon.yellow,
                        onClick = onReview,
                    )
                }
                row.status == ConduitTaskStatus.Running && row.canStop -> {
                    TaskStopButton(onClick = onRequestStop)
                }
            }
        }
        if (!isLast) {
            HorizontalDivider(color = neon.lineSoft, thickness = 1.dp)
        }
    }
}

/** 34dp hairline ring around a 10dp red rounded square, in a >=44dp tap target. */
@Composable
private fun TaskStopButton(onClick: () -> Unit) {
    val neon = LocalNeonTheme.current
    Box(
        modifier = Modifier
            .size(44.dp)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size(34.dp)
                .clip(CircleShape)
                .border(1.dp, neon.lineSoft, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Box(
                modifier = Modifier
                    .size(10.dp)
                    .clip(RoundedCornerShape(2.5.dp))
                    .background(neon.red),
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Previews
// ---------------------------------------------------------------------------

@Preview(showBackground = true, backgroundColor = 0xFF04050A)
@Composable
private fun TasksSheetContentPreview() {
    val neon = NeonTheme.resolve(palette = NeonPalette.ICE, dark = true, glow = true)
    androidx.compose.runtime.CompositionLocalProvider(LocalNeonTheme provides neon) {
        val groups = TasksSheetLogic.groups(
            roster = previewRoster,
            sessionAgent = "codex",
            nowMs = previewNowMs,
        )
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            TaskGroupSection(
                title = "NEEDS YOU",
                rows = groups.needsYou,
                labelTint = neon.yellow,
                glowCard = true,
                onReview = {},
                onRequestStop = {},
            )
            TaskGroupSection(
                title = "RUNNING",
                rows = groups.running,
                labelTint = null,
                glowCard = false,
                onReview = {},
                onRequestStop = {},
            )
            TaskGroupSection(
                title = "FINISHED",
                rows = groups.finished,
                labelTint = null,
                glowCard = false,
                onReview = {},
                onRequestStop = {},
            )
        }
    }
}

// `TasksSheetLogic.groups` always maps real roster entries to
// `canStop = false` (no broker kill verb exists yet -- see object doc), so
// the only way to preview the stop control is to construct a row directly.
@Preview(showBackground = true, backgroundColor = 0xFF04050A)
@Composable
private fun TaskSheetRowCanStopPreview() {
    val neon = NeonTheme.resolve(palette = NeonPalette.ICE, dark = true, glow = true)
    androidx.compose.runtime.CompositionLocalProvider(LocalNeonTheme provides neon) {
        TaskSheetRowView(
            row = TaskSheetRow(
                id = "preview-stop",
                title = "PR B - Start sheet + wizard",
                status = ConduitTaskStatus.Running,
                agent = "codex",
                meta = "4m 02s · swift build",
                canStop = true,
                startedEpochMs = 0L,
                endedEpochMs = 0L,
            ),
            isLast = true,
            onReview = {},
            onRequestStop = {},
        )
    }
}

@Preview(showBackground = true, backgroundColor = 0xFF04050A)
@Composable
private fun TaskSheetRowGatePreview() {
    val neon = NeonTheme.resolve(palette = NeonPalette.ICE, dark = true, glow = true)
    androidx.compose.runtime.CompositionLocalProvider(LocalNeonTheme provides neon) {
        TaskSheetRowView(
            row = TaskSheetRow(
                id = "preview-gate",
                title = "PR C - Monitor",
                status = ConduitTaskStatus.Gate,
                agent = "claude",
                meta = "gate - review before merge",
                canStop = false,
                startedEpochMs = 0L,
                endedEpochMs = 0L,
            ),
            isLast = true,
            onReview = {},
            onRequestStop = {},
        )
    }
}

private val previewNowMs = System.currentTimeMillis()

private val previewRoster: List<SubagentEntry> = listOf(
    SubagentEntry(
        taskId = "gate-1",
        name = "PR C - Monitor",
        description = "gate - review before merge",
        status = "gate",
        lastTool = "",
        tokens = 0L,
        toolUses = 0,
        durationMs = 0L,
        startedAt = java.time.Instant.ofEpochMilli(previewNowMs - 370_000).toString(),
        endedAt = "",
    ),
    SubagentEntry(
        taskId = "running-1",
        name = "PR B - Start sheet + wizard",
        description = "",
        status = "working",
        lastTool = "swift build",
        tokens = 0L,
        toolUses = 0,
        durationMs = 0L,
        startedAt = java.time.Instant.ofEpochMilli(previewNowMs - 242_000).toString(),
        endedAt = "",
    ),
    SubagentEntry(
        taskId = "done-1",
        name = "PR A - Flow atoms + home",
        description = "",
        status = "done",
        lastTool = "",
        tokens = 0L,
        toolUses = 0,
        durationMs = 12 * 60 * 1000L,
        startedAt = java.time.Instant.ofEpochMilli(previewNowMs - 900_000).toString(),
        endedAt = java.time.Instant.ofEpochMilli(previewNowMs - 180_000).toString(),
    ),
    SubagentEntry(
        taskId = "error-1",
        name = "PR D - Broker redeploy",
        description = "",
        status = "failed",
        lastTool = "",
        tokens = 0L,
        toolUses = 0,
        durationMs = 45 * 1000L,
        startedAt = java.time.Instant.ofEpochMilli(previewNowMs - 500_000).toString(),
        endedAt = java.time.Instant.ofEpochMilli(previewNowMs - 400_000).toString(),
    ),
)
