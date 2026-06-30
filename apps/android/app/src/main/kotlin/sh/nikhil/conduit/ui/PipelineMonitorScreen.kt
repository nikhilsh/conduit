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
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry
import java.net.HttpURLConnection
import java.net.URL

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
)

private fun parsePipeline(json: JSONObject): Pipeline {
    val stepsArr = json.optJSONArray("steps")
    val steps = mutableListOf<PipelineStep>()
    if (stepsArr != null) {
        for (i in 0 until stepsArr.length()) {
            val s = stepsArr.getJSONObject(i)
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
                ),
            )
        }
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
    )
}

private val TERMINAL_STATES = setOf("done", "failed", "cancelled")

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
) {
    val neon = LocalNeonTheme.current
    val endpoint by store.endpoint.collectAsState()
    val scope = rememberCoroutineScope()

    var pipeline by remember { mutableStateOf<Pipeline?>(null) }
    var pollError by remember { mutableStateOf<String?>(null) }
    var showCancelConfirm by remember { mutableStateOf(false) }
    var isContinuing by remember { mutableStateOf(false) }
    var isCancelling by remember { mutableStateOf(false) }
    var actionError by remember { mutableStateOf<String?>(null) }

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

    // Polling loop: every 5 seconds until terminal state
    LaunchedEffect(pipelineId) {
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
                        "Loading pipeline...",
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

                // Step rows
                Text(
                    "STEPS",
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.Bold,
                    fontSize = 11.sp,
                    color = neon.textDim,
                )

                p.steps.forEach { step ->
                    val stepState = resolveStepState(step, p)
                    PipelineStepRow(
                        step = step,
                        stepState = stepState,
                        neon = neon,
                        onTap = {
                            step.sessionId?.let { sid ->
                                Telemetry.breadcrumb(
                                    "pipeline",
                                    "step_session_opened",
                                    mapOf("pipeline_id" to pipelineId, "step" to step.index.toString()),
                                )
                                onOpenSession(sid)
                            }
                        },
                    )
                }

                // Awaiting gate card
                if (p.state == "awaiting_gate") {
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
                                "Waiting for your approval",
                                fontFamily = neon.sans,
                                fontWeight = FontWeight.SemiBold,
                                color = neon.yellow,
                            )
                            Text(
                                "The pipeline is paused at a gate step. Review the output above, then continue.",
                                fontFamily = neon.sans,
                                fontSize = 13.sp,
                                color = neon.textDim,
                            )
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(10.dp))
                                    .background(if (!isContinuing) neon.yellow else neon.surface2)
                                    .clickable(enabled = !isContinuing) {
                                        isContinuing = true
                                        Telemetry.breadcrumb(
                                            "pipeline",
                                            "gate_continue_tapped",
                                            mapOf("pipeline_id" to pipelineId),
                                        )
                                        scope.launch {
                                            val result = withContext(Dispatchers.IO) {
                                                postEndpoint("/api/pipeline/$pipelineId/continue")
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
                                    Text(
                                        "Continue",
                                        fontFamily = neon.sans,
                                        fontWeight = FontWeight.Bold,
                                        color = neon.accentText,
                                    )
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
                                "Pipeline failed",
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
                                            onOpenSession(failedStep.sessionId)
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
            title = { Text("Cancel pipeline?") },
            text = { Text("This will stop the running pipeline. This cannot be undone.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        showCancelConfirm = false
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
                ) { Text("Cancel pipeline", color = neon.red) }
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
}

/** Derive a display state string for a step given pipeline state. */
private fun resolveStepState(step: PipelineStep, pipeline: Pipeline): String {
    val phase = step.phase
    if (phase.isNullOrEmpty()) {
        return if (step.index < pipeline.currentStep) "queued" else "queued"
    }
    if (!phase.startsWith("exited")) return "running"
    val open = phase.indexOf('(')
    val close = phase.indexOf(')')
    if (open in 0 until close) {
        val code = phase.substring(open + 1, close).toIntOrNull()
        if (code != null) return if (code == 0) "done" else "failed"
    }
    return "done"
}

@Composable
private fun PipelineStateChip(state: String, neon: NeonTheme) {
    val color = when (state) {
        "running" -> neon.accent
        "done" -> neon.green
        "failed" -> neon.red
        "awaiting_gate" -> neon.yellow
        "cancelled" -> neon.textFaint
        else -> neon.textFaint
    }
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(color.copy(alpha = 0.15f))
            .border(1.dp, color.copy(alpha = 0.45f), RoundedCornerShape(50))
            .padding(horizontal = 10.dp, vertical = 4.dp),
    ) {
        Text(
            state.replace("_", " "),
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
    neon: NeonTheme,
    onTap: () -> Unit,
) {
    val stateColor = when (stepState) {
        "running" -> neon.accent
        "done" -> neon.green
        "failed" -> neon.red
        "awaiting-gate" -> neon.yellow
        else -> neon.textFaint
    }
    val isTappable = step.sessionId != null

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = RoundedCornerShape(12.dp), fill = neon.surface)
            .then(if (isTappable) Modifier.clickable(onClick = onTap) else Modifier),
    ) {
        Row(
            modifier = Modifier.padding(12.dp).fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            AgentAvatar(assistant = step.agentType, size = 30.dp)
            Column(modifier = Modifier.weight(1f)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        step.role.ifEmpty { step.agentType },
                        fontFamily = neon.sans,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 13.sp,
                        color = neon.text,
                    )
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(50))
                            .background(neon.surface2)
                            .padding(horizontal = 6.dp, vertical = 2.dp),
                    ) {
                        Text(
                            "Step ${step.index + 1}",
                            fontFamily = neon.mono,
                            fontSize = 10.sp,
                            color = neon.textFaint,
                        )
                    }
                }
                if (!step.inputFromPrev.isNullOrEmpty() && step.inputFromPrev != "none") {
                    Text(
                        "input: ${step.inputFromPrev}",
                        fontFamily = neon.mono,
                        fontSize = 11.sp,
                        color = neon.textFaint,
                    )
                }
            }
            PipelineStepStateChip(state = stepState, neon = neon)
            if (stateColor == neon.accent) {
                CircularProgressIndicator(
                    modifier = Modifier.size(12.dp),
                    color = neon.accent,
                    strokeWidth = 1.5.dp,
                )
            }
        }
    }
}

@Composable
private fun PipelineStepStateChip(state: String, neon: NeonTheme) {
    val color = when (state) {
        "running" -> neon.accent
        "done" -> neon.green
        "failed" -> neon.red
        "awaiting-gate" -> neon.yellow
        else -> neon.textFaint
    }
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(color.copy(alpha = 0.12f))
            .border(1.dp, color.copy(alpha = 0.40f), RoundedCornerShape(50))
            .padding(horizontal = 7.dp, vertical = 3.dp),
    ) {
        Text(
            state,
            fontFamily = neon.mono,
            fontSize = 10.sp,
            fontWeight = FontWeight.SemiBold,
            color = color,
        )
    }
}
