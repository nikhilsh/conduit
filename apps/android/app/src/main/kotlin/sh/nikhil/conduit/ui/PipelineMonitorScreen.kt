package sh.nikhil.conduit.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import sh.nikhil.conduit.SavedSession
import sh.nikhil.conduit.SavedSessionStatus
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry
import sh.nikhil.conduit.ui.components.AgentDot
import sh.nikhil.conduit.ui.components.ConduitChip
import sh.nikhil.conduit.ui.components.FlowAgentStatus
import sh.nikhil.conduit.ui.components.GateGlyph
import sh.nikhil.conduit.ui.components.GatePill
import java.net.HttpURLConnection
import java.net.URL

// MARK: Fanout data classes

/** One parallel run within a fanout step. */
data class FanoutRun(
    val index: Int,
    val agentType: String,
    val sessionId: String?,
    val branch: String?,
    val phase: String?,
    val started: String? = null,
    val ended: String? = null,
) {
    // "turn_complete" is the structured-chat (claude/codex) completion
    // signal -- those backends never exit the process between turns, so
    // there is no "exited(0)" to observe. It counts as done, mirroring
    // exitCodeFromPhase in broker/internal/pipeline/orchestrator.go.
    val isDone: Boolean get() = phase == "exited(0)" || phase == "exited" || phase == "turn_complete"
    val isFailed: Boolean get() = phase != null && phase.startsWith("exited") && !isDone
    val isRunning: Boolean get() = phase == "running" || phase == "ready"
}

/** Fanout configuration + runtime state on a pipeline step. */
data class FanoutStatus(
    val count: Int,
    val agentTypes: List<String>,
    val runs: List<FanoutRun>,
    val winner: Int?,
)

/**
 * Live state for a `kind == "loop"` step -- broker `pipeline.LoopConfig`
 * (docs/PLAN-HARNESS-BUILDER.md §4.2). Only the fields the Monitor needs to
 * render "iteration k/N" are decoded here (not `body`/`until`, which are
 * create-time config the Monitor never re-renders).
 */
data class PipelineLoopStatus(
    val maxIterations: Int,
    /** Number of completed passes so far. */
    val iteration: Int?,
)

/** Data classes for pipeline state. */
data class PipelineStep(
    val index: Int,
    val agentType: String,
    val role: String,
    val promptTemplate: String,
    val inputFromPrev: String,
    val gateAfter: Boolean,
    val sessionId: String?,
    val phase: String?,
    val started: String? = null,
    val ended: String? = null,
    /** Number of times this step has been retried via POST /api/pipeline/{id}/resume. */
    val retries: Int = 0,
    /** Previous session IDs for retried executions of this step. */
    val prevSessionIds: List<String> = emptyList(),
    /** Fanout config and runtime state; null for normal steps. */
    val fanout: FanoutStatus? = null,
    /**
     * "" (plain agent step) | "branch" | "loop" (PLAN-HARNESS-BUILDER
     * Phase 3). A "branch" step is transient -- the orchestrator splices it
     * away once its condition is resolved, so this is really only ever
     * observed as "loop" or absent/"" in practice.
     */
    val kind: String = "",
    /**
     * Provenance set when this step was produced by resolving a branch's
     * condition (e.g. "step 2 branch (then)"). Null for a step that was
     * never spliced.
     */
    val splicedFrom: String? = null,
    /** Live loop state. Present only when kind == "loop". */
    val loop: PipelineLoopStatus? = null,
    /**
     * This step's harvested last-assistant text (broker `Step.Output`,
     * #906). Null/empty on older brokers or a step that hasn't produced
     * output yet. Drives the per-step output disclosure in
     * [PipelineStepRow] -- the transcript stays the deep-dive path, this
     * is just a preview.
     */
    val output: String? = null,
) {
    val isFanout: Boolean get() = fanout != null
    val isLoop: Boolean get() = kind == "loop"
    val wasSpliced: Boolean get() = !splicedFrom.isNullOrEmpty()

    /** Display-state fallback for a step whose `phase` doesn't map to a
     * known bucket (null/empty or an unmapped future value). Inferred from
     * surrounding pipeline context, in precedence order, so an unrecognized
     * phase never misrepresents a step that has plainly already run (or
     * hasn't started):
     *   a. `ended` is set                             -> DONE
     *   b. the pipeline itself completed successfully -> DONE
     *   c. this step's index is behind currentStep    -> DONE
     *   d. the pipeline failed AND this is the current
     *      step (the one that failed)                 -> FAILED
     *   e. otherwise                                   -> null (queued)
     * Returns null to mean "no fallback signal applies" -- the caller
     * renders QUEUED in that case. Mirror of iOS
     * `PipelineStepStatus.fallbackState`. */
    fun fallbackState(pipeline: Pipeline): PipelineStepDisplayViewModel.State? {
        if (ended != null) return PipelineStepDisplayViewModel.State.DONE
        if (pipeline.state == "complete") return PipelineStepDisplayViewModel.State.DONE
        if (index < pipeline.currentStep) return PipelineStepDisplayViewModel.State.DONE
        if (pipeline.state == "failed" && index == pipeline.currentStep) {
            return PipelineStepDisplayViewModel.State.FAILED
        }
        return null
    }
}

/**
 * Gate metadata returned by the broker when a pipeline is in the
 * `awaiting_gate` state. Present only when the broker supports the
 * `pipeline_gate_preview` capability.
 */
data class PipelineGate(
    /** Index of the completed gated step. */
    val step: Int,
    /** Computed {{prev}} handoff text for the next step. May be empty. */
    val prev: String,
    /** Final assistant text from the gated step. May be absent. */
    val output: String?,
)

/**
 * End-of-run summary populated once a pipeline reaches "complete" (broker
 * `pipeline.PipelineResult`, #906/#907). The Monitor gates the Result card
 * on BOTH `state == "complete"` AND this being non-null AND the
 * `pipeline_result` capability -- an older broker, or a pipeline
 * completed before this feature shipped, has no result even though state
 * is complete.
 */
data class PipelineResult(
    /** Final step's harvested last-assistant text. */
    val output: String,
    /** RFC3339 completion timestamp. */
    val finished: String,
    /**
     * `git diff --stat` counts for the final step's worktree against the
     * pipeline's base branch. Best-effort: a git error leaves these at
     * zero rather than blocking completion.
     */
    val filesChanged: Int,
    val insertions: Int,
    val deletions: Int,
    /**
     * The `pipeline-<id>-step-*` branch names that actually backed the
     * steps that ran, in step order. Best-effort -- a step whose exact
     * backing branch can't be reconstructed is omitted.
     */
    val branches: List<String> = emptyList(),
)

data class Pipeline(
    val id: String,
    val title: String,
    val task: String,
    val cwd: String,
    val base: String,
    val state: String,
    val currentStep: Int,
    val steps: List<PipelineStep>,
    /** Present only when state == "awaiting_gate" and broker supports pipeline_gate_preview. */
    val gate: PipelineGate? = null,
    /** Present only when state == "complete" and broker supports pipeline_result. */
    val result: PipelineResult? = null,
) {
    val isComplete: Boolean get() = state == "complete"
}

// Made non-private (was file-private) so PipelineResultViewModelTest
// can decode-test the real parser instead of duplicating its logic.
fun parsePipeline(json: JSONObject): Pipeline {
    val stepsArr = json.optJSONArray("steps")
    val steps = mutableListOf<PipelineStep>()
    if (stepsArr != null) {
        for (i in 0 until stepsArr.length()) {
            val s = stepsArr.getJSONObject(i)
            val prevSessionIdsArr = s.optJSONArray("prev_session_ids")
            val prevSessionIds = buildList {
                if (prevSessionIdsArr != null) {
                    for (j in 0 until prevSessionIdsArr.length()) {
                        val sid = prevSessionIdsArr.optString(j, "")
                        if (sid.isNotEmpty()) add(sid)
                    }
                }
            }
            // Parse optional fanout block
            val fanoutObj = s.optJSONObject("fanout")
            val fanout: FanoutStatus? = fanoutObj?.let { fo ->
                val runsArr = fo.optJSONArray("runs")
                val runs = buildList {
                    if (runsArr != null) {
                        for (r in 0 until runsArr.length()) {
                            val run = runsArr.getJSONObject(r)
                            add(FanoutRun(
                                index = run.optInt("index", r),
                                agentType = run.optString("agent_type", "claude"),
                                sessionId = run.optString("session_id", "").takeIf { it.isNotEmpty() },
                                branch = run.optString("branch", "").takeIf { it.isNotEmpty() },
                                phase = run.optString("phase", "").takeIf { it.isNotEmpty() },
                                started = run.optString("started", "").takeIf { it.isNotEmpty() },
                                ended = run.optString("ended", "").takeIf { it.isNotEmpty() },
                            ))
                        }
                    }
                }
                val agentTypesArr = fo.optJSONArray("agent_types")
                val agentTypes = buildList {
                    if (agentTypesArr != null) {
                        for (a in 0 until agentTypesArr.length()) add(agentTypesArr.optString(a, ""))
                    }
                }
                FanoutStatus(
                    count = fo.optInt("count", 0),
                    agentTypes = agentTypes,
                    runs = runs,
                    winner = fo.optInt("winner", -1).takeIf { it >= 0 },
                )
            }
            // Live loop state (PLAN-HARNESS-BUILDER Phase 3). Present only
            // when kind == "loop".
            val loopObj = s.optJSONObject("loop")
            val loop = loopObj?.let {
                PipelineLoopStatus(
                    maxIterations = it.optInt("max_iterations", 0),
                    iteration = if (it.has("iteration")) it.optInt("iteration", 0) else null,
                )
            }
            steps.add(
                PipelineStep(
                    index = s.optInt("index", i),
                    agentType = s.optString("agent_type", "claude"),
                    role = s.optString("role", ""),
                    promptTemplate = s.optString("prompt_template", ""),
                    inputFromPrev = s.optString("input_from_prev", "none"),
                    gateAfter = s.optBoolean("gate_after", false),
                    sessionId = s.optString("session_id", "").takeIf { it.isNotEmpty() },
                    phase = s.optString("phase", "").takeIf { it.isNotEmpty() },
                    started = s.optString("started", "").takeIf { it.isNotEmpty() },
                    ended = s.optString("ended", "").takeIf { it.isNotEmpty() },
                    retries = s.optInt("retries", 0),
                    prevSessionIds = prevSessionIds,
                    fanout = fanout,
                    kind = s.optString("kind", ""),
                    splicedFrom = s.optString("spliced_from", "").takeIf { it.isNotEmpty() },
                    loop = loop,
                    output = s.optString("output", "").takeIf { it.isNotEmpty() },
                ),
            )
        }
    }
    // Parse optional gate block (present when state == "awaiting_gate" and broker
    // supports pipeline_gate_preview capability).
    val gate = json.optJSONObject("gate")?.let { g ->
        PipelineGate(
            step = g.optInt("step", 0),
            prev = g.optString("prev", ""),
            output = g.optString("output", "").takeIf { it.isNotEmpty() },
        )
    }
    // Parse optional result block (present when state == "complete" and
    // broker supports pipeline_result, #906/#907).
    val result = json.optJSONObject("result")?.let { r ->
        val branchesArr = r.optJSONArray("branches")
        val branches = buildList {
            if (branchesArr != null) {
                for (b in 0 until branchesArr.length()) {
                    val branch = branchesArr.optString(b, "")
                    if (branch.isNotEmpty()) add(branch)
                }
            }
        }
        PipelineResult(
            output = r.optString("output", ""),
            finished = r.optString("finished", ""),
            filesChanged = r.optInt("files_changed", 0),
            insertions = r.optInt("insertions", 0),
            deletions = r.optInt("deletions", 0),
            branches = branches,
        )
    }
    return Pipeline(
        id = json.optString("id", ""),
        title = json.optString("title", ""),
        task = json.optString("task", ""),
        cwd = json.optString("cwd", ""),
        base = json.optString("base", "main"),
        state = json.optString("state", ""),
        currentStep = json.optInt("current_step", 0),
        steps = steps,
        gate = gate,
        result = result,
    )
}

private val TERMINAL_STATES = setOf("done", "failed", "cancelled", "complete")

/**
 * Pipeline monitor screen. Polls GET /api/pipeline/{id} every 5 seconds
 * until a terminal state is reached. Shows step progress, gate controls,
 * and cancel option.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PipelineMonitorScreen(
    store: SessionStore,
    pipelineId: String,
    pipelineTitle: String = "",
    onOpenSession: (String) -> Unit = {},
    onBack: () -> Unit = {},
    /**
     * Static demo fixture: when non-null, the screen renders this fixed
     * [Pipeline] and skips the poll loop + all network actions entirely --
     * mirrors iOS `PipelineMonitorView.demoStatus` / ChatPage's
     * readOnlyItems seam. "Approve · continue" and "Cancel" become inert
     * no-ops; "Open session" is naturally disabled since demo steps carry
     * no live session for the queued step. Fed by
     * `DemoData.pipelineStatus(id:)`.
     */
    demoStatus: Pipeline? = null,
) {
    val neon = LocalNeonTheme.current
    val endpoint by store.endpoint.collectAsState()
    val pipelineGatePreview by store.pipelineGatePreview.collectAsState()
    val pipelineResume by store.pipelineResume.collectAsState()
    val pipelineFanout by store.pipelineFanout.collectAsState()
    val pipelineResultCapability by store.pipelineResult.collectAsState()
    val scope = rememberCoroutineScope()

    var pipeline by remember { mutableStateOf(demoStatus) }
    var pollError by remember { mutableStateOf<String?>(null) }
    var showCancelConfirm by remember { mutableStateOf(false) }
    var isContinuing by remember { mutableStateOf(false) }
    var isCancelling by remember { mutableStateOf(false) }
    var actionError by remember { mutableStateOf<String?>(null) }
    // Gate handoff edit state
    var isEditingHandoff by remember { mutableStateOf(false) }
    var handoffDraft by remember { mutableStateOf("") }
    // Resume (retry-from-failed) state
    var showResumeArea by remember { mutableStateOf(false) }
    var resumePromptDraft by remember { mutableStateOf("") }
    var isResuming by remember { mutableStateOf(false) }
    // Fanout pick state
    var pickCompareRuns by remember { mutableStateOf<List<FanOutCompareRun>>(emptyList()) }
    var isLoadingCompare by remember { mutableStateOf(false) }
    var isPicking by remember { mutableStateOf(false) }
    var pickLoadedForId by remember { mutableStateOf("") }
    // Result card (#907): collapsed by default when the final output is
    // long; "Show more" reveals the rest.
    var resultExpanded by remember { mutableStateOf(false) }
    // Per-step output disclosure (#907): indices of steps whose inline
    // output preview is expanded. Tapping the row itself still opens the
    // transcript -- this is a separate, subtle affordance.
    var expandedStepOutputs by remember { mutableStateOf<Set<Int>>(emptySet()) }
    // Read-only transcript fallback (bug 2): a completed step's agent
    // process is reaped (#881), so it's usually gone from `store.sessions`
    // by the time its row is tapped. Rather than a blank screen, we show
    // the persisted transcript read-only via SavedTranscriptScreen -- the
    // same path SessionsScreen/HistoryScreen use for exited rows.
    var stepTranscriptTarget by remember { mutableStateOf<SavedSession?>(null) }
    val liveSessions by store.sessions.collectAsState()

    fun openStepSession(sessionId: String, agentType: String, roleLabel: String, started: String?, ended: String?) {
        if (liveSessions.any { it.id == sessionId }) {
            onOpenSession(sessionId)
            return
        }
        stepTranscriptTarget = SavedSession(
            id = sessionId,
            serverId = "",
            agent = agentType,
            cwd = pipeline?.cwd,
            firstSeen = started ?: "",
            lastSeen = ended ?: started ?: "",
            messageCount = 0,
            summary = roleLabel,
            status = SavedSessionStatus.EXITED,
        )
    }

    Telemetry.breadcrumb(
        "pipeline",
        "monitor_opened",
        mapOf("pipeline_id" to pipelineId),
    )

    fun getEndpoint(path: String): Result<JSONObject> {
        val base = endpoint.httpBaseUrl ?: return Result.failure(Exception("No active endpoint"))
        return runCatching {
            val conn = (URL("$base$path").openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                setRequestProperty("Authorization", "Bearer ${endpoint.token}")
                connectTimeout = 10_000
                readTimeout = 20_000
            }
            try {
                val code = conn.responseCode
                val stream = if (code in 200..299) conn.inputStream else conn.errorStream
                val text = stream?.bufferedReader()?.use { it.readText() } ?: "{}"
                conn.disconnect()
                JSONObject(text)
            } catch (e: Exception) {
                conn.disconnect()
                throw e
            }
        }
    }

    fun postEndpoint(path: String, body: JSONObject = JSONObject()): Result<JSONObject> {
        val base = endpoint.httpBaseUrl ?: return Result.failure(Exception("No active endpoint"))
        return runCatching {
            val conn = (URL("$base$path").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                doOutput = true
                setRequestProperty("Authorization", "Bearer ${endpoint.token}")
                setRequestProperty("Content-Type", "application/json")
                connectTimeout = 10_000
                readTimeout = 20_000
            }
            try {
                conn.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
                val code = conn.responseCode
                val stream = if (code in 200..299) conn.inputStream else conn.errorStream
                val text = stream?.bufferedReader()?.use { it.readText() } ?: "{}"
                conn.disconnect()
                JSONObject(text)
            } catch (e: Exception) {
                conn.disconnect()
                throw e
            }
        }
    }

    fun deleteEndpoint(path: String): Result<JSONObject> {
        val base = endpoint.httpBaseUrl ?: return Result.failure(Exception("No active endpoint"))
        return runCatching {
            val conn = (URL("$base$path").openConnection() as HttpURLConnection).apply {
                requestMethod = "DELETE"
                setRequestProperty("Authorization", "Bearer ${endpoint.token}")
                connectTimeout = 10_000
                readTimeout = 20_000
            }
            try {
                val code = conn.responseCode
                val stream = if (code in 200..299) conn.inputStream else conn.errorStream
                val text = stream?.bufferedReader()?.use { it.readText() } ?: "{}"
                conn.disconnect()
                JSONObject(text)
            } catch (e: Exception) {
                conn.disconnect()
                throw e
            }
        }
    }

    // Polling loop: every 5 seconds until terminal state (skipped entirely
    // in demo mode -- `pipeline` is already seeded from `demoStatus` above,
    // no network).
    LaunchedEffect(pipelineId) {
        if (demoStatus != null) {
            Telemetry.breadcrumb("pipeline", "monitor_demo_static", mapOf("pipeline_id" to pipelineId))
            return@LaunchedEffect
        }
        while (true) {
            val result = withContext(Dispatchers.IO) {
                getEndpoint("/api/pipeline/$pipelineId")
            }
            result.onSuccess { json ->
                val parsed = parsePipeline(json)
                val prevState = pipeline?.state
                pipeline = parsed
                if (prevState != parsed.state) {
                    Telemetry.breadcrumb(
                        "pipeline",
                        "state_changed",
                        mapOf(
                            "pipeline_id" to pipelineId,
                            "state" to parsed.state,
                            "step" to parsed.currentStep.toString(),
                        ),
                    )
                }
                pollError = null
                if (parsed.state in TERMINAL_STATES) return@LaunchedEffect
            }.onFailure { e ->
                Telemetry.capture(
                    error = e,
                    message = "pipeline poll error",
                    tags = mapOf("surface" to "android", "phase" to "pipeline-monitor"),
                    extras = mapOf("pipeline_id" to pipelineId),
                )
                pollError = e.message ?: "Poll error"
            }
            delay(5_000)
        }
    }

    val displayTitle = pipeline?.title?.takeIf { it.isNotEmpty() } ?: pipelineTitle.takeIf { it.isNotEmpty() } ?: pipelineId

    Scaffold(
        containerColor = neon.bg,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        displayTitle,
                        fontFamily = neon.sans,
                        fontWeight = FontWeight.Bold,
                        color = neon.text,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                },
                // Demo-only: the real screen has no back affordance here
                // (the caller wires system/hardware back via BackHandler).
                // A text-labeled "Home" nav icon gives the Appetize tour a
                // tappable, text-matched way back after shooting the
                // gated-flow monitor -- mirrors the equally demo-only
                // "Home" toolbar button added to iOS's PipelineMonitorView.
                navigationIcon = {
                    if (demoStatus != null) {
                        TextButton(onClick = onBack) {
                            Text("Home", color = neon.accent, fontFamily = neon.sans, fontWeight = FontWeight.SemiBold)
                        }
                    }
                },
                actions = {
                    TextButton(onClick = { showCancelConfirm = true }) {
                        Text("Cancel", color = neon.red, fontFamily = neon.sans)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = neon.surfaceSolid,
                ),
            )
        },
    ) { paddingValues ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
                .navigationBarsPadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 14.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            val p = pipeline
            if (p == null) {
                // Loading state
                Row(
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(18.dp),
                        color = neon.accent,
                        strokeWidth = 2.dp,
                    )
                    Text(
                        "Loading flow...",
                        fontFamily = neon.sans,
                        color = neon.textDim,
                    )
                }
                pollError?.let { err ->
                    Text(
                        "Error: $err",
                        fontFamily = neon.mono,
                        fontSize = 12.sp,
                        color = neon.red,
                    )
                }
            } else {
                // Header card: overall state chip + step label
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface),
                ) {
                    Row(
                        modifier = Modifier.padding(14.dp).fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        PipelineStateChip(state = p.state, neon = neon)
                        Spacer(Modifier.width(10.dp))
                        Text(
                            "Step ${p.currentStep + 1} / ${p.steps.size}",
                            fontFamily = neon.mono,
                            fontSize = 13.sp,
                            color = neon.textDim,
                        )
                        if (p.state == "running") {
                            Spacer(Modifier.width(8.dp))
                            CircularProgressIndicator(
                                modifier = Modifier.size(14.dp),
                                color = neon.accent,
                                strokeWidth = 2.dp,
                            )
                        }
                    }
                }

                // Result card (#907): leads when the pipeline is complete
                // and the broker supports pipeline_result -- an older
                // broker, or a pipeline that finished before this shipped,
                // has state == "complete" but no result.
                val pipelineResult = p.result
                if (p.isComplete && pipelineResult != null && pipelineResultCapability) {
                    PipelineResultCard(
                        neon = neon,
                        result = pipelineResult,
                        expanded = resultExpanded,
                        onToggleExpanded = {
                            resultExpanded = !resultExpanded
                            Telemetry.breadcrumb(
                                "pipeline",
                                "result_output_expand_toggled",
                                mapOf("pipeline_id" to pipelineId, "expanded" to resultExpanded.toString()),
                            )
                        },
                    )
                }

                // Step rows
                Text(
                    "STEPS",
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.Bold,
                    fontSize = 11.sp,
                    color = neon.textDim,
                )

                // Vertical rail (design_handoff_flow/README.md "7. Monitor"):
                // AgentDot(44dp) leading each step card, joined by a thin
                // connector at the dot's x-center; a GatePill splices into
                // the connector where the step above `gateAfter`.
                p.steps.forEachIndexed { i, step ->
                    val displayState = PipelineStepDisplayViewModel.state(step, p)
                    val stepState = resolveStepState(step, p)
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(14.dp),
                    ) {
                        AgentDot(
                            agent = step.agentType,
                            size = 44.dp,
                            status = pipelineStepDotStatus(displayState),
                        )
                        PipelineStepRow(
                            step = step,
                            stepState = stepState,
                            displayState = displayState,
                            neon = neon,
                            modifier = Modifier.weight(1f),
                            outputExpanded = expandedStepOutputs.contains(step.index),
                            onToggleOutput = {
                                expandedStepOutputs = if (expandedStepOutputs.contains(step.index)) {
                                    expandedStepOutputs - step.index
                                } else {
                                    Telemetry.breadcrumb(
                                        "pipeline",
                                        "step_output_preview_expanded",
                                        mapOf("pipeline_id" to pipelineId, "step" to step.index.toString()),
                                    )
                                    expandedStepOutputs + step.index
                                }
                            },
                            onTap = {
                                step.sessionId?.let { sid ->
                                    Telemetry.breadcrumb(
                                        "pipeline",
                                        "step_session_opened",
                                        mapOf("pipeline_id" to pipelineId, "step" to step.index.toString()),
                                    )
                                    openStepSession(sid, step.agentType, step.role, step.started, step.ended)
                                }
                            },
                            onTapRun = { sessionId ->
                                Telemetry.breadcrumb(
                                    "pipeline",
                                    "fanout_run_opened",
                                    mapOf("pipeline_id" to pipelineId, "session_id" to sessionId),
                                )
                                val run = step.fanout?.runs?.firstOrNull { it.sessionId == sessionId }
                                openStepSession(sessionId, run?.agentType ?: step.agentType, step.role, run?.started, run?.ended)
                            },
                        )
                    }
                    if (i < p.steps.size - 1) {
                        PipelineStepConnector(step = step, pipeline = p, neon = neon)
                    }
                }

                // Awaiting pick panel (fanout)
                if (p.state == "awaiting_pick" && pipelineFanout) {
                    val fanoutStep = p.steps.firstOrNull { it.index == p.currentStep && it.isFanout }
                    val fanoutRuns = fanoutStep?.fanout?.runs ?: emptyList()

                    // Trigger compare load
                    LaunchedEffect(pipelineId, p.state) {
                        if (pickLoadedForId != pipelineId && fanoutRuns.isNotEmpty()) {
                            val sessionIds = fanoutRuns.mapNotNull { it.sessionId }
                            if (sessionIds.isNotEmpty()) {
                                Telemetry.breadcrumb(
                                    "pipeline",
                                    "pick_shown",
                                    mapOf("pipeline_id" to pipelineId, "run_count" to fanoutRuns.size.toString()),
                                )
                                isLoadingCompare = true
                                val result = withContext(Dispatchers.IO) {
                                    val base = endpoint.httpBaseUrl ?: return@withContext Result.failure(Exception("no endpoint"))
                                    runCatching {
                                        val body = JSONObject().apply {
                                            put("session_ids", JSONArray(sessionIds))
                                            put("base", p.base)
                                        }
                                        val conn = (URL("$base/api/fanout/compare").openConnection() as HttpURLConnection).apply {
                                            requestMethod = "POST"
                                            doOutput = true
                                            setRequestProperty("Authorization", "Bearer ${endpoint.token}")
                                            setRequestProperty("Content-Type", "application/json")
                                            connectTimeout = 10_000
                                            readTimeout = 20_000
                                        }
                                        try {
                                            conn.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
                                            val code = conn.responseCode
                                            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
                                            val text = stream?.bufferedReader()?.use { it.readText() } ?: "{}"
                                            conn.disconnect()
                                            text
                                        } catch (e: Exception) {
                                            conn.disconnect()
                                            throw e
                                        }
                                    }
                                }
                                isLoadingCompare = false
                                result.onSuccess { raw ->
                                    val obj = runCatching { JSONObject(raw) }.getOrNull()
                                    val runsArr = obj?.optJSONArray("runs")
                                    val parsed = buildList {
                                        if (runsArr != null) {
                                            for (r in 0 until runsArr.length()) {
                                                val run = runsArr.getJSONObject(r)
                                                add(FanOutCompareRun(
                                                    sessionId = run.optString("session_id", ""),
                                                    label = run.optString("label", ""),
                                                    phase = run.optString("phase", ""),
                                                    filesChanged = run.optInt("files_changed", 0),
                                                    insertions = run.optInt("insertions", 0),
                                                    deletions = run.optInt("deletions", 0),
                                                    diffStat = run.optString("diff_stat", ""),
                                                    agentSummary = run.optString("agent_summary", ""),
                                                    error = run.optString("error", ""),
                                                ))
                                            }
                                        }
                                    }
                                    pickCompareRuns = parsed
                                    pickLoadedForId = pipelineId
                                }.onFailure { e ->
                                    Telemetry.capture(
                                        error = e,
                                        message = "pipeline pick compare error",
                                        tags = mapOf("surface" to "android", "phase" to "pipeline-monitor"),
                                        extras = mapOf("pipeline_id" to pipelineId),
                                    )
                                }
                            }
                        }
                    }

                    // Pick panel card
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(14.dp))
                            .background(neon.accent.copy(alpha = 0.08f))
                            .border(1.dp, neon.accent.copy(alpha = 0.30f), RoundedCornerShape(14.dp))
                            .padding(14.dp),
                    ) {
                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            Text(
                                "Pick the winning run",
                                fontFamily = neon.sans,
                                fontWeight = FontWeight.SemiBold,
                                fontSize = 14.sp,
                                color = neon.accent,
                            )
                            Text(
                                "All runs have finished. Compare them and pick the one to continue the flow.",
                                fontFamily = neon.sans,
                                fontSize = 13.sp,
                                color = neon.textDim,
                            )

                            if (isLoadingCompare) {
                                Row(
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    CircularProgressIndicator(
                                        modifier = Modifier.size(14.dp),
                                        color = neon.accent,
                                        strokeWidth = 2.dp,
                                    )
                                    Text(
                                        "Loading compare...",
                                        fontFamily = neon.sans,
                                        fontSize = 13.sp,
                                        color = neon.textDim,
                                    )
                                }
                            } else if (pickCompareRuns.isNotEmpty()) {
                                pickCompareRuns.forEach { run ->
                                    val runEntry = fanoutRuns.firstOrNull { it.sessionId == run.sessionId }
                                    val runIdx = runEntry?.index ?: 0
                                    val isWinner = fanoutStep?.fanout?.winner == runIdx
                                    val canPick = run.error.isEmpty() && !isPicking && !isWinner
                                    PickRunCard(
                                        run = run,
                                        runIndex = runIdx,
                                        isWinner = isWinner,
                                        canPick = canPick,
                                        isPicking = isPicking,
                                        neon = neon,
                                        onOpen = {
                                            openStepSession(
                                                run.sessionId,
                                                runEntry?.agentType ?: run.label,
                                                fanoutStep?.role ?: "",
                                                runEntry?.started,
                                                runEntry?.ended,
                                            )
                                        },
                                        onPick = {
                                            isPicking = true
                                            Telemetry.breadcrumb(
                                                "pipeline",
                                                "pick_tapped",
                                                mapOf("pipeline_id" to pipelineId, "run" to runIdx.toString()),
                                            )
                                            scope.launch {
                                                val result = withContext(Dispatchers.IO) {
                                                    postEndpoint(
                                                        "/api/pipeline/$pipelineId/pick",
                                                        JSONObject().put("run", runIdx),
                                                    )
                                                }
                                                isPicking = false
                                                result.onSuccess { json ->
                                                    Telemetry.breadcrumb(
                                                        "pipeline",
                                                        "pick_ok",
                                                        mapOf("pipeline_id" to pipelineId, "run" to runIdx.toString()),
                                                    )
                                                    pickCompareRuns = emptyList()
                                                    pickLoadedForId = ""
                                                    val parsed = parsePipeline(json)
                                                    pipeline = parsed
                                                }.onFailure { e ->
                                                    Telemetry.capture(
                                                        error = e,
                                                        message = "pipeline pick error",
                                                        tags = mapOf("surface" to "android", "phase" to "pipeline-monitor"),
                                                        extras = mapOf("pipeline_id" to pipelineId, "run" to runIdx.toString()),
                                                    )
                                                    actionError = e.message ?: "Pick failed"
                                                }
                                            }
                                        },
                                    )
                                }
                            } else {
                                // Fallback: show runs from fanout without compare data
                                fanoutRuns.forEach { run ->
                                    val isWinner = fanoutStep?.fanout?.winner == run.index
                                    val canPick = run.isDone && !isPicking && !isWinner
                                    Row(
                                        modifier = Modifier.fillMaxWidth(),
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                                    ) {
                                        AgentGlyph(assistant = run.agentType, size = 22.dp)
                                        Column(modifier = Modifier.weight(1f)) {
                                            Text(
                                                "Run ${run.index + 1} — ${run.agentType}",
                                                fontFamily = neon.mono,
                                                fontWeight = FontWeight.SemiBold,
                                                fontSize = 12.sp,
                                                color = neon.text,
                                            )
                                            Text(
                                                run.phase ?: "queued",
                                                fontFamily = neon.mono,
                                                fontSize = 10.sp,
                                                color = if (run.isFailed) neon.red else neon.textFaint,
                                            )
                                        }
                                        Box(
                                            modifier = Modifier
                                                .clip(RoundedCornerShape(50))
                                                .background(if (canPick) neon.accent else neon.surface2)
                                                .clickable(enabled = canPick) {
                                                    isPicking = true
                                                    scope.launch {
                                                        val result = withContext(Dispatchers.IO) {
                                                            postEndpoint("/api/pipeline/$pipelineId/pick", JSONObject().put("run", run.index))
                                                        }
                                                        isPicking = false
                                                        result.onSuccess { json ->
                                                            pipeline = parsePipeline(json)
                                                        }.onFailure { e ->
                                                            actionError = e.message ?: "Pick failed"
                                                        }
                                                    }
                                                }
                                                .padding(horizontal = 12.dp, vertical = 6.dp),
                                        ) {
                                            Text(
                                                if (isWinner) "Winner" else "Pick",
                                                fontFamily = neon.mono,
                                                fontWeight = FontWeight.Bold,
                                                fontSize = 11.sp,
                                                color = if (canPick) neon.accentText else neon.textFaint,
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Completed recap (design_handoff_flow "7. Monitor" --
                // accent/cyan-bordered "All steps finished" + mono
                // diffstat) for when the richer `PipelineResultCard` above
                // didn't render: an older broker without `pipeline_result`,
                // or a pipeline that completed before that feature shipped.
                if (p.isComplete && !(pipelineResult != null && pipelineResultCapability)) {
                    val diffstat = pipelineCompleteDiffstat(pipelineResult)
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .neonCardSurface(
                                neon = neon,
                                shape = RoundedCornerShape(14.dp),
                                fill = neon.accent.copy(alpha = 0.05f),
                                borderColor = neon.accent.copy(alpha = 0.2f),
                            ),
                    ) {
                        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(
                                "All steps finished",
                                fontFamily = neon.sans,
                                fontWeight = FontWeight.Bold,
                                fontSize = 14.5.sp,
                                color = neon.text,
                            )
                            Text(
                                diffstat,
                                fontFamily = neon.mono,
                                fontSize = 11.5.sp,
                                color = neon.textDim,
                            )
                        }
                    }
                }

                // Awaiting gate card
                if (p.state == "awaiting_gate") {
                    val gate = p.gate
                    val gatedStep = p.steps.getOrNull(p.currentStep)
                    val gatedSessionId = gatedStep?.sessionId
                    val gatedRole = gatedStep?.role?.takeIf { it.isNotEmpty() }
                        ?.let { it[0].uppercase() + it.substring(1) } ?: "Step ${p.currentStep + 1}"
                    // Determine preview text: prefer prev, then output, then null.
                    val previewText: String? = gate?.let { g ->
                        g.prev.takeIf { it.isNotEmpty() } ?: g.output?.takeIf { it.isNotEmpty() }
                    }
                    val showGatePreview = pipelineGatePreview && gate != null

                    // Breadcrumb when preview is shown (side-effect on first display).
                    LaunchedEffect(showGatePreview, gate) {
                        if (showGatePreview && gate != null) {
                            Telemetry.breadcrumb(
                                "pipeline",
                                "gate_preview_shown",
                                mapOf(
                                    "pipeline_id" to pipelineId,
                                    "step" to p.currentStep.toString(),
                                    "prev_len" to gate.prev.length.toString(),
                                ),
                            )
                        }
                    }

                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(14.dp))
                            .background(neon.yellow.copy(alpha = 0.10f))
                            .border(1.dp, neon.yellow.copy(alpha = 0.55f), RoundedCornerShape(14.dp))
                            .padding(14.dp),
                    ) {
                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            Text(
                                "$gatedRole is ready for review",
                                fontFamily = neon.sans,
                                fontWeight = FontWeight.SemiBold,
                                color = neon.yellow,
                            )

                            if (showGatePreview && previewText != null) {
                                // Handoff preview header row
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                ) {
                                    Text(
                                        "HANDOFF PREVIEW",
                                        fontFamily = neon.mono,
                                        fontWeight = FontWeight.Bold,
                                        fontSize = 11.sp,
                                        color = neon.textDim,
                                    )
                                    Text(
                                        if (isEditingHandoff) "Done" else "Edit handoff",
                                        fontFamily = neon.mono,
                                        fontWeight = FontWeight.SemiBold,
                                        fontSize = 11.sp,
                                        color = neon.accent,
                                        modifier = Modifier.clickable {
                                            if (!isEditingHandoff) {
                                                handoffDraft = gate?.prev ?: ""
                                                Telemetry.breadcrumb(
                                                    "pipeline",
                                                    "gate_handoff_edited",
                                                    mapOf(
                                                        "pipeline_id" to pipelineId,
                                                        "step" to p.currentStep.toString(),
                                                    ),
                                                )
                                            }
                                            isEditingHandoff = !isEditingHandoff
                                        },
                                    )
                                }

                                if (isEditingHandoff) {
                                    // Editable text field, fixed 240dp height, multiline.
                                    OutlinedTextField(
                                        value = handoffDraft,
                                        onValueChange = { handoffDraft = it },
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .height(240.dp),
                                        textStyle = TextStyle(
                                            fontFamily = neon.mono,
                                            fontSize = 12.sp,
                                            color = neon.text,
                                        ),
                                        maxLines = Int.MAX_VALUE,
                                        shape = RoundedCornerShape(8.dp),
                                    )
                                } else {
                                    // Read-only preview, capped height. Nested vertical
                                    // scroll inside the outer scrollable Column is not
                                    // supported by Compose; use maxLines clipping instead.
                                    Box(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .clip(RoundedCornerShape(8.dp))
                                            .background(neon.surface2)
                                            .border(1.dp, neon.borderStrong, RoundedCornerShape(8.dp))
                                            .padding(10.dp),
                                    ) {
                                        Text(
                                            previewText,
                                            fontFamily = neon.mono,
                                            fontSize = 12.sp,
                                            color = neon.textDim,
                                            maxLines = 12,
                                            overflow = TextOverflow.Ellipsis,
                                        )
                                    }
                                }
                            } else if (!showGatePreview) {
                                Text(
                                    "The flow is paused at a gate step. Review the output above, then continue.",
                                    fontFamily = neon.sans,
                                    fontSize = 13.sp,
                                    color = neon.textDim,
                                )
                            }

                            // "Open session" (secondary) + "Approve ·
                            // continue" (amber, GateGlyph leading) --
                            // design_handoff_flow "7. Monitor". Edit
                            // handoff stays folded in as the tertiary text
                            // action in the handoff-preview header above
                            // (never removed).
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Box(
                                    modifier = Modifier
                                        .weight(1f)
                                        .clip(RoundedCornerShape(50))
                                        .background(neon.surface2)
                                        .border(1.dp, neon.borderStrong, RoundedCornerShape(50))
                                        .then(
                                            if (gatedSessionId != null) {
                                                Modifier.clickable {
                                                    Telemetry.breadcrumb(
                                                        "pipeline",
                                                        "gate_open_session_tapped",
                                                        mapOf("pipeline_id" to pipelineId, "step" to p.currentStep.toString()),
                                                    )
                                                    openStepSession(
                                                        gatedSessionId,
                                                        gatedStep?.agentType ?: "",
                                                        gatedStep?.role ?: "",
                                                        gatedStep?.started,
                                                        gatedStep?.ended,
                                                    )
                                                }
                                            } else {
                                                Modifier
                                            },
                                        )
                                        .alpha(if (gatedSessionId == null) 0.5f else 1f)
                                        .padding(vertical = 12.dp),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Text(
                                        "Open session",
                                        fontFamily = neon.sans,
                                        fontWeight = FontWeight.SemiBold,
                                        color = neon.text,
                                    )
                                }

                                Box(
                                    modifier = Modifier
                                        .weight(1f)
                                        .clip(RoundedCornerShape(10.dp))
                                        .background(if (!isContinuing) neon.yellow else neon.surface2)
                                        .clickable(enabled = !isContinuing) {
                                            if (demoStatus != null) {
                                                Telemetry.breadcrumb(
                                                    "pipeline",
                                                    "demo_gate_continue_no_op",
                                                    mapOf("pipeline_id" to pipelineId),
                                                )
                                                return@clickable
                                            }
                                            val edited = isEditingHandoff &&
                                                handoffDraft != (gate?.prev ?: "")
                                            isContinuing = true
                                            Telemetry.breadcrumb(
                                                "pipeline",
                                                "gate_continue_tapped",
                                                mapOf(
                                                    "pipeline_id" to pipelineId,
                                                    "edited" to edited.toString(),
                                                ),
                                            )
                                            scope.launch {
                                                val body = if (edited) {
                                                    JSONObject().put("prev", handoffDraft)
                                                } else {
                                                    JSONObject()
                                                }
                                                val result = withContext(Dispatchers.IO) {
                                                    postEndpoint(
                                                        "/api/pipeline/$pipelineId/continue",
                                                        body,
                                                    )
                                                }
                                                isContinuing = false
                                                result.onSuccess { json ->
                                                    val parsed = parsePipeline(json)
                                                    pipeline = parsed
                                                }.onFailure { e ->
                                                    Telemetry.capture(
                                                        error = e,
                                                        message = "pipeline gate-continue error",
                                                        tags = mapOf("surface" to "android", "phase" to "pipeline-monitor"),
                                                        extras = mapOf("pipeline_id" to pipelineId),
                                                    )
                                                    actionError = e.message ?: "Continue failed"
                                                }
                                            }
                                        }
                                        .padding(vertical = 12.dp),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    if (isContinuing) {
                                        CircularProgressIndicator(
                                            modifier = Modifier.size(18.dp),
                                            color = neon.accentText,
                                            strokeWidth = 2.dp,
                                        )
                                    } else {
                                        Row(
                                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                                            verticalAlignment = Alignment.CenterVertically,
                                        ) {
                                            GateGlyph(color = neon.accentText, size = 11.dp)
                                            Text(
                                                "Approve · continue",
                                                fontFamily = neon.sans,
                                                fontWeight = FontWeight.Bold,
                                                color = neon.accentText,
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Failed card
                if (p.state == "failed") {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(14.dp))
                            .background(neon.red.copy(alpha = 0.10f))
                            .border(1.dp, neon.red.copy(alpha = 0.55f), RoundedCornerShape(14.dp))
                            .padding(14.dp),
                    ) {
                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            Text(
                                "Flow failed",
                                fontFamily = neon.sans,
                                fontWeight = FontWeight.SemiBold,
                                color = neon.red,
                            )
                            // Find the failed step's session
                            val failedStep = p.steps.firstOrNull {
                                it.phase?.startsWith("exited") == true &&
                                    it.phase != "exited(0)"
                            }
                            if (failedStep?.sessionId != null) {
                                Box(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clip(RoundedCornerShape(10.dp))
                                        .background(neon.surface2)
                                        .clickable {
                                            Telemetry.breadcrumb(
                                                "pipeline",
                                                "failed_step_session_opened",
                                                mapOf("pipeline_id" to pipelineId),
                                            )
                                            openStepSession(
                                                failedStep.sessionId,
                                                failedStep.agentType,
                                                failedStep.role,
                                                failedStep.started,
                                                failedStep.ended,
                                            )
                                        }
                                        .padding(vertical = 12.dp),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Text(
                                        "Open session",
                                        fontFamily = neon.sans,
                                        fontWeight = FontWeight.SemiBold,
                                        color = neon.red,
                                    )
                                }
                            }

                            // Resume (retry-from-failed) affordance.
                            if (pipelineResume) {
                                if (showResumeArea) {
                                    // Optional prompt override editor.
                                    Text(
                                        "OVERRIDE PROMPT (OPTIONAL)",
                                        fontFamily = neon.mono,
                                        fontWeight = FontWeight.SemiBold,
                                        fontSize = 10.sp,
                                        color = neon.textFaint,
                                    )
                                    OutlinedTextField(
                                        value = resumePromptDraft,
                                        onValueChange = { resumePromptDraft = it },
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .height(120.dp),
                                        placeholder = {
                                            Text(
                                                "Leave empty to re-run unchanged...",
                                                fontFamily = neon.sans,
                                                fontSize = 13.sp,
                                                color = neon.textFaint,
                                            )
                                        },
                                        maxLines = Int.MAX_VALUE,
                                        shape = RoundedCornerShape(8.dp),
                                    )
                                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        // Cancel resume
                                        Box(
                                            modifier = Modifier
                                                .weight(1f)
                                                .clip(RoundedCornerShape(50))
                                                .background(neon.surface2)
                                                .border(1.dp, neon.borderStrong, RoundedCornerShape(50))
                                                .clickable {
                                                    showResumeArea = false
                                                    resumePromptDraft = ""
                                                }
                                                .padding(vertical = 10.dp),
                                            contentAlignment = Alignment.Center,
                                        ) {
                                            Text(
                                                "Cancel",
                                                fontFamily = neon.sans,
                                                fontWeight = FontWeight.SemiBold,
                                                fontSize = 13.sp,
                                                color = neon.textDim,
                                            )
                                        }
                                        // Confirm retry
                                        Box(
                                            modifier = Modifier
                                                .weight(1f)
                                                .clip(RoundedCornerShape(50))
                                                .background(if (isResuming) neon.surface2 else neon.accent)
                                                .clickable(enabled = !isResuming) {
                                                    val edited = resumePromptDraft.trim().isNotEmpty()
                                                    isResuming = true
                                                    Telemetry.breadcrumb(
                                                        "pipeline",
                                                        "resume_tapped",
                                                        mapOf(
                                                            "pipeline_id" to pipelineId,
                                                            "edited" to edited.toString(),
                                                        ),
                                                    )
                                                    scope.launch {
                                                        val body = if (edited) {
                                                            JSONObject().put("prompt", resumePromptDraft.trim())
                                                        } else {
                                                            JSONObject()
                                                        }
                                                        val result = withContext(Dispatchers.IO) {
                                                            postEndpoint(
                                                                "/api/pipeline/$pipelineId/resume",
                                                                body,
                                                            )
                                                        }
                                                        isResuming = false
                                                        result.onSuccess { json ->
                                                            Telemetry.breadcrumb(
                                                                "pipeline",
                                                                "resume_ok",
                                                                mapOf("pipeline_id" to pipelineId),
                                                            )
                                                            showResumeArea = false
                                                            resumePromptDraft = ""
                                                            val parsed = parsePipeline(json)
                                                            pipeline = parsed
                                                        }.onFailure { e ->
                                                            Telemetry.capture(
                                                                error = e,
                                                                message = "pipeline resume error",
                                                                tags = mapOf("surface" to "android", "phase" to "pipeline-monitor"),
                                                                extras = mapOf("pipeline_id" to pipelineId),
                                                            )
                                                            actionError = e.message ?: "Resume failed"
                                                        }
                                                    }
                                                }
                                                .padding(vertical = 10.dp),
                                            contentAlignment = Alignment.Center,
                                        ) {
                                            if (isResuming) {
                                                CircularProgressIndicator(
                                                    modifier = Modifier.size(16.dp),
                                                    color = neon.accentText,
                                                    strokeWidth = 2.dp,
                                                )
                                            } else {
                                                Text(
                                                    "Confirm retry",
                                                    fontFamily = neon.sans,
                                                    fontWeight = FontWeight.Bold,
                                                    fontSize = 13.sp,
                                                    color = neon.accentText,
                                                )
                                            }
                                        }
                                    }
                                } else {
                                    // Retry step button
                                    Box(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .clip(RoundedCornerShape(50))
                                            .background(neon.accent.copy(alpha = 0.12f))
                                            .border(1.dp, neon.accent.copy(alpha = 0.35f), RoundedCornerShape(50))
                                            .clickable { showResumeArea = true }
                                            .padding(vertical = 10.dp),
                                        contentAlignment = Alignment.Center,
                                    ) {
                                        Text(
                                            "Retry step",
                                            fontFamily = neon.sans,
                                            fontWeight = FontWeight.SemiBold,
                                            fontSize = 13.sp,
                                            color = neon.accent,
                                        )
                                    }
                                }
                            }
                        }
                    }
                }

                pollError?.let { err ->
                    Text(
                        "Poll error: $err",
                        fontFamily = neon.mono,
                        fontSize = 12.sp,
                        color = neon.red,
                    )
                }
            }
        }
    }

    // Cancel confirm dialog
    if (showCancelConfirm) {
        AlertDialog(
            onDismissRequest = { showCancelConfirm = false },
            title = { Text("Cancel flow?") },
            text = { Text("This will stop the running flow. This cannot be undone.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        showCancelConfirm = false
                        if (demoStatus != null) {
                            Telemetry.breadcrumb(
                                "pipeline",
                                "demo_cancel_no_op",
                                mapOf("pipeline_id" to pipelineId),
                            )
                            onBack()
                            return@TextButton
                        }
                        isCancelling = true
                        Telemetry.breadcrumb(
                            "pipeline",
                            "cancel_confirmed",
                            mapOf("pipeline_id" to pipelineId),
                        )
                        scope.launch {
                            val result = withContext(Dispatchers.IO) {
                                deleteEndpoint("/api/pipeline/$pipelineId")
                            }
                            isCancelling = false
                            result.onSuccess {
                                onBack()
                            }.onFailure { e ->
                                Telemetry.capture(
                                    error = e,
                                    message = "pipeline cancel error",
                                    tags = mapOf("surface" to "android", "phase" to "pipeline-monitor"),
                                    extras = mapOf("pipeline_id" to pipelineId),
                                )
                                actionError = e.message ?: "Cancel failed"
                            }
                        }
                    },
                ) { Text("Cancel flow", color = neon.red) }
            },
            dismissButton = {
                TextButton(onClick = { showCancelConfirm = false }) { Text("Keep running") }
            },
        )
    }

    actionError?.let { msg ->
        AlertDialog(
            onDismissRequest = { actionError = null },
            title = { Text("Error") },
            text = { Text(msg) },
            confirmButton = {
                TextButton(onClick = { actionError = null }) { Text("OK") }
            },
        )
    }

    // Read-only transcript fallback for a step whose session isn't live
    // (bug 2) -- overlays on top of the Scaffold above, same sibling-
    // composable-in-a-Box pattern AppRoot uses for its full-screen
    // overlays.
    stepTranscriptTarget?.let { session ->
        SavedTranscriptScreen(
            store = store,
            session = session,
            onDismiss = { stepTranscriptTarget = null },
        )
    }
}

/**
 * Pure step-display-state mapping -- kept off Compose (mirrors
 * [PipelineListViewModel]) so the phase -> display-state rules are
 * directly unit-testable. Maps a step's raw `phase` string (as persisted
 * by the broker -- "running", "exited(0)", "exited(1)", "turn_complete",
 * or any future/unmapped value) plus pipeline context to one of the
 * Monitor's display buckets. Mirror of iOS
 * `ConduitUI.PipelineStepDisplayViewModel`.
 */
object PipelineStepDisplayViewModel {
    enum class State { QUEUED, RUNNING, DONE, FAILED, AWAITING_GATE, AWAITING_PICK }

    fun state(step: PipelineStep, pipeline: Pipeline): State {
        // Fanout step at current position while awaiting pick
        if (step.isFanout && step.index == pipeline.currentStep && pipeline.state == "awaiting_pick") {
            return State.AWAITING_PICK
        }
        val phase = step.phase
        // "turn_complete" is the structured-chat (claude/codex) completion
        // signal -- those backends never exit the process between turns,
        // so there is no "exited(0)" to observe. It counts as done,
        // mirroring exitCodeFromPhase in broker/internal/pipeline/orchestrator.go.
        if (phase == "turn_complete" || phase == "exited(0)" || phase == "exited") return State.DONE
        if (phase != null && phase.startsWith("exited")) return State.FAILED
        // Only explicitly-live phases map to running/awaiting-gate -- any
        // other non-null phase is an unmapped/future value and must fall
        // through to the same fallback chain as a null/empty phase below,
        // never straight to "running".
        if (phase == "running" || phase == "ready") {
            if (pipeline.state == "awaiting_gate" && step.index == pipeline.currentStep) {
                return State.AWAITING_GATE
            }
            return State.RUNNING
        }
        // Fanout step with runs but no step-level session is "running"
        if (step.isFanout && step.fanout?.runs?.isNotEmpty() == true) return State.RUNNING
        // A loop step's own SessionID/Phase is only adopted once the loop is
        // DONE (orchestrator.advanceLoop) -- while iterating both stay null,
        // so without this check an in-progress loop would misleadingly show
        // "queued" (PLAN-HARNESS-BUILDER Phase 3).
        if (step.isLoop && step.index == pipeline.currentStep && pipeline.state !in TERMINAL_STATES) return State.RUNNING
        // Unmapped/unknown future phase (or no phase at all) -- never
        // render "queued" for a step that has plainly already run (see
        // `PipelineStep.fallbackState` docs).
        return step.fallbackState(pipeline) ?: State.QUEUED
    }
}

/**
 * "+N -N · N files" from the completed pipeline's diffstat -- falls back
 * to a generic message when [result] is absent (older broker or a
 * pre-#906 pipeline). Mirror of iOS `PipelineMonitorView.completeDiffstat`.
 */
private fun pipelineCompleteDiffstat(result: PipelineResult?): String {
    if (result == null) return "no diffstat available"
    val parts = mutableListOf<String>()
    if (result.insertions > 0) parts.add("+${result.insertions}")
    if (result.deletions > 0) parts.add("-${result.deletions}")
    val stats = parts.joinToString(" ")
    if (result.filesChanged > 0) {
        return if (stats.isEmpty()) "${result.filesChanged} files" else "$stats · ${result.filesChanged} files"
    }
    return stats.ifEmpty { "no diffstat available" }
}

/** Capitalized role (falling back to agent type) for a rail step's title,
 *  never crashing on an unexpectedly empty string. */
private fun pipelineStepRailTitle(step: PipelineStep): String {
    val raw = step.role.ifEmpty { step.agentType }
    return raw.ifEmpty { null }?.let { it[0].uppercase() + it.substring(1) } ?: raw
}

/** Derive a display state string for a step given pipeline state. */
private fun resolveStepState(step: PipelineStep, pipeline: Pipeline): String =
    when (PipelineStepDisplayViewModel.state(step, pipeline)) {
        PipelineStepDisplayViewModel.State.QUEUED -> "queued"
        PipelineStepDisplayViewModel.State.RUNNING -> "running"
        PipelineStepDisplayViewModel.State.DONE -> "done"
        PipelineStepDisplayViewModel.State.FAILED -> "failed"
        PipelineStepDisplayViewModel.State.AWAITING_GATE -> "awaiting-gate"
        PipelineStepDisplayViewModel.State.AWAITING_PICK -> "pick"
    }

/**
 * `AgentDot` ring for a step's display state. `DONE` uses `LIVE` (green
 * ring) rather than the atom's default `DONE` (accent) -- the Monitor's
 * per-step rail spec explicitly wants a green ring here (vs. the home
 * `FlowCard`/`TopoMini` topology strip, which uses the atom default accent
 * for done). `AWAITING_GATE`/`AWAITING_PICK` both read as the active/amber
 * "needs attention" ring, same family as `RUNNING`. Mirror of iOS
 * `PipelineMonitorView.dotStatus`.
 */
private fun pipelineStepDotStatus(state: PipelineStepDisplayViewModel.State): FlowAgentStatus? = when (state) {
    PipelineStepDisplayViewModel.State.QUEUED -> null
    PipelineStepDisplayViewModel.State.RUNNING,
    PipelineStepDisplayViewModel.State.AWAITING_GATE,
    PipelineStepDisplayViewModel.State.AWAITING_PICK,
    -> FlowAgentStatus.RUNNING
    PipelineStepDisplayViewModel.State.DONE -> FlowAgentStatus.LIVE
    PipelineStepDisplayViewModel.State.FAILED -> FlowAgentStatus.ERROR
}

/** Mono status-line text tint per the design's status map. Mirror of iOS
 *  `PipelineMonitorView.statusTint`. */
private fun pipelineStepStatusTint(state: PipelineStepDisplayViewModel.State, neon: NeonTheme): Color = when (state) {
    PipelineStepDisplayViewModel.State.QUEUED -> neon.textFaint
    PipelineStepDisplayViewModel.State.RUNNING,
    PipelineStepDisplayViewModel.State.AWAITING_GATE,
    PipelineStepDisplayViewModel.State.AWAITING_PICK,
    -> neon.yellow
    PipelineStepDisplayViewModel.State.DONE -> neon.green
    PipelineStepDisplayViewModel.State.FAILED -> neon.red
}

/** "<agent> · <dur>" when done, "working…" running, an "exited(N)"-style
 *  phase on failure, "waiting" queued. Mirror of iOS
 *  `PipelineMonitorView.statusLine`. */
private fun pipelineStepStatusLine(step: PipelineStep, state: PipelineStepDisplayViewModel.State): String =
    when (state) {
        PipelineStepDisplayViewModel.State.DONE -> {
            val dur = pipelineStepDuration(step)
            if (dur != null) "${step.agentType} · $dur" else "${step.agentType} · done"
        }
        PipelineStepDisplayViewModel.State.RUNNING, PipelineStepDisplayViewModel.State.AWAITING_GATE -> "working…"
        PipelineStepDisplayViewModel.State.AWAITING_PICK -> "pick a result"
        PipelineStepDisplayViewModel.State.FAILED -> step.phase ?: "exited(1)"
        PipelineStepDisplayViewModel.State.QUEUED -> "waiting"
    }

/** Short "4m 12s" / "1h 3m" / "12s" duration from a step's started/ended
 *  RFC3339 timestamps. Null when either is missing or unparseable. */
private fun pipelineStepDuration(step: PipelineStep): String? {
    val startedStr = step.started ?: return null
    val endedStr = step.ended ?: return null
    val started = runCatching { java.time.Instant.parse(startedStr) }.getOrNull() ?: return null
    val ended = runCatching { java.time.Instant.parse(endedStr) }.getOrNull() ?: return null
    val totalSeconds = maxOf(0L, ended.epochSecond - started.epochSecond)
    val h = totalSeconds / 3600
    val m = (totalSeconds % 3600) / 60
    val s = totalSeconds % 60
    return when {
        h > 0 -> "${h}h ${m}m"
        m > 0 -> "${m}m ${s}s"
        else -> "${s}s"
    }
}

/**
 * Connector between two rail rows: a 1.5dp line at the dot's x-center
 * (inset to match the 44dp `AgentDot`), green ~40% when the step above is
 * done, else `lineSoft`. Where the step above has `gateAfter`, a
 * `GatePill` splices in: active (amber) while that gate is the CURRENT
 * awaiting boundary, "approved" once passed, plain "gate" before it's
 * reached. Mirror of iOS `PipelineMonitorView.connector`.
 */
@Composable
private fun PipelineStepConnector(step: PipelineStep, pipeline: Pipeline, neon: NeonTheme) {
    val state = PipelineStepDisplayViewModel.state(step, pipeline)
    val isDone = state == PipelineStepDisplayViewModel.State.DONE
    val gateActive = pipeline.state == "awaiting_gate" && step.gateAfter && step.index == pipeline.currentStep
    val gateApproved = step.gateAfter && isDone && !gateActive
    val lineHeight = if (gateActive) 44.dp else 30.dp

    Row(
        modifier = Modifier.padding(start = 21.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .width(1.5.dp)
                .height(lineHeight)
                .background(if (isDone) neon.green.copy(alpha = 0.4f) else neon.lineSoft),
        )
        if (step.gateAfter) {
            GatePill(
                label = if (gateActive) "gate — review below" else if (gateApproved) "approved" else "gate",
                active = gateActive,
            )
        }
    }
}

/**
 * Pure view-model for the Result card's "collapse long output" behavior
 * (#907) -- kept off Compose so it's directly unit-testable, mirroring
 * [PipelineStepDisplayViewModel]. Mirror of iOS
 * `ConduitUI.PipelineResultViewModel`.
 */
object PipelineResultViewModel {
    /** Lines beyond which the Result card's output collapses behind "Show more". */
    const val COLLAPSE_LINE_THRESHOLD = 12

    /** Whether [text] has enough lines to warrant the collapsed / "Show more" treatment. */
    fun needsCollapse(text: String, threshold: Int = COLLAPSE_LINE_THRESHOLD): Boolean =
        text.split('\n').size > threshold

    /**
     * The first [threshold] lines of [text], joined back with newlines --
     * what renders while collapsed. Returns [text] unchanged when it
     * doesn't need collapsing.
     */
    fun collapsed(text: String, threshold: Int = COLLAPSE_LINE_THRESHOLD): String {
        val lines = text.split('\n')
        if (lines.size <= threshold) return text
        return lines.take(threshold).joinToString("\n")
    }
}

/**
 * Leads the Monitor when the pipeline is complete and the broker supports
 * `pipeline_result` (#906/#907): the final step's output rendered as
 * markdown, git-outcome chips, and the backing branch(es). Collapsed to
 * [PipelineResultViewModel.COLLAPSE_LINE_THRESHOLD] lines with a "Show
 * more" expand when the output is long. Mirror of iOS `resultCard`.
 */
@Composable
private fun PipelineResultCard(
    neon: NeonTheme,
    result: PipelineResult,
    expanded: Boolean,
    onToggleExpanded: () -> Unit,
) {
    // #920 hang parity note: iOS's Result card was recomputing
    // needsCollapse/collapsed (a String.split over up to 16KB) inside
    // SwiftUI `body` on every render pass, causing a fully-blocked
    // main-thread hang under 5s polling + observable-store churn (Sentry:
    // "App Hang Fully Blocked" 3.2-4.0s, release 0.0.218+246). Android
    // already gates both computed values behind remember(result.output),
    // so recomposition only re-splits when the output string itself
    // changes -- hoisted the collapsed() call out of the conditional
    // branch so toggling `expanded` never disposes/recreates its
    // remember slot and forces a redundant recompute.
    val needsCollapse = remember(result.output) { PipelineResultViewModel.needsCollapse(result.output) }
    val collapsedText = remember(result.output) { PipelineResultViewModel.collapsed(result.output) }
    val displayText = if (needsCollapse && !expanded) collapsedText else result.output
    val hasGitOutcome = result.filesChanged > 0 || result.insertions > 0 || result.deletions > 0

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(
                neon = neon,
                shape = RoundedCornerShape(14.dp),
                fill = neon.green.copy(alpha = 0.05f),
                borderColor = neon.green.copy(alpha = 0.22f),
            ),
    ) {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(
                "RESULT",
                fontFamily = neon.mono,
                fontWeight = FontWeight.Bold,
                fontSize = 11.sp,
                color = neon.textDim,
            )

            if (result.output.isNotEmpty()) {
                MarkdownBlock(displayText, ConversationRole.Assistant)

                if (needsCollapse) {
                    Text(
                        if (expanded) "Show less" else "Show more",
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 11.sp,
                        color = neon.accent,
                        modifier = Modifier.clickable(onClick = onToggleExpanded),
                    )
                }
            }

            if (hasGitOutcome) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (result.filesChanged > 0) {
                        ConduitChip(label = "${result.filesChanged} files", tint = neon.textDim)
                    }
                    if (result.insertions > 0) {
                        ConduitChip(label = "+${result.insertions}", tint = neon.green)
                    }
                    if (result.deletions > 0) {
                        ConduitChip(label = "-${result.deletions}", tint = neon.red)
                    }
                }
            }

            if (result.branches.isNotEmpty()) {
                Text(
                    result.branches.joinToString(", "),
                    fontFamily = neon.mono,
                    fontSize = 10.sp,
                    color = neon.textFaint,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

// NavHeader trailing state Chip (design_handoff_flow/README.md "7.
// Monitor"): needs you (amber) while awaiting_gate/awaiting_pick, running
// (green) while active, done (accent/cyan) complete, failed (red) halted.
@Composable
private fun PipelineStateChip(state: String, neon: NeonTheme) {
    val (label, color) = when (state) {
        "running" -> "running" to neon.green
        "complete" -> "done" to neon.accent
        "failed" -> "failed" to neon.red
        "awaiting_gate" -> "needs you" to neon.yellow
        "awaiting_pick" -> "needs you" to neon.yellow
        "cancelled" -> "cancelled" to neon.textFaint
        else -> state.replace("_", " ") to neon.textFaint
    }
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(color.copy(alpha = 0.15f))
            .border(1.dp, color.copy(alpha = 0.45f), RoundedCornerShape(50))
            .padding(horizontal = 10.dp, vertical = 4.dp),
    ) {
        Text(
            label,
            fontFamily = neon.mono,
            fontWeight = FontWeight.SemiBold,
            fontSize = 12.sp,
            color = color,
        )
    }
}

@Composable
private fun PipelineStepRow(
    step: PipelineStep,
    stepState: String,
    displayState: PipelineStepDisplayViewModel.State,
    neon: NeonTheme,
    onTap: () -> Unit,
    onTapRun: (String) -> Unit = {},
    outputExpanded: Boolean = false,
    onToggleOutput: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val isActive = stepState == "running" || stepState == "awaiting-gate" || stepState == "pick"
    val isQueued = stepState == "queued"
    val isTappable = step.sessionId != null
    val borderColor = if (isActive) neon.yellow.copy(alpha = 0.27f) else neon.lineSoft
    val glowTint: Color? = if (isActive && neon.glow) neon.yellow else null

    // The tap-to-transcript click is scoped to the main info Row below,
    // not the whole card: the disclosure IconButton lives inside that Row
    // (Compose's own click consumption keeps it a reliable, separate hit
    // target), while the expanded output preview and fanout sub-run lines
    // sit outside the Row and must never navigate on tap (#918).
    Box(
        modifier = modifier
            .fillMaxWidth()
            .alpha(if (isQueued) 0.55f else 1f)
            .neonCardSurface(
                neon = neon,
                shape = RoundedCornerShape(12.dp),
                fill = neon.surface,
                borderColor = borderColor,
                glowTint = glowTint,
            ),
    ) {
        Column(modifier = Modifier.padding(13.dp).fillMaxWidth()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .then(if (isTappable && !isQueued) Modifier.clickable(onClick = onTap) else Modifier),
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(
                            "${step.index + 1}. ${pipelineStepRailTitle(step)}",
                            fontFamily = neon.sans,
                            fontWeight = FontWeight.SemiBold,
                            fontSize = 15.sp,
                            color = neon.text,
                        )
                        // Fanout badge
                        if (step.isFanout) {
                            step.fanout?.let { fo ->
                                Box(
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(50))
                                        .background(neon.accent.copy(alpha = 0.14f))
                                        .padding(horizontal = 5.dp, vertical = 2.dp),
                                ) {
                                    Text(
                                        "${fo.count}x",
                                        fontFamily = neon.mono,
                                        fontWeight = FontWeight.Bold,
                                        fontSize = 10.sp,
                                        color = neon.accent,
                                    )
                                }
                            }
                        }
                        // Loop iteration badge (PLAN-HARNESS-BUILDER Phase
                        // 3, §4.2): "iteration k/N" -- k = current pass
                        // (1-indexed: iteration+1 while a pass is in flight).
                        if (step.isLoop) {
                            step.loop?.let { lp ->
                                Box(
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(50))
                                        .background(neon.accent.copy(alpha = 0.14f))
                                        .padding(horizontal = 6.dp, vertical = 2.dp),
                                ) {
                                    Text(
                                        "iteration ${(lp.iteration ?: 0) + 1}/${lp.maxIterations}",
                                        fontFamily = neon.mono,
                                        fontWeight = FontWeight.Bold,
                                        fontSize = 10.sp,
                                        color = neon.accent,
                                    )
                                }
                            }
                        }
                        // Retry chip
                        if (step.retries > 0) {
                            Box(
                                modifier = Modifier
                                    .clip(RoundedCornerShape(50))
                                    .background(neon.yellow.copy(alpha = 0.15f))
                                    .border(1.dp, neon.yellow.copy(alpha = 0.35f), RoundedCornerShape(50))
                                    .padding(horizontal = 6.dp, vertical = 2.dp),
                            ) {
                                Text(
                                    "retry ${step.retries}",
                                    fontFamily = neon.mono,
                                    fontWeight = FontWeight.SemiBold,
                                    fontSize = 10.sp,
                                    color = neon.yellow,
                                )
                            }
                        }
                    }
                    // Mono status-line, tinted per the design's status map:
                    // "<agent> · <dur>" done, "working…" running, an
                    // "exited(N)"-style phase on failure, "waiting" queued.
                    Text(
                        pipelineStepStatusLine(step, displayState),
                        fontFamily = neon.mono,
                        fontSize = 11.sp,
                        color = pipelineStepStatusTint(displayState, neon),
                        modifier = Modifier.padding(top = 2.dp),
                    )
                    if (step.inputFromPrev.isNotEmpty() && step.inputFromPrev != "none") {
                        Text(
                            "input: ${step.inputFromPrev}",
                            fontFamily = neon.mono,
                            fontSize = 11.sp,
                            color = neon.textFaint,
                        )
                    }
                    // Spliced-from-branch provenance annotation
                    // (PLAN-HARNESS-BUILDER Phase 3, §4.1): set when the
                    // orchestrator resolved a branch's condition and
                    // spliced this step in from the chosen arm.
                    if (step.wasSpliced) {
                        Text(
                            "from ${step.splicedFrom}",
                            fontFamily = neon.mono,
                            fontSize = 9.sp,
                            color = neon.textFaint,
                        )
                    }
                }
                // Output disclosure (#907): a subtle affordance, separate
                // from the row's tap-to-transcript click, that expands an
                // inline preview of this step's harvested output. The
                // transcript stays the deep-dive path.
                if (!step.output.isNullOrEmpty()) {
                    IconButton(onClick = onToggleOutput, modifier = Modifier.size(44.dp)) {
                        Icon(
                            if (outputExpanded) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                            contentDescription = if (outputExpanded) "Hide output preview" else "Show output preview",
                            tint = neon.textFaint,
                            modifier = Modifier.size(16.dp),
                        )
                    }
                }
                // Chevron whenever the row has activity -- per design, no
                // chevron on an idle/queued row.
                if (isTappable && !isQueued) {
                    Icon(
                        Icons.AutoMirrored.Filled.KeyboardArrowRight,
                        contentDescription = null,
                        tint = neon.textFaint,
                        modifier = Modifier.size(16.dp),
                    )
                }
            }

            // Inline output preview (#907): shown only while this step's
            // disclosure is expanded.
            if (!step.output.isNullOrEmpty() && outputExpanded) {
                Text(
                    step.output,
                    fontFamily = neon.mono,
                    fontSize = 11.sp,
                    color = neon.textDim,
                    maxLines = 6,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 8.dp).fillMaxWidth(),
                )
            }

            // Fanout sub-run cluster
            if (step.isFanout) {
                val runs = step.fanout?.runs ?: emptyList()
                if (runs.isNotEmpty()) {
                    Spacer(Modifier.height(8.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        runs.forEach { run ->
                            val runColor = when {
                                step.fanout?.winner == run.index -> neon.green
                                run.isFailed -> neon.red
                                run.isRunning -> neon.accent
                                run.isDone -> neon.green
                                else -> neon.textFaint
                            }
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .then(
                                        if (run.sessionId != null) {
                                            Modifier.clickable { onTapRun(run.sessionId) }
                                        } else Modifier,
                                    )
                                    .alpha(if (run.isFailed) 0.5f else 1f),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                AgentGlyph(assistant = run.agentType, size = 18.dp)
                                Text(
                                    run.agentType,
                                    fontFamily = neon.mono,
                                    fontSize = 11.sp,
                                    color = if (run.isFailed) neon.textFaint else neon.textDim,
                                )
                                Text(
                                    "run ${run.index + 1}",
                                    fontFamily = neon.mono,
                                    fontSize = 10.sp,
                                    color = neon.textFaint,
                                )
                                Spacer(Modifier.weight(1f))
                                if (step.fanout?.winner == run.index) {
                                    Text(
                                        "winner",
                                        fontFamily = neon.mono,
                                        fontWeight = FontWeight.Bold,
                                        fontSize = 9.sp,
                                        color = neon.green,
                                    )
                                }
                                Box(
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(50))
                                        .background(runColor.copy(alpha = 0.13f))
                                        .padding(horizontal = 6.dp, vertical = 2.dp),
                                ) {
                                    Text(
                                        run.phase ?: "queued",
                                        fontFamily = neon.mono,
                                        fontWeight = FontWeight.SemiBold,
                                        fontSize = 9.sp,
                                        color = runColor,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun PickRunCard(
    run: FanOutCompareRun,
    runIndex: Int,
    isWinner: Boolean,
    canPick: Boolean,
    isPicking: Boolean,
    neon: NeonTheme,
    onOpen: () -> Unit,
    onPick: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(if (run.error.isNotEmpty()) neon.red.copy(alpha = 0.05f) else neon.surface2)
            .border(
                1.dp,
                if (run.error.isNotEmpty()) neon.red.copy(alpha = 0.20f) else neon.border,
                RoundedCornerShape(10.dp),
            )
            .alpha(if (run.error.isNotEmpty()) 0.65f else 1f)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            AgentGlyph(assistant = run.label.ifEmpty { "claude" }, size = 20.dp)
            Text(
                run.label.ifEmpty { "Run ${runIndex + 1}" },
                fontFamily = neon.mono,
                fontWeight = FontWeight.Bold,
                fontSize = 13.sp,
                color = neon.text,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (isWinner) {
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(50))
                        .background(neon.green.copy(alpha = 0.15f))
                        .padding(horizontal = 6.dp, vertical = 2.dp),
                ) {
                    Text(
                        "winner",
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.Bold,
                        fontSize = 9.sp,
                        color = neon.green,
                    )
                }
            }
            val phaseColor = if (run.error.isNotEmpty()) neon.red else neon.green
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(50))
                    .background(phaseColor.copy(alpha = 0.13f))
                    .padding(horizontal = 6.dp, vertical = 2.dp),
            ) {
                Text(
                    run.phase.ifEmpty { "done" },
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 9.sp,
                    color = phaseColor,
                )
            }
        }

        if (run.filesChanged > 0) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("${run.filesChanged} files", fontFamily = neon.mono, fontSize = 11.sp, color = neon.textDim)
                Text("+${run.insertions}", fontFamily = neon.mono, fontSize = 11.sp, color = neon.green)
                Text("-${run.deletions}", fontFamily = neon.mono, fontSize = 11.sp, color = neon.red)
            }
        }

        if (run.agentSummary.isNotEmpty()) {
            Text(
                run.agentSummary,
                fontFamily = neon.sans,
                fontSize = 12.sp,
                color = neon.textDim,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }

        if (run.error.isNotEmpty()) {
            Text(
                run.error,
                fontFamily = neon.sans,
                fontSize = 11.sp,
                color = neon.red,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }

        if (run.error.isEmpty()) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                // Open button
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(50))
                        .background(neon.surface2)
                        .border(1.dp, neon.borderStrong, RoundedCornerShape(50))
                        .clickable(onClick = onOpen)
                        .padding(vertical = 8.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        "Open",
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 12.sp,
                        color = neon.accent,
                    )
                }
                // Pick button
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(50))
                        .background(if (canPick) neon.accent else neon.surface2)
                        .clickable(enabled = canPick, onClick = onPick)
                        .padding(vertical = 8.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    if (isPicking) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(14.dp),
                            color = neon.accentText,
                            strokeWidth = 2.dp,
                        )
                    } else {
                        Text(
                            if (isWinner) "Picked" else "Pick",
                            fontFamily = neon.mono,
                            fontWeight = FontWeight.Bold,
                            fontSize = 12.sp,
                            color = if (canPick) neon.accentText else neon.textFaint,
                        )
                    }
                }
            }
        }
    }
}

