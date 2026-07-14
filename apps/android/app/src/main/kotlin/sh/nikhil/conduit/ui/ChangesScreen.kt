package sh.nikhil.conduit.ui

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.automirrored.filled.CallSplit
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import org.json.JSONArray
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry
import sh.nikhil.conduit.ui.components.ConduitActionPill
import sh.nikhil.conduit.ui.components.ConduitCard
import sh.nikhil.conduit.ui.components.ConduitChip
import sh.nikhil.conduit.ui.components.ButtonVariant
import sh.nikhil.conduit.ui.components.ConduitButton
import sh.nikhil.conduit.ui.components.DiffFileHunks
import sh.nikhil.conduit.ui.components.DiffHunkData
import sh.nikhil.conduit.ui.components.DiffLineData
import sh.nikhil.conduit.ui.components.NeonPillSegment
import sh.nikhil.conduit.ui.components.NeonSegmentedPill
import uniffi.conduit_core.ProjectSession

/**
 * The "Changes" surface (Feature A -- docs/PLAN-REVIEW-SHIP.md): a structured
 * diff review + line-anchored annotation + stage/commit/push/PR ship flow,
 * gated on `features.review_ship`. Android mirror of iOS
 * `ConduitUI.ConduitChangesView`.
 *
 * Two hosts, same [content]: a full-height [ModalBottomSheet] on phone
 * (mirrors [SessionInfoScreen]'s `embedded` convention), or embedded inline
 * as a tablet right-pane tab when [embedded] is true.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChangesScreen(
    store: SessionStore,
    session: ProjectSession,
    onDismiss: () -> Unit,
    embedded: Boolean = false,
) {
    val neon = LocalNeonTheme.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val viewModel = remember(session.id) { ChangesViewModel() }

    var selectedFilePath by remember(session.id) { mutableStateOf<String?>(null) }
    var annotateTarget by remember { mutableStateOf<Triple<String, DiffHunkData, DiffLineData>?>(null) }
    var commentDraft by remember { mutableStateOf("") }
    var showPRDialog by remember { mutableStateOf(false) }
    var prTitle by remember { mutableStateOf("") }
    var prBody by remember { mutableStateOf("") }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var isBusy by remember { mutableStateOf(false) }

    suspend fun loadDiff() {
        viewModel.isLoading = true
        viewModel.loadError = null
        Telemetry.breadcrumb(
            "review_ship", "diff_fetch_start",
            mapOf("session" to session.id, "scope" to viewModel.scope.wire),
        )
        val diff = store.fetchGitDiff(session.id, viewModel.scope)
        val state = store.fetchGitState(session.id)
        viewModel.isLoading = false
        if (diff != null) {
            viewModel.applyDiff(diff)
        } else {
            viewModel.loadError = "Couldn't load changes."
        }
        if (state != null) viewModel.gitState = state
    }

    LaunchedEffect(session.id) {
        Telemetry.breadcrumb("review_ship", "changes_open", mapOf("session" to session.id))
        viewModel.annotations = ChangesAnnotationStore.load(context, session.id)
    }
    LaunchedEffect(session.id, viewModel.scope) {
        loadDiff()
    }
    LaunchedEffect(viewModel.annotations) {
        ChangesAnnotationStore.save(context, session.id, viewModel.annotations)
    }

    fun runGitAction(label: String, action: suspend () -> org.json.JSONObject) {
        scope.launch {
            isBusy = true
            val result = action()
            isBusy = false
            if (result.optBoolean("ok", false)) {
                loadDiff()
            } else {
                errorMessage = result.optString("stderr", "$label failed")
            }
        }
    }

    val content: @Composable () -> Unit = {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .then(if (embedded) Modifier else Modifier.windowInsetsPadding(WindowInsets.navigationBars))
                .padding(horizontal = 14.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            ChangesHeader(
                title = if (selectedFilePath != null) selectedFilePath!!.substringAfterLast('/') else "Changes",
                diffstat = viewModel.diff?.diffstat,
                onBack = if (selectedFilePath != null) {
                    { selectedFilePath = null }
                } else {
                    null
                },
                onDismiss = if (!embedded) onDismiss else null,
            )

            if (selectedFilePath == null) {
                NeonSegmentedPill(
                    segments = listOf(NeonPillSegment("Uncommitted"), NeonPillSegment("Branch")),
                    selected = if (viewModel.scope == DiffScope.UNCOMMITTED) 0 else 1,
                    onSelect = { i -> viewModel.scope = if (i == 0) DiffScope.UNCOMMITTED else DiffScope.BRANCH },
                )
            }

            Column(
                modifier = Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                when {
                    viewModel.isLoading && viewModel.diff == null -> {
                        Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
                            CircularProgressIndicator(color = neon.accent)
                        }
                    }
                    viewModel.loadError != null -> {
                        Text(viewModel.loadError!!, fontFamily = neon.sans, color = neon.textDim)
                    }
                    selectedFilePath != null -> {
                        val file = viewModel.diff?.files?.firstOrNull { it.path == selectedFilePath }
                        if (file == null) {
                            Text("File no longer in the diff.", fontFamily = neon.sans, color = neon.textDim)
                        } else if (file.binary) {
                            Text("Binary file -- no inline diff.", fontFamily = neon.sans, color = neon.textDim)
                        } else {
                            DiffFileHunks(
                                hunks = file.hunks,
                                isLineAnnotated = { _, line -> viewModel.isAnnotated(file.path, line) },
                                onLineClick = { hunk, line ->
                                    Telemetry.breadcrumb(
                                        "review_ship", "annotate_add",
                                        mapOf("session" to session.id, "file" to file.path),
                                    )
                                    commentDraft = ""
                                    annotateTarget = Triple(file.path, hunk, line)
                                },
                            )
                        }
                    }
                    else -> {
                        ChangesBody(
                            neon = neon,
                            viewModel = viewModel,
                            isBusy = isBusy,
                            onOpenFile = { selectedFilePath = it },
                            onToggleStaged = { file ->
                                Telemetry.breadcrumb(
                                    "review_ship",
                                    if (file.staged) "unstage" else "stage",
                                    mapOf("session" to session.id, "file" to file.path),
                                )
                                if (file.staged) {
                                    runGitAction("Unstage") { store.gitUnstage(session.id, listOf(file.path)) }
                                } else {
                                    runGitAction("Stage") { store.gitStage(session.id, listOf(file.path)) }
                                }
                            },
                            onSendToAgent = {
                                val prompt = viewModel.composePrompt()
                                Telemetry.breadcrumb(
                                    "review_ship", "send_to_agent",
                                    mapOf("session" to session.id, "count" to viewModel.annotations.size.toString()),
                                )
                                store.sendChat(session.id, prompt)
                            },
                            onCommitStaged = {
                                val msg = viewModel.commitMessage.trim()
                                viewModel.commitMessage = ""
                                runGitAction("Commit") { store.gitCommit(session.id, msg, all = false) }
                            },
                            onCommitAll = {
                                val msg = viewModel.commitMessage.trim()
                                viewModel.commitMessage = ""
                                runGitAction("Commit") { store.gitCommit(session.id, msg, all = true) }
                            },
                            onPush = { runGitAction("Push") { store.gitPush(session.id) } },
                            onCreatePR = {
                                prTitle = ""
                                prBody = ""
                                showPRDialog = true
                            },
                        )
                    }
                }
            }
        }
    }

    if (embedded) {
        content()
    } else {
        ModalBottomSheet(
            onDismissRequest = onDismiss,
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            containerColor = neon.surfaceSolid,
            shape = RoundedCornerShape(topStart = 26.dp, topEnd = 26.dp),
        ) {
            content()
        }
    }

    annotateTarget?.let { (filePath, hunk, line) ->
        AlertDialog(
            onDismissRequest = { annotateTarget = null },
            title = { Text("Comment on line") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        line.text.ifBlank { " " },
                        fontFamily = neon.mono,
                        fontSize = 11.sp,
                        color = neon.textDim,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                    OutlinedTextField(
                        value = commentDraft,
                        onValueChange = { commentDraft = it },
                        label = { Text("Markdown comment") },
                        minLines = 3,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            },
            confirmButton = {
                TextButton(
                    enabled = commentDraft.isNotBlank(),
                    onClick = {
                        viewModel.addAnnotation(filePath, hunk, line, commentDraft.trim())
                        annotateTarget = null
                    },
                ) { Text("Save") }
            },
            dismissButton = {
                TextButton(onClick = { annotateTarget = null }) { Text("Cancel") }
            },
        )
    }

    if (showPRDialog) {
        AlertDialog(
            onDismissRequest = { showPRDialog = false },
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
                    enabled = prTitle.trim().isNotEmpty() && !isBusy,
                    onClick = {
                        showPRDialog = false
                        val title = prTitle.trim()
                        val bodyText = prBody
                        runGitAction("Create PR") { store.gitCreatePR(session.id, title, bodyText) }
                    },
                ) { Text("Open PR") }
            },
            dismissButton = {
                TextButton(onClick = { showPRDialog = false }) { Text("Cancel") }
            },
        )
    }

    errorMessage?.let { msg ->
        AlertDialog(
            onDismissRequest = { errorMessage = null },
            title = { Text("Git error") },
            text = { Text(msg, fontFamily = neon.mono, fontSize = 12.sp) },
            confirmButton = {
                TextButton(onClick = { errorMessage = null }) { Text("OK") }
            },
        )
    }
}

@Composable
private fun ChangesHeader(
    title: String,
    diffstat: DiffStat?,
    onBack: (() -> Unit)?,
    onDismiss: (() -> Unit)?,
) {
    val neon = LocalNeonTheme.current
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (onBack != null) {
            Text(
                "< Back",
                fontFamily = neon.sans,
                fontWeight = FontWeight.SemiBold,
                color = neon.accent,
                modifier = Modifier.clickable(onClick = onBack),
            )
        }
        Text(
            title,
            fontFamily = neon.sans,
            fontWeight = FontWeight.Bold,
            fontSize = 17.sp,
            color = neon.text,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (diffstat != null) {
            ConduitChip(label = "+${diffstat.additions}", tint = neon.green)
            ConduitChip(label = "−${diffstat.deletions}", tint = neon.red)
        }
        if (onDismiss != null && onBack == null) {
            Text(
                "Done",
                fontFamily = neon.sans,
                fontWeight = FontWeight.SemiBold,
                color = neon.accent,
                modifier = Modifier.clickable(onClick = onDismiss),
            )
        }
    }
}

@Composable
private fun ChangesBody(
    neon: NeonTheme,
    viewModel: ChangesViewModel,
    isBusy: Boolean,
    onOpenFile: (String) -> Unit,
    onToggleStaged: (DiffFile) -> Unit,
    onSendToAgent: () -> Unit,
    onCommitStaged: () -> Unit,
    onCommitAll: () -> Unit,
    onPush: () -> Unit,
    onCreatePR: () -> Unit,
) {
    val diff = viewModel.diff
    val gitState = viewModel.gitState

    // File list
    ConduitCard(pad = 0.dp) {
        val files = diff?.files.orEmpty()
        if (files.isEmpty()) {
            Text(
                "No changes.",
                modifier = Modifier.padding(14.dp),
                fontFamily = neon.sans,
                color = neon.textDim,
            )
        } else {
            files.forEachIndexed { idx, file ->
                FileRow(file = file, onOpen = { onOpenFile(file.path) }, onToggleStaged = { onToggleStaged(file) })
                if (idx != files.lastIndex) {
                    Box(Modifier.fillMaxWidth().height(1.dp).background(neon.border))
                }
            }
        }
    }

    // Review bar
    if (viewModel.annotations.isNotEmpty()) {
        ConduitCard {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    "${viewModel.annotations.size} comment${if (viewModel.annotations.size == 1) "" else "s"}",
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.SemiBold,
                    color = neon.text,
                    modifier = Modifier.weight(1f),
                )
                ConduitActionPill(label = "Send to agent", onClick = onSendToAgent, variant = sh.nikhil.conduit.ui.components.ActionPillVariant.Solid)
            }
            if (viewModel.unanchoredAnnotations.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                Text(
                    "${viewModel.unanchoredAnnotations.size} unanchored -- line text no longer present, still included when sent.",
                    fontFamily = neon.sans,
                    fontSize = 11.sp,
                    color = neon.yellow,
                )
            }
        }
    }

    // Ship card
    ConduitCard {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(
                "SHIP",
                fontFamily = neon.mono,
                fontWeight = FontWeight.SemiBold,
                fontSize = 11.sp,
                color = neon.textDim,
            )
            if (gitState != null && gitState.isGitRepo) {
                Text(
                    "${gitState.branch ?: "detached"} · ${gitState.staged} staged · ${gitState.unstaged} unstaged · ${gitState.untracked} untracked",
                    fontFamily = neon.mono,
                    fontSize = 11.sp,
                    color = neon.textDim,
                )
            }
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(neon.surface2)
                    .padding(horizontal = 12.dp, vertical = 10.dp),
            ) {
                if (viewModel.commitMessage.isEmpty()) {
                    Text("Commit message", fontFamily = neon.sans, fontSize = 14.sp, color = neon.textFaint)
                }
                BasicTextField(
                    value = viewModel.commitMessage,
                    onValueChange = { viewModel.commitMessage = it },
                    textStyle = androidx.compose.ui.text.TextStyle(fontFamily = neon.sans, color = neon.text, fontSize = 14.sp),
                    cursorBrush = SolidColor(neon.accent),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                ConduitButton(
                    title = "Commit staged",
                    onClick = onCommitStaged,
                    variant = ButtonVariant.Secondary,
                    enabled = !isBusy && viewModel.commitMessage.isNotBlank() && (gitState?.staged ?: 0) > 0,
                    modifier = Modifier.weight(1f),
                )
                ConduitButton(
                    title = "Commit all",
                    onClick = onCommitAll,
                    variant = ButtonVariant.Primary,
                    enabled = !isBusy && viewModel.commitMessage.isNotBlank(),
                    modifier = Modifier.weight(1f),
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                ConduitButton(
                    title = "Push",
                    onClick = onPush,
                    variant = ButtonVariant.Secondary,
                    enabled = !isBusy,
                    modifier = Modifier.weight(1f),
                )
                if (gitState?.hasGh == true) {
                    ConduitButton(
                        title = "Create PR",
                        onClick = onCreatePR,
                        variant = ButtonVariant.Secondary,
                        enabled = !isBusy,
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        }
    }
}

@Composable
private fun FileRow(file: DiffFile, onOpen: () -> Unit, onToggleStaged: () -> Unit) {
    val neon = LocalNeonTheme.current
    val (icon, tint) = statusGlyph(file.status, neon)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 14.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(icon, contentDescription = file.status, tint = tint, modifier = Modifier.size(16.dp))
        Column(
            modifier = Modifier.weight(1f).clickable(onClick = onOpen),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                file.path,
                fontFamily = neon.mono,
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                color = neon.text,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("+${file.additions}", fontFamily = neon.mono, fontSize = 11.sp, color = neon.green)
                Text("−${file.deletions}", fontFamily = neon.mono, fontSize = 11.sp, color = neon.red)
            }
        }
        Switch(
            checked = file.staged,
            onCheckedChange = { onToggleStaged() },
            colors = SwitchDefaults.colors(checkedTrackColor = neon.accent),
        )
    }
}

private fun statusGlyph(status: String, neon: NeonTheme): Pair<ImageVector, Color> = when (status) {
    "added", "untracked" -> Icons.Filled.Add to neon.green
    "deleted" -> Icons.Filled.Delete to neon.red
    "renamed", "copied" -> Icons.AutoMirrored.Filled.CallSplit to neon.accent
    else -> Icons.Filled.Edit to neon.yellow // "modified" fallback -- distinct tinted symbol, not a filled tile
}

/**
 * Local (client-side only, per-device) annotation persistence keyed by
 * session id -- no broker storage in v1 (docs/PLAN-REVIEW-SHIP.md §8). Plain
 * SharedPreferences JSON blob rather than a new Room/DataStore dependency:
 * this box has no Android SDK to verify a new Gradle dependency compiles, so
 * we stay on an already-shipped persistence primitive (mirrors
 * `AppearanceStore`'s `getSharedPreferences` pattern).
 */
object ChangesAnnotationStore {
    private const val PREFS = "conduit.changes_annotations"

    fun load(context: Context, sessionId: String): List<ChangeAnnotation> {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val raw = prefs.getString(sessionId, null) ?: return emptyList()
        return runCatching { ChangesJson.decodeAnnotations(JSONArray(raw)) }.getOrElse { emptyList() }
    }

    fun save(context: Context, sessionId: String, annotations: List<ChangeAnnotation>) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.edit().putString(sessionId, ChangesJson.encodeAnnotations(annotations).toString()).apply()
    }
}
