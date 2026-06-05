package sh.nikhil.conduit.ui

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
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import sh.nikhil.conduit.SessionStore

/**
 * Conduit redesign "Fan-out · parallel runs" surface (handoff §B.11,
 * image 13). One task, many runs: configure a single task + N branches,
 * launch N parallel sessions of that same task (one per branch), and watch
 * each run's progress / status (running / done / failed). Android mirror of
 * iOS `ConduitUI.FanOutView`.
 *
 * ── HOW TO PRESENT ──────────────────────────────────────────────────────
 * Shown as a [ModalBottomSheet] (dismiss via [onDismiss]). The host owns
 * the launch wiring:
 *
 *     if (showFanOut) {
 *         FanOutScreen(
 *             store = store,
 *             onLaunch = { task, branches ->
 *                 // REAL launch: one session per branch
 *                 branches.forEach { b ->
 *                     store.createSession(assistant = "claude", branch = b,
 *                                         initialPrompt = task)
 *                 }
 *             },
 *             onCompare = { /* no backend yet — see below */ },
 *             onDismiss = { showFanOut = false },
 *         )
 *     }
 *
 * ── WHAT IS REAL vs. STUB ───────────────────────────────────────────────
 * • LAUNCH is real: [onLaunch] hands the host the task + branches; the host
 *   fans out into `store.createSession(assistant, branch, reasoningEffort,
 *   model, cwd)` (or the `createSession(assistant, branch, initialPrompt)`
 *   convenience overload) ONCE PER BRANCH. There is no dedicated fan-out /
 *   orchestration backend — a fan-out is literally N independent sessions
 *   of the same task across N branches.
 * • PROGRESS is real, but only AFTER launch: each run's status is derived
 *   from the live [uniffi.conduit_core.SessionStatus.phase] for the session
 *   keyed to that branch (running → cyan, exited(0) → done/green,
 *   exited(≠0) → failed/red). Before launch the configured branches show a
 *   neutral "queued" state — never a fabricated in-progress bar.
 * • COMPARE & KEEP BEST is a STUB: there is no backend to diff / rank the N
 *   runs and keep the winner. The button just invokes [onCompare]
 *   (defaulted no-op). Wire it when a backend exists.
 *
 * This composable does NOT call `createSession` and does NOT mutate the
 * store — it only reflects status the store already holds (via
 * [runs]). Launch wiring is the host's job.
 */

/** Status of a single run, derived purely from the session phase. */
enum class FanOutRunState { QUEUED, RUNNING, DONE, FAILED }

/**
 * One configured run inside a fan-out: a branch + the box it runs on.
 * [sessionId] is null until the host launches the run and supplies the
 * freshly-created session id; once set, the row's progress/status is driven
 * from the live `SessionStatus.phase`.
 */
data class FanOutRun(
    val branch: String,
    val box: String = "",
    val sessionId: String? = null,
)

/**
 * Map a launched run's live `SessionStatus.phase` to a [FanOutRunState].
 * `phase` mirrors the broker vocabulary: "running", "ready", "exited",
 * "exited(0)", "exited(137)", … An exited phase with a non-zero code is a
 * failure; "exited(0)"/"exited" is done; anything else is running.
 */
fun fanOutRunState(sessionId: String?, phase: String?): FanOutRunState {
    if (sessionId == null) return FanOutRunState.QUEUED
    if (phase.isNullOrEmpty()) return FanOutRunState.RUNNING
    if (!phase.startsWith("exited")) return FanOutRunState.RUNNING
    val open = phase.indexOf('(')
    val close = phase.indexOf(')')
    if (open in 0 until close) {
        val code = phase.substring(open + 1, close).toIntOrNull()
        if (code != null) return if (code == 0) FanOutRunState.DONE else FanOutRunState.FAILED
    }
    // Bare "exited" with no code → clean finish.
    return FanOutRunState.DONE
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FanOutScreen(
    store: SessionStore,
    onLaunch: (String, List<String>) -> Unit = { _, _ -> },
    onCompare: () -> Unit = {},
    onDismiss: () -> Unit = {},
    runs: List<FanOutRun> = emptyList(),
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val statuses by store.statusBySession.collectAsState()
    val neon = LocalNeonTheme.current

    // Configure state (pre-launch). `runs` non-empty = launched view.
    var task by remember { mutableStateOf("") }
    val branchDrafts = remember { mutableStateListOf<String>() }
    var newBranch by remember { mutableStateOf("") }

    val hasLaunched = runs.isNotEmpty()
    val visibleRuns: List<FanOutRun> =
        if (hasLaunched) runs else branchDrafts.map { FanOutRun(branch = it) }

    val branchesBoxesLabel = remember(visibleRuns) {
        val boxes = visibleRuns.mapNotNull { it.box.takeIf(String::isNotBlank) }.toSet().size
        if (boxes > 0) "${visibleRuns.size} branches · $boxes boxes" else "${visibleRuns.size} branches"
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = neon.surfaceSolid,
        shape = RoundedCornerShape(topStart = 26.dp, topEnd = 26.dp),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                // Honor the real bottom safe-area inset so the Compare bar
                // clears the gesture pill / 3-button nav (handoff §C.1).
                .windowInsetsPadding(WindowInsets.navigationBars)
                .padding(horizontal = 16.dp, vertical = 12.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            // Title + run count.
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    "Fan-out",
                    style = MaterialTheme.typography.titleLarge,
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.Bold,
                    color = neon.text,
                )
                Text(
                    "${visibleRuns.size} runs",
                    style = MaterialTheme.typography.labelMedium,
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.SemiBold,
                    color = neon.textDim,
                )
            }

            // ── Shared task card ──────────────────────────────────────────
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface),
            ) {
                Column(
                    modifier = Modifier.padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Text(
                        "SHARED TASK",
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.Bold,
                        color = neon.textDim,
                    )
                    if (hasLaunched) {
                        Text(
                            task.ifBlank { "—" },
                            style = MaterialTheme.typography.titleMedium,
                            fontFamily = neon.sans,
                            fontWeight = FontWeight.SemiBold,
                            color = neon.text,
                        )
                    } else {
                        // Editable before launch (configure state).
                        BasicTextField(
                            value = task,
                            onValueChange = { task = it },
                            textStyle = MaterialTheme.typography.titleMedium.copy(
                                fontFamily = neon.sans,
                                fontWeight = FontWeight.SemiBold,
                                color = neon.text,
                            ),
                            cursorBrush = androidx.compose.ui.graphics.SolidColor(neon.accent),
                            modifier = Modifier.fillMaxWidth(),
                            decorationBox = { inner ->
                                if (task.isEmpty()) {
                                    Text(
                                        "Describe the task to run across branches…",
                                        style = MaterialTheme.typography.titleMedium,
                                        fontFamily = neon.sans,
                                        color = neon.textFaint,
                                    )
                                }
                                inner()
                            },
                        )
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FanOutChip("1 task", neon.green, neon)
                        FanOutChip(branchesBoxesLabel, neon.accent, neon)
                    }
                }
            }

            // ── Parallel runs ─────────────────────────────────────────────
            Text(
                "PARALLEL RUNS",
                style = MaterialTheme.typography.labelSmall,
                fontFamily = neon.mono,
                fontWeight = FontWeight.Bold,
                color = neon.textDim,
                modifier = Modifier.padding(start = 4.dp),
            )

            if (visibleRuns.isEmpty()) {
                Text(
                    "Add branches below to configure runs.",
                    style = MaterialTheme.typography.bodyMedium,
                    fontFamily = neon.sans,
                    color = neon.textFaint,
                )
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    visibleRuns.forEach { run ->
                        val state = fanOutRunState(run.sessionId, statuses[run.sessionId]?.phase)
                        RunRow(run = run, state = state, neon = neon)
                    }
                }
            }

            // ── Configure: add branch ─────────────────────────────────────
            if (!hasLaunched) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface),
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp).fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        BasicTextField(
                            value = newBranch,
                            onValueChange = { newBranch = it },
                            textStyle = MaterialTheme.typography.bodyMedium.copy(
                                fontFamily = neon.mono,
                                color = neon.text,
                            ),
                            cursorBrush = androidx.compose.ui.graphics.SolidColor(neon.accent),
                            modifier = Modifier.weight(1f),
                            decorationBox = { inner ->
                                if (newBranch.isEmpty()) {
                                    Text(
                                        "branch name (e.g. fix/ratelimit-a)",
                                        style = MaterialTheme.typography.bodyMedium,
                                        fontFamily = neon.mono,
                                        color = neon.textFaint,
                                    )
                                }
                                inner()
                            },
                        )
                        val trimmed = newBranch.trim()
                        val canAdd = trimmed.isNotEmpty() && !branchDrafts.contains(trimmed)
                        Box(
                            modifier = Modifier
                                .size(32.dp)
                                .clip(CircleShape)
                                .background(if (canAdd) neon.accent else neon.surface2)
                                .clickable(enabled = canAdd) {
                                    branchDrafts.add(trimmed)
                                    newBranch = ""
                                },
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                Icons.Default.Add,
                                contentDescription = "Add branch",
                                tint = if (canAdd) neon.accentText else neon.textFaint,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }
                }
            }

            // ── Launch (pre-launch) / Compare (post-launch) ────────────────
            if (hasLaunched) {
                FanOutPrimaryButton(
                    label = "Compare & keep best",
                    icon = Icons.Default.Check,
                    enabled = true,
                    neon = neon,
                    onClick = onCompare,
                )
            } else {
                val canLaunch = task.trim().isNotEmpty() && branchDrafts.isNotEmpty()
                FanOutPrimaryButton(
                    label = "Launch ${branchDrafts.size} runs",
                    icon = null,
                    enabled = canLaunch,
                    neon = neon,
                    onClick = { onLaunch(task.trim(), branchDrafts.toList()) },
                )
            }

            Spacer(Modifier.height(8.dp))
        }
    }
}

/** One run row: branch + box + progress bar + status chip. */
@Composable
private fun RunRow(run: FanOutRun, state: FanOutRunState, neon: NeonTheme) {
    val tint = when (state) {
        FanOutRunState.QUEUED -> neon.textFaint
        FanOutRunState.RUNNING -> neon.accent // cyan
        FanOutRunState.DONE -> neon.green
        FanOutRunState.FAILED -> neon.red
    }
    val label = when (state) {
        FanOutRunState.QUEUED -> "queued"
        FanOutRunState.RUNNING -> "running"
        FanOutRunState.DONE -> "done"
        FanOutRunState.FAILED -> "failed"
    }
    // No backend % signal: full bar for done/failed, partial for running,
    // empty for queued. Never fabricate intermediate progress.
    val fraction = when (state) {
        FanOutRunState.QUEUED -> 0f
        FanOutRunState.RUNNING -> 0.5f
        FanOutRunState.DONE -> 1f
        FanOutRunState.FAILED -> 1f
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(
                neon = neon,
                shape = RoundedCornerShape(14.dp),
                fill = neon.surface,
                failed = state == FanOutRunState.FAILED,
                glowTint = if (state == FanOutRunState.QUEUED) null else tint,
            ),
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                ConduitMark(size = 16.dp, color = tint)
                Spacer(Modifier.width(8.dp))
                Text(
                    run.branch,
                    style = MaterialTheme.typography.bodyMedium,
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.SemiBold,
                    color = neon.text,
                )
                Spacer(Modifier.weight(1f))
                if (run.box.isNotBlank()) {
                    Text(
                        run.box,
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = neon.mono,
                        color = neon.textFaint,
                    )
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                // Progress track.
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .height(6.dp)
                        .clip(RoundedCornerShape(3.dp))
                        .background(neon.surface2),
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth(fraction)
                            .height(6.dp)
                            .clip(RoundedCornerShape(3.dp))
                            .background(tint),
                    )
                }
                Spacer(Modifier.width(10.dp))
                Text(
                    label.uppercase(),
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.Bold,
                    color = tint,
                )
            }
        }
    }
}

@Composable
private fun FanOutChip(text: String, tint: Color, neon: NeonTheme) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(neon.surface2)
            .border(1.dp, tint.copy(alpha = 0.45f), RoundedCornerShape(50))
            .padding(horizontal = 9.dp, vertical = 4.dp),
    ) {
        Text(
            text,
            style = MaterialTheme.typography.labelMedium,
            fontFamily = neon.mono,
            fontWeight = FontWeight.SemiBold,
            color = tint,
        )
    }
}

@Composable
private fun FanOutPrimaryButton(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector?,
    enabled: Boolean,
    neon: NeonTheme,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(if (enabled) neon.accent else neon.surface2)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(vertical = 14.dp),
        contentAlignment = Alignment.Center,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (icon != null) {
                Icon(
                    icon,
                    contentDescription = null,
                    tint = if (enabled) neon.accentText else neon.textFaint,
                    modifier = Modifier.size(16.dp),
                )
            }
            Text(
                label,
                style = MaterialTheme.typography.titleSmall,
                fontFamily = neon.sans,
                fontWeight = FontWeight.Bold,
                color = if (enabled) neon.accentText else neon.textFaint,
            )
        }
    }
}
