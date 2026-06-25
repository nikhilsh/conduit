package sh.nikhil.conduit.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.outlined.KeyboardArrowRight
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry
import uniffi.conduit_core.ConversationItem
import uniffi.conduit_core.ProjectSession
import java.net.HttpURLConnection
import java.net.URL

/**
 * Diff review -> commit / PR  (handoff §B.6).
 *
 * A session's changed files, top to bottom:
 *   1. Summary bar — `N files · +added −removed` + a stacked add/del bar
 *      (green additions / red deletions), from parsed per-file totals
 *      (precise) or the session `linesAdded`/`linesRemoved` rollup.
 *   2. File list — path + per-file `+/−`, tappable to expand an inline
 *      unified diff (mono, +green / −red).
 *   3. Commit bar — message field + `Commit & push` / `Open PR`.
 *
 * The Commit & push and Open PR buttons call broker endpoints:
 *   POST /api/session/{id}/git/commit  — broker PR #764
 *   POST /api/session/{id}/git/pr      — broker PR #764
 * Both buttons are disabled while an inflight request is in progress.
 */
@Composable
fun DiffReviewScreen(
    store: SessionStore,
    session: ProjectSession,
    onDismiss: () -> Unit = {},
) {
    val neon = LocalNeonTheme.current
    val conversationLog by store.conversationLog.collectAsState()
    val displayNames by store.displayNames.collectAsState()
    val endpoint by store.endpoint.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    val log = conversationLog[session.id].orEmpty()
    val files = remember(log) { DiffReviewStats.files(log) }
    val hasInlineDiff = remember(log) { DiffReviewStats.hasInlineDiff(log) }
    val summary = remember(log, files, session) { DiffReviewStats.summary(session, files, log) }
    val distinctPaths = remember(log) {
        log.filter { it.kind == "diff" }.flatMap { it.files.map { f -> f.path } }.distinct().sorted()
    }
    val name = displayNames[session.id] ?: session.name

    var commitMessage by remember { mutableStateOf(TextFieldValue("")) }
    val expanded = remember { mutableStateMapOf<String, Boolean>() }

    // Inflight state — buttons are disabled while a request is in flight.
    var isCommitting by remember { mutableStateOf(false) }
    var isOpeningPR by remember { mutableStateOf(false) }

    // Dialog state
    var commitResultSha by remember { mutableStateOf<String?>(null) }
    var prResultUrl by remember { mutableStateOf<String?>(null) }
    var showPRInput by remember { mutableStateOf(false) }
    var prTitle by remember { mutableStateOf("") }
    var prBody by remember { mutableStateOf("") }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    // Helper: POST to broker and parse {"ok":bool,...} response.
    // Returns a Result<JSONObject> from an IO dispatcher.
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

    Column(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 14.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // Header
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    name,
                    style = MaterialTheme.typography.titleLarge,
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.Bold,
                    color = neon.text,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    DiffPill(session.assistant, neonAgentColor(session.assistant, neon), neon)
                    session.branch?.takeIf { it.isNotBlank() }?.let { DiffPill(it, neon.accent, neon) }
                }
                NeonOutcomeChips(
                    neon = neon,
                    linesAdded = null,
                    linesRemoved = null,
                    commits = session.commits?.toInt(),
                    prNumber = session.prNumber?.toInt(),
                    prState = session.prState,
                    prUrl = session.prUrl,
                )
            }

            // Summary bar
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface),
            ) {
                Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(
                            "${summary.fileCount}",
                            fontFamily = neon.mono,
                            fontWeight = FontWeight.Bold,
                            fontSize = 28.sp,
                            color = neon.accent,
                        )
                        Column {
                            Text(
                                "FILES",
                                fontFamily = neon.mono,
                                fontWeight = FontWeight.SemiBold,
                                fontSize = 11.sp,
                                color = neon.textDim,
                            )
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text("+${summary.added}", fontFamily = neon.mono, fontWeight = FontWeight.SemiBold, fontSize = 13.sp, color = neon.green)
                                Text("−${summary.removed}", fontFamily = neon.mono, fontWeight = FontWeight.SemiBold, fontSize = 13.sp, color = neon.red)
                            }
                        }
                    }
                    StackedAddDelBar(addedFraction = summary.addedFraction, neon = neon)
                }
            }

            // Files
            Text(
                "FILES",
                fontFamily = neon.mono,
                fontWeight = FontWeight.Bold,
                fontSize = 11.sp,
                color = neon.textDim,
            )

            when {
                files.isNotEmpty() -> {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        files.forEach { file ->
                            FileRow(
                                file = file,
                                isOpen = expanded[file.path] == true,
                                neon = neon,
                                onToggle = { expanded[file.path] = expanded[file.path] != true },
                            )
                        }
                    }
                }
                hasInlineDiff -> FallbackNote("No file detail in this diff. Open the chat for the full diff.", neon)
                summary.fileCount > 0 || summary.added > 0 || summary.removed > 0 -> {
                    if (distinctPaths.isNotEmpty()) {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            distinctPaths.forEach { PathOnlyRow(it, neon) }
                        }
                    }
                    FallbackNote("Open the chat for the full diff.", neon)
                }
                else -> FallbackNote("No changes yet.", neon)
            }
        }

        // Commit bar
        CommitBar(
            message = commitMessage,
            onMessageChange = { commitMessage = it },
            isCommitting = isCommitting,
            isOpeningPR = isOpeningPR,
            onCommitPush = {
                val msg = commitMessage.text.trim()
                if (msg.isEmpty()) return@CommitBar
                isCommitting = true
                Telemetry.breadcrumb(
                    "diff-review",
                    "commit start",
                    mapOf("session" to session.id, "host" to endpoint.displayHost),
                )
                scope.launch {
                    val body = JSONObject().apply {
                        put("message", msg)
                        put("push", true)
                    }
                    val result = withContext(Dispatchers.IO) {
                        postToEndpoint("/api/session/${session.id}/git/commit", body)
                    }
                    isCommitting = false
                    result.onSuccess { json ->
                        val ok = json.optBoolean("ok", false)
                        if (ok) {
                            val sha = json.optString("commit_sha", "(unknown)")
                            Telemetry.breadcrumb(
                                "diff-review",
                                "commit ok",
                                mapOf("session" to session.id, "sha" to sha),
                            )
                            commitMessage = TextFieldValue("")
                            commitResultSha = sha
                        } else {
                            val stderr = json.optString("stderr", "Commit failed")
                            Telemetry.diagnostic(
                                "diff-review commit failed",
                                tags = mapOf("surface" to "android", "phase" to "diff-review"),
                                extras = mapOf("session" to session.id, "stderr" to stderr),
                            )
                            errorMessage = stderr
                        }
                    }.onFailure { e ->
                        Telemetry.capture(
                            error = e,
                            message = "diff-review commit network error",
                            tags = mapOf("surface" to "android", "phase" to "diff-review"),
                            extras = mapOf("session" to session.id),
                        )
                        errorMessage = e.message ?: "Network error"
                    }
                }
            },
            onOpenPR = {
                prTitle = ""
                prBody = ""
                showPRInput = true
            },
            neon = neon,
        )
    }

    // PR input dialog
    if (showPRInput) {
        AlertDialog(
            onDismissRequest = { showPRInput = false },
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
                        showPRInput = false
                        val title = prTitle.trim()
                        isOpeningPR = true
                        Telemetry.breadcrumb(
                            "diff-review",
                            "open-pr start",
                            mapOf("session" to session.id, "host" to endpoint.displayHost),
                        )
                        scope.launch {
                            val body = JSONObject().apply {
                                put("title", title)
                                put("body", prBody)
                            }
                            val result = withContext(Dispatchers.IO) {
                                postToEndpoint("/api/session/${session.id}/git/pr", body)
                            }
                            isOpeningPR = false
                            result.onSuccess { json ->
                                val ok = json.optBoolean("ok", false)
                                if (ok) {
                                    val url = json.optString("pr_url", "")
                                    Telemetry.breadcrumb(
                                        "diff-review",
                                        "open-pr ok",
                                        mapOf("session" to session.id, "url" to url),
                                    )
                                    prResultUrl = url
                                } else {
                                    val stderr = json.optString("stderr", "Failed to open PR")
                                    Telemetry.diagnostic(
                                        "diff-review open-pr failed",
                                        tags = mapOf("surface" to "android", "phase" to "diff-review"),
                                        extras = mapOf("session" to session.id, "stderr" to stderr),
                                    )
                                    errorMessage = stderr
                                }
                            }.onFailure { e ->
                                Telemetry.capture(
                                    error = e,
                                    message = "diff-review open-pr network error",
                                    tags = mapOf("surface" to "android", "phase" to "diff-review"),
                                    extras = mapOf("session" to session.id),
                                )
                                errorMessage = e.message ?: "Network error"
                            }
                        }
                    },
                ) { Text("Open PR") }
            },
            dismissButton = {
                TextButton(onClick = { showPRInput = false }) { Text("Cancel") }
            },
        )
    }

    // Commit success dialog
    commitResultSha?.let { sha ->
        AlertDialog(
            onDismissRequest = { commitResultSha = null },
            title = { Text("Committed") },
            text = { Text("SHA: $sha") },
            confirmButton = {
                TextButton(onClick = { commitResultSha = null }) { Text("OK") }
            },
        )
    }

    // PR success dialog — shows URL and an "Open" button
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
private fun StackedAddDelBar(addedFraction: Double, neon: NeonTheme) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(8.dp)
            .clip(RoundedCornerShape(50)),
    ) {
        val green = addedFraction.coerceIn(0.0, 1.0).toFloat()
        if (green > 0f) {
            Box(modifier = Modifier.weight(green).fillMaxWidth().height(8.dp).background(neon.green))
        }
        if (green < 1f) {
            Box(modifier = Modifier.weight(1f - green).fillMaxWidth().height(8.dp).background(neon.red))
        }
    }
}

@Composable
private fun FileRow(
    file: DiffReviewStats.DiffFile,
    isOpen: Boolean,
    neon: NeonTheme,
    onToggle: () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = RoundedCornerShape(12.dp), fill = neon.surface),
    ) {
        Column {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .let { if (file.lines.isNotEmpty()) it.clickable(onClick = onToggle) else it }
                    .padding(horizontal = 12.dp, vertical = 11.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text(
                    file.path,
                    modifier = Modifier.weight(1f),
                    fontFamily = neon.mono,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                    color = neon.text,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text("+${file.added}", fontFamily = neon.mono, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = neon.green)
                Text("−${file.removed}", fontFamily = neon.mono, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = neon.red)
                if (file.lines.isNotEmpty()) {
                    Icon(
                        if (isOpen) Icons.Filled.KeyboardArrowDown else Icons.Outlined.KeyboardArrowRight,
                        contentDescription = null,
                        tint = neon.textFaint,
                    )
                }
            }
            if (isOpen && file.lines.isNotEmpty()) {
                Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(neon.border))
                InlineDiff(file.lines, neon)
            }
        }
    }
}

@Composable
private fun InlineDiff(lines: List<DiffReviewStats.DiffLine>, neon: NeonTheme) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(vertical = 6.dp),
    ) {
        lines.forEach { line ->
            val color = when (line.kind) {
                DiffReviewStats.LineKind.ADDED -> neon.green
                DiffReviewStats.LineKind.REMOVED -> neon.red
                DiffReviewStats.LineKind.HUNK -> neon.accent
                DiffReviewStats.LineKind.META -> neon.textFaint
                DiffReviewStats.LineKind.CONTEXT -> neon.textDim
            }
            val bg = when (line.kind) {
                DiffReviewStats.LineKind.ADDED -> neon.green.copy(alpha = 0.10f)
                DiffReviewStats.LineKind.REMOVED -> neon.red.copy(alpha = 0.10f)
                else -> Color.Transparent
            }
            Text(
                line.text.ifEmpty { " " },
                modifier = Modifier
                    .fillMaxWidth()
                    .background(bg)
                    .padding(horizontal = 12.dp, vertical = 1.dp),
                fontFamily = neon.mono,
                fontSize = 11.sp,
                color = color,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun PathOnlyRow(path: String, neon: NeonTheme) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = RoundedCornerShape(12.dp), fill = neon.surface),
    ) {
        Text(
            path,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 11.dp),
            fontFamily = neon.mono,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            color = neon.text,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun FallbackNote(text: String, neon: NeonTheme) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = RoundedCornerShape(12.dp), fill = neon.surface),
    ) {
        Text(
            text,
            modifier = Modifier.padding(14.dp),
            fontFamily = neon.sans,
            fontSize = 13.sp,
            color = neon.textDim,
        )
    }
}

@Composable
private fun CommitBar(
    message: TextFieldValue,
    onMessageChange: (TextFieldValue) -> Unit,
    isCommitting: Boolean,
    isOpeningPR: Boolean,
    onCommitPush: () -> Unit,
    onOpenPR: () -> Unit,
    neon: NeonTheme,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(neon.bg)
            .navigationBarsPadding()
            .imePadding()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(neon.border))
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(neon.surface2)
                .padding(horizontal = 12.dp, vertical = 10.dp),
        ) {
            if (message.text.isEmpty()) {
                Text("Commit message", fontFamily = neon.sans, fontSize = 14.sp, color = neon.textFaint)
            }
            BasicTextField(
                value = message,
                onValueChange = onMessageChange,
                textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = neon.sans, color = neon.text),
                cursorBrush = androidx.compose.ui.graphics.SolidColor(neon.accent),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
            val canCommit = message.text.isNotBlank() && !isCommitting && !isOpeningPR
            Surface(
                shape = RoundedCornerShape(50),
                color = neon.green.copy(alpha = if (canCommit) 1f else 0.55f),
                modifier = Modifier
                    .weight(1f)
                    .let { if (canCommit) it.clickable(onClick = onCommitPush) else it },
            ) {
                Row(
                    modifier = Modifier.padding(vertical = 12.dp),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (isCommitting) {
                        CircularProgressIndicator(
                            modifier = Modifier
                                .height(14.dp)
                                .width(14.dp),
                            color = neon.accentText,
                            strokeWidth = 2.dp,
                        )
                        Spacer(Modifier.width(6.dp))
                    }
                    Text(
                        if (isCommitting) "Committing..." else "Commit & push",
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 13.sp,
                        color = neon.accentText,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    )
                }
            }
            val canPR = !isCommitting && !isOpeningPR
            Surface(
                shape = RoundedCornerShape(50),
                color = neon.surface,
                modifier = Modifier
                    .weight(1f)
                    .let { if (canPR) it.clickable(onClick = onOpenPR) else it },
            ) {
                Row(
                    modifier = Modifier.padding(vertical = 12.dp),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (isOpeningPR) {
                        CircularProgressIndicator(
                            modifier = Modifier
                                .height(14.dp)
                                .width(14.dp),
                            color = neon.accent,
                            strokeWidth = 2.dp,
                        )
                        Spacer(Modifier.width(6.dp))
                    }
                    Text(
                        if (isOpeningPR) "Opening..." else "Open PR",
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 13.sp,
                        color = neon.accent,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    )
                }
            }
        }
    }
}

@Composable
private fun DiffPill(label: String, tint: Color, neon: NeonTheme) {
    Surface(shape = RoundedCornerShape(50), color = tint.copy(alpha = 0.30f)) {
        Text(
            label,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
            style = MaterialTheme.typography.labelMedium,
            fontFamily = neon.mono,
            fontWeight = FontWeight.SemiBold,
            color = neon.text,
        )
    }
}

/**
 * Pure, unit-testable diff parsing + summary math for [DiffReviewScreen].
 * String-in / value-out — no Compose deps. Mirror of iOS
 * `ConduitUI.DiffReviewModel`.
 *
 * The diff body comes from the most recent `kind == "diff"`
 * [ConversationItem]'s `content` (a raw unified diff: `diff --git` headers,
 * `@@` hunks, `+`/`-` lines). Per-file +/- counts are real `+`/`-` body-line
 * tallies, never fabricated. Falls back to the session `linesAdded`/
 * `linesRemoved` rollup for the summary when no diff item is present.
 */
object DiffReviewStats {

    enum class LineKind { ADDED, REMOVED, CONTEXT, HUNK, META }

    data class DiffLine(val kind: LineKind, val text: String)

    data class DiffFile(
        val path: String,
        val added: Int,
        val removed: Int,
        val lines: List<DiffLine>,
    )

    data class Summary(val fileCount: Int, val added: Int, val removed: Int) {
        /** Green fraction of the add/del bar; 0.5 when both are zero. */
        val addedFraction: Double
            get() {
                val total = added + removed
                return if (total > 0) added.toDouble() / total.toDouble() else 0.5
            }

        val deltaLabel: String get() = "+$added −$removed"
        val fileCountLabel: String get() = "$fileCount file${if (fileCount == 1) "" else "s"}"
    }

    /** Parse the most recent `diff` item's patch text into per-file groups. */
    fun files(log: List<ConversationItem>): List<DiffFile> {
        val latest = log.lastOrNull { it.kind == "diff" } ?: return emptyList()
        return parsePatch(latest.content)
    }

    fun hasInlineDiff(log: List<ConversationItem>): Boolean = log.any { it.kind == "diff" }

    fun summary(session: ProjectSession, files: List<DiffFile>, log: List<ConversationItem>): Summary {
        if (files.isNotEmpty()) {
            return Summary(
                fileCount = files.size,
                added = files.sumOf { it.added },
                removed = files.sumOf { it.removed },
            )
        }
        val paths = log.filter { it.kind == "diff" }.flatMap { it.files.map { f -> f.path } }.toSet()
        return Summary(
            fileCount = paths.size,
            added = session.linesAdded?.toInt() ?: 0,
            removed = session.linesRemoved?.toInt() ?: 0,
        )
    }

    fun parsePatch(patch: String): List<DiffFile> {
        val files = mutableListOf<DiffFile>()
        var path: String? = null
        var added = 0
        var removed = 0
        var lines = mutableListOf<DiffLine>()

        fun flush() {
            path?.let { files.add(DiffFile(it, added, removed, lines)) }
            path = null; added = 0; removed = 0; lines = mutableListOf()
        }

        for (line in patch.split("\n")) {
            when {
                line.startsWith("diff --git ") -> {
                    flush()
                    path = pathFromGitHeader(line)
                }
                line.startsWith("+++ ") -> {
                    if (path == null) path = pathFromTripleHeader(line)
                    else if (path == "") path = pathFromTripleHeader(line)
                    if (path != null) lines.add(DiffLine(LineKind.META, line))
                }
                line.startsWith("--- ") -> if (path != null) lines.add(DiffLine(LineKind.META, line))
                line.startsWith("@@") -> if (path != null) lines.add(DiffLine(LineKind.HUNK, line))
                line.startsWith("+") -> if (path != null) { added++; lines.add(DiffLine(LineKind.ADDED, line)) }
                line.startsWith("-") -> if (path != null) { removed++; lines.add(DiffLine(LineKind.REMOVED, line)) }
                line.startsWith("index ") || line.startsWith("new file") ||
                    line.startsWith("deleted file") || line.startsWith("similarity") ||
                    line.startsWith("rename ") ->
                    if (path != null) lines.add(DiffLine(LineKind.META, line))
                else -> if (path != null) lines.add(DiffLine(LineKind.CONTEXT, line))
            }
        }
        flush()
        return files.filter { !(it.path.isEmpty() && it.added == 0 && it.removed == 0 && it.lines.isEmpty()) }
    }

    /** `diff --git a/src/x.ts b/src/x.ts` -> `src/x.ts` (prefers the b-side). */
    fun pathFromGitHeader(line: String): String {
        val rest = line.removePrefix("diff --git ")
        val parts = rest.split(" ", limit = 2)
        if (parts.size != 2) return ""
        return stripABPrefix(parts[1])
    }

    /** `+++ b/src/x.ts` -> `src/x.ts`. Trims a trailing tab-timestamp. */
    fun pathFromTripleHeader(line: String): String {
        var rest = line.removePrefix("+++ ")
        val tab = rest.indexOf('\t')
        if (tab >= 0) rest = rest.substring(0, tab)
        return stripABPrefix(rest)
    }

    private fun stripABPrefix(s: String): String =
        if (s.startsWith("a/") || s.startsWith("b/")) s.substring(2) else s
}
