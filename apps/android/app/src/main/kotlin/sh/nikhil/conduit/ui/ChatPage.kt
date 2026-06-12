package sh.nikhil.conduit.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.outlined.AccountCircle
import androidx.compose.material.icons.outlined.ArrowDownward
import androidx.compose.material.icons.outlined.Build
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Create
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Fullscreen
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.SmartToy
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.material3.AssistChip
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledIconButton

import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme

import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import sh.nikhil.conduit.FeatureFlags
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.PendingChatKind
import sh.nikhil.conduit.PinnedContext
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry
import sh.nikhil.conduit.descriptorFor
import sh.nikhil.conduit.sortedByConversationTs
import sh.nikhil.conduit.stripPendingSentinel
import kotlinx.coroutines.launch
import uniffi.conduit_core.ChatEvent
import uniffi.conduit_core.ConversationItem
import uniffi.conduit_core.ProjectSession
import uniffi.conduit_core.ViewEventFile

/**
 * The deterministic pending-input sentinel the broker prepends to a
 * genuine AskUserQuestion. Byte-identical to the broker / core / iOS
 * constants. Core strips it on the typed path; the apps strip it
 * defensively for the raw-chatLog fallback.
 */
private const val PENDING_INPUT_SENTINEL = "[[conduit:needs-input]]"

/**
 * Lets the neon command card reach the live [SessionStore] + current
 * session id to wire its "Re-run" action (terminal write) without
 * threading them through every card signature. Provided by [ChatPage]
 * where both are in scope; null in detached previews / read-only opens.
 */

internal val LocalSessionStore = compositionLocalOf<SessionStore?> { null }
internal val LocalSessionId = compositionLocalOf<String?> { null }

/**
 * Host for the chat-local Material snackbar (failed-send RETRY action). Provided
 * by [ChatPage] over its root content; null in read-only panes (no live send).
 */
internal val LocalChatSnackbar = compositionLocalOf<SnackbarHostState?> { null }

/**
 * Lets the command card jump the session to its Terminal tab ("Open in
 * terminal", and the post-Re-run focus). Provided by [ProjectScreen] for
 * the live phone pager (where a Terminal tab exists); null in read-only /
 * tablet chat-only panes, which disables the action.
 */
internal val LocalOpenInTerminal = compositionLocalOf<(() -> Unit)?> { null }

private sealed class ConversationRole {
    data object User : ConversationRole()
    data object Assistant : ConversationRole()
    data object Tool : ConversationRole()
    data object System : ConversationRole()

    companion object {
        fun from(raw: String): ConversationRole = when (raw.lowercase()) {
            "user" -> User
            "assistant" -> Assistant
            "tool" -> Tool
            else -> System
        }
    }
}

private sealed class ConversationBlock {
    data class Markdown(val text: String) : ConversationBlock()
    data class Code(val language: String?, val content: String) : ConversationBlock()
}

private sealed class ToolSection {
    data class Meta(val exitCode: Int?, val duration: String?) : ToolSection()
    data class Command(val command: String) : ToolSection()
    data class Files(val files: List<ViewEventFile>) : ToolSection()
    data class Stdout(val text: String) : ToolSection()
    data class Stderr(val text: String) : ToolSection()
    data class Text(val text: String) : ToolSection()
    data class Code(val language: String?, val content: String) : ToolSection()
    data class Diff(val content: String) : ToolSection()
}

private object ConversationRenderer {
    fun blocks(content: String): List<ConversationBlock> {
        val lines = content.split('\n')
        val blocks = mutableListOf<ConversationBlock>()
        val markdownLines = mutableListOf<String>()
        val codeLines = mutableListOf<String>()
        var codeLanguage: String? = null
        var inCode = false

        fun flushMarkdown() {
            val text = markdownLines.joinToString("\n").trim()
            if (text.isNotEmpty()) blocks += ConversationBlock.Markdown(text)
            markdownLines.clear()
        }

        fun flushCode() {
            val text = codeLines.joinToString("\n")
            if (text.isNotEmpty()) blocks += ConversationBlock.Code(codeLanguage, text)
            codeLines.clear()
            codeLanguage = null
        }

        lines.forEach { line ->
            if (line.startsWith("```")) {
                val fence = line.removePrefix("```").trim()
                if (inCode) {
                    flushCode()
                    inCode = false
                } else {
                    flushMarkdown()
                    codeLanguage = fence.ifEmpty { null }
                    inCode = true
                }
            } else if (inCode) {
                codeLines += line
            } else {
                markdownLines += line
            }
        }

        if (inCode) flushCode() else flushMarkdown()
        if (blocks.isEmpty()) return listOf(ConversationBlock.Markdown(content))
        return blocks
    }

    fun toolSections(event: ConversationItem): List<ToolSection> {
        val sections = mutableListOf<ToolSection>()
        // Prefer the Rust classifier output (event.exitCode / event.durationMs /
        // event.command); fall back to in-Swift/Kotlin parsing for older
        // payloads. Keeps the Kotlin renderer thin per PLAN-2026-05-19.md.
        val typedExit = event.exitCode?.toInt()
        val typedDuration = event.durationMs?.let { formatDuration(it) }
        val (parsedExit, parsedDuration) = if (typedExit == null && typedDuration == null) {
            extractToolMetadata(event.content)
        } else {
            null to null
        }
        val finalExit = typedExit ?: parsedExit
        val finalDuration = typedDuration ?: parsedDuration
        if (finalExit != null || finalDuration != null) {
            sections += ToolSection.Meta(finalExit, finalDuration)
        }
        val command = event.command?.takeIf { it.isNotBlank() } ?: extractCommand(event.content)
        command?.let { sections += ToolSection.Command(it) }
        if (event.files.isNotEmpty()) sections += ToolSection.Files(event.files)
        val trimmed = event.content.trim()
        if (trimmed.isEmpty()) return sections
        var currentStream: String? = null
        blocks(trimmed).forEach { block ->
            when (block) {
                is ConversationBlock.Markdown -> {
                    val lower = block.text.lowercase()
                    if (lower == "stdout:" || lower == "stdout") {
                        currentStream = "stdout"
                        return@forEach
                    }
                    if (lower == "stderr:" || lower == "stderr") {
                        currentStream = "stderr"
                        return@forEach
                    }
                    if (currentStream == "stdout") {
                        sections += ToolSection.Stdout(block.text)
                        currentStream = null
                        return@forEach
                    }
                    if (currentStream == "stderr") {
                        sections += ToolSection.Stderr(block.text)
                        currentStream = null
                        return@forEach
                    }
                    // Drop single-line echo lines that duplicate the COMMAND
                    // block (e.g. "Bash: ls -la" when the card already shows
                    // COMMAND: ls -la). Only the echo is suppressed.
                    if (command != null && isCommandEcho(block.text, command)) return@forEach
                    if (looksLikeDiff(block.text)) sections += ToolSection.Diff(block.text)
                    else sections += ToolSection.Text(block.text)
                }
                is ConversationBlock.Code -> {
                    if (block.language == "diff" || looksLikeDiff(block.content)) {
                        sections += ToolSection.Diff(block.content)
                    } else {
                        sections += ToolSection.Code(block.language, block.content)
                    }
                }
            }
        }
        return sections
    }

    /**
     * Returns true when [text] is a single-line command-echo that
     * duplicates the COMMAND card (e.g. "Bash: ls -la" when the card
     * already shows COMMAND: ls -la). Case-insensitive; only suppresses
     * single-line blocks so multi-line output is never dropped.
     */
    fun isCommandEcho(text: String, command: String): Boolean {
        val lines = text.trim().lines().filter { it.isNotBlank() }
        if (lines.size != 1) return false
        val line = lines[0].trim()
        val normalCmd = command.trim().lowercase()
        val colonIdx = line.indexOf(": ")
        if (colonIdx >= 0) {
            val suffix = line.substring(colonIdx + 2).trim().lowercase()
            if (suffix == normalCmd) return true
        }
        return false
    }

    private fun formatDuration(ms: ULong): String {
        val msLong = ms.toLong()
        if (msLong < 1_000) return "${msLong}ms"
        val seconds = msLong / 1_000.0
        if (seconds < 60) return String.format("%.1fs", seconds)
        val mins = seconds / 60.0
        return String.format("%.1fmin", mins)
    }

    private fun extractToolMetadata(text: String): Pair<Int?, String?> {
        var exitCode: Int? = null
        var duration: String? = null
        text.lineSequence().forEach { raw ->
            val line = raw.trim()
            val lower = line.lowercase()
            when {
                lower.startsWith("exit code:") -> exitCode = line.substringAfter("exit code:").trim().toIntOrNull()
                lower.startsWith("exit=") -> exitCode = line.substringAfter("exit=").trim().toIntOrNull()
                lower.startsWith("duration:") -> duration = line.substringAfter("duration:").trim()
                lower.startsWith("took ") -> duration = line.substringAfter("took ").trim()
            }
        }
        return exitCode to duration
    }

    private fun looksLikeDiff(text: String): Boolean =
        text.lineSequence().any { it.startsWith("+") || it.startsWith("-") || it.startsWith("@@") }

    private fun extractCommand(text: String): String? {
        text.lineSequence().forEach { raw ->
            val line = raw.trim()
            when {
                line.startsWith("$ ") -> return line.removePrefix("$ ").trim()
                line.lowercase().startsWith("running ") -> return line.substringAfter("running ").trim()
                line.lowercase().startsWith("cmd:") -> return line.substringAfter("cmd:").trim()
            }
        }
        return null
    }

    fun extractPendingOptions(text: String): List<String> {
        val options = linkedSetOf<String>()
        text.lineSequence().forEach { raw ->
            val line = raw.trim()
            when {
                line.startsWith("- ") || line.startsWith("* ") -> {
                    val value = line.drop(2).trim()
                    if (value.isNotEmpty()) options += value
                }
                line.lowercase().startsWith("option:") -> {
                    val value = line.substringAfter("option:").trim()
                    if (value.isNotEmpty()) options += value
                }
            }
        }
        return options.take(4)
    }
}

@Composable
fun ChatPage(
    store: SessionStore,
    session: ProjectSession,
    readOnly: Boolean = false,
    /**
     * When non-null, skip [SessionStore.conversationLog] / [SessionStore.chatLog]
     * and render exactly these items. Used by [SavedTranscriptScreen] to
     * replay a fetched archived transcript without polluting the live
     * log maps. Mirror of iOS `ConduitUI.ChatView(session, readOnlyItems:)`.
     */
    readOnlyItems: List<ConversationItem>? = null,
    /**
     * Jump this session to its Terminal tab. Wired by [ProjectScreen] for
     * the live phone pager so the command card's "Open in terminal" (and
     * the post-Re-run focus) can switch tabs; null elsewhere (read-only /
     * tablet chat-only) where there is no sibling Terminal tab.
     */
    onOpenTerminal: (() -> Unit)? = null,
) {
    val agentAccent = neonAgentColor(session.assistant, LocalNeonTheme.current)
    val typedLog by store.conversationLog.collectAsState()
    val fallbackLog by store.chatLog.collectAsState()
    val aiQuickReplies by store.quickReplies.collectAsState()
    // Live per-session status (carries the broker's authoritative
    // `turn_active` for the typing indicator's reconnect fix).
    val statusBySession by store.statusBySession.collectAsState()
    // "Queued Next" panel: observe the pending queue + agent descriptors.
    val pendingChatsQueue by store.pendingChats.collectAsState()
    val agentDescriptorsMap by store.agentDescriptors.collectAsState()
    // PR #111 + iOS ChatViewModel parity: render a SINGLE chronologically
    // sorted list, merging the typed `conversationLog` with the broker's
    // raw `chatLog`. Picking one source or the other (the prior
    // `typedLog ?: fallbackLog`) dropped codex assistant replies — which
    // arrive via `on_chat_event` into `chatLog` only — and, because
    // server items were concatenated ahead of locally-echoed user turns,
    // sank every user message to the bottom. `mergedConversation` dedupes
    // by role+content and sorts by `ts`, interleaving user and assistant
    // turns correctly. Mirror of iOS `ConduitUI.ChatViewModel.mergedEvents`.
    val events = remember(typedLog, fallbackLog, session.id, readOnlyItems) {
        // Read-only history opens hand us a pre-fetched transcript;
        // bypass the live log maps so the saved render doesn't see
        // stale entries from a recently-attached live session of the
        // same id, and so the live maps don't accumulate archived rows.
        if (readOnlyItems != null) {
            readOnlyItems
        } else {
            mergedConversation(
                conversation = typedLog[session.id] ?: emptyList(),
                chatLog = fallbackLog[session.id] ?: emptyList(),
            )
        }
    }
    var draft by remember { mutableStateOf("") }
    // Durable lock for answered pending-input cards: survives the card being
    // recreated as new events stream in, so a settled card can't re-fire.
    // Mirror of iOS `ConduitChatView.answeredPendingIDs`.
    var answeredPendingIds by remember { mutableStateOf(setOf<String>()) }
    // Content fingerprints of answered pending-input cards: prompt + sorted
    // options joined with "|". Supplements `answeredPendingIds` so a broker
    // re-emitting the SAME pending card with a fresh id (after an app
    // reconnect) still renders locked / "Sent" rather than showing a duplicate
    // interactive card. Mirror of iOS `answeredPendingFingerprints`.
    var answeredPendingFingerprints by remember { mutableStateOf(setOf<String>()) }
    val listState = rememberLazyListState()
    val pinnedContextsMap by store.pinnedContexts.collectAsState()
    val pinnedContexts = pinnedContextsMap[session.id] ?: emptyList()
    var pendingAttachments by remember { mutableStateOf(listOf<ComposerAttachment>()) }
    var showAttachSheet by remember { mutableStateOf(false) }
    var showExpandedComposer by remember { mutableStateOf(false) }

    // Task #38: hoist the parsed-markdown LRU above the LazyColumn so
    // recycled rows render from cache instead of re-parsing. One cache
    // per chat surface, kept across recompositions (and session swaps,
    // since the content-hash key is session-agnostic and identical text
    // legitimately shares an entry).

    val markdownCache = remember { ParsedMarkdownCache() }

    // Fix 8: chat-local snackbar host for the failed-send RETRY action.
    val chatSnackbar = remember { SnackbarHostState() }

    // Task #39: streaming auto-scroll that doesn't fight the user.
    var autoScroll by remember { mutableStateOf(ChatAutoScrollModel()) }
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    // 80dp near-bottom band, in px for the LazyListState geometry.
    val thresholdPx = with(density) { 80.dp.toPx() }
    LaunchedEffect(thresholdPx) {
        autoScroll = autoScroll.copy(nearBottomThresholdPx = thresholdPx)
    }

    // Track distance-from-bottom off the LazyListState so the model can
    // tell "pinned to bottom" from "scrolled up". When the last item is
    // visible we approximate the remaining distance from the viewport
    // end offset minus the last item's bottom; otherwise we're far from
    // the bottom and report a large distance.
    LaunchedEffect(listState) {
        snapshotFlow {
            val info = listState.layoutInfo
            val lastVisible = info.visibleItemsInfo.lastOrNull()
            val totalCount = info.totalItemsCount
            when {
                totalCount == 0 -> 0f
                lastVisible == null -> Float.MAX_VALUE
                lastVisible.index < totalCount - 1 -> Float.MAX_VALUE
                else -> {
                    // Last item is visible: distance = how far its bottom
                    // sits past the viewport end (0 when fully pinned).
                    val itemBottom = lastVisible.offset + lastVisible.size
                    (itemBottom - info.viewportEndOffset).toFloat().coerceAtLeast(0f)
                }
            }
        }
            .collect { distance -> autoScroll = autoScroll.onBottomProximityChanged(distance) }
    }

    // Follow the stream + new messages. The last event's content length
    // changes on every streamed token (broker appends to the same item);
    // `events.size` changes on a new turn. Either, while not scrolled up,
    // re-pins the bottom.
    val streamingSignature = events.size to (events.lastOrNull()?.content?.length ?: 0)

    // Bug 3: "agent is typing…" indicator. Drive a content-growth state
    // machine off the same streaming signature the follow uses. A timer
    // re-evaluates the quiet window so the indicator disappears promptly
    // once the stream stops (read-only transcripts never stream, so it
    // stays hidden there).
    var typing by remember { mutableStateOf(TypingIndicatorModel()) }
    var typingTick by remember { mutableStateOf(0L) }
    LaunchedEffect(streamingSignature) {
        val last = events.lastOrNull()
        typing = typing.onTrailingTurn(
            role = last?.role,
            contentLength = last?.content?.length ?: 0,
            nowMs = System.currentTimeMillis(),
        )
        typingTick = System.currentTimeMillis()
        // After the quiet window with no further growth, re-evaluate so
        // the indicator hides without needing a new event. Keyed on the
        // signature, so a fresh token cancels + reschedules this.
        kotlinx.coroutines.delay(TypingIndicatorModel.DEFAULT_QUIET_WINDOW_MS + 50)
        typingTick = System.currentTimeMillis()
    }
    // Device feedback v0.0.50 #5 (parity): show the indicator during the
    // pre-token "thinking" phase too, not just active streaming — the
    // user's own message being last (no assistant turn started yet) or a
    // working/thinking/pending assistant status both count as busy.
    val agentWorking = run {
        val l = events.lastOrNull()
        TypingIndicatorModel.agentWorking(
            lastRole = l?.role,
            lastStatus = l?.status,
            lastContentEmpty = l?.content.orEmpty().isBlank(),
            // Authoritative broker turn-state: clears a stuck indicator on
            // reconnect / keeps it on when a turn is really running. null for
            // TUI-scrape sessions or a pre-field broker → falls back to
            // log-role inference.
            serverTurnActive = statusBySession[session.id]?.turnActive,
        )
    }
    val showTyping = !readOnly && (typing.isStreaming(typingTick) || agentWorking)

    // Reply haptics (ChatGPT-style start/finish taps; iOS `ReplyHaptics`
    // parity). The pure model decides which tap to fire on each `showTyping`
    // busy-state flip; `View.performHapticFeedback` plays it and honours the
    // system haptic-feedback-enabled setting. Suppressed when read-only or the
    // flag is off — the model still tracks the flip so the NEXT real
    // transition is computed correctly. Re-seeded per session so a stale busy
    // state doesn't fire a spurious tap on session switch.
    val replyHapticsView = androidx.compose.ui.platform.LocalView.current

    val appearanceStore = sh.nikhil.conduit.LocalAppearanceStore.current
    val replyHapticsEnabled by appearanceStore.replyHaptics.collectAsState()
    // Fix 10: arm-B (Signature) coalesces consecutive tool turns into clusters.
    val chatStylePref by appearanceStore.chatStylePreference.collectAsState()
    val chatExperimentKilled by appearanceStore.chatExperimentKilled.collectAsState()
    val chatAssignedArm by appearanceStore.chatAssignedArm.collectAsState()
    val signatureArm = FeatureFlags.resolvedChatArm(
        chatStylePref, chatExperimentKilled, chatAssignedArm,
    ) == FeatureFlags.ChatArm.B
    var replyHaptics by remember(session.id) { mutableStateOf(ReplyHapticsModel()) }
    LaunchedEffect(showTyping, replyHapticsEnabled, session.id) {
        val (next, event) = replyHaptics.observe(
            busy = showTyping,
            enabled = replyHapticsEnabled && !readOnly,
            nowMs = System.currentTimeMillis(),
        )
        replyHaptics = next
        if (event != null) {
            val constant = when (event) {
                // CONTEXT_CLICK (API 23) — a light, immediate tick: "a turn
                // began". Available on our whole min-26 range.
                ReplyHapticEvent.TurnStart ->
                    android.view.HapticFeedbackConstants.CONTEXT_CLICK
                // CONFIRM (API 30) — a completion tick: "the turn finished".
                // Falls back to CONTEXT_CLICK on API 26–29 (a tap is better
                // than silence; CONFIRM no-ops there anyway).
                ReplyHapticEvent.TurnFinish ->
                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R)
                        android.view.HapticFeedbackConstants.CONFIRM
                    else
                        android.view.HapticFeedbackConstants.CONTEXT_CLICK
            }
            replyHapticsView.performHapticFeedback(constant)
            sh.nikhil.conduit.Telemetry.breadcrumb(
                "haptics", "reply tap",
                mapOf("event" to if (event == ReplyHapticEvent.TurnStart) "start" else "finish"),
            )
        }
    }

    // Follow the stream + new messages + the typing row appearing. While
    // not scrolled up, re-pin the absolute bottom. Keyed on `showTyping`
    // too so the indicator stays visible above the composer when pinned.
    LaunchedEffect(streamingSignature, showTyping, autoScroll.shouldFollow) {
        if (autoScroll.shouldFollow && events.isNotEmpty()) {
            scrollToTrueBottom(listState)
        }
    }

    // ~300ms settle after the stream goes quiet: the final layout pass
    // can change the last row's height once code/diff blocks finish, so
    // re-pin once content stops growing (unless the user scrolled away).
    val lastContentLength = events.lastOrNull()?.content?.length ?: 0
    LaunchedEffect(lastContentLength) {
        kotlinx.coroutines.delay(300)
        if (autoScroll.shouldFollow && events.isNotEmpty()) {
            scrollToTrueBottom(listState)
        }
    }

    // Android IME handling (task #39): on sdk35 `WindowInsets.isImeVisible`
    // is unreliable, so detect the keyboard via the LazyColumn's
    // `viewportEndOffset` shrinking. When the viewport shrinks (keyboard
    // came up) while we're following, keep the latest message above the
    // input by re-pinning the bottom.
    LaunchedEffect(listState) {
        snapshotFlow { listState.layoutInfo.viewportEndOffset }
            .collect {
                if (autoScroll.shouldFollow && events.isNotEmpty()) {
                    listState.scrollToItem((listState.layoutInfo.totalItemsCount - 1).coerceAtLeast(0))
                }
            }
    }

    // Hoisted out of the Column scope so the showExpandedComposer
    // dialog (which lives at the ChatPage function scope, outside
    // Column) can also reach it. Single dispatch path, two call sites.
    val dispatchSend: () -> Unit = {
        val attachmentsToSend = pendingAttachments
        val msg = composeOutgoingMessage(
            draft = draft,
            pinnedContexts = pinnedContexts,
            pendingAttachments = attachmentsToSend,
            sessionId = session.id,
        )
        if (msg.isNotEmpty()) {
            // Clear the composer immediately (optimistic) so the UI feels
            // responsive; the upload + chat dispatch run in the
            // background and reference the paths the broker writes.
            draft = ""
            pendingAttachments = emptyList()
            scope.launch {
                // Upload each picked file over the 0x01 binary frame
                // (core send_file → broker writes uploads/<sid>/<name>)
                // BEFORE the chat message lands, so the referenced paths
                // exist by the time the agent reads them.
                attachmentsToSend.forEach { att ->
                    store.sendFile(
                        sessionId = session.id,
                        filename = att.filename,
                        mime = att.mimeType,
                        payload = att.bytes,
                    )
                }
                store.sendChat(session.id, msg)
            }
            // Sending is explicit intent to see the reply — re-arm follow
            // even if the user had scrolled up.
            autoScroll = autoScroll.onScrollToBottomRequested()
        }
    }

    // Dismiss the soft keyboard when the user scrolls the thread. iOS uses
    // `.scrollDismissesKeyboard(.interactively)`; on Android we hook the
    // list's nested-scroll so any user-driven scroll lowers the IME (device
    // feedback: "can't dismiss keyboard so can't scroll well"). Programmatic
    // autoscroll (animateScrollToItem) does NOT dispatch through nestedScroll,
    // so streaming follow won't fight the keyboard.
    val focusManager = androidx.compose.ui.platform.LocalFocusManager.current
    val keyboardController = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    val dismissKeyboardOnScroll = remember(focusManager, keyboardController) {
        object : androidx.compose.ui.input.nestedscroll.NestedScrollConnection {
            override fun onPreScroll(
                available: Offset,
                source: androidx.compose.ui.input.nestedscroll.NestedScrollSource,
            ): Offset {
                if (available.y != 0f) {
                    keyboardController?.hide()
                    focusManager.clearFocus()
                }
                return Offset.Zero
            }
        }
    }

    CompositionLocalProvider(
        LocalParsedMarkdownCache provides markdownCache,
        // Read-only transcripts have no live WS to write into, so don't
        // expose the store there — the command card's Re-run stays disabled.

        LocalSessionStore provides (if (readOnly) null else store),
        LocalSessionId provides session.id,
        LocalChatSnackbar provides (if (readOnly) null else chatSnackbar),
        // Only the live tabbed pager wires a Terminal jump; read-only / tablet
        // panes pass null, which disables "Open in terminal".
        LocalOpenInTerminal provides (if (readOnly) null else onOpenTerminal),
    ) {
    BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
        // Mirror iOS chatContentMaxWidth (760pt cap on regular/tablet size
        // class). On phone (< 840dp) use full width; on tablet constrain and
        // center so the thread doesn't span the full wide display.
        val isTablet = maxWidth >= 840.dp
        val chatContentMaxWidth = if (isTablet) 760.dp else maxWidth
    Column(modifier = Modifier.fillMaxSize()) {
        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
            LazyColumn(
                state = listState,
                modifier = (if (isTablet)
                    Modifier.fillMaxHeight().widthIn(max = chatContentMaxWidth).align(Alignment.TopCenter)
                    else Modifier.fillMaxSize())
                    .nestedScroll(dismissKeyboardOnScroll)
                    .padding(horizontal = 12.dp, vertical = 10.dp)
                    // Finger-down is the user taking manual control — latch
                    // `userScrolledUp` so the stream stops yanking them back.
                    // The proximity observer clears it once they return near
                    // the bottom. `Initial` pass so we see the drag even
                    // though the LazyColumn consumes it for scrolling.
                    .pointerInput(Unit) {
                        awaitPointerEventScope {
                            while (true) {
                                val event = awaitPointerEvent(
                                    androidx.compose.ui.input.pointer.PointerEventPass.Initial,
                                )
                                if (event.changes.any { it.pressed }) {
                                    autoScroll = autoScroll.onUserDragged()
                                }
                            }
                        }
                    },
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {

                if (events.isEmpty()) {
                    item { EmptyConversationCard(assistant = session.assistant) }
                } else {
                    // Fix 10: in arm B, fold runs of 2+ consecutive tool turns
                    // into one cluster unit; arm A and lone tools stay inline.
                    val renderUnits = groupChatUnits(events.map { it.role }, signatureArm)
                    items(renderUnits.size) { unitIndex ->
                        when (val unit = renderUnits[unitIndex]) {
                            is ChatRenderUnit.ToolCluster ->
                                ToolClusterCard(unit.indices.map { events[it] })
                            is ChatRenderUnit.Single -> {
                                val index = unit.index
                                val previousRole = if (index > 0) events[index - 1].role else null
                                val ev = events[index]
                                ConversationEventRow(
                                    ev = ev,
                                    agentAccent = agentAccent,
                                    isContinuation = previousRole?.lowercase() == ev.role.lowercase(),
                                    pendingAnswered = ev.id in answeredPendingIds
                                        || pendingContentFingerprint(ev) in answeredPendingFingerprints,
                                    // A pending-input answer is delivered as the user's
                                    // next chat message — the broker matches it to the
                                    // blocked AskUserQuestion control request. Mirror of
                                    // iOS (`store.sendChat`), not the draft-fill path the
                                    // composer's quick-reply chips use.
                                    onAnswerPending = { msg -> store.sendChat(session.id, msg) },
                                    onPendingAnswered = {
                                        answeredPendingIds = answeredPendingIds + ev.id
                                        answeredPendingFingerprints = answeredPendingFingerprints + pendingContentFingerprint(ev)
                                    },
                                )
                            }
                        }
                    }
                }
                // "Agent is typing…" — last content row (before the
                // trailing spacer) so when pinned to the bottom it's
                // followed by autoscroll like any new content.
                if (showTyping) {
                    item { TypingIndicatorRow(session.assistant, agentAccent) }
                }
                item { Spacer(Modifier.height(1.dp)) }
            }

            // Scroll-to-bottom button: a fixed overlay pinned to the
            // bottom-end of the list region (Box-anchored, NOT a
            // LazyColumn item) so it does not move as messages
            // appear/stream. It fades out via an animated alpha when the
            // user is practically at the bottom and fades in only once
            // they've scrolled up a meaningful amount
            // (`scrollToBottomButtonAlpha`). Tapping scrolls to the
            // ABSOLUTE bottom and re-pins follow.
            val targetAlpha = if (events.isEmpty()) 0f else autoScroll.scrollToBottomButtonAlpha
            val buttonAlpha by androidx.compose.animation.core.animateFloatAsState(
                targetValue = targetAlpha,
                label = "scrollToBottomAlpha",
            )
            if (buttonAlpha > 0.01f) {
                // Neon glass disc — parity with iOS's glass scroll-to-bottom
                // and the header circle buttons. Was an off-theme Material3
                // `secondaryContainer` FilledIconButton that didn't match the
                // neon chrome.
                val neon = LocalNeonTheme.current
                Box(
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .padding(12.dp)
                        .graphicsLayer {
                            alpha = buttonAlpha
                            scaleX = 0.85f + 0.15f * buttonAlpha
                            scaleY = 0.85f + 0.15f * buttonAlpha
                        }
                        .size(40.dp)
                        .glassCircle()
                        .clickable {
                            autoScroll = autoScroll.onScrollToBottomRequested()
                            scope.launch { scrollToTrueBottom(listState) }
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Outlined.ArrowDownward,
                        contentDescription = "Scroll to latest",
                        modifier = Modifier.size(18.dp),
                        tint = neon.accent,
                    )
                }
            }
        }

        // Read-only (exited/archived) sessions are a frozen transcript --
        // no live WS to send into -- so the composer + quick-reply bar are
        // suppressed entirely (mirrors iOS `ConduitChatView` read-only mode).
        if (!readOnly) {
            // "Queued Next" panel: compute queued entries + steer capability
            // once so both the panel and the send-button glyph share the same
            // derived state.
            val queuedEntries = remember(pendingChatsQueue, session.id) {
                pendingChatsQueue.queuedTurnEntries(session.id)
            }
            val supportsSteer = remember(agentDescriptorsMap, session.assistant) {
                descriptorFor(session.assistant, agentDescriptorsMap).supportsSteer
            }
            // Agent-tinted hairline above the composer -- a quiet "you're
            // talking to X" cue. Pairs with the composer's tinted shadow
            // (see ConversationComposer's outer modifier) so the cluster
            // reads as agent-coloured without painting the surface.
            HorizontalDivider(
                thickness = 1.5.dp,
                color = agentAccent.copy(alpha = 0.55f),
            )
            // "Queued Next" panel -- visible when there are queued-turn entries.
            // On tablet cap width to chatContentMaxWidth (760dp) and center,
            // matching the LazyColumn treatment above.
            if (queuedEntries.isNotEmpty()) {
                Box(
                    modifier = Modifier.fillMaxWidth(),
                    contentAlignment = Alignment.TopCenter,
                ) {
                    QueuedNextPanel(
                        entries = queuedEntries,
                        supportsSteer = supportsSteer,
                        onSteer = { localId -> store.retrySteer(session.id, localId) },
                        onCancel = { localId -> store.cancelQueued(session.id, localId) },
                        modifier = if (isTablet) Modifier.widthIn(max = chatContentMaxWidth) else Modifier,
                    )
                }
            }
            ConversationComposer(
                draft = draft,
                // AI-generated chips from the broker (task #233) are
                // PRIMARY; the client-side heuristic only fills in when
                // the broker sends none (feature off, codex, generation
                // failed, or before the post-turn set arrives).
                quickReplies = remember(events, aiQuickReplies) {
                    val ai = aiQuickReplies[session.id]?.replies ?: emptyList()
                    if (ai.isNotEmpty()) ai else QuickReplyDetector.suggestions(events)
                },
                agentAccent = agentAccent,
                currentAssistant = session.assistant,
                pinnedContexts = pinnedContexts,
                pendingAttachments = pendingAttachments,
                onRemovePinned = { id -> store.unpinContext(id, session.id) },
                onRemoveAttachment = { id ->
                    pendingAttachments = pendingAttachments.filterNot { it.id == id }
                },
                onAttachClick = { showAttachSheet = true },
                onExpandClick = { showExpandedComposer = true },
                onSwitchAgent = { next -> store.switchAgent(session.id, next) },
                onDraftChange = { draft = it },
                onQuickReply = { reply ->
                    draft = if (draft.trim().isEmpty()) reply else "$draft\n$reply"
                },
                onSend = dispatchSend,
                agentWorking = agentWorking,
                // Codex with an active turn: send button shows steer glyph.
                sendIsSteer = agentWorking && supportsSteer,

                onStop = { store.stopTurn(session.id) },
            )
        }
    }
        // Fix 8: failed-send RETRY snackbar, anchored to the chat bottom.
        if (!readOnly) {
            SnackbarHost(
                hostState = chatSnackbar,
                modifier = Modifier.align(Alignment.BottomCenter),
            )
        }
    } // BoxWithConstraints
    }

    if (showAttachSheet) {
        val attachContext = androidx.compose.ui.platform.LocalContext.current
        ComposerAttachSheet(
            onAttach = { attachment ->
                pendingAttachments = pendingAttachments + attachment
            },
            onDismiss = { showAttachSheet = false },
            onError = { message ->
                android.widget.Toast
                    .makeText(attachContext, message, android.widget.Toast.LENGTH_SHORT)
                    .show()
            },
        )
    }

    if (showExpandedComposer) {
        ExpandedComposerView(
            draft = draft,
            placeholder = "Message ${session.assistant}…",
            accentTint = agentAccent,
            onDraftChange = { draft = it },
            onSend = dispatchSend,
            onDismiss = { showExpandedComposer = false },
        )
    }
}

/**
 * Scroll the chat list to its ABSOLUTE bottom, reliably. A single
 * `animateScrollToItem(lastIndex)` can land short while the stream is
 * still appending or the final layout pass hasn't settled (the last
 * row's measured height changes after code/diff blocks finish), so we
 * animate to the true last index and then, on the next frame, snap
 * again if we're still not pinned. The trailing 1dp `Spacer` is the
 * genuine last item, so `totalItemsCount - 1` is the real end.
 */
private suspend fun scrollToTrueBottom(listState: androidx.compose.foundation.lazy.LazyListState) {
    repeat(3) {
        val target = (listState.layoutInfo.totalItemsCount - 1).coerceAtLeast(0)
        listState.animateScrollToItem(target)
        val last = listState.layoutInfo.visibleItemsInfo.lastOrNull()
        val atBottom = last != null &&
            last.index >= listState.layoutInfo.totalItemsCount - 1 &&
            last.offset + last.size <= listState.layoutInfo.viewportEndOffset + 4
        if (atBottom) return
    }

    // Final hard snap in case animation kept losing the race to layout.
    listState.scrollToItem((listState.layoutInfo.totalItemsCount - 1).coerceAtLeast(0))
}

/**
 * Fix 10 — a unit of the chat list after arm-B tool grouping. A [Single]
 * renders one event inline exactly as today; a [ToolCluster] coalesces 2+
 * CONSECUTIVE tool-role events into one collapsible cluster. Carries event
 * indices so the existing index-keyed continuation logic is preserved.
 */
private sealed class ChatRenderUnit {
    data class Single(val index: Int) : ChatRenderUnit()
    data class ToolCluster(val indices: List<Int>) : ChatRenderUnit()
}

/**
 * Coalesce consecutive tool-role events into clusters for arm B (Signature)
 * ONLY. Arm A and a lone tool call pass through as [ChatRenderUnit.Single],
 * so the existing inline rendering is untouched. Pure + index-based so it is
 * unit-testable and keeps the continuation/key logic intact.
 */
private fun groupChatUnits(roles: List<String>, signature: Boolean): List<ChatRenderUnit> {
    if (!signature) return roles.indices.map { ChatRenderUnit.Single(it) }
    val units = mutableListOf<ChatRenderUnit>()
    var i = 0
    while (i < roles.size) {
        if (roles[i].lowercase() == "tool") {
            var j = i
            while (j < roles.size && roles[j].lowercase() == "tool") j++
            val run = (i until j).toList()
            // Only 2+ consecutive tool turns collapse; a single one stays inline.
            if (run.size >= 2) units.add(ChatRenderUnit.ToolCluster(run))
            else units.add(ChatRenderUnit.Single(run[0]))
            i = j
        } else {
            units.add(ChatRenderUnit.Single(i))
            i++
        }
    }
    return units
}

/**
 * Resolve the single chronologically-ordered event stream the chat
 * surface renders, merging the typed [conversation] log with the
 * broker's raw [chatLog]. Mirror of iOS
 * `ConduitUI.ChatViewModel.mergedEvents`.
 *
 * The typed `conversationLog` (built from the broker's structured
 * `view_event` stream) is preferred, but for sessions where the broker
 * emits the assistant reply through `on_chat_event` (codex today) the
 * typed `listConversationItems` surface can lag — that reply lives only
 * in [chatLog]. Without folding it in, the codex assistant reply showed
 * up in the Terminal tab but never reached the chat tab.
 *
 * Every raw chat event missing from the typed log (matched by
 * role+content, the only stable identity a [ChatEvent] carries) is
 * synthesized into a [ConversationItem] and spliced in. The combined
 * list is sorted by `ts` so user and assistant turns interleave in true
 * chronological order rather than clumping by source/role.
 *
 * Top-level + internal so it's unit-testable without a composition.
 */
internal fun mergedConversation(
    conversation: List<ConversationItem>,
    chatLog: List<ChatEvent>,
): List<ConversationItem> {
    // Fast path: nothing raw to fold in.
    if (chatLog.isEmpty()) return conversation

    val typedFingerprints = conversation
        .map { "${it.role.lowercase()}|${it.content}" }
        .toSet()
    val synthetic = chatLog.mapIndexedNotNull { idx, ev ->
        // Strip the pending-input sentinel before fingerprinting so this
        // raw chatLog item dedupes against the already-stripped typed card
        // (same role+content key), and before setting content so the
        // sentinel never leaks as a bare raw bubble.
        val strippedContent = stripPendingSentinel(ev.content)
        val key = "${ev.role.lowercase()}|$strippedContent"
        if (key in typedFingerprints) {
            null
        } else {
            ConversationItem(
                id = "chatlog-${ev.ts}-$idx",
                role = ev.role,
                kind = if (ev.role.lowercase() == "tool") "tool" else "message",
                status = "done",
                content = strippedContent,
                ts = ev.ts,
                files = ev.files,
                toolName = null,
                command = null,
                exitCode = null,
                durationMs = null,
                diffSummary = null,
                pendingOptions = emptyList(),
                sourceAgent = null,
                targetAgent = null,
                taskText = null,
                resultSummary = null,
                planSteps = emptyList(),
            )
        }
    }
    if (synthetic.isEmpty()) return conversation
    // Interleave the synthesized chat-event items into the typed log in true
    // chronological order. Carry-forward sort (see [sortedByConversationTs]):
    // a chat event whose `ts` we can't parse keeps its arrival position
    // instead of collapsing to 0L and jumping above the user turn that
    // preceded it (device bug: agent reply / command card rendered before
    // the user's own prompt).
    return (conversation + synthetic).sortedByConversationTs { it.ts }
}

/**
 * Folds the draft text + any pinned contexts + any pending
 * attachments into a single outgoing chat message. Mirror of iOS
 * `ChatTab.composeOutgoingMessage` — inlined here rather than on
 * SessionStore because it's purely a presentation concern.
 *
 * Attachments are NOT inlined as base64 anymore: the bytes go over the
 * 0x01 binary upload frame (core `send_file`) and the broker lands them
 * at `uploads/<sessionId>/<filename>`. We append one reference line per
 * file so the agent (running in the session workspace) can read each by
 * its relative path. [sessionId] is required to build that path.
 */
internal fun composeOutgoingMessage(
    draft: String,
    pinnedContexts: List<PinnedContext>,
    pendingAttachments: List<ComposerAttachment>,
    sessionId: String,
): String {
    val pieces = mutableListOf<String>()
    if (pinnedContexts.isNotEmpty()) {
        val formatted = pinnedContexts.joinToString("\n\n") { ctx ->
            "[pinned ${ctx.kind.name.lowercase()}: ${ctx.label}]\n${ctx.payload}"
        }
        pieces += formatted
    }
    val trimmed = draft.trim()
    if (trimmed.isNotEmpty()) pieces += trimmed
    pendingAttachments.forEach {
        pieces += attachmentReferenceLine(it.kind, it.filename, sessionId)
    }
    return pieces.joinToString("\n\n")
}

/**
 * Folds everything that affects parsed-markdown output into a single
 * cache revision: the content, the body point size, and the font
 * choice. Same inputs ⇒ same revision ⇒ a [ParsedMarkdownCache] hit.
 * Top-level + internal so it's unit-testable without a composition.
 */
internal fun markdownRevision(
    text: String,
    bodyPointSize: Float,
    fontChoice: sh.nikhil.conduit.AppearanceStore.FontFamily,
): Int {
    var result = text.hashCode()
    result = 31 * result + bodyPointSize.toRawBits()
    result = 31 * result + fontChoice.ordinal
    return result
}

@Composable
private fun EmptyConversationCard(assistant: String) {
    val neon = LocalNeonTheme.current
    val shape = RoundedCornerShape(neon.radiusDp.dp)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = shape, fill = neon.surface)
            .padding(horizontal = 16.dp, vertical = 18.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("No conversation yet", style = MaterialTheme.typography.titleMedium, fontFamily = neon.sans, color = neon.text)
        Text(
            "Send a message to $assistant. Replies appear here as structured turns; the Terminal tab still shows the raw TUI if you want to peek at the unparsed stream.",
            style = MaterialTheme.typography.bodyMedium,
            fontFamily = neon.sans,
            color = neon.textDim,
        )
    }
}

@Composable
private fun ConversationEventRow(
    ev: ConversationItem,
    agentAccent: Color,
    /** True when the immediately preceding event had the same role. */
    isContinuation: Boolean = false,
    /** Durable lock: this pending-input card was already answered. */
    pendingAnswered: Boolean = false,
    /** Deliver a pending-input answer (sends as the user's chat message). */
    onAnswerPending: (String) -> Unit = {},
    /** Record this pending-input card as answered (durable upstream lock). */
    onPendingAnswered: () -> Unit = {},
) {
    if (ev.status.lowercase() == "swapping") {
        // Transient agent-swap marker — inline divider, not a full row.
        SwapNotice(fromAgent = ev.sourceAgent, toAgent = ev.targetAgent)
        return
    }
    if (ev.kind == "pending_input") {
        PendingInputCard(
            ev = ev,
            agentAccent = agentAccent,
            alreadyAnswered = pendingAnswered,
            onAnswer = onAnswerPending,
            onAnswered = onPendingAnswered,
        )
        return
    }
    if (ev.kind == "handoff") {
        HandoffCard(ev)
        return
    }
    if (ev.kind == "plan") {
        PlanCard(ev)
        return
    }
    if (ev.kind == "subagent") {
        SubagentCard(ev)
        return
    }
    // chat-shell-v2 arm (§2). Arm B "Signature" gives each assistant turn a
    // cyan→green spine lane; arm A "Breathe" keeps today's flat layout.
    val appearance = sh.nikhil.conduit.LocalAppearanceStore.current
    val pref by appearance.chatStylePreference.collectAsState()
    val killed by appearance.chatExperimentKilled.collectAsState()
    val assigned by appearance.chatAssignedArm.collectAsState()
    val arm = FeatureFlags.resolvedChatArm(pref, killed, assigned)
    val signature = arm == FeatureFlags.ChatArm.B
    val spineNeon = LocalNeonTheme.current
    when (ConversationRole.from(ev.role)) {
        ConversationRole.User ->
            ConversationBubble(ev, ConversationRole.User, agentAccent, Modifier, alignEnd = true, isContinuation = isContinuation)
        ConversationRole.Assistant -> {
            val assistantMod = if (signature) {
                val brush = Brush.verticalGradient(listOf(spineNeon.codex, spineNeon.green))
                Modifier
                    .drawBehind {
                        drawLine(
                            brush = brush,
                            start = Offset(1.dp.toPx(), 0f),
                            end = Offset(1.dp.toPx(), size.height),
                            strokeWidth = 2.dp.toPx(),
                            alpha = 0.55f,
                        )
                    }
                    .padding(start = 14.dp)
            } else {
                Modifier
            }
            ConversationBubble(ev, ConversationRole.Assistant, agentAccent, assistantMod, alignEnd = false, isContinuation = isContinuation)
        }
        ConversationRole.Tool -> ConversationToolCard(ev)
        ConversationRole.System -> {
            val neon = LocalNeonTheme.current
            Row(
                modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    Icons.Outlined.Info,
                    contentDescription = null,
                    tint = neon.textFaint,
                    modifier = Modifier.size(12.dp),
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    ev.content,
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = neon.sans,
                    color = neon.textFaint,
                    maxLines = 2,
                )
            }
        }
    }
}

/**
 * Small uppercase neon label (monospaced). Applies a soft text-glow halo
 * via a layered shadow when the theme has [NeonTheme.textGlow] (dark +
 * glow on); a plain tinted label otherwise. Compose has no native text
 * shadow blur stacking, so this is a single-layer approximation of the
 * two-layer CSS text glow — fidelity gap vs. the web reference.
 */
@Composable
private fun NeonLabel(
    text: String,
    color: Color,
    neon: NeonTheme,
    style: androidx.compose.ui.text.TextStyle = MaterialTheme.typography.labelSmall,
) {
    val glow = neon.textGlow
    val shadow = if (glow != null) {
        androidx.compose.ui.graphics.Shadow(
            color = glow.outer.color,
            offset = Offset.Zero,
            blurRadius = glow.outer.radiusDp,
        )
    } else {
        null
    }
    Text(
        text = text,
        style = style.copy(shadow = shadow),
        color = color,
        fontFamily = neon.mono,
        fontWeight = FontWeight.Bold,
    )
}

/** A small filled status dot. When [pulsing], it breathes via an infinite alpha. */
@Composable
private fun NeonStatusDot(color: Color, pulsing: Boolean, size: Dp = 8.dp) {
    val alpha = if (pulsing) {
        val transition = androidx.compose.animation.core.rememberInfiniteTransition(label = "neonDot")
        val a by transition.animateFloat(
            initialValue = 0.35f,
            targetValue = 1f,
            animationSpec = androidx.compose.animation.core.infiniteRepeatable(
                animation = androidx.compose.animation.core.tween(700),
                repeatMode = androidx.compose.animation.core.RepeatMode.Reverse,
            ),
            label = "neonDotAlpha",
        )
        a
    } else {
        1f
    }
    Box(
        modifier = Modifier
            .size(size)
            .graphicsLayer { this.alpha = alpha }
            .background(color, CircleShape),
    )
}

/**
 * Content fingerprint for a pending-input event: prompt + sorted options,
 * joined with "|". Used as a dedupe key that survives broker re-emission of
 * the same pending card under a fresh id. Mirror of iOS `pendingFingerprint`.
 */
private fun pendingContentFingerprint(ev: ConversationItem): String {
    val opts = ev.pendingOptions.sorted().joinToString(",")
    val prompt = ev.content.trim()
    return "$prompt|$opts"
}

@Composable
private fun PendingInputCard(
    ev: ConversationItem,
    @Suppress("UNUSED_PARAMETER") agentAccent: Color,
    alreadyAnswered: Boolean,
    onAnswer: (String) -> Unit,
    onAnswered: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    // Recover per-question groups (prompt + its own options + multi-select
    // marker) from the rendered content. Falls back to the flat option list
    // as one unlabeled question. Mirror of iOS ConduitPendingInputCard.
    val questions = remember(ev.id, ev.content, ev.pendingOptions) {
        val parsed = PendingQuestions.parse(ev.content)
        if (parsed.isNotEmpty()) {
            parsed
        } else {
            val stripped = ev.content.lines()
                .filter { it.trim() != PENDING_INPUT_SENTINEL }.joinToString("\n")
            val flat = ev.pendingOptions.takeIf { it.isNotEmpty() }
                ?: ConversationRenderer.extractPendingOptions(stripped)
            listOf(PendingQuestion(prompt = "", options = flat))
        }
    }
    // The explicit Send appears for multiple questions OR any multi-select
    // question — only a lone single-select question keeps tap-to-send.
    val needsSend = questions.size > 1 || questions.any { it.multiSelect }

    // Chosen option per single-select question; chosen set per multi-select
    // question. Keyed on ev.id so the selection survives recomposition as new
    // events stream in.
    val selections = remember(ev.id) { mutableStateMapOf<Int, String>() }
    val multiSelections = remember(ev.id) { mutableStateMapOf<Int, Set<String>>() }
    var localSubmitted by remember(ev.id) { mutableStateOf(false) }
    var sentAnswer by remember(ev.id) { mutableStateOf<String?>(null) }
    // Settled once submitted locally OR recorded answered upstream — the
    // second source is what makes the lock survive a card re-render.
    val submitted = localSubmitted || alreadyAnswered

    // One question's answer: multi-select joins the chosen labels (in option
    // order) with ", " — the broker passes that comma-joined string through
    // verbatim to the agent; single-select is the chosen label.
    fun answerFor(qIdx: Int, q: PendingQuestion): String? =
        if (q.multiSelect) {
            val set = multiSelections[qIdx]
            if (set.isNullOrEmpty()) null else q.options.filter { it in set }.joinToString(", ")
        } else {
            selections[qIdx]
        }

    // Lock the card and deliver the answer(s); multiple questions newline-
    // joined into one message. Guarded against a double submit.
    fun submit(answers: List<String>) {
        if (localSubmitted || alreadyAnswered) return
        val joined = answers.joinToString("\n")
        // Lock optimistically and immediately — before the send — so the card
        // visibly settles the instant the user taps.
        localSubmitted = true
        sentAnswer = joined
        onAnswered()
        onAnswer(joined)
    }

    val shape = RoundedCornerShape(neon.radiusDp.dp)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            // §4.6: claude-tinted wash, 1.5dp claude border, glowing.
            .neonCardSurface(
                neon = neon,
                shape = shape,
                fill = neon.claude.copy(alpha = if (neon.dark) 0.12f else 0.10f),
                borderWidth = 1.5.dp,
                borderColor = neon.claude,
                glowTint = neon.claude,
            )
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.Info, null, tint = neon.claude, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(8.dp))
            NeonLabel("NEEDS YOUR INPUT", neon.claude, neon)
            Spacer(Modifier.width(6.dp))
            NeonStatusChip(ev.status, neon)
        }
        questions.forEachIndexed { qIdx, question ->
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (question.prompt.isNotEmpty()) {
                    MarkdownBlock(question.prompt, ConversationRole.Assistant)
                }
                if (question.multiSelect) {
                    Text(
                        "select all that apply",
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = neon.mono,
                        color = neon.textFaint,
                    )
                }
                question.options.forEachIndexed { oIdx, option ->
                    val selected = if (question.multiSelect) {
                        multiSelections[qIdx]?.contains(option) == true
                    } else {
                        selections[qIdx] == option
                    }
                    NeonPendingOptionRow(
                        text = option,
                        index = oIdx,
                        selected = selected,
                        dimmed = submitted && !selected,
                        enabled = !submitted,
                        neon = neon,
                        onClick = {
                            if (question.multiSelect) {
                                // Checkbox semantics: toggle membership; Send delivers.
                                val cur = multiSelections[qIdx] ?: emptySet()
                                multiSelections[qIdx] =
                                    if (option in cur) cur - option else cur + option
                            } else {
                                selections[qIdx] = option
                                // A lone single-select question sends on tap
                                // (tap == answer); anything needing Send waits.
                                if (!needsSend) submit(listOf(option))
                            }
                        },
                    )
                }
            }
        }
        if (needsSend && !submitted) {
            // Only questions that actually offer options need an answer.
            val answerable = questions.withIndex().filter { it.value.options.isNotEmpty() }
            val answers = answerable.mapNotNull { answerFor(it.index, it.value) }
            val allAnswered = answers.size == answerable.size
            NeonSendAnswerButton(
                enabled = allAnswered,
                neon = neon,
                onClick = { if (allAnswered) submit(answers) },
            )
        }
        if (submitted) {
            // A tap had no visible "delivered" affordance, so a sent answer
            // read as nothing happening and the user tapped again. Echo the
            // chosen answer next to a "Sent" check. Mirror of iOS.
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                Icon(Icons.Filled.CheckCircle, null, tint = neon.green, modifier = Modifier.size(14.dp))
                Text(
                    sentAnswer?.let { "Sent · $it" } ?: "Sent",
                    style = MaterialTheme.typography.labelMedium,
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.SemiBold,
                    color = neon.green,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/**
 * A big tappable pending-option row (§4.6). A selected option is filled
 * claude + a check; the rest are bordered with a trailing index. Multi-
 * select rows toggle; single-select rows highlight the choice. Min 44dp
 * touch target; dimmed + non-interactive once the card is answered.
 */
@Composable
private fun NeonPendingOptionRow(
    text: String,
    index: Int,
    selected: Boolean,
    dimmed: Boolean,
    enabled: Boolean,
    neon: NeonTheme,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(14.dp)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .graphicsLayer { this.alpha = if (dimmed) 0.45f else 1f }
            .clip(shape)
            .then(
                if (selected) Modifier.background(neon.claude)
                else Modifier.border(1.dp, neon.claude.copy(alpha = 0.55f), shape),
            )
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (selected) {
            Icon(Icons.Filled.Check, null, tint = neon.accentText, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(10.dp))
        }
        Text(
            text,
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.bodyMedium,
            fontFamily = neon.sans,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
            color = if (selected) neon.accentText else neon.text,
        )
        if (!selected) {
            Text(
                "${index + 1}",
                style = MaterialTheme.typography.labelSmall,
                fontFamily = neon.mono,
                color = neon.textFaint,
            )
        }
    }
}

/** The explicit "Send" CTA shown for multi-select / multi-question cards. */
@Composable
private fun NeonSendAnswerButton(
    enabled: Boolean,
    neon: NeonTheme,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(14.dp)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .graphicsLayer { this.alpha = if (enabled) 1f else 0.5f }
            .clip(shape)
            .background(neon.claude)
            .clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            "Send",
            style = MaterialTheme.typography.bodyMedium,
            fontFamily = neon.sans,
            fontWeight = FontWeight.SemiBold,
            color = neon.accentText,
        )
    }
}

// Per-agent neon brand colour for handoff avatars / names now lives in
// NeonComponents.kt as the shared top-level `neonAgentColor`, reused by
// the home list + sheets so chrome and chat agree.

/**
 * Tiny circular agent avatar (first letter), tinted to the agent brand.
 * [glow] applies a soft halo for the handoff target.
 */
@Composable
private fun NeonAgentAvatar(agent: String?, neon: NeonTheme, glow: Boolean) {
    val color = neonAgentColor(agent, neon)
    Box(
        modifier = Modifier
            .size(26.dp)
            .then(if (glow) Modifier.neonGlowBox(neon.glowBox?.let {
                NeonGlowBox(
                    NeonShadowLayer(it.inner.radiusDp, color.copy(alpha = it.inner.color.alpha)),
                    NeonShadowLayer(it.outer.radiusDp, color.copy(alpha = it.outer.color.alpha)),
                )
            }, CircleShape) else Modifier)
            .clip(CircleShape)
            .background(color.copy(alpha = 0.20f))
            .border(1.dp, color, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            (agent?.firstOrNull()?.uppercase() ?: "?"),
            style = MaterialTheme.typography.labelMedium,
            fontFamily = neon.mono,
            fontWeight = FontWeight.Bold,
            color = color,
        )
    }
}

@Composable
private fun HandoffCard(ev: ConversationItem) {
    val neon = LocalNeonTheme.current
    // Structured handoff fields now arrive on ConversationItem over UniFFI
    // (core Tier-1 classifier, see docs/NEON-CORE-FIELDS.md).
    val fromAgent = ev.sourceAgent?.takeIf { it.isNotBlank() }
    val toAgent = ev.targetAgent?.takeIf { it.isNotBlank() }
    val taskText = ev.taskText?.takeIf { it.isNotBlank() }
    val resultSummary = ev.resultSummary?.takeIf { it.isNotBlank() }
    val targetColor = neonAgentColor(toAgent, neon)
    val running = ev.status.equals("running", true) || ev.status.equals("pending", true)
    val shape = RoundedCornerShape(15.dp)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = shape, fill = neon.surface, borderColor = targetColor, glowTint = targetColor)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (fromAgent != null) {
                NeonAgentAvatar(fromAgent, neon, glow = false)
                Spacer(Modifier.width(6.dp))
                Icon(Icons.Outlined.KeyboardArrowRight, null, tint = neon.textDim, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
            }
            NeonAgentAvatar(toAgent, neon, glow = true)
            Spacer(Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                NeonLabel(
                    (toAgent ?: "AGENT").uppercase(),
                    targetColor,
                    neon,
                    style = MaterialTheme.typography.labelMedium,
                )
                Text(
                    "subagent · ${if (running) "working…" else "done"}",
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = neon.mono,
                    color = neon.textDim,
                )
            }
            NeonStatusChip(ev.status, neon)
        }
        // TASK inset block — the delegated instruction.
        if (taskText != null) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(neon.codeBg)
                    .padding(10.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                NeonLabel("TASK", neon.textFaint, neon, style = MaterialTheme.typography.labelSmall)
                Text(
                    taskText,
                    style = MaterialTheme.typography.bodyMedium,
                    fontFamily = neon.sans,
                    color = neon.codeText,
                )
            }
        }
        // Body content (markdown) when present.
        if (ev.content.isNotBlank()) {
            Text(
                ev.content,
                style = MaterialTheme.typography.bodyMedium,
                fontFamily = neon.sans,
                color = neon.text,
            )
        }
        if (running) {
            // Nested progress strip.
            androidx.compose.material3.LinearProgressIndicator(
                modifier = Modifier.fillMaxWidth().clip(CircleShape),
                color = targetColor,
                trackColor = neon.border,
            )
        }
        // Result block (top-bordered, faint green wash) — parsed summary.
        if (resultSummary != null) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(neon.green.copy(alpha = 0.08f))
                    .padding(10.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Check, null, tint = neon.green, modifier = Modifier.size(12.dp))
                    Spacer(Modifier.width(5.dp))
                    NeonLabel("RESULT", neon.textFaint, neon, style = MaterialTheme.typography.labelSmall)
                }
                Text(
                    resultSummary,
                    style = MaterialTheme.typography.bodyMedium,
                    fontFamily = neon.sans,
                    color = neon.text,
                )
            }
        }
    }
}

/**
 * §4.2 SwapNotice — an inline divider shown when a turn is swapping to a
 * new agent. ConversationItem has no dedicated "swapping" status carried
 * to the client today, so this is exposed for PHASE 2 wiring but is NOT
 * currently rendered by the dispatcher.
 */
@Composable
private fun SwapNotice(fromAgent: String?, toAgent: String?) {
    val neon = LocalNeonTheme.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        HorizontalDivider(modifier = Modifier.weight(1f), color = neon.border)
        Text(
            "${fromAgent ?: "?"} → ${toAgent ?: "?"}",
            style = MaterialTheme.typography.labelSmall,
            fontFamily = neon.mono,
            color = neonAgentColor(toAgent, neon),
        )
        HorizontalDivider(modifier = Modifier.weight(1f), color = neon.border)
    }
}

@Composable
private fun SubagentCard(ev: ConversationItem) {
    val neon = LocalNeonTheme.current
    var expanded by remember { mutableStateOf(false) }
    val running = ev.status.equals("running", true) || ev.status.equals("pending", true)
    val shape = RoundedCornerShape(15.dp)
    val chevron by androidx.compose.animation.core.animateFloatAsState(
        targetValue = if (expanded) 180f else 0f,
        label = "subagentChevron",
    )
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = shape, fill = neon.surface, glowTint = neon.purple)
            .clickable { expanded = !expanded }
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier
                    .size(22.dp)
                    .clip(RoundedCornerShape(7.dp))
                    .background(neon.purple.copy(alpha = 0.18f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Outlined.SmartToy, null, tint = neon.purple, modifier = Modifier.size(14.dp))
            }
            Spacer(Modifier.width(10.dp))
            NeonLabel("SUBAGENT", neon.purple, neon)
            Spacer(Modifier.width(6.dp))
            NeonStatusChip(ev.status, neon)
            Spacer(Modifier.weight(1f))
            Icon(
                Icons.Filled.KeyboardArrowDown,
                contentDescription = if (expanded) "Collapse" else "Expand",
                tint = neon.textDim,
                modifier = Modifier.size(20.dp).graphicsLayer { rotationZ = chevron },
            )
        }
        if (running) {
            androidx.compose.material3.LinearProgressIndicator(
                modifier = Modifier.fillMaxWidth().clip(CircleShape),
                color = neon.purple,
                trackColor = neon.border,
            )
        }
        Text(
            if (expanded) ev.content
            else (ev.content.lineSequence().firstOrNull()?.trim()?.takeIf { it.isNotEmpty() } ?: "Subagent activity"),
            style = MaterialTheme.typography.bodyMedium,
            fontFamily = neon.sans,
            color = neon.text,
            maxLines = if (expanded) Int.MAX_VALUE else 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * §4.3 PLAN card. Wired into [ConversationEventRow] on kind=="plan";
 * driven by `ev.planSteps` (core Tier-3 classifier, see
 * docs/NEON-CORE-FIELDS.md). Each [PlanStep] carries a `state` string
 * ("done"|"active"|"todo"). Renders nothing when there are no steps.
 */
@Composable
private fun PlanCard(ev: ConversationItem) {
    if (ev.planSteps.isEmpty()) return
    val neon = LocalNeonTheme.current
    val shape = RoundedCornerShape(neon.radiusDp.dp)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = shape, fill = neon.surface)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        NeonLabel("PLAN", neon.accent, neon)
        ev.planSteps.forEach { step ->
            val state = step.state.lowercase()
            val isDone = state == "done"
            val isActive = state == "active"
            Row(verticalAlignment = Alignment.CenterVertically) {
                when {
                    isDone -> Box(
                        modifier = Modifier.size(16.dp).clip(CircleShape).background(neon.green),
                        contentAlignment = Alignment.Center,
                    ) { Icon(Icons.Filled.Check, null, tint = neon.accentText, modifier = Modifier.size(11.dp)) }
                    isActive -> Box(
                        modifier = Modifier.size(16.dp).clip(CircleShape).border(2.dp, neon.accent2, CircleShape),
                        contentAlignment = Alignment.Center,
                    ) { NeonStatusDot(neon.accent2, pulsing = true, size = 6.dp) }
                    else -> Box(
                        modifier = Modifier.size(16.dp).clip(CircleShape).border(2.dp, neon.textFaint, CircleShape),
                    )
                }
                Spacer(Modifier.width(10.dp))
                Text(
                    step.text + if (isActive) "  running…" else "",
                    style = MaterialTheme.typography.bodyMedium.copy(
                        textDecoration = if (isDone)
                            androidx.compose.ui.text.style.TextDecoration.LineThrough else null,
                    ),
                    fontFamily = neon.sans,
                    color = if (isDone) neon.textDim else neon.text,
                )
            }
        }
    }
}

@Composable
private fun ConversationBubble(
    ev: ConversationItem,
    role: ConversationRole,
    agentAccent: Color,
    modifier: Modifier,
    alignEnd: Boolean,
    /** True when the immediately preceding event had the same role —
     *  hides the role label and tightens top spacing to group messages. */
    isContinuation: Boolean = false,
) {
    // Mirror of iOS `ConduitChatMessageRow`: a monospaced uppercase role
    // label ("YOU" in the brand accent, "ASSISTANT" in secondary) above
    // the body. USER messages right-align (trailing) and carry a subtle
    // rounded surface; ASSISTANT messages flow full-width with no
    // container. `alignEnd` drives the horizontal alignment so the
    // dispatch site stays the source of truth for which role trails.
    val neon = LocalNeonTheme.current
    val roleLabel = when (role) {
        ConversationRole.User -> "YOU"
        ConversationRole.Assistant -> "ASSISTANT"
        ConversationRole.Tool -> "TOOL"
        ConversationRole.System -> "SYSTEM"
    }
    val labelColor = when (role) {
        ConversationRole.User -> neon.accent2
        else -> neon.textDim
    }
    // Continuation rows sit closer to the previous message: the
    // LazyColumn's 12dp item spacing minus 8dp offset = 4dp effective gap.
    Column(
        modifier = modifier
            .fillMaxWidth()
            .then(if (isContinuation) Modifier.offset(y = (-8).dp) else Modifier),
        horizontalAlignment = if (alignEnd) Alignment.End else Alignment.Start,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (!isContinuation) {
            NeonLabel(roleLabel, labelColor, neon)
        }
        if (role == ConversationRole.User) {
            // Right-aligned, content-sized pill. `neon.accent` fill +
            // `neon.accentText` foreground, pill radius — the §2 user
            // bubble. `fillMaxWidth(0.82f)` caps long turns; `wrapContentWidth`
            // shrinks to content + pins trailing so short turns hug the right.
            Box(
                modifier = Modifier
                    .fillMaxWidth(0.82f)
                    .wrapContentWidth(Alignment.End)
                    .clip(RoundedCornerShape(18.dp))
                    // Device feedback v0.0.68: fill with `accent`, NOT `accent2`.
                    // `accentText` is the guaranteed-contrast partner of `accent`
                    // (in light mode `accent2` is a bright tint, e.g. Matrix lime,
                    // and `accentText` is white → white-on-lime was unreadable).
                    .background(neon.accent),
            ) {
                Column(
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    ConversationRenderer.blocks(ev.content).forEach { block ->
                        when (block) {
                            is ConversationBlock.Markdown ->
                                Text(
                                    block.text,
                                    style = MaterialTheme.typography.bodyMedium,
                                    fontFamily = neon.sans,
                                    color = neon.accentText,
                                )
                            is ConversationBlock.Code -> CodeBlock(block.language, block.content)
                        }
                    }
                    if (ev.files.isNotEmpty()) FileStrip(ev.files)
                }
            }
            // "sending…" clock while queued, or a "failed — retry" affordance
            // once delivery gives up. Collapsed once the broker acks (status
            // flips to `done`). Mirror of iOS `sendStatusFooter`. Reads
            // `ev.status` so a status flip rebuilds the row.
            SendStatusFooter(ev)
        } else {
            ConversationRenderer.blocks(ev.content).forEach { block ->
                when (block) {
                    is ConversationBlock.Markdown -> MarkdownBlock(block.text, role)
                    is ConversationBlock.Code -> CodeBlock(block.language, block.content)
                }
            }
            if (ev.files.isNotEmpty()) FileStrip(ev.files)
        }
    }
}

/**
 * Optimistic-send status under a user bubble: a "sending…" clock while the
 * message is queued, or a "failed — tap to retry" affordance once delivery
 * gives up. Renders nothing once the broker acks (status `done`). Reads
 * [LocalSessionStore]/[LocalSessionId] for the retry action so the dispatch
 * site stays thin. Mirror of iOS `sendStatusFooter`.
 */
@Composable
private fun SendStatusFooter(ev: ConversationItem) {
    val neon = LocalNeonTheme.current
    when (ev.status.lowercase()) {
        "pending" -> {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Icon(
                    Icons.Outlined.Schedule,
                    contentDescription = null,
                    tint = neon.textDim,
                    modifier = Modifier.size(11.dp),
                )
                Text(
                    "sending…",
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = neon.mono,
                    color = neon.textDim,
                )
            }
        }

        "retrying" -> {
            // Fix 8: transient state while a manual retry's WS write is
            // in-flight. Flips back to done/failed when attemptDeliver settles.
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                CircularProgressIndicator(
                    strokeWidth = 1.5.dp,
                    color = neon.textDim,
                    modifier = Modifier.size(11.dp),
                )
                Text(
                    "retrying…",
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = neon.mono,
                    color = neon.textDim,
                )
            }
        }
        "failed" -> {
            val store = LocalSessionStore.current
            val sessionId = LocalSessionId.current
            val snackbar = LocalChatSnackbar.current
            val scope = rememberCoroutineScope()
            val doRetry: () -> Unit = retry@{
                if (store == null || sessionId == null) return@retry
                Telemetry.breadcrumb(
                    "chat",
                    "retry_tap",
                    mapOf("session" to sessionId, "local_id" to ev.id),
                )
                store.retryPendingChat(sessionId, ev.id)
            }
            // Warning + retry icon pair mirrors iOS exclamation+refresh.
            // Semantic Button role for TalkBack accessibility. Tapping the chip
            // OR the snackbar RETRY action re-submits the same content.
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                modifier = Modifier
                    .semantics { role = Role.Button }
                    .clickable(enabled = store != null && sessionId != null) {
                        doRetry()
                        if (snackbar != null) {
                            scope.launch {
                                val result = snackbar.showSnackbar(
                                    message = "Couldn't send",
                                    actionLabel = "RETRY",
                                    duration = SnackbarDuration.Short,
                                )
                                if (result == SnackbarResult.ActionPerformed) doRetry()
                            }
                        }
                    },
            ) {
                Icon(
                    Icons.Outlined.Warning,
                    contentDescription = null,
                    tint = neon.red,
                    modifier = Modifier.size(12.dp),
                )
                Icon(
                    Icons.Outlined.Refresh,
                    contentDescription = null,
                    tint = neon.red,
                    modifier = Modifier.size(12.dp),
                )
                Text(
                    "failed — tap to retry",
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = neon.mono,
                    color = neon.red,
                )
            }
        }
        else -> Unit
    }
}

/**
 * Lightweight "agent is typing…" row: an animated three-dot pulse plus
 * the agent name. Shown at the bottom of the message list while the
 * agent streams (Bug 3 / iOS `isStreaming` parity). Three dots pulse
 * out of phase via an infinite transition.
 */
@Composable
private fun TypingIndicatorRow(assistant: String, @Suppress("UNUSED_PARAMETER") accent: Color) {
    val neon = LocalNeonTheme.current
    val transition = androidx.compose.animation.core.rememberInfiniteTransition(label = "typing")
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            Icons.Outlined.SmartToy,
            contentDescription = null,
            tint = neon.accent2,
            modifier = Modifier.size(14.dp),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
            repeat(3) { i ->
                val dotAlpha by transition.animateFloat(
                    initialValue = 0.3f,
                    targetValue = 1f,
                    animationSpec = androidx.compose.animation.core.infiniteRepeatable(
                        animation = androidx.compose.animation.core.tween(
                            durationMillis = 600,
                            delayMillis = i * 160,
                        ),
                        repeatMode = androidx.compose.animation.core.RepeatMode.Reverse,
                    ),
                    label = "dot$i",
                )
                Box(
                    modifier = Modifier
                        .size(6.dp)
                        .graphicsLayer { alpha = dotAlpha }
                        .background(neon.accent2, CircleShape),
                )
            }
        }
        Text(
            "$assistant is typing…",
            style = MaterialTheme.typography.labelSmall,
            fontFamily = neon.sans,
            color = neon.textDim,
        )
    }
}

@Composable
private fun MarkdownBlock(text: String, role: ConversationRole) {
    val neon = LocalNeonTheme.current
    val appearance = sh.nikhil.conduit.LocalAppearanceStore.current
    val fontChoice by appearance.fontFamily.collectAsState()
    val bodyPointSize by appearance.bodyPointSize.collectAsState()
    // Prose renders in the user's chosen Chat font (handoff Part A):
    // System / Space Grotesk / IBM Plex Sans / Newsreader.
    val resolvedFont = neonProseFontFamily(fontChoice)
    val onColor = if (role == ConversationRole.System) {
        neon.textDim
    } else {
        neon.text
    }

    // Android parity of the iOS chat-polish change: agent markdown was
    // rendering cramped + structurally collapsed — a whole reply went
    // into one `Text`, so GFM tables came out as run-on `| a | b |`
    // text, headings jammed into the following line, and blocks had no
    // vertical rhythm. We now split into typed [ConduitMarkdownBlocks]
    // and render each block as its own composable with real spacing:
    // headings weighted + spaced, lists with bullets/indent, tables
    // stacked as "header: value" rows, code monospaced.
    //
    // Block parsing is a cheap structural pass; the expensive
    // per-heading scaled [AnnotatedString] styling still goes through
    // the hoisted LRU [ParsedMarkdownCache] (task #38) so streaming
    // ticks and LazyColumn recycles render from cache rather than
    // re-parsing (0px → final height judder). The cache key folds
    // content + body size + font into a revision; the id is the
    // content hash so identical text shares one entry.
    val cache = LocalParsedMarkdownCache.current
    val blocks = remember(text) { ConduitMarkdownBlocks.parse(text) }
    SelectionContainer {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            blocks.forEach { block ->
                when (block) {
                    is ConduitMarkdownBlocks.MdBlock.Heading ->
                        MarkdownHeading(block, bodyPointSize, resolvedFont, onColor)
                    is ConduitMarkdownBlocks.MdBlock.Paragraph ->
                        MarkdownProse(block.text, bodyPointSize, fontChoice, resolvedFont, onColor, cache)
                    is ConduitMarkdownBlocks.MdBlock.ListBlock ->
                        MarkdownList(block, bodyPointSize, resolvedFont, onColor)
                    is ConduitMarkdownBlocks.MdBlock.Quote ->
                        MarkdownQuote(block.text, bodyPointSize, resolvedFont)
                    is ConduitMarkdownBlocks.MdBlock.Table ->
                        MarkdownTable(block, bodyPointSize, resolvedFont, onColor)
                }
            }
            if (blocks.isEmpty()) {
                MarkdownProse(text, bodyPointSize, fontChoice, resolvedFont, onColor, cache)
            }
        }
    }
}

/** A scaled, weighted heading line with clear breathing room. */
@Composable
private fun MarkdownHeading(
    block: ConduitMarkdownBlocks.MdBlock.Heading,
    bodyPointSize: Float,
    font: FontFamily,
    onColor: Color,
) {
    val mult = ConduitMarkdownHeadingScaler.multiplier(block.level) ?: 1f
    Text(
        text = block.text,
        modifier = Modifier.padding(top = 4.dp, bottom = 2.dp),
        fontSize = androidx.compose.ui.unit.TextUnit(
            bodyPointSize * mult,
            androidx.compose.ui.unit.TextUnitType.Sp,
        ),
        fontWeight = FontWeight.SemiBold,
        fontFamily = font,
        color = onColor,
    )
}

/**
 * A prose paragraph at the user-chosen body size. The styled
 * [AnnotatedString] is served through the hoisted [ParsedMarkdownCache]
 * (task #38) so streaming ticks and LazyColumn recycles render from
 * cache instead of re-styling — keeping the cache meaningfully wired
 * post block-split.
 */
@Composable
private fun MarkdownProse(
    text: String,
    bodyPointSize: Float,
    fontChoice: sh.nikhil.conduit.AppearanceStore.FontFamily,
    font: FontFamily,
    onColor: Color,
    cache: ParsedMarkdownCache,
) {
    val revision = remember(text, bodyPointSize, fontChoice) {
        markdownRevision(text, bodyPointSize, fontChoice)
    }
    val annotated = remember(text, revision) {
        cache.getOrPut(id = text.hashCode().toString(), revision = revision) {
            ConduitMarkdownHeadingScaler.scaledAnnotated(text, basePointSize = bodyPointSize)
        }
    }
    Text(
        text = annotated,
        style = MaterialTheme.typography.bodyMedium.copy(
            fontSize = androidx.compose.ui.unit.TextUnit(
                bodyPointSize,
                androidx.compose.ui.unit.TextUnitType.Sp,
            ),
            // De-cramp (handoff §1/§7): both chat arms read calmer at ~1.7
            // line-height vs the cramped ~1.46 baseline. Mirrors iOS
            // `proseLineSpacing`.
            lineHeight = androidx.compose.ui.unit.TextUnit(
                bodyPointSize * 1.7f,
                androidx.compose.ui.unit.TextUnitType.Sp,
            ),
        ),
        fontFamily = font,
        color = onColor,
    )
}

/** Bullet / numbered list with markers + indent. */
@Composable
private fun MarkdownList(
    block: ConduitMarkdownBlocks.MdBlock.ListBlock,
    bodyPointSize: Float,
    font: FontFamily,
    onColor: Color,
) {
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        block.items.forEachIndexed { idx, item ->
            val marker = if (block.ordered) "${idx + 1}." else "•"
            Row(modifier = Modifier.padding(start = (item.indent * 14).dp)) {
                Text(
                    text = marker,
                    style = MaterialTheme.typography.bodyMedium.copy(
                        fontSize = androidx.compose.ui.unit.TextUnit(
                            bodyPointSize,
                            androidx.compose.ui.unit.TextUnitType.Sp,
                        ),
                    ),
                    fontFamily = font,
                    color = onColor,
                    modifier = Modifier.widthIn(min = 20.dp),
                )
                Text(
                    text = item.text,
                    style = MaterialTheme.typography.bodyMedium.copy(
                        fontSize = androidx.compose.ui.unit.TextUnit(
                            bodyPointSize,
                            androidx.compose.ui.unit.TextUnitType.Sp,
                        ),
                    ),
                    fontFamily = font,
                    color = onColor,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

/** A blockquote with a left accent rule. */
@Composable
private fun MarkdownQuote(
    text: String,
    bodyPointSize: Float,
    font: FontFamily,
) {
    val neon = LocalNeonTheme.current
    Row(modifier = Modifier.height(IntrinsicSize.Min)) {
        Box(
            modifier = Modifier
                .width(3.dp)
                .fillMaxHeight()
                .background(neon.accent.copy(alpha = 0.6f), RoundedCornerShape(2.dp)),
        )
        Spacer(Modifier.width(10.dp))
        Text(
            text = text,
            style = MaterialTheme.typography.bodyMedium.copy(
                fontSize = androidx.compose.ui.unit.TextUnit(
                    bodyPointSize,
                    androidx.compose.ui.unit.TextUnitType.Sp,
                ),
            ),
            fontFamily = font,
            color = neon.textDim,
        )
    }
}

/**
 * GFM table rendered as stacked per-record "header: value" rows — the
 * robust narrow-phone layout the iOS change picked over a true grid.
 * Each data row becomes a small card of label/value pairs; cells never
 * concatenate into run-on text.
 */
@Composable
private fun MarkdownTable(
    block: ConduitMarkdownBlocks.MdBlock.Table,
    bodyPointSize: Float,
    font: FontFamily,
    onColor: Color,
) {
    val neon = LocalNeonTheme.current
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        block.rows.forEach { row ->
            Surface(
                shape = RoundedCornerShape(12.dp),
                color = neon.surface,
            ) {
                Column(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(3.dp),
                ) {
                    block.header.forEachIndexed { idx, headerCell ->
                        val value = row.getOrNull(idx).orEmpty()
                        Row(verticalAlignment = Alignment.Top) {
                            Text(
                                text = if (headerCell.isNotEmpty()) "$headerCell:" else "",
                                style = MaterialTheme.typography.labelMedium,
                                fontWeight = FontWeight.SemiBold,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.weight(0.4f),
                            )
                            Spacer(Modifier.width(8.dp))
                            Text(
                                text = value,
                                style = MaterialTheme.typography.bodyMedium.copy(
                                    fontSize = androidx.compose.ui.unit.TextUnit(
                                        bodyPointSize,
                                        androidx.compose.ui.unit.TextUnitType.Sp,
                                    ),
                                ),
                                fontFamily = font,
                                color = onColor,
                                modifier = Modifier.weight(0.6f),
                            )
                        }
                    }
                }
            }
        }
        // A header-only table (no data rows) still reads as its columns.
        if (block.rows.isEmpty() && block.header.isNotEmpty()) {
            Text(
                text = block.header.joinToString("  •  "),
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun CodeBlock(language: String?, content: String) {
    val neon = LocalNeonTheme.current
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (!language.isNullOrBlank()) {
            NeonLabel(language.uppercase(), neon.textDim, neon)
        }
        SelectionContainer {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp))
                    .background(neon.codeBg)
                    .border(1.dp, neon.border, RoundedCornerShape(14.dp))
                    .padding(12.dp)
                    .horizontalScroll(rememberScrollState()),
            ) {
                Text(
                    text = content,
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = neon.mono,
                    color = neon.codeText,
                )
            }
        }
    }
}

@Composable
private fun ConversationToolCard(ev: ConversationItem) {
    // §4.1 vs §4.5: bash/exec tool calls (or any with a shell command)
    // get the COMMAND headline card; everything else gets the compact
    // tool card. Both keep ConversationRenderer.toolSections intact for
    // the expanded body.

    if (isNeonCommandCard(ev.toolName, ev.command)) {
        NeonCommandCard(ev)
    } else {
        NeonToolCard(ev)
    }
}

/** Worst (highest-magnitude non-zero) exit code across a tool cluster. */
private fun clusterWorstExit(items: List<ConversationItem>): Int? {
    val exits = items.mapNotNull { it.exitCode?.toInt() }
    if (exits.isEmpty()) return null
    return exits.firstOrNull { it != 0 } ?: 0
}

/** One-line label for a clustered tool row: its command, else the tool name. */
private fun clusterRowLabel(ev: ConversationItem): String {
    ev.command?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
    ev.toolName?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
    return ev.kind.replaceFirstChar { it.uppercase() }
}

/**
 * Fix 10 — arm-B grouped tool cluster. Header summarizes the run
 * ("3 commands · all exit 0", or the worst non-zero exit), then hairline-split
 * one-line command rows. Collapsed (default) shows header + rows; tapping the
 * header expands to the full inline tool cards for each call. A single tool
 * call never reaches here (see [groupChatUnits]) so the inline path is intact.
 */
@Composable
private fun ToolClusterCard(items: List<ConversationItem>) {
    val neon = LocalNeonTheme.current
    var expanded by remember { mutableStateOf(false) }
    val worstExit = remember(items) { clusterWorstExit(items) }
    val anyFailed = items.any { it.status.equals("failed", true) } ||
        (worstExit != null && worstExit != 0)
    val summary = remember(items, worstExit, anyFailed) {
        val n = items.size
        val noun = if (n == 1) "command" else "commands"
        when {
            worstExit == null && !anyFailed -> "$n $noun"
            worstExit == 0 && !anyFailed -> "$n $noun · all exit 0"
            worstExit != null -> "$n $noun · exit $worstExit"
            else -> "$n $noun · failed"
        }
    }
    val chevron by androidx.compose.animation.core.animateFloatAsState(
        targetValue = if (expanded) 180f else 0f,
        label = "clusterChevron",
    )
    val shape = RoundedCornerShape(neon.radiusDp.dp)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = shape, fill = neon.surface, failed = anyFailed),
    ) {
        // Header — tap toggles expand.
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable { expanded = !expanded }
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(22.dp)
                    .clip(RoundedCornerShape(7.dp))
                    .background(neon.green.copy(alpha = 0.18f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Outlined.Terminal, null, tint = neon.green, modifier = Modifier.size(14.dp))
            }
            Spacer(Modifier.width(10.dp))
            Text(
                summary,
                style = MaterialTheme.typography.bodyMedium,
                fontFamily = neon.sans,
                fontWeight = FontWeight.SemiBold,
                color = if (anyFailed) neon.red else neon.text,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )

            Icon(
                Icons.Default.KeyboardArrowDown,
                contentDescription = if (expanded) "Collapse" else "Expand",
                tint = neon.textDim,
                modifier = Modifier
                    .size(18.dp)
                    .graphicsLayer { rotationZ = chevron },
            )
        }
        if (expanded) {
            // Expanded: the full inline tool cards, one per call.
            Column(
                modifier = Modifier.padding(start = 12.dp, end = 12.dp, bottom = 12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items.forEach { ConversationToolCard(it) }
            }
        } else {
            // Collapsed: hairline-split one-line command rows.
            Column(modifier = Modifier.fillMaxWidth()) {
                items.forEach { ev ->
                    HorizontalDivider(color = neon.border, thickness = 0.5.dp)
                    val exit = ev.exitCode?.toInt()
                    val rowFailed = ev.status.equals("failed", true) || (exit != null && exit != 0)
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            clusterRowLabel(ev),
                            style = MaterialTheme.typography.labelSmall,
                            fontFamily = neon.mono,
                            color = neon.codeText,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        if (exit != null) {
                            Spacer(Modifier.width(8.dp))
                            Text(
                                "exit $exit",
                                style = MaterialTheme.typography.labelSmall.copy(fontSize = 10.5.sp),
                                fontFamily = neon.mono,
                                color = if (rowFailed) neon.red else neon.green,
                                maxLines = 1,
                            )
                        }
                    }
                }
            }
        }
    }
}

/** Icon + tint for a tool family (§4.5 tile colours). */
@Composable
private fun toolTileIcon(kind: NeonToolKind, neon: NeonTheme): Pair<ImageVector, Color> = when (kind) {
    NeonToolKind.SEARCH -> Icons.Outlined.Search to neon.purple
    NeonToolKind.READ -> Icons.Outlined.Visibility to neon.blue
    NeonToolKind.EDIT -> Icons.Outlined.Create to neon.claude
    NeonToolKind.BASH -> Icons.Outlined.Terminal to neon.green
    NeonToolKind.GENERIC -> Icons.Outlined.Build to neon.accent2
}

/** Human label for a tool family, used as the §4.5 header. */
private fun toolHumanLabel(ev: ConversationItem, kind: NeonToolKind): String {
    ev.toolName?.takeIf { it.isNotBlank() }?.let { return it }
    return when (kind) {
        NeonToolKind.SEARCH -> "Search"
        NeonToolKind.READ -> "Read"
        NeonToolKind.EDIT -> "Edit"
        NeonToolKind.BASH -> "Run"
        NeonToolKind.GENERIC -> ev.kind.replaceFirstChar { it.uppercase() }
    }
}

/**
 * §4.5 compact tool card: a 22dp tinted icon tile, human label, mono meta
 * + duration, a rotating chevron, expanding to the mono output on codeBg.
 */
@Composable
private fun NeonToolCard(ev: ConversationItem) {
    val neon = LocalNeonTheme.current
    var expanded by remember { mutableStateOf(false) }
    val sections = remember(ev) { ConversationRenderer.toolSections(ev) }
    val kind = remember(ev.toolName) { neonToolKind(ev.toolName) }
    val (icon, tint) = toolTileIcon(kind, neon)
    val durationText = ev.durationMs?.let { formatNeonDuration(it) }
    val exit = ev.exitCode?.toInt()
    val failed = ev.status.equals("failed", true) || (exit != null && exit != 0)
    val chevron by androidx.compose.animation.core.animateFloatAsState(
        targetValue = if (expanded) 180f else 0f,
        label = "toolChevron",
    )
    val shape = RoundedCornerShape(neon.radiusDp.dp)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = shape, fill = neon.surface, failed = failed)
            .clickable { expanded = !expanded }
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier
                    .size(22.dp)
                    .clip(RoundedCornerShape(7.dp))
                    .background(tint.copy(alpha = 0.18f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(icon, null, tint = tint, modifier = Modifier.size(14.dp))
            }
            Spacer(Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    toolHumanLabel(ev, kind),
                    style = MaterialTheme.typography.bodyMedium,
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.SemiBold,
                    color = neon.text,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                val meta = buildList {
                    if (exit != null) add("exit $exit")
                    durationText?.let { add(it) }
                }.joinToString(" · ")
                if (meta.isNotEmpty()) {
                    Text(
                        meta,
                        style = MaterialTheme.typography.labelSmall.copy(fontSize = 10.5.sp),
                        fontFamily = neon.mono,
                        color = if (failed) neon.red else neon.green,
                        maxLines = 1,
                    )
                }
            }
            ev.diffSummary?.takeIf { it.isNotBlank() }?.let { ds ->
                NeonLabel(ds.uppercase(), neon.textDim, neon)
                Spacer(Modifier.width(8.dp))
            }
            NeonStatusChip(ev.status, neon)
            Spacer(Modifier.width(6.dp))
            Icon(
                Icons.Filled.KeyboardArrowDown,
                contentDescription = if (expanded) "Collapse" else "Expand",
                tint = neon.textDim,
                modifier = Modifier.size(20.dp).graphicsLayer { rotationZ = chevron },
            )
        }
        androidx.compose.animation.AnimatedVisibility(
            visible = expanded,
            enter = fadeIn() + expandVertically(),
            exit = fadeOut() + shrinkVertically(),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                sections.forEach { section -> NeonToolSection(section) }
            }
        }
    }
}

/** Dispatch a parsed [ToolSection] to its neon composable. */
@Composable
private fun NeonToolSection(section: ToolSection) {
    when (section) {
        is ToolSection.Meta -> ToolMetaRow(section.exitCode, section.duration)
        is ToolSection.Command -> CommandBlock(section.command)
        is ToolSection.Files -> FileStrip(section.files)
        is ToolSection.Stdout -> LabeledOutputBlock("STDOUT", section.text)
        is ToolSection.Stderr -> LabeledOutputBlock("STDERR", section.text)
        is ToolSection.Text -> MarkdownBlock(section.text, ConversationRole.Tool)
        is ToolSection.Code -> CodeBlock(section.language, section.content)
        is ToolSection.Diff -> DiffBlock(section.content)
    }
}

/**
 * §4.1 COMMAND headline card. Container codeBg, 14dp radius, 1dp border
 * (red on fail), state-tinted glow; a 3dp full-height left status rail;
 * a header with mono `$` + command; a meta strip; collapsible output with
 * a blinking cursor while running; and an action bar (Copy / Re-run /
 * Open in terminal).
 */
@Composable
private fun NeonCommandCard(ev: ConversationItem) {
    val neon = LocalNeonTheme.current
    val store = LocalSessionStore.current
    val sessionId = LocalSessionId.current
    val openInTerminal = LocalOpenInTerminal.current
    val clipboard = LocalClipboardManager.current
    var expanded by remember { mutableStateOf(true) }

    val sections = remember(ev) { ConversationRenderer.toolSections(ev) }
    val command = remember(ev) {
        ev.command?.takeIf { it.isNotBlank() }
            ?: sections.filterIsInstance<ToolSection.Command>().firstOrNull()?.command
            ?: ev.content.lineSequence().firstOrNull()?.trim().orEmpty()
    }
    val exit = ev.exitCode?.toInt()
    val running = ev.status.equals("running", true) || ev.status.equals("pending", true)
    val failed = ev.status.equals("failed", true) || (exit != null && exit != 0)
    val railColor = when {
        running -> neon.accent2
        failed -> neon.red
        else -> neon.green
    }
    val durationText = ev.durationMs?.let { formatNeonDuration(it) }
    val shape = RoundedCornerShape(14.dp)

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = shape, fill = neon.codeBg, failed = failed, glowTint = railColor)
            .clip(shape)
            .height(IntrinsicSize.Min),
    ) {
        // Left 3dp full-height status rail.
        Box(
            modifier = Modifier
                .width(3.dp)
                .fillMaxHeight()
                .background(railColor),
        )
        Column(
            modifier = Modifier.fillMaxWidth().padding(start = 11.dp, end = 12.dp, top = 10.dp, bottom = 6.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            // Header: $ prompt + command, status chip on the right.
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("$", style = MaterialTheme.typography.bodyMedium, fontFamily = neon.mono, color = railColor)
                Spacer(Modifier.width(8.dp))
                Text(
                    command,
                    modifier = Modifier
                        .weight(1f)
                        .clickable { expanded = !expanded },
                    style = MaterialTheme.typography.bodyMedium,
                    fontFamily = neon.mono,
                    color = neon.codeText,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.width(8.dp))
                if (running) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                        NeonStatusDot(neon.accent2, pulsing = true, size = 6.dp)
                        Text("running", style = MaterialTheme.typography.labelSmall, fontFamily = neon.mono, color = neon.accent2)
                    }
                } else {
                    val ok = !failed
                    val label = if (exit != null) "exit $exit" else if (ok) "exit 0" else "exit 1"
                    Row(
                        modifier = Modifier
                            .clip(CircleShape)
                            .background((if (ok) neon.green else neon.red).copy(alpha = 0.14f))
                            .padding(horizontal = 8.dp, vertical = 3.dp),
                    ) {
                        Text(
                            label,
                            style = MaterialTheme.typography.labelSmall,
                            fontFamily = neon.mono,
                            fontWeight = FontWeight.Bold,
                            color = if (ok) neon.green else neon.red,
                        )
                    }
                }
            }

            // Meta strip — folder + cwd · host · duration. Fields omitted
            // gracefully when absent. (cwd/host aren't carried on
            // ConversationItem today, so this typically shows duration only.)
            val metaPieces = buildList {
                durationText?.let { add(it) }
            }
            if (metaPieces.isNotEmpty()) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.Folder, null, tint = neon.textFaint, modifier = Modifier.size(12.dp))
                    Spacer(Modifier.width(5.dp))
                    Text(
                        metaPieces.joinToString("  ·  "),
                        modifier = Modifier.weight(1f),
                        style = MaterialTheme.typography.labelSmall.copy(fontSize = 10.5.sp),
                        fontFamily = neon.mono,
                        color = if (failed) neon.red else neon.textDim,
                        textAlign = androidx.compose.ui.text.style.TextAlign.End,
                    )
                }
            }

            // Output (collapsible, ~132dp max).
            androidx.compose.animation.AnimatedVisibility(
                visible = expanded,
                enter = fadeIn() + expandVertically(),
                exit = fadeOut() + shrinkVertically(),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    NeonCommandOutput(sections, running, neon)
                }
            }

            // Action bar (top-bordered): Copy / Re-run / Open in terminal.
            HorizontalDivider(color = neon.border, thickness = 1.dp)
            Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                NeonActionButton("Copy", neon) {
                    clipboard.setText(AnnotatedString(command))
                }
                NeonActionButton("Re-run", neon, enabled = sessionId != null && store != null) {
                    // Resend the command as a chat message so the agent
                    // re-executes it and the result is VISIBLE in the thread
                    // — matches iOS. The prior sendInput wrote into the PTY,
                    // which is invisible from the Chat tab (device feedback:
                    // "re-run doesn't work").
                    if (sessionId != null && store != null && command.isNotBlank()) {
                        store.sendChat(sessionId, command)
                    }
                }
                // Switch the session to its Terminal tab. Disabled when no
                // jump is wired (read-only / tablet chat-only pane).
                NeonActionButton("Open in terminal", neon, enabled = openInTerminal != null) {
                    openInTerminal?.invoke()
                }
            }
        }
    }
}

/** Renders the command card's output region: stdout codeText, stderr red. */
@Composable
private fun NeonCommandOutput(sections: List<ToolSection>, running: Boolean, neon: NeonTheme) {
    val outputs = sections.filter {
        it is ToolSection.Stdout || it is ToolSection.Stderr ||
            it is ToolSection.Text || it is ToolSection.Code || it is ToolSection.Diff
    }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(max = 132.dp)
            .verticalScroll(rememberScrollState()),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            outputs.forEach { section ->
                when (section) {
                    is ToolSection.Stdout -> NeonOutputLines(section.text, neon.codeText, neon)
                    is ToolSection.Stderr -> NeonOutputLines(section.text, neon.red, neon, glow = true)
                    is ToolSection.Text -> NeonOutputLines(section.text, neon.codeText, neon)
                    is ToolSection.Code -> NeonOutputLines(section.content, neon.codeText, neon)
                    is ToolSection.Diff -> DiffBlock(section.content)
                    else -> Unit
                }
            }
            if (running) {
                NeonBlinkingCursor(neon)
            }
        }
    }
}

@Composable
private fun NeonOutputLines(text: String, color: Color, neon: NeonTheme, glow: Boolean = false) {
    val shadow = if (glow && neon.textGlow != null) {
        androidx.compose.ui.graphics.Shadow(color = color.copy(alpha = 0.5f), blurRadius = 8f)
    } else {
        null
    }
    SelectionContainer {
        Text(
            text,
            style = MaterialTheme.typography.bodySmall.copy(fontSize = 11.3.sp, shadow = shadow),
            fontFamily = neon.mono,
            color = color,
        )
    }
}

/** A blinking block cursor for the running command output. */
@Composable
private fun NeonBlinkingCursor(neon: NeonTheme) {
    val transition = androidx.compose.animation.core.rememberInfiniteTransition(label = "cursor")
    val a by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = androidx.compose.animation.core.infiniteRepeatable(
            animation = androidx.compose.animation.core.tween(500),
            repeatMode = androidx.compose.animation.core.RepeatMode.Reverse,
        ),
        label = "cursorAlpha",
    )
    Box(
        modifier = Modifier
            .padding(top = 2.dp)
            .size(width = 8.dp, height = 14.dp)
            .graphicsLayer { alpha = a }
            .background(neon.accent2),
    )
}

/** A small text action button for the command card action bar. */
@Composable
private fun NeonActionButton(label: String, neon: NeonTheme, enabled: Boolean = true, onClick: () -> Unit) {
    Text(
        label,
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(vertical = 4.dp),
        style = MaterialTheme.typography.labelMedium,
        fontFamily = neon.mono,
        color = if (enabled) neon.accent else neon.textFaint,
    )
}

/** ms → "120ms" / "1.4s" / "1.4min". Mirrors the renderer's formatter. */
private fun formatNeonDuration(ms: ULong): String {
    val msLong = ms.toLong()
    if (msLong < 1_000) return "${msLong}ms"
    val seconds = msLong / 1_000.0
    if (seconds < 60) return String.format("%.1fs", seconds)
    return String.format("%.1fmin", seconds / 60.0)
}

@Composable
private fun CommandBlock(command: String) {
    val neon = LocalNeonTheme.current
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        NeonLabel("COMMAND", neon.textDim, neon)
        SelectionContainer {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(neon.codeBg)
                    .border(1.dp, neon.border, RoundedCornerShape(12.dp))
                    .padding(horizontal = 10.dp, vertical = 8.dp),
            ) {
                Text("$ ", style = MaterialTheme.typography.bodySmall, fontFamily = neon.mono, color = neon.accent2)
                Text(
                    command,
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = neon.mono,
                    color = neon.codeText,
                )
            }
        }
    }
}

@Composable
private fun ToolMetaRow(exitCode: Int?, duration: String?) {
    val neon = LocalNeonTheme.current
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        if (exitCode != null) {
            val ok = exitCode == 0
            val c = if (ok) neon.green else neon.red
            Text(
                "EXIT $exitCode",
                modifier = Modifier.clip(CircleShape).background(c.copy(alpha = 0.14f)).padding(horizontal = 8.dp, vertical = 3.dp),
                style = MaterialTheme.typography.labelSmall,
                fontFamily = neon.mono,
                color = c,
                fontWeight = FontWeight.Bold,
            )
        }
        if (!duration.isNullOrBlank()) {
            Text(
                "DURATION $duration",
                modifier = Modifier.clip(CircleShape).background(neon.surface).padding(horizontal = 8.dp, vertical = 3.dp),
                style = MaterialTheme.typography.labelSmall,
                fontFamily = neon.mono,
                color = neon.textDim,
                fontWeight = FontWeight.Bold,
            )
        }
    }
}

@Composable
private fun LabeledOutputBlock(title: String, text: String) {
    val neon = LocalNeonTheme.current
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        NeonLabel(title, if (title == "STDERR") neon.red else neon.textDim, neon)
        SelectionContainer {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(neon.codeBg)
                    .border(1.dp, neon.border, RoundedCornerShape(12.dp))
                    .padding(12.dp)
                    .horizontalScroll(rememberScrollState()),
            ) {
                Text(
                    text,
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = neon.mono,
                    color = if (title == "STDERR") neon.red else neon.codeText,
                )
            }
        }
    }
}

/** Neon status pill — running=accent2, pending=blue, failed=red, else green. */
@Composable
private fun NeonStatusChip(status: String, neon: NeonTheme) {
    val normalized = status.lowercase().ifEmpty { "done" }
    val fg = when (normalized) {
        "running" -> neon.accent2
        "pending" -> neon.blue
        "failed" -> neon.red
        else -> neon.green
    }
    Row(
        modifier = Modifier
            .clip(CircleShape)
            .background(fg.copy(alpha = 0.14f))
            .padding(horizontal = 8.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        if (normalized == "running") {
            NeonStatusDot(fg, pulsing = true, size = 6.dp)
        }
        Text(
            normalized.uppercase(),
            style = MaterialTheme.typography.labelSmall,
            color = fg,
            fontFamily = neon.mono,
            fontWeight = FontWeight.Bold,
        )
    }
}

@Composable
private fun FileStrip(files: List<ViewEventFile>) {
    val neon = LocalNeonTheme.current
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        NeonLabel("FILES", neon.textDim, neon)
        files.forEach { file ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(neon.surface)
                    .border(1.dp, neon.border, RoundedCornerShape(12.dp))
                    .padding(horizontal = 10.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Outlined.Description, null, tint = neon.blue, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(8.dp))
                Column {
                    Text(file.path, style = MaterialTheme.typography.labelMedium, fontFamily = neon.mono, color = neon.text)
                    if (file.rev.isNotEmpty()) {
                        Text("@${file.rev.take(7)}", style = MaterialTheme.typography.labelSmall, fontFamily = neon.mono, color = neon.textDim)
                    }
                }
            }
        }
    }
}

@Composable
private fun DiffBlock(content: String) {
    val files = remember(content) { parseDiffFiles(content) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        files.forEach { file ->
            DiffFileGroup(file)
        }
    }
}

private data class DiffFileSection(
    val id: String,
    val path: String,
    val lines: List<String>,
)

@Composable
private fun DiffFileGroup(file: DiffFileSection) {
    val neon = LocalNeonTheme.current
    var expanded by remember(file.id) { mutableStateOf(true) }
    val stat = remember(file.id) {
        parseNeonDiffStat(null, file.lines.joinToString("\n"))
    }
    val shape = RoundedCornerShape(14.dp)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = shape, fill = neon.codeBg)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Header: edit icon + filename + +N green / −M red.
        Row(
            modifier = Modifier.fillMaxWidth().clickable { expanded = !expanded },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Outlined.Create, null, tint = neon.claude, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(8.dp))
            Text(
                file.path,
                style = MaterialTheme.typography.labelMedium,
                fontFamily = neon.mono,
                color = neon.codeText,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (stat != null) {
                Spacer(Modifier.width(8.dp))
                Text("+${stat.added}", style = MaterialTheme.typography.labelSmall, fontFamily = neon.mono, color = neon.green)
                Spacer(Modifier.width(6.dp))
                Text("−${stat.removed}", style = MaterialTheme.typography.labelSmall, fontFamily = neon.mono, color = neon.red)
            }
        }

        if (expanded) {
            Column(verticalArrangement = Arrangement.spacedBy(0.dp)) {
                file.lines.forEach { line ->
                    val (bg, fg) = when {
                        line.startsWith("+++") || line.startsWith("---") -> neon.surface to neon.textDim
                        line.startsWith("+") -> neon.green.copy(alpha = 0.12f) to neon.green
                        line.startsWith("-") || line.startsWith("−") -> neon.red.copy(alpha = 0.12f) to neon.red
                        line.startsWith("@@") -> neon.accent2.copy(alpha = 0.12f) to neon.accent2
                        else -> Color.Transparent to neon.textDim
                    }
                    Text(
                        line.ifEmpty { " " },
                        modifier = Modifier.fillMaxWidth().background(bg).padding(horizontal = 6.dp, vertical = 1.dp),
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = neon.mono,
                        color = fg,
                    )
                }
            }
        }
    }
}

private fun parseDiffFiles(content: String): List<DiffFileSection> {
    val lines = content.split('\n')
    val sections = mutableListOf<DiffFileSection>()
    var currentPath = "patch.diff"
    val bucket = mutableListOf<String>()

    fun flush() {
        if (bucket.isNotEmpty()) {
            sections += DiffFileSection(
                id = "$currentPath-${sections.size}",
                path = currentPath,
                lines = bucket.toList(),
            )
            bucket.clear()
        }
    }

    lines.forEach { line ->
        if (line.startsWith("diff --git ")) {
            flush()
            val parts = line.split(' ')
            currentPath = parts.getOrNull(3)?.removePrefix("b/") ?: "patch.diff"
            bucket += line
        } else {
            bucket += line
        }
    }
    flush()
    if (sections.isEmpty()) {
        return listOf(DiffFileSection(id = "patch", path = "patch.diff", lines = lines))
    }
    return sections
}

/**
 * Conduit-style composer (Stage 2):
 *  - Single rounded-rect with leading `+`, message field, trailing mic/send
 *  - Send button only appears when draft is non-empty (mic otherwise)
 *  - Agent selector moved to the chat header dropdown, not per-row
 */
@Composable
private fun ConversationComposer(
    draft: String,
    quickReplies: List<String>,
    @Suppress("UNUSED_PARAMETER") agentAccent: Color,
    currentAssistant: String,
    pinnedContexts: List<PinnedContext>,
    pendingAttachments: List<ComposerAttachment>,
    onRemovePinned: (String) -> Unit,
    onRemoveAttachment: (String) -> Unit,
    onAttachClick: () -> Unit,
    onExpandClick: () -> Unit,
    @Suppress("UNUSED_PARAMETER") onSwitchAgent: (String) -> Unit,
    onDraftChange: (String) -> Unit,
    onQuickReply: (String) -> Unit,
    onSend: () -> Unit,
    /** True while the agent is producing output -- the trailing button becomes Stop. */
    agentWorking: Boolean = false,
    /**
     * True when the agent is codex with an active turn: the send button shows
     * the steer glyph (subdirectory/arrow-turn-down-right) instead of the
     * normal up-arrow, indicating that sending will queue + steer.
     */
    sendIsSteer: Boolean = false,
    /** Interrupt the agent's current turn (the Stop button). */
    onStop: () -> Unit = {},
) {
    val neon = LocalNeonTheme.current
    val hasDraft = draft.trim().isNotEmpty()
    Column(
        modifier = Modifier
            .fillMaxWidth()
            // Accent-tinted halo around the composer cluster (neon glow
            // colour). Sits BEFORE the background fill so the shadow
            // projects outside the composer's solid backdrop.
            .shadow(
                elevation = 10.dp,
                shape = RectangleShape,
                ambientColor = neon.accent.copy(alpha = 0.45f),
                spotColor = neon.accent.copy(alpha = 0.55f),
            )
            // No color seam where chat meets the keyboard (iOS #236
            // parity): paint the composer cluster with the SAME backdrop
            // as the chat surface (the wrapping `surfaceVariant 0.35f`
            // Surface in ProjectScreen) and do it BEFORE `imePadding()`,
            // so the fill extends down through the IME-inset band. Without
            // this the band above the keyboard showed the bare window
            // background — a visible mismatched stripe between the chat
            // list and the keyboard.
            .background(neon.panel)
            // Lift the whole composer cluster (quick-reply chips + pinned
            // context + the input row) above the soft keyboard. The
            // Activity's `adjustResize` shrinks the window when the IME is
            // up so the bottom-anchored composer rides above it; the
            // `imePadding()` here is the edge-to-edge-correct belt to the
            // resize suspenders, so the cluster sits directly above the
            // keyboard regardless of inset-dispatch mode (device bug #19:
            // the input row was occluded while the chips peeked above).
            .imePadding()
            .padding(10.dp)
            .windowInsetsPadding(WindowInsets.navigationBars),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (quickReplies.isNotEmpty()) {
            // Device feedback v0.0.49 (round 2) #1 (Android parity): NO strip
            // background behind the quick replies — the chips float directly
            // over the chat (overlay-style, like the scroll-to-bottom button),
            // matching the iOS change. Each `AssistChip` keeps its own
            // container so it stays tappable and legible; the earlier
            // translucent `Surface` strip still read as a flat bar.
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                quickReplies.forEach { reply ->
                    Text(
                        reply,
                        modifier = Modifier
                            .clip(RoundedCornerShape(50))
                            .background(neon.surface)
                            .border(1.dp, neon.borderStrong, RoundedCornerShape(50))
                            .clickable { onQuickReply(reply) }
                            .padding(horizontal = 14.dp, vertical = 8.dp),
                        style = MaterialTheme.typography.labelLarge,
                        fontFamily = neon.sans,
                        color = neon.accent,
                    )
                }
            }
        }

        // Pinned contexts strip — shows above the input row when one or
        // more contexts are pinned. Hides itself when empty.
        ContextBar(contexts = pinnedContexts, onRemove = onRemovePinned)

        // Pending attachments preview — same chip shape as context, but
        // lives inline so it dismisses on send.
        if (pendingAttachments.isNotEmpty()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                pendingAttachments.forEach { att ->
                    PendingAttachmentChip(attachment = att) { onRemoveAttachment(att.id) }
                }
            }
        }

        Row(
            verticalAlignment = Alignment.Bottom,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(26.dp))
                .background(neon.surface)
                .border(1.dp, neon.borderStrong, RoundedCornerShape(26.dp))
                .padding(horizontal = 8.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
                FilledIconButton(
                    onClick = onAttachClick,
                    colors = androidx.compose.material3.IconButtonDefaults.filledIconButtonColors(
                        containerColor = neon.surface2,
                        contentColor = neon.accent,
                    ),
                    modifier = Modifier.size(36.dp),
                ) {
                    Icon(Icons.Default.Add, contentDescription = "Attach")
                }
                BasicTextField(
                    value = draft,
                    onValueChange = onDraftChange,
                    textStyle = MaterialTheme.typography.bodyMedium.copy(
                        color = neon.text,
                        fontFamily = neon.sans,
                    ),
                    cursorBrush = androidx.compose.ui.graphics.SolidColor(neon.accent),
                    decorationBox = { inner ->
                        Box(modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp, horizontal = 4.dp)) {
                            if (draft.isEmpty()) {
                                Text(
                                    "Message $currentAssistant…",
                                    style = MaterialTheme.typography.bodyMedium,
                                    fontFamily = neon.sans,
                                    color = neon.textFaint,
                                )
                            }
                            inner()
                        }
                    },
                    maxLines = 6,
                    modifier = Modifier.weight(1f),
                )
                // Expand into the fullscreen editor — mirror of iOS
                // ChatTab's expandButton.
                FilledIconButton(
                    onClick = onExpandClick,
                    colors = androidx.compose.material3.IconButtonDefaults.filledIconButtonColors(
                        containerColor = neon.surface2,
                        contentColor = neon.textDim,
                    ),
                    modifier = Modifier.size(36.dp),
                ) {
                    Icon(Icons.Outlined.Fullscreen, contentDescription = "Expand composer")
                }
                // Trailing slot: voice (empty) vs send (has draft). Pin it to a
                // constant 42.dp box so the row height doesn't change when the
                // mic (42.dp) is swapped for the smaller send button (36.dp) —
                // otherwise the whole composer visibly shrinks the moment you
                // start typing (device bug). The text field still grows the row
                // for multi-line drafts via the Bottom alignment.
                Box(modifier = Modifier.size(42.dp), contentAlignment = Alignment.Center) {
                    when {
                        hasDraft -> FilledIconButton(
                            onClick = onSend,
                            colors = androidx.compose.material3.IconButtonDefaults.filledIconButtonColors(
                                containerColor = neon.accent,
                                contentColor = neon.accentText,
                            ),
                            modifier = Modifier.size(36.dp),
                        ) {
                            // Codex with active turn: steer glyph instead of up-arrow.
                            // Mirrors iOS arrow.turn.down.right affordance.
                            if (sendIsSteer) {
                                Icon(
                                    Icons.AutoMirrored.Filled.KeyboardArrowRight,
                                    contentDescription = "Queue and steer",
                                )
                            } else {
                                Icon(Icons.Default.KeyboardArrowUp, contentDescription = "Send")
                            }
                        }
                        // Empty composer while the agent is producing output: the
                        // send affordance becomes a Stop button that interrupts the
                        // current turn (how Claude's own app / codex behave). Typing
                        // flips it back to Send so the user can still queue the next
                        // message; idle + empty shows the voice mic.
                        agentWorking -> FilledIconButton(
                            onClick = onStop,
                            colors = androidx.compose.material3.IconButtonDefaults.filledIconButtonColors(
                                containerColor = neon.accent,
                                contentColor = neon.accentText,
                            ),
                            modifier = Modifier.size(36.dp),
                        ) {
                            Icon(Icons.Default.Stop, contentDescription = "Stop")
                        }
                        else -> InlineVoiceButton { transcript ->
                            val trimmed = transcript.trim()
                            if (trimmed.isNotEmpty()) {
                                val next = if (draft.isBlank()) trimmed else "$draft $trimmed"
                                onDraftChange(next)
                            }
                        }
                    }
                }
        }
    }
}

/**
 * "Queued Next" panel -- shows above the composer when one or more messages
 * are queued while a turn is active. Each card shows a truncated preview,
 * a status badge, an optional Steer button (codex only), and an X to cancel.
 *
 * Badge tints match the spec:
 *   Queued   = accent (neon.accent)
 *   Steering = accentBright (brightest; button disabled)
 *   Retrying = warning/orange (MaterialTheme.colorScheme.error tinted)
 *
 * Mirror of iOS `QueuedNextPanel`. Copy strings are spec-exact.
 */
@Composable
private fun QueuedNextPanel(
    entries: List<sh.nikhil.conduit.PendingChat>,
    supportsSteer: Boolean,
    onSteer: (localId: String) -> Unit,
    onCancel: (localId: String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val neon = LocalNeonTheme.current
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 10.dp, vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        // Header: "Queued Next" with optional count pill when >1 entry.
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                "Queued Next",
                style = MaterialTheme.typography.labelSmall,
                color = neon.textDim,
                fontFamily = neon.sans,
            )
            if (entries.size > 1) {
                Text(
                    "${entries.size}",
                    modifier = Modifier
                        .clip(RoundedCornerShape(50))
                        .background(neon.surface2)
                        .padding(horizontal = 6.dp, vertical = 1.dp),
                    style = MaterialTheme.typography.labelSmall,
                    color = neon.accent,
                    fontFamily = neon.sans,
                )
            }
        }
        entries.forEach { entry ->
            QueuedNextCard(
                entry = entry,
                supportsSteer = supportsSteer,
                onSteer = { onSteer(entry.localId) },
                onCancel = { onCancel(entry.localId) },
            )
        }
    }
}

@Composable
private fun QueuedNextCard(
    entry: sh.nikhil.conduit.PendingChat,
    supportsSteer: Boolean,
    onSteer: () -> Unit,
    onCancel: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    // Badge label + tint per spec.
    val (badgeLabel, badgeColor) = when (entry.kind) {
        PendingChatKind.steering -> "Steering" to neon.accentBright
        PendingChatKind.retrying -> "Retrying" to neon.yellow
        else -> "Queued" to neon.accent
    }
    val steerEnabled = supportsSteer && entry.kind != PendingChatKind.steering

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(neon.surface)
            .border(1.dp, neon.borderStrong, RoundedCornerShape(10.dp))
            .padding(horizontal = 10.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Message preview (up to 2 lines).
        Text(
            text = entry.message,
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.bodySmall,
            color = neon.text,
            fontFamily = neon.sans,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        // Status badge.
        Text(
            text = badgeLabel,
            modifier = Modifier
                .clip(RoundedCornerShape(50))
                .background(badgeColor.copy(alpha = 0.15f))
                .padding(horizontal = 6.dp, vertical = 2.dp),
            style = MaterialTheme.typography.labelSmall,
            color = badgeColor,
            fontFamily = neon.sans,
        )
        // Steer button (codex only, disabled while in-flight).
        // Icon + "Steer" label, mirrors iOS arrow.turn.down.right + Text("Steer").
        if (supportsSteer) {
            val steerColor = if (steerEnabled) neon.accent else neon.textFaint
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(50))
                    .then(
                        if (steerEnabled) Modifier.clickable(onClick = onSteer)
                        else Modifier
                    )
                    .padding(horizontal = 6.dp, vertical = 3.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = "Steer",
                    tint = steerColor,
                    modifier = Modifier.size(14.dp),
                )
                Text(
                    "Steer",
                    style = MaterialTheme.typography.labelSmall,
                    color = steerColor,
                    fontFamily = neon.sans,
                )
            }
        }
        // Cancel (X) button.
        androidx.compose.material3.IconButton(
            onClick = onCancel,
            modifier = Modifier.size(28.dp),
        ) {
            Icon(
                Icons.Outlined.Close,
                contentDescription = "Cancel queued message",
                tint = neon.textFaint,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

@Composable
private fun PendingAttachmentChip(
    attachment: ComposerAttachment,
    onRemove: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(50),
        color = MaterialTheme.colorScheme.tertiaryContainer.copy(alpha = 0.55f),
    ) {
        Row(
            modifier = Modifier.padding(start = 10.dp, end = 2.dp, top = 4.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column {
                Text(
                    attachment.filename,
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    humanReadableSize(attachment.sizeBytes),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            androidx.compose.material3.IconButton(
                onClick = onRemove,
                modifier = Modifier.size(24.dp),
            ) {
                Icon(
                    Icons.Outlined.Close,
                    contentDescription = "Remove attachment ${attachment.filename}",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(14.dp),
                )
            }
        }
    }
}

/** Human-friendly byte count for the attachment chip ("12 KB", "3.4 MB"). */
internal fun humanReadableSize(bytes: Int): String = when {
    bytes < 1024 -> "$bytes B"
    bytes < 1024 * 1024 -> "${bytes / 1024} KB"
    else -> String.format("%.1f MB", bytes / (1024.0 * 1024.0))
}

private object QuickReplyDetector {
    fun suggestions(events: List<ConversationItem>): List<String> {
        val source = events
            .asReversed()
            .firstOrNull { ev ->
                val role = ev.role.lowercase()
                role == "assistant" || role == "tool"
            }
            ?.content
            ?.lowercase()
            ?: return listOf("Continue", "Summarize next steps")

        val chips = linkedSetOf<String>()
        if ("confirm" in source || "proceed" in source || "continue" in source) {
            chips += "Proceed"
            chips += "Hold for review"
        }
        if ("error" in source || "failed" in source || "exception" in source) {
            chips += "Show full error log"
            chips += "Retry with diagnostics"
        }
        if ("test" in source || "ci" in source) {
            chips += "Run targeted tests first"
            chips += "Run full suite"
        }
        if ("choose" in source || "option" in source || "which" in source) {
            chips += "Pick the recommended option"
            chips += "Explain trade-offs"
        }
        if (chips.isEmpty()) {
            chips += "Continue"
            chips += "Summarize next steps"
        }
        return chips.take(4)
    }
}
