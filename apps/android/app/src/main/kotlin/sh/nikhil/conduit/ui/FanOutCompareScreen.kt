package sh.nikhil.conduit.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry
import java.net.HttpURLConnection
import java.net.URL

/** One run result from POST /api/fanout/compare. */
data class FanOutCompareRun(
    val sessionId: String,
    val label: String,
    val phase: String,
    val filesChanged: Int,
    val insertions: Int,
    val deletions: Int,
    val diffStat: String,
    val agentSummary: String,
    val error: String,
)

/**
 * Compare-results screen shown after POST /api/fanout/compare succeeds.
 * Receives the sorted run list from the caller (already network-resolved).
 * Runs are sorted by filesChanged descending; failed runs go last at 0.4f alpha.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FanOutCompareScreen(
    store: SessionStore,
    runs: List<FanOutCompareRun>,
    onOpenSession: (String) -> Unit = {},
    onBack: () -> Unit = {},
) {
    val neon = LocalNeonTheme.current
    val endpoint by store.endpoint.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    Telemetry.breadcrumb(
        "fanout",
        "compare_view_opened",
        mapOf("run_count" to runs.size.toString()),
    )

    // Sort: filesChanged desc, then failed runs (non-empty error) go last.
    val sorted = remember(runs) {
        runs.sortedWith(
            compareBy<FanOutCompareRun> { it.error.isNotEmpty() }
                .thenByDescending { it.filesChanged },
        )
    }

    // PR dialog state (shared across runs)
    var prDialogSessionId by remember { mutableStateOf<String?>(null) }
    var prTitle by remember { mutableStateOf("") }
    var prBody by remember { mutableStateOf("") }
    var prResultUrl by remember { mutableStateOf<String?>(null) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    fun postToEndpoint(path: String, body: JSONObject): Result<JSONObject> {
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

    Scaffold(
        containerColor = neon.bg,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        "Compare runs",
                        fontFamily = neon.sans,
                        fontWeight = FontWeight.Bold,
                        color = neon.text,
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = neon.text)
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
            if (sorted.isEmpty()) {
                Text(
                    "No compare results.",
                    fontFamily = neon.sans,
                    color = neon.textDim,
                )
            } else {
                sorted.forEach { run ->
                    val isFailed = run.error.isNotEmpty()
                    val alpha = if (isFailed) 0.4f else 1f

                    Box(modifier = Modifier.alpha(alpha)) {
                        CompareRunCard(
                            run = run,
                            neon = neon,
                            onOpen = {
                                Telemetry.breadcrumb(
                                    "fanout",
                                    "compare_open_session",
                                    mapOf("session_id" to run.sessionId, "label" to run.label),
                                )
                                onOpenSession(run.sessionId)
                            },
                            onCommitPR = {
                                Telemetry.breadcrumb(
                                    "fanout",
                                    "compare_commit_pr_tapped",
                                    mapOf("session_id" to run.sessionId, "label" to run.label),
                                )
                                prDialogSessionId = run.sessionId
                                prTitle = ""
                                prBody = ""
                            },
                        )
                    }
                }
            }
        }
    }

    // PR input dialog
    prDialogSessionId?.let { sid ->
        AlertDialog(
            onDismissRequest = { prDialogSessionId = null },
            title = { Text("Open Pull Request") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedTextField(
                        value = prTitle,
                        onValueChange = { prTitle = it },
                        label = { Text("Title (required)") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    OutlinedTextField(
                        value = prBody,
                        onValueChange = { prBody = it },
                        label = { Text("Description (optional)") },
                        minLines = 3,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            },
            confirmButton = {
                TextButton(
                    enabled = prTitle.trim().isNotEmpty(),
                    onClick = {
                        val title = prTitle.trim()
                        val sessionId = sid
                        prDialogSessionId = null
                        scope.launch {
                            val body = JSONObject().apply {
                                put("title", title)
                                put("body", prBody)
                            }
                            val result = withContext(Dispatchers.IO) {
                                postToEndpoint("/api/session/$sessionId/git/pr", body)
                            }
                            result.onSuccess { json ->
                                val ok = json.optBoolean("ok", false)
                                if (ok) {
                                    val url = json.optString("pr_url", "")
                                    Telemetry.breadcrumb(
                                        "fanout",
                                        "compare_pr_opened",
                                        mapOf("session_id" to sessionId, "url" to url),
                                    )
                                    prResultUrl = url
                                } else {
                                    errorMessage = json.optString("stderr", "Failed to open PR")
                                }
                            }.onFailure { e ->
                                Telemetry.capture(
                                    error = e,
                                    message = "fanout compare open-pr network error",
                                    tags = mapOf("surface" to "android", "phase" to "fanout-compare"),
                                    extras = mapOf("session_id" to sessionId),
                                )
                                errorMessage = e.message ?: "Network error"
                            }
                        }
                    },
                ) { Text("Open PR") }
            },
            dismissButton = {
                TextButton(onClick = { prDialogSessionId = null }) { Text("Cancel") }
            },
        )
    }

    // PR success dialog
    prResultUrl?.let { url ->
        AlertDialog(
            onDismissRequest = { prResultUrl = null },
            title = { Text("Pull Request Opened") },
            text = { Text(url) },
            confirmButton = {
                TextButton(onClick = {
                    prResultUrl = null
                    runCatching {
                        context.startActivity(
                            Intent(Intent.ACTION_VIEW, Uri.parse(url))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                    }
                }) { Text("Open") }
            },
            dismissButton = {
                TextButton(onClick = { prResultUrl = null }) { Text("OK") }
            },
        )
    }

    // Error dialog
    errorMessage?.let { msg ->
        AlertDialog(
            onDismissRequest = { errorMessage = null },
            title = { Text("Error") },
            text = { Text(msg) },
            confirmButton = {
                TextButton(onClick = { errorMessage = null }) { Text("OK") }
            },
        )
    }
}

@Composable
private fun CompareRunCard(
    run: FanOutCompareRun,
    neon: NeonTheme,
    onOpen: () -> Unit,
    onCommitPR: () -> Unit,
) {
    val isFailed = run.error.isNotEmpty()
    val isDone = run.phase == "exited(0)" || (run.phase.startsWith("exited") && !isFailed)
    val statusColor = when {
        isFailed -> neon.red
        isDone -> neon.green
        else -> neon.red
    }
    val statusLabel = when {
        isFailed -> "error"
        run.phase == "exited(0)" -> "exited(0)"
        run.phase.isNotEmpty() -> run.phase
        else -> "unknown"
    }

    var showDiff by remember { mutableStateOf(false) }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(
                neon = neon,
                shape = RoundedCornerShape(14.dp),
                fill = neon.surface,
                failed = isFailed,
            ),
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            // Header row: label + status chip
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    run.label,
                    modifier = Modifier.weight(1f),
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 14.sp,
                    color = neon.text,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.width(8.dp))
                StatusChip(label = statusLabel, color = statusColor, neon = neon)
            }

            // Diff stat row (omit if filesChanged == 0)
            if (run.filesChanged > 0) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "${run.filesChanged} files",
                        fontFamily = neon.mono,
                        fontSize = 12.sp,
                        color = neon.textDim,
                    )
                    Text(
                        "+${run.insertions}",
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 12.sp,
                        color = neon.green,
                    )
                    Text(
                        "-${run.deletions}",
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 12.sp,
                        color = neon.red,
                    )
                }
            }

            // Agent summary (max 2 lines)
            if (run.agentSummary.isNotEmpty()) {
                Text(
                    run.agentSummary,
                    fontFamily = neon.sans,
                    fontSize = 13.sp,
                    color = neon.textDim,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }

            // Show diff toggle
            if (run.diffStat.isNotEmpty()) {
                Text(
                    if (showDiff) "Hide diff" else "Show diff",
                    modifier = Modifier
                        .clickable { showDiff = !showDiff }
                        .padding(vertical = 2.dp),
                    fontFamily = neon.mono,
                    fontSize = 12.sp,
                    color = neon.accent,
                )
                AnimatedVisibility(visible = showDiff) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .background(neon.codeBg)
                            .horizontalScroll(rememberScrollState())
                            .padding(10.dp),
                    ) {
                        Text(
                            run.diffStat,
                            fontFamily = neon.mono,
                            fontSize = 11.sp,
                            color = neon.codeText,
                        )
                    }
                }
            }

            // Error text
            if (run.error.isNotEmpty()) {
                Text(
                    run.error,
                    fontFamily = neon.mono,
                    fontSize = 12.sp,
                    color = neon.red,
                )
            }

            // Action buttons
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                // Open button
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(10.dp))
                        .background(neon.surface2)
                        .border(1.dp, neon.border, RoundedCornerShape(10.dp))
                        .clickable(onClick = onOpen)
                        .padding(vertical = 10.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        "Open",
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 13.sp,
                        color = neon.accent,
                    )
                }

                // Commit & PR button
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(10.dp))
                        .background(neon.green.copy(alpha = 0.15f))
                        .border(1.dp, neon.green.copy(alpha = 0.45f), RoundedCornerShape(10.dp))
                        .clickable(onClick = onCommitPR)
                        .padding(vertical = 10.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        "Commit & PR",
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 13.sp,
                        color = neon.green,
                    )
                }
            }
        }
    }
}

@Composable
private fun StatusChip(label: String, color: Color, neon: NeonTheme) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(color.copy(alpha = 0.15f))
            .border(1.dp, color.copy(alpha = 0.45f), RoundedCornerShape(50))
            .padding(horizontal = 8.dp, vertical = 3.dp),
    ) {
        Text(
            label,
            fontFamily = neon.mono,
            fontWeight = FontWeight.SemiBold,
            fontSize = 11.sp,
            color = color,
        )
    }
}
