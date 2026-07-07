package sh.nikhil.conduit.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CallSplit
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry
import sh.nikhil.conduit.ui.components.ConduitChip
import kotlin.math.max
import kotlin.math.min

/**
 * One row of `GET /api/pipelines`. Mirrors
 * `broker/internal/ws/pipeline.go`'s `pipelineListItem` JSON shape and iOS
 * `ConduitUI.PipelineSummary`. `state` is a raw string (not an enum) so an
 * unrecognized future state from a newer broker never fails decode -- it
 * just falls into the "active" default sort bucket (see
 * [PipelineListViewModel.group]).
 */
data class PipelineSummary(
    val id: String,
    val title: String,
    val state: String,
    val currentStep: Int,
    val stepCount: Int,
    val created: String?,
    /** Per-step topology summary carried on each list item since broker
     *  #922 -- null on an older broker. [FlowCard] uses this for a real
     *  `TopoMini` strip (agent dots + gate glyphs + per-step status)
     *  instead of the stepCount-only degraded rendering. */
    val steps: List<PipelineSummaryStep>? = null,
    /** Diffstat-only recap, populated once the pipeline completes (broker
     *  #922). Null on an older broker or a pre-#906 pipeline. */
    val result: PipelineSummaryResult? = null,
    /** Whether this flow has been archived (broker #932, `pipeline_archive`
     *  capability). False on an older broker. Mirror of iOS
     *  `PipelineSummary.archived`. */
    val archived: Boolean = false,
)

/**
 * One step's mini-topology entry on a `GET /api/pipelines` list item
 * (broker #922 `pipelineStepSummary`). Mirrors iOS `PipelineSummaryStep`.
 */
data class PipelineSummaryStep(
    val agent: String,
    val role: String,
    /** "queued" | "running" | "done" | "failed" | "awaiting_gate" | "awaiting_pick" */
    val status: String,
    val gateAfter: Boolean,
)

/**
 * Diffstat-only slice of `PipelineResult` carried on a completed list item
 * (broker #922) -- output is deliberately omitted. Mirrors iOS
 * `PipelineSummaryResult`.
 */
data class PipelineSummaryResult(
    val filesChanged: Int,
    val insertions: Int,
    val deletions: Int,
    val finished: String?,
)

/**
 * Pure sort/group helpers for the pipeline list -- kept off Compose so
 * they're unit-testable from a plain JVM test (mirrors iOS
 * `ConduitUI.PipelineListViewModel`).
 */
object PipelineListViewModel {
    enum class Group { NEEDS_YOU, ACTIVE, TERMINAL }

    /**
     * `awaiting_gate` / `awaiting_pick` need the user; `complete` / `failed` /
     * `cancelled` are terminal; everything else (`pending`, `running`,
     * `step_done`, and any unrecognized future state) is treated as active
     * so new broker states stay visible rather than vanishing or misfiling
     * as "needs you".
     */
    fun group(state: String): Group = when (state) {
        "awaiting_gate", "awaiting_pick" -> Group.NEEDS_YOU
        "complete", "failed", "cancelled" -> Group.TERMINAL
        else -> Group.ACTIVE
    }

    /**
     * Sort order: needs-you first, then active/running, then terminal
     * pipelines most-recently-created first. Stable within the needs-you/
     * active groups (preserves broker list order); terminal pipelines sort
     * by `created` descending (ISO8601 strings sort lexicographically).
     */
    fun sorted(items: List<PipelineSummary>): List<PipelineSummary> {
        return items.withIndex().sortedWith(
            compareBy<IndexedValue<PipelineSummary>> { group(it.value.state).ordinal }
                .thenByDescending { if (group(it.value.state) == Group.TERMINAL) (it.value.created ?: "") else "" }
                .thenBy { it.index },
        ).map { it.value }
    }

    /**
     * Home's "any pipeline active" affordance gate -- every non-terminal
     * broker state (`pending` / `running` / `step_done` / `awaiting_gate` /
     * `awaiting_pick`; see `broker/internal/pipeline/pipeline.go`).
     * Originally just the three "awaiting/running" states, which missed a
     * just-started flow sitting in `pending` and the brief `step_done`
     * window between steps -- a live flow could sit in either without ever
     * qualifying for the Home FLOWS section (device feedback). Mirror of
     * iOS `isActiveForHomeAffordance`.
     */
    fun isActiveForHomeAffordance(state: String): Boolean =
        state == "pending" || state == "running" || state == "step_done" ||
            state == "awaiting_gate" || state == "awaiting_pick"

    /**
     * Home's "recently finished" affordance gate: a pipeline that reached
     * `complete` or `failed` within the last 24h. Keeps a just-finished
     * pipeline visible on Home instead of vanishing the instant its last
     * step settles (only reachable via the full Pipelines list before
     * this) -- but doesn't resurrect arbitrarily old history.
     *
     * `GET /api/pipelines` carries only `created` (no top-level "ended"
     * timestamp), so this uses `created` as the recency signal -- a
     * reasonable proxy since pipelines are short-lived (minutes to low
     * hours), not a precise completion time. `cancelled` is deliberately
     * excluded (an explicit user action, not a completion the user needs
     * surfaced back to them). Mirror of iOS `isRecentTerminal`.
     */
    fun isRecentTerminal(summary: PipelineSummary, nowMillis: Long = System.currentTimeMillis()): Boolean {
        if (summary.state != "complete" && summary.state != "failed") return false
        val created = summary.created ?: return false
        val createdMillis = parseIso8601Millis(created) ?: return false
        return nowMillis - createdMillis <= 24L * 3600 * 1000
    }

    /** Minimal ISO-8601 (RFC3339, `Z`-suffixed UTC) parser -- avoids
     * pulling in java.time.Instant's stricter format requirements for the
     * broker's `time.Now().UTC().Format(time.RFC3339)` output. Returns
     * null on any parse failure (treated as "not recent" by the caller). */
    private fun parseIso8601Millis(iso: String): Long? = try {
        java.time.Instant.parse(iso).toEpochMilli()
    } catch (_: Exception) {
        null
    }
}

/**
 * Lists pipelines from `GET /api/pipelines` and opens the monitor for the
 * tapped one via [onOpenPipeline]. Android mirror of iOS
 * `ConduitUI.PipelineListView`. This closes the gap where a pipeline kept
 * running server-side but became unreachable in the app the moment its
 * creation sheet was dismissed -- `PipelineBuilderScreen`'s own post-create
 * navigation was previously the ONLY path to the monitor.
 */
@Composable
fun PipelineListScreen(
    store: SessionStore,
    onOpenPipeline: (id: String, title: String) -> Unit,
    onDismiss: () -> Unit = {},
) {
    val neon = LocalNeonTheme.current
    val pipelineArchive by store.pipelineArchive.collectAsState()
    var pipelines by remember { mutableStateOf<List<PipelineSummary>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    // design_handoff_flow audit §F: smallest-viable way to see archived
    // flows -- a toggle that refetches with include_archived=1. Off by
    // default so the everyday list stays uncluttered.
    var showArchived by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    suspend fun load() {
        isLoading = true
        val fetched = store.refreshPipelines(includeArchived = showArchived)
        pipelines = fetched
        isLoading = false
        Telemetry.breadcrumb("pipeline", "list opened", mapOf("count" to fetched.size.toString(), "includeArchived" to showArchived.toString()))
    }

    fun setArchived(p: PipelineSummary, archived: Boolean) {
        scope.launch {
            val ok = store.setPipelineArchived(id = p.id, archived = archived)
            if (ok) load()
        }
    }

    // Reruns on toggle (and once on first composition) -- `load()` itself
    // emits the "list opened" breadcrumb with the current includeArchived
    // state, so no separate toggle breadcrumb is needed here.
    LaunchedEffect(showArchived) { load() }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(neon.bg)
            .windowInsetsPadding(WindowInsets.navigationBars),
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier
                        .size(32.dp)
                        .background(neon.surface, CircleShape)
                        .border(1.dp, neon.border, CircleShape)
                        .clickable(onClick = onDismiss),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Default.Close, "Close", tint = neon.textDim, modifier = Modifier.size(16.dp))
                }
                Spacer(Modifier.width(12.dp))
                Text(
                    "Flows",
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.Bold,
                    fontSize = 18.sp,
                    color = neon.text,
                    modifier = Modifier.weight(1f),
                )
            }

            if (pipelineArchive) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 14.dp, vertical = 4.dp)
                        .clickable { showArchived = !showArchived },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "Show archived",
                        fontFamily = neon.sans,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 13.sp,
                        color = neon.text,
                        modifier = Modifier.weight(1f),
                    )
                    androidx.compose.material3.Switch(
                        checked = showArchived,
                        onCheckedChange = { showArchived = it },
                        colors = androidx.compose.material3.SwitchDefaults.colors(checkedTrackColor = neon.accent),
                    )
                }
            }

            when {
                isLoading && pipelines.isEmpty() -> EmptyPipelines(neon, loading = true)
                pipelines.isEmpty() -> EmptyPipelines(neon, loading = false)
                else -> {
                    val sorted = remember(pipelines) { PipelineListViewModel.sorted(pipelines) }
                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(start = 14.dp, end = 14.dp, top = 4.dp, bottom = 18.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        items(sorted, key = { it.id }) { p ->
                            PipelineListRow(
                                pipeline = p,
                                neon = neon,
                                archiveEnabled = pipelineArchive,
                                onTap = {
                                    Telemetry.breadcrumb(
                                        "pipeline", "reentered monitor",
                                        mapOf("id_prefix" to p.id.take(8)),
                                    )
                                    onOpenPipeline(p.id, p.title.ifEmpty { "Flow" })
                                },
                                onArchive = { setArchived(p, true) },
                                onUnarchive = { setArchived(p, false) },
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun EmptyPipelines(neon: NeonTheme, loading: Boolean) {
    Column(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        if (loading) {
            CircularProgressIndicator(color = neon.accent)
            Spacer(Modifier.height(12.dp))
            Text("Loading flows...", fontFamily = neon.sans, fontSize = 14.sp, color = neon.textDim)
        } else {
            Icon(Icons.AutoMirrored.Filled.CallSplit, null, tint = neon.textFaint, modifier = Modifier.size(28.dp))
            Spacer(Modifier.height(12.dp))
            Text(
                "No flows yet",
                fontFamily = neon.sans,
                fontWeight = FontWeight.SemiBold,
                fontSize = 15.sp,
                color = neon.text,
            )
            Spacer(Modifier.height(6.dp))
            Text(
                "Flows you create keep running here even after you close the sheet.",
                fontFamily = neon.sans,
                fontSize = 13.sp,
                color = neon.textDim,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 32.dp),
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun PipelineListRow(
    pipeline: PipelineSummary,
    neon: NeonTheme,
    onTap: () -> Unit,
    archiveEnabled: Boolean = false,
    onArchive: () -> Unit = {},
    onUnarchive: () -> Unit = {},
) {
    var menuOpen by remember { mutableStateOf(false) }
    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                // design_handoff_flow audit §F: archived rows render at
                // reduced opacity so "Show archived" reads as a distinct,
                // quieter set.
                .alpha(if (pipeline.archived) 0.55f else 1f)
                .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface)
                .combinedClickable(onClick = onTap, onLongClick = { if (archiveEnabled) menuOpen = true })
                .padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    pipeline.title.ifEmpty { "Flow" },
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 14.sp,
                    color = neon.text,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(4.dp))
                val stepCount = max(pipeline.stepCount, 1)
                Text(
                    "Step ${min(pipeline.currentStep + 1, stepCount)} / $stepCount",
                    fontFamily = neon.mono,
                    fontSize = 11.sp,
                    color = neon.textDim,
                )
            }
            if (pipeline.archived) {
                ConduitChip(label = "archived", tint = neon.textFaint)
            }
            PipelineListStateChip(state = pipeline.state, neon = neon)
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = neon.textFaint, modifier = Modifier.size(14.dp))
        }
        if (archiveEnabled) {
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                if (pipeline.archived) {
                    DropdownMenuItem(
                        text = { Text("Unarchive") },
                        onClick = { menuOpen = false; onUnarchive() },
                    )
                } else if (PipelineListViewModel.group(pipeline.state) == PipelineListViewModel.Group.TERMINAL) {
                    DropdownMenuItem(
                        text = { Text("Archive") },
                        onClick = { menuOpen = false; onArchive() },
                    )
                }
            }
        }
    }
}

@Composable
private fun PipelineListStateChip(state: String, neon: NeonTheme) {
    val (label, color) = when (state) {
        "running" -> "Running" to neon.accent
        "awaiting_gate" -> "Needs you" to neon.yellow
        "awaiting_pick" -> "Needs you" to neon.yellow
        "complete" -> "Complete" to neon.textDim
        "failed" -> "Failed" to neon.red
        "cancelled" -> "Cancelled" to neon.textFaint
        else -> state to neon.textFaint
    }
    ConduitChip(label = label, tint = color)
}
