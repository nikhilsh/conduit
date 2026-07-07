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
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.outlined.Chat
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
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme

import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
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
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.drawscope.Stroke
import sh.nikhil.conduit.FeatureFlags
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.PendingChatKind
import sh.nikhil.conduit.PinnedContext
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.SubagentEntry
import sh.nikhil.conduit.Telemetry
import sh.nikhil.conduit.auth.OAuthProvider
import sh.nikhil.conduit.descriptorFor
import sh.nikhil.conduit.sortedByConversationTs
import sh.nikhil.conduit.stripPendingSentinel
import sh.nikhil.conduit.tsEpochMillis
import sh.nikhil.conduit.ui.components.ConduitRunningPill
import sh.nikhil.conduit.ui.components.ConduitTaskRow
import sh.nikhil.conduit.ui.components.ConduitTaskStatus
import sh.nikhil.conduit.ui.components.runningTaskCount
import kotlinx.coroutines.delay
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

// Made non-private (was file-private) so PipelineMonitorScreen's
// Result card (#907, pairs with #906) can reuse MarkdownBlock for the
// final step output instead of forking a renderer.
sealed class ConversationRole {
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
    // Streaming overlay: partial assistant content from chat_streaming
    // view_events, shown before the final on_chat_event commits the message.
    val streamingMessageMap by store.streamingMessage.collectAsState()
    val streamingOverlayContent: String? = streamingMessageMap[session.id]
        ?.takeIf { it.isNotEmpty() }
    // Current turn phase ("writing", "working", "") -- drives distinct indicator states.
    val turnPhaseMap by store.turnPhaseBySession.collectAsState()
    val turnPhase: String? = turnPhaseMap[session.id]
    // Accumulated thinking/reasoning text (thinking_streaming view_events, Claude only).
    // Ephemeral: cleared at turn end alongside streamingMessage.
    val thinkingMap by store.thinkingBySession.collectAsState()
    val thinkingText: String? = thinkingMap[session.id]?.takeIf { it.isNotEmpty() }
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
    // Fingerprints of answered pending-input cards, now stored in SessionStore
    // so they persist across chat view dismissals within the same app launch.
    // Mirror of iOS SessionStore.answeredPendingBySession.
    val answeredPendingBySession by store.answeredPendingBySession.collectAsState()
    val answeredPendingTextBySession by store.answeredPendingTextBySession.collectAsState()
    val answeredPendingFingerprintsForSession = answeredPendingBySession[session.id] ?: emptySet()
    val answeredPendingTextForSession = answeredPendingTextBySession[session.id] ?: emptyMap()
    // IDs resolved via out-of-band approval paths (ApprovalsScreen, push
    // notification action). Folds in immediately so the inline card flips
    // to answered without waiting for the broker echo. Mirror of iOS
    // `SessionStore.resolvedPendingInputIDs`.
    val resolvedPendingInputIDs by store.resolvedPendingInputIDs.collectAsState()
    val credentialSourceMap by store.credentialSource.collectAsState()
    // §D 401 handling: "Sign in on this box" banner state.
    val agentAuthFailureMap by store.agentAuthFailure.collectAsState()
    // Running-tasks pill above the composer (design handoff session_tasks
    // PR2). Gate data doesn't exist yet -- gatedCount is always 0 here.
    val subagentRosterMap by store.subagentRoster.collectAsState()
    var showTasksSheet by remember { mutableStateOf(false) }
    var showAgentLogin by remember { mutableStateOf(false) }
    var loginAutoStartProvider by remember { mutableStateOf<OAuthProvider?>(null) }
    val listState = rememberLazyListState()

    // Backward-pagination state. Observe the store's pagination map so the
    // near-top trigger fires whenever hasMoreHistory becomes true and the user
    // scrolls up. Only populated for archived sessions (exited transcript view);
    // live sessions leave this entry absent so the trigger never fires there.
    val paginationStateMap by store.paginationState.collectAsState()
    val pagState = paginationStateMap[session.id]
    val hasMoreHistory = pagState?.hasMoreHistory ?: false
    val oldestLoadedTs = pagState?.oldestLoadedTs ?: 0L

    // Guard flag: true while a fetchOlderConversation call is in flight.
    var isLoadingOlder by remember { mutableStateOf(false) }
    // Settled flag: prevents the near-top trigger from firing during the
    // initial bottom-anchor scroll. Set to true only after the initial
    // session-open LaunchedEffect has completed its scroll. Keyed on
    // session.id so switching sessions resets it.
    var hasSettledAfterOpen by remember(session.id) { mutableStateOf(false) }

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
    // re-pins the bottom. Also include streaming overlay length so the
    // overlay growth triggers auto-scroll follow.
    val streamingSignature = Triple(
        events.size,
        events.lastOrNull()?.content?.length ?: 0,
        streamingOverlayContent?.length ?: 0,
    )

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
    val showCommandDetail by appearanceStore.showCommandDetail.collectAsState()
    // §10 / §10b command-run Mono block flag (chat.commandRunBlock, default OFF).
    val commandRunBlock by appearanceStore.commandRunBlock.collectAsState()
    // Working indicator style (debug.workingIndicatorStyle, default "Spine").
    val workingIndicatorStyleRaw by appearanceStore.workingIndicatorStyle.collectAsState()
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

    // Switching to an already-cached session: streamingSignature may not change
    // (same size/last-length), so the follow effects above don't re-fire and the
    // list opens at the top. Key on the session id to pin the bottom on switch.
    // Also marks hasSettledAfterOpen so the near-top pagination trigger knows
    // the initial scroll has completed and user-driven scrolls can be trusted.
    LaunchedEffect(session.id) {
        if (events.isNotEmpty()) {
            scrollToTrueBottom(listState)
        }
        hasSettledAfterOpen = true
    }

    // WS background throttle: resume when this chat is in composition, pause
    // on dispose (screen navigated away). Skip read-only (no live WS to manage).
    if (!readOnly) {
        DisposableEffect(session.id) {
            store.resumeSession(session.id)
            onDispose { store.pauseSession(session.id) }
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

    // Backward-pagination near-top trigger. Fires when the user has
    // actually scrolled up (firstVisibleItemIndex <= 2) AND the initial
    // bottom-anchor has already settled (hasSettledAfterOpen) AND there are
    // more pages AND we're not already loading one. The hasSettledAfterOpen
    // gate prevents the trigger from misfiring immediately on open because
    // the list starts at item 0 before scrollToTrueBottom runs.
    //
    // Viewport-pin after prepend: capture firstVisibleItemIndex + scrollOffset
    // before the prepend, then after the new items land, jump to
    // (firstVisible + newItemCount) to keep the visible message stable.
    LaunchedEffect(listState, hasMoreHistory, hasSettledAfterOpen) {
        snapshotFlow { listState.firstVisibleItemIndex to listState.firstVisibleItemScrollOffset }
            .collect { (visibleIndex, visibleOffset) ->
                if (!hasSettledAfterOpen) return@collect
                if (!hasMoreHistory) return@collect
                if (isLoadingOlder) return@collect
                if (oldestLoadedTs <= 0L) return@collect
                if (visibleIndex > 2) return@collect
                // Trigger: user is near the top and there are older pages.
                val countBefore = listState.layoutInfo.totalItemsCount
                isLoadingOlder = true
                Telemetry.breadcrumb(
                    "pagination", "older_trigger",
                    mapOf("session" to session.id, "before_ts" to oldestLoadedTs.toString()),
                )
                scope.launch {
                    try {
                        val result = store.fetchOlderConversation(session.id, oldestLoadedTs)
                        if (result != null) {
                            val (newItems, _) = result
                            // Pin the viewport so the visible message doesn't jump after
                            // prepend. New items land at the front; shift by their count.
                            val addedCount = newItems.size
                            if (addedCount > 0 && countBefore > 0) {
                                listState.scrollToItem(
                                    index = (visibleIndex + addedCount).coerceAtLeast(0),
                                    scrollOffset = visibleOffset,
                                )
                            }
                        }
                    } finally {
                        isLoadingOlder = false
                    }
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
        // class). On phone use full width; on tablet constrain and center
        // so the thread doesn't span the full wide display.
        // Gate on sw>=600dp so a phone in landscape (wide but small sw) stays full-width.
        val isTablet = LocalConfiguration.current.smallestScreenWidthDp >= 600 && maxWidth >= 840.dp
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
                // "Loading earlier messages..." progress row — shown at the top
                // of the list while a backward-pagination fetch is in flight.
                if (isLoadingOlder) {
                    item {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 8.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            androidx.compose.foundation.layout.Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                androidx.compose.material3.CircularProgressIndicator(
                                    modifier = Modifier.size(14.dp),
                                    strokeWidth = 2.dp,
                                    color = LocalNeonTheme.current.accent,
                                )
                                Text(
                                    text = "Loading earlier messages...",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = LocalNeonTheme.current.textDim,
                                    fontFamily = LocalNeonTheme.current.sans,
                                )
                            }
                        }
                    }
                }

                // Credential-source banner: shown when the broker is using the
                // app-forwarded credential because the box is not logged in.
                if (credentialSourceMap[session.id] == "app_forwarded") {
                    item {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .background(MaterialTheme.colorScheme.tertiaryContainer.copy(alpha = 0.4f))
                                .padding(horizontal = 16.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Icon(
                                imageVector = Icons.Outlined.Warning,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.tertiary,
                                modifier = Modifier.size(16.dp),
                            )
                            Text(
                                text = "Using your app login — box credential missing",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onTertiaryContainer,
                            )
                        }
                    }
                }

                if (events.isEmpty()) {
                    item { EmptyConversationCard(assistant = session.assistant) }
                } else {
                    // Fix 10: in arm B, fold runs of 2+ consecutive tool turns
                    // into one cluster unit; arm A and lone tools stay inline.
                    // When command detail is hidden, ALL contiguous tool runs
                    // (including lone single commands) collapse into a cluster.
                    // §10 flag: when commandRunBlock is ON, lone commands also
                    // cluster so they render in the Mono surface.
                    val hideCommands = !showCommandDetail
                    val renderUnits = groupChatUnits(
                        roles = events.map { it.role },
                        signature = signatureArm,
                        hideCommands = hideCommands,
                        monoBlock = commandRunBlock,
                    )
                    items(renderUnits.size) { unitIndex ->
                        when (val unit = renderUnits[unitIndex]) {
                            is ChatRenderUnit.ToolCluster ->
                                // Arm B: typed-step ToolLedger replaces the legacy
                                // NeonMonoCommandCluster / ToolClusterCard for all users.
                                ToolLedger(
                                    items = unit.indices.map { events[it] },
                                )
                            is ChatRenderUnit.Single -> {
                                val index = unit.index
                                val previousRole = if (index > 0) events[index - 1].role else null
                                val ev = events[index]
                                ConversationEventRow(
                                    ev = ev,
                                    agentAccent = agentAccent,
                                    isContinuation = previousRole?.lowercase() == ev.role.lowercase(),
                                    pendingAnswered = ev.id in answeredPendingIds
                                        || pendingContentFingerprint(ev) in answeredPendingFingerprintsForSession
                                        || ev.id in resolvedPendingInputIDs,
                                    answeredText = answeredPendingTextForSession[pendingContentFingerprint(ev)],
                                    // A pending-input answer is delivered as the user's
                                    // next chat message — the broker matches it to the
                                    // blocked AskUserQuestion control request. Mirror of
                                    // iOS (`store.sendChat`), not the draft-fill path the
                                    // composer's quick-reply chips use.
                                    onAnswerPending = { msg ->
                                        store.markPendingInputAnswered(
                                            session.id,
                                            pendingContentFingerprint(ev),
                                            msg,
                                        )
                                        store.sendChat(session.id, msg)
                                    },
                                    onPendingAnswered = {
                                        answeredPendingIds = answeredPendingIds + ev.id
                                    },
                                    subagentRoster = subagentRosterMap[session.id] ?: emptyList(),
                                    onOpenTasks = { showTasksSheet = true },
                                )
                            }
                        }
                    }
                }
                // Streaming overlay: shows in-progress assistant content
                // from chat_streaming view_events before the final
                // on_chat_event commits the message to the store.
                // Old brokers never send chat_streaming so this is nil.
                if (!readOnly && streamingOverlayContent != null) {
                    item(key = "streaming-overlay") {
                        StreamingSpineRow(
                            content = streamingOverlayContent,
                            thinking = thinkingText,
                        )
                    }
                }
                // "Agent is typing…" — last content row (before the
                // trailing spacer) so when pinned to the bottom it's
                // followed by autoscroll like any new content.
                // Show indicator only when there is no streaming overlay
                // content (i.e. the pre-first-token thinking phase).
                if (showTyping && streamingOverlayContent == null) {
                    item {
                        TypingIndicatorRow(
                            session.assistant,
                            agentAccent,
                            turnPhase,
                            workingIndicatorStyleRaw,
                            thinkingPeek = thinkingPeekLine(thinkingText),
                        )
                    }
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
            // §D 401 handling: "Sign in on this box" banner shown above the
            // composer when a 401 / auth-failure was detected in an incoming
            // assistant/result event. Cleared bidirectionally: when the user
            // sends a new turn OR when the agent replies without a 401 (out-
            // of-band sign-in on the box). Mirror of iOS `agentAuthBanner`.
            val authFailureProvider = agentAuthFailureMap[session.id]
            if (authFailureProvider != null) {
                val neon = LocalNeonTheme.current
                val providerLabel = if (authFailureProvider == OAuthProvider.ANTHROPIC) "Claude" else "Codex"
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable {
                            loginAutoStartProvider = authFailureProvider
                            showAgentLogin = true
                        }
                        .background(neon.surface)
                        .padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Icon(
                        imageVector = Icons.Outlined.AccountCircle,
                        contentDescription = null,
                        tint = neon.accent,
                        modifier = Modifier.size(20.dp),
                    )
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            "Sign in to $providerLabel on this box",
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = neon.sans,
                            fontWeight = FontWeight.SemiBold,
                            color = neon.accent,
                        )
                        Text(
                            "This box rejected the agent credential (401). Tap to sign in.",
                            style = MaterialTheme.typography.labelSmall,
                            fontFamily = neon.sans,
                            color = neon.textDim,
                        )
                    }
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                        contentDescription = null,
                        tint = neon.textDim,
                        modifier = Modifier.size(16.dp),
                    )
                }
            }
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
            // Running-tasks pill -- live count of this session's background
            // tasks from the subagent roster (design handoff session_tasks
            // PR2). Gate data doesn't exist yet, so gatedCount is always 0;
            // tapping opens the [TasksSheet] wired below (PR3).
            val runningCount = remember(subagentRosterMap, session.id) {
                runningTaskCount(subagentRosterMap[session.id]?.map { it.status } ?: emptyList())
            }
            Box(
                modifier = Modifier.fillMaxWidth(),
                contentAlignment = Alignment.TopStart,
            ) {
                ConduitRunningPill(
                    runningCount = runningCount,
                    onTap = { showTasksSheet = true },
                )
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

    // §D 401 handling: agent login sheet opened from the "Sign in on this
    // box" banner. Pre-selected to the failing provider so the user lands
    // on the correct OAuth flow. Mirror of iOS `showAgentLogin` sheet.
    if (showAgentLogin && !readOnly) {
        AgentLoginSheet(
            store = store,
            autoStartProvider = loginAutoStartProvider,
            onAutoStartConsumed = { loginAutoStartProvider = null },
            onDismiss = { showAgentLogin = false },
        )
    }

    // Tasks sheet (design handoff session_tasks PR3): grouped view of this
    // session's background tasks, opened from the RunningPill tap above.
    // `!readOnly` mirrors the `showAgentLogin` guard just above -- the pill
    // that sets `showTasksSheet` only renders inside the live composer, but
    // this stays defensive against a stale flag surviving a mode flip.
    if (showTasksSheet && !readOnly) {
        TasksSheet(
            roster = subagentRosterMap[session.id] ?: emptyList(),
            sessionAgent = session.assistant,
            onDismiss = { showTasksSheet = false },
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
// internal (not private): also used by FoundSessionsSheet's WatchLiveSheet so the
// watch transcript pins the true bottom on open (same 3-retry + final snap).
internal suspend fun scrollToTrueBottom(listState: androidx.compose.foundation.lazy.LazyListState) {
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
 * Internal so [groupChatUnits] is unit-testable via [CommandRunBlockTest].
 */
internal sealed class ChatRenderUnit {
    data class Single(val index: Int) : ChatRenderUnit()
    data class ToolCluster(val indices: List<Int>) : ChatRenderUnit()
}

/**
 * Coalesce consecutive tool-role events into clusters.
 *
 * When [hideCommands] is true (Show command detail OFF), ALL contiguous tool
 * runs — including lone single commands — collapse into a [ToolCluster] so
 * they render as a compact muted footnote line. This applies regardless of the
 * [signature] arm.
 *
 * When [monoBlock] is true (chat.commandRunBlock ON), ALL contiguous tool
 * runs — including lone single commands — collapse into a [ToolCluster] so
 * they render in the §10 Mono surface. This is independent of [hideCommands].
 *
 * When [hideCommands] is false and [monoBlock] is false and [signature] is
 * true (arm B), only runs of 2+ consecutive tool turns collapse; a lone tool
 * stays inline.
 *
 * When [hideCommands] is false and [monoBlock] is false and [signature] is
 * false (arm A), every event is rendered inline (no clustering).
 *
 * Pure + index-based so it is unit-testable and keeps the continuation/key
 * logic intact.
 */
internal fun groupChatUnits(
    roles: List<String>,
    signature: Boolean,
    hideCommands: Boolean = false,
    monoBlock: Boolean = false,
): List<ChatRenderUnit> {
    val collapseAll = hideCommands || monoBlock
    if (!collapseAll && !signature) return roles.indices.map { ChatRenderUnit.Single(it) }
    val units = mutableListOf<ChatRenderUnit>()
    var i = 0
    while (i < roles.size) {
        if (roles[i].lowercase() == "tool") {
            var j = i
            while (j < roles.size && roles[j].lowercase() == "tool") j++
            val run = (i until j).toList()
            when {
                // hideCommands or monoBlock: collapse even a single tool turn.
                collapseAll -> units.add(ChatRenderUnit.ToolCluster(run))
                // signature arm B: only 2+ consecutive tool turns collapse.
                run.size >= 2 -> units.add(ChatRenderUnit.ToolCluster(run))
                else -> units.add(ChatRenderUnit.Single(run[0]))
            }
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
    if (chatLog.isEmpty()) return dropPendingInputEchoes(conversation)

    val typedFingerprints = conversation
        .map { "${it.role.lowercase()}|${it.content}" }
        .toSet()
    // Track keys seen within chatLog to deduplicate repeated replays of the
    // same resolved entry (each WS reconnect replays the transcript).
    val seenChatLogKeys = HashSet<String>()
    val synthetic = chatLog.mapIndexedNotNull { idx, ev ->
        // Strip only the needs-input sentinel from content (for display), but
        // use PendingQuestions.strippedKey (strips BOTH sentinel AND resolved
        // marker) for the dedup fingerprint. This makes a resolved chatLog
        // entry ("[[conduit:needs-input]]\n[[conduit:resolved]]{...}\ntext")
        // match the typed conversationLog item ("text") that core has already
        // double-stripped, preventing a raw resolved-marker bubble from
        // appearing on each WS reconnect.
        val strippedContent = stripPendingSentinel(ev.content)
        val key = "${ev.role.lowercase()}|${PendingQuestions.strippedKey(ev.content)}"
        if (key in typedFingerprints) {
            null
        } else if (!seenChatLogKeys.add(key)) {
            null // deduplicate within chatLog (repeated replay)
        } else {
            val isPendingInput = ev.content.contains(PendingQuestions.PENDING_INPUT_SENTINEL)
            ConversationItem(
                id = "chatlog-${ev.ts}-$idx",
                role = ev.role,
                kind = if (ev.role.lowercase() == "tool") "tool"
                       else if (isPendingInput) "pending_input"
                       else "message",
                status = "done",
                content = strippedContent,
                ts = ev.ts,
                files = ev.files,
                toolName = null,
                command = null,
                exitCode = null,
                durationMs = null,
                diffSummary = null,
                pendingOptions = if (isPendingInput) ConversationRenderer.extractPendingOptions(strippedContent) else emptyList(),
                sourceAgent = null,
                targetAgent = null,
                taskText = null,
                resultSummary = null,
                planSteps = emptyList(),
            )
        }
    }
    if (synthetic.isEmpty()) return dropPendingInputEchoes(conversation)
    // Interleave the synthesized chat-event items into the typed log in true
    // chronological order. Carry-forward sort (see [sortedByConversationTs]):
    // a chat event whose `ts` we can't parse keeps its arrival position
    // instead of collapsing to 0L and jumping above the user turn that
    // preceded it (device bug: agent reply / command card rendered before
    // the user's own prompt).
    return dropPendingInputEchoes((conversation + synthetic).sortedByConversationTs { it.ts })
}

/**
 * Mirror of iOS `dropPendingInputEchoes`. A `pending_input` choice card and a
 * plain bubble that merely echoes the same question can both reach the merged
 * log (the synthesized chatLog item and the typed card differ enough to dodge
 * the role+content fingerprint). Two passes:
 *  (a) collapse duplicate `pending_input` items sharing the same stripped
 *      prompt+options key down to one card; among duplicates the RESOLVED card
 *      (carrying a `[[conduit:resolved]]` marker line) wins over the raw
 *      original so the answered state is never dropped. The survivor occupies
 *      the FIRST occurrence's position.
 *  (b) drop any non-`pending_input` item whose trimmed content is contained in
 *      any surviving `pending_input` stripped body (length floor of 8 chars so
 *      short replies like "yes"/"ok" are never nuked). Distinct prompts are
 *      preserved.
 */
internal fun dropPendingInputEchoes(items: List<ConversationItem>): List<ConversationItem> {
    // Fast path: no pending-input cards → nothing to dedup or echo-drop. Return
    // the SAME list reference unchanged (callers rely on referential identity:
    // mergedConversation's empty-chatLog path and MergedConversationTest).
    if (items.none { it.kind == "pending_input" }) return items
    // --- Pass 1: pick the winning pending_input per normalized key -----------
    // Key = stripped content (sentinel + resolved-marker lines removed) +
    //       sorted options joined with US (unit separator). This makes the
    //       original and resolved versions of the same card share one key.
    data class PendingKey(val strippedContent: String, val sortedOptions: String)

    fun itemKey(item: ConversationItem): PendingKey = PendingKey(
        strippedContent = PendingQuestions.strippedKey(item.content),
        sortedOptions = item.pendingOptions.sorted().joinToString(""),
    )

    fun hasResolutionMarker(content: String): Boolean =
        content.split("\n").any { it.trim().startsWith(PendingQuestions.PENDING_RESOLVED_MARKER) }

    // First pass: determine winner per key (resolved beats unanswered).
    val winner = LinkedHashMap<PendingKey, ConversationItem>()
    for (item in items) {
        if (item.kind != "pending_input") continue
        val key = itemKey(item)
        val existing = winner[key]
        if (existing == null) {
            winner[key] = item
        } else if (hasResolutionMarker(item.content) && !hasResolutionMarker(existing.content)) {
            // Upgrade: resolved card beats the unanswered original.
            winner[key] = item
        }
    }

    // Second pass: emit items in order, replacing each pending_input with its
    // winner at first occurrence, dropping subsequent duplicates.
    val emittedKeys = HashSet<PendingKey>()
    var collapsed = 0
    val deduped = items.mapNotNull { item ->
        if (item.kind != "pending_input") return@mapNotNull item
        val key = itemKey(item)
        if (emittedKeys.contains(key)) { collapsed++; return@mapNotNull null }
        emittedKeys += key
        winner[key] ?: item
    }
    if (collapsed > 0) {
        Telemetry.breadcrumb(
            "chat", "pending_input dedup collapsed",
            mapOf("count" to collapsed.toString()),
        )
    }

    // --- Pass 2: drop plain-message echoes of any surviving pending body -----
    val pendingBodies = deduped
        .filter { it.kind == "pending_input" }
        .map { PendingQuestions.strippedKey(it.content) }
        .filter { it.length >= 8 }
    // Exact-option-match filter: drop user messages that are exact matches
    // of any pending_input option regardless of the 8-char floor. Handles
    // short answers ("Yes", "No", "1") from broker's appendUser.
    val pendingOptionSet = deduped
        .filter { it.kind == "pending_input" }
        .flatMap { it.pendingOptions }
        .map { it.trim() }
        .filter { it.isNotEmpty() }
        .toSet()
    if (pendingBodies.isEmpty() && pendingOptionSet.isEmpty()) return deduped

    return deduped.filter { item ->
        if (item.kind == "pending_input") return@filter true
        val c = item.content.trim()
        // Exact option match: drop regardless of length floor (covers short
        // answers like "Yes", "No", "1" that appendUser writes to conversation.jsonl).
        // Also drop multi-question answers ("A\nB") where every non-empty line is
        // an option — the submit() path joins per-question answers with "\n".
        if (item.role.lowercase() == "user" && pendingOptionSet.isNotEmpty()) {
            val parts = c.split("\n").map { it.trim() }.filter { it.isNotEmpty() }
            if (parts.isNotEmpty() && parts.all { it in pendingOptionSet }) return@filter false
        }
        if (c.length < 8) return@filter true
        pendingBodies.none { it == c || it.contains(c) }
    }
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
    /** Answer text for the chip label when the card was answered in this
     *  app launch but the view was closed+reopened (no persisted resolution
     *  in transcript yet). Falls back to the persisted resolution answer. */
    answeredText: String? = null,
    /** Deliver a pending-input answer (sends as the user's chat message). */
    onAnswerPending: (String) -> Unit = {},
    /** Record this pending-input card as answered (durable upstream lock). */
    onPendingAnswered: () -> Unit = {},
    /** Live subagent roster for this session (design handoff session_tasks
     *  PR4) -- used to bind a `kind == "subagent"` row to its live task. */
    subagentRoster: List<SubagentEntry> = emptyList(),
    /** Opens the session's Tasks sheet -- the inline task row's tap target.
     *  No per-task transcript surface exists yet, so every row opens the
     *  same sheet as the RunningPill. */
    onOpenTasks: () -> Unit = {},
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
            answeredText = answeredText,
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
        InlineTaskRow(ev = ev, roster = subagentRoster, onOpenTasks = onOpenTasks)
        return
    }
    if (ev.role.lowercase() == "user") {
        val peer = PeerMessage.parse(ev.content)
        if (peer != null) {
            PeerMessageCard(peer)
            return
        }
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
            if (ev.content.contains("Resumed from your terminal")) {
                RecapBanner(ev.content)
            } else {
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
}

/**
 * Prominent banner for the broker-seeded resume-recap system entry.
 *
 * The broker seeds a recap entry with role "system" whenever the user
 * resumes a terminal/found session. Its content always begins with the
 * marker "Resumed from your terminal". Unlike short system notices
 * (session-expired footer, /help) which render as a 2-line faint stub,
 * this entry can be multi-paragraph and must read clearly as a
 * "here is where you left off" summary. We render it as a full-width
 * card with a left accent border, matching the iOS treatment.
 *
 * Detection: [content] contains "Resumed from your terminal" (the
 * stable broker-side prefix; robust to the leading U+21A9 char).
 */
@Composable
private fun RecapBanner(content: String) {
    val neon = LocalNeonTheme.current
    Telemetry.breadcrumb("chat", "recap_banner_render", mapOf("contentLen" to content.length.toString()))
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp)
            .background(neon.surface, shape = RoundedCornerShape(8.dp))
            .drawBehind {
                drawLine(
                    color = neon.accent2,
                    start = Offset(0f, 0f),
                    end = Offset(0f, size.height),
                    strokeWidth = 3.dp.toPx(),
                )
            }
            .padding(start = 12.dp, end = 12.dp, top = 10.dp, bottom = 10.dp),
    ) {
        MarkdownBlock(content, ConversationRole.Assistant)
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
    /** Answer text carried from the SessionStore for same-session-reopen display.
     *  Supplements persistedResolution?.answer for the in-launch (no-transcript) path. */
    answeredText: String? = null,
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
    // Decode the persisted resolution from the transcript (iOS PR #721
    // parity). The broker writes `[[conduit:resolved]]{"answered":true,
    // "answer":"<option>"}` into the item's content right after the sentinel;
    // core strips it on the live path but the HTTP-fetch path keeps it so
    // the card can rehydrate its answered / selected state after close+reopen.
    // On the live path this returns null (marker already stripped by core),
    // which is correct — the ephemeral local state handles optimistic locking.
    val persistedResolution = remember(ev.id, ev.content) {
        PendingQuestions.parsePendingResolution(ev.content)
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
    // sentAnswer: the chosen option text shown in "Sent . <answer>". Seeded
    // from the persisted resolution (app-restart path) or from the in-session
    // store answeredText (same-launch close+reopen path, no transcript marker yet).
    var sentAnswer by remember(ev.id) {
        mutableStateOf(persistedResolution?.answer ?: answeredText)
    }
    // Settled once submitted locally OR recorded answered upstream OR the
    // transcript carries a persisted resolution (rehydration path).
    val submitted = localSubmitted || alreadyAnswered || persistedResolution?.answered == true
    // Pre-populate the selected option highlight from the persisted answer so
    // the answered option renders filled/checked after close+reopen. Only runs
    // once per card (keyed on ev.id); safe to no-op when already seeded.
    LaunchedEffect(ev.id) {
        val answer = persistedResolution?.answer ?: return@LaunchedEffect
        if (questions.size == 1 && !questions[0].multiSelect) {
            if (answer in questions[0].options && selections[0] == null) {
                selections[0] = answer
            }
        }
    }
    Telemetry.breadcrumb(
        "chat", "pending_input_render",
        mapOf(
            "id" to ev.id,
            "submitted" to submitted.toString(),
            "rehydrated" to (persistedResolution?.answered == true).toString(),
        ),
    )

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

    if (submitted) {
        // Compact pill chip once answered — collapses the full card.
        val chipShape = RoundedCornerShape(50)
        val rawAnswer = sentAnswer ?: "Answered"
        val displayText = rawAnswer.split("\n").filter { it.isNotEmpty() }.joinToString(" · ")
        Row(
            modifier = Modifier
                .background(neon.green.copy(alpha = 0.10f), chipShape)
                .border(1.dp, neon.green.copy(alpha = 0.30f), chipShape)
                .padding(horizontal = 11.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Icon(Icons.Filled.CheckCircle, null, tint = neon.green, modifier = Modifier.size(12.dp))
            Text(
                displayText,
                style = MaterialTheme.typography.labelSmall,
                fontFamily = neon.mono,
                fontWeight = FontWeight.Medium,
                color = neon.green,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        return
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
                        dimmed = false,
                        enabled = true,
                        neon = neon,
                        onClick = {
                            if (question.multiSelect) {
                                val cur = multiSelections[qIdx] ?: emptySet()
                                multiSelections[qIdx] =
                                    if (option in cur) cur - option else cur + option
                            } else {
                                selections[qIdx] = option
                                if (!needsSend) submit(listOf(option))
                            }
                        },
                    )
                }
            }
        }
        if (needsSend) {
            val answerable = questions.withIndex().filter { it.value.options.isNotEmpty() }
            val answers = answerable.mapNotNull { answerFor(it.index, it.value) }
            val allAnswered = answers.size == answerable.size
            NeonSendAnswerButton(
                enabled = allAnswered,
                neon = neon,
                onClick = { if (allAnswered) submit(answers) },
            )
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

// ---------------------------------------------------------------------------
// Inline task row (design handoff session_tasks PR4)
// ---------------------------------------------------------------------------
//
// Replaces the old expand/collapse `SubagentCard` with the shared
// [ConduitTaskRow] (PR1) for a `kind == "subagent"` transcript event.
//
// Binding investigation (see PR4 notes, mirrors iOS `ConduitInlineTaskRow`):
// there is NO shared id between a `kind == "subagent"` [ConversationItem]
// and a live [SubagentEntry] on the wire -- the core classifier
// (`looks_like_subagent`) derives the item purely from free-text system
// content ("subagent started: ..."), while the roster
// (`SessionStore.subagentRoster`, `view:"agents"`) is built from separate
// `task_*` stream frames keyed by `task_id`. The broker's task_* handling
// (`broker/internal/session/claudechat.go` + `codexappserver.go`)
// explicitly `continue`s / documents "must NEVER ... emit parent chat
// events" -- so in the CURRENT broker, a `subagent`-kind chat line isn't
// actually produced by a live dispatch at all; this branch only fires for
// legacy/other-source system text matching the classifier's phrasing.
//
// Given that gap, [ConduitInlineTaskLogic.rowModel] does a best-effort
// NAME + RECENCY match against the live roster (substring match on
// name/description, broken by nearest `startedAt` to the event's own
// `ts`); when nothing matches -- the common case -- it falls back to the
// event's own static content/status ("failed" -> Error, else Done, per
// the design intent "no roster match -> treat as done, historic
// transcript"). Unit-tested directly by `ConduitInlineTaskRowLogicTest`.

@Composable
private fun InlineTaskRow(ev: ConversationItem, roster: List<SubagentEntry>, onOpenTasks: () -> Unit) {
    // Elapsed + tail refresh at most once a second -- mirrors the
    // [TasksSheet] ticker (`nowMs` + `LaunchedEffect`/`delay(1000)`).
    var nowMs by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(1000)
            nowMs = System.currentTimeMillis()
        }
    }
    val model = remember(ev, roster, nowMs) {
        ConduitInlineTaskLogic.rowModel(ev, roster, nowMs)
    }
    ConduitTaskRow(
        title = model.title,
        status = model.status,
        elapsed = model.elapsed,
        tail = model.tail,
        onOpen = onOpenTasks,
    )
}

/**
 * Pure mapping logic behind [InlineTaskRow] -- no Compose runtime
 * dependency, unit-tested in `ConduitInlineTaskRowLogicTest` mirroring the
 * [TasksSheetLogic] precedent.
 */
object ConduitInlineTaskLogic {
    /** Lifecycle prefixes the core's `looks_like_subagent` (conversation.rs)
     *  recognizes -- mirrored here so the extracted title strips the same
     *  boilerplate the classifier anchored on. */
    private val subagentPrefixes = listOf(
        "sub-agent started", "sub-agent done", "sub-agent failed",
        "sub-agent running", "sub-agent complete",
        "subagent started", "subagent done", "subagent failed",
        "subagent running", "subagent complete",
    )

    /** Recover the free-text title/description the CLI wrote after a
     *  recognized lifecycle prefix ("subagent started: investigating the
     *  build failure" -> "investigating the build failure"). Falls back to
     *  the first content line, then the old card's placeholder. */
    fun extractedTitle(content: String): String {
        val trimmed = content.trim()
        val lower = trimmed.lowercase()
        if (lower.startsWith("spawning agent")) {
            val rest = trimmed.substring("spawning agent".length).trim(':', ' ')
            if (rest.isNotEmpty()) return rest
        }
        for (prefix in subagentPrefixes) {
            if (lower.startsWith(prefix)) {
                val rest = trimmed.substring(prefix.length).trim(':', ' ')
                if (rest.isNotEmpty()) return rest
            }
        }
        return trimmed.lineSequence().firstOrNull()?.trim()?.takeIf { it.isNotEmpty() } ?: "Subagent activity"
    }

    /** Best-effort correlation to a LIVE roster entry: no shared id exists
     *  (see the file-header note above), so match candidates by
     *  name/description substring, then break ties (or pick among all
     *  entries when nothing matches on text) by nearest `startedAt` to the
     *  event's own `ts`. */
    fun matchingRosterEntry(title: String, eventTs: String, roster: List<SubagentEntry>): SubagentEntry? {
        if (roster.isEmpty()) return null
        val needle = title.lowercase()
        val candidates = roster.filter { entry ->
            val name = entry.name.lowercase()
            val description = entry.description.lowercase()
            (name.isNotEmpty() || description.isNotEmpty()) &&
                ((name.isNotEmpty() && (needle.contains(name) || name.contains(needle))) ||
                    (description.isNotEmpty() && (needle.contains(description) || description.contains(needle))))
        }
        val pool = candidates.ifEmpty { roster }
        if (eventTs.isEmpty()) return pool.firstOrNull()
        val eventEpochMs = tsEpochMillis(eventTs)
        return pool.minByOrNull { entry ->
            if (entry.startedAt.isEmpty()) Long.MAX_VALUE
            else kotlin.math.abs(tsEpochMillis(entry.startedAt) - eventEpochMs)
        }
    }

    /** The inline row's fully-resolved render inputs. */
    data class RowModel(
        val title: String,
        val status: ConduitTaskStatus,
        val elapsed: String?,
        val tail: String?,
        /** True when bound to a live roster entry (elapsed ticks, tail
         *  tracks `lastTool`); false for the static last-resort fallback. */
        val isLive: Boolean,
    )

    /** Map a `kind == "subagent"` [ConversationItem] (+ the live roster) to
     *  the row's render inputs. [nowMs] is injectable so callers/tests can
     *  pin a stable elapsed value. */
    fun rowModel(ev: ConversationItem, roster: List<SubagentEntry>, nowMs: Long): RowModel {
        val title = extractedTitle(ev.content)
        val entry = matchingRosterEntry(title, ev.ts, roster)
        if (entry != null) {
            val status = TasksSheetLogic.statusFromRaw(entry.status)
            val elapsed = if (status == ConduitTaskStatus.Running && entry.startedAt.isNotEmpty()) {
                TasksSheetLogic.elapsedLabel(((nowMs - tsEpochMillis(entry.startedAt)) / 1000).coerceAtLeast(0))
            } else {
                null
            }
            val liveTail = entry.lastTool.trim()
            return RowModel(
                title = entry.name.ifEmpty { title },
                status = status,
                elapsed = elapsed,
                tail = liveTail.ifEmpty { null },
                isLive = true,
            )
        }
        // Last resort: no live roster match (the common case -- see the
        // file header) -- render from the event's own static content.
        // "failed" -> Error, everything else -> Done (design intent:
        // "no roster match -> treat as done, historic transcript").
        val staticStatus = if (ev.status.equals("failed", ignoreCase = true)) {
            ConduitTaskStatus.Error
        } else {
            ConduitTaskStatus.Done
        }
        val tailLine = ev.content.lineSequence().drop(1).firstOrNull()?.trim()?.takeIf { it.isNotEmpty() }
        return RowModel(title = title, status = staticStatus, elapsed = null, tail = tailLine, isLive = false)
    }
}

/**
 * Renders a peer-session message (broker `SendPeerChat` /
 * `framePeerMessage`) as a distinct inbound card instead of the "YOU"
 * user bubble -- the raw framed envelope was showing up as a giant user
 * message with no indication it came from another agent session, not the
 * human. Header is tappable to jump to the sender session when it's one
 * this device already knows about (via `LocalSessionStore.sessions`);
 * otherwise the tap is a no-op (no session id, or an id we can't resolve).
 */
@Composable
private fun PeerMessageCard(peer: PeerMessage.Parsed) {
    val neon = LocalNeonTheme.current
    val store = LocalSessionStore.current
    val sessions = store?.sessions?.collectAsState()?.value ?: emptyList()
    val knownSession = peer.fromSessionId?.let { id -> sessions.firstOrNull { it.id == id } }
    val shape = RoundedCornerShape(14.dp)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = shape, fill = neon.surface, glowTint = neon.blue)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .then(
                    if (knownSession != null) {
                        Modifier.clickable { store?.switchTo(knownSession.id) }
                    } else {
                        Modifier
                    },
                ),
        ) {
            Icon(
                Icons.AutoMirrored.Outlined.Chat,
                contentDescription = null,
                tint = neon.blue,
                modifier = Modifier.size(14.dp),
            )
            Spacer(Modifier.width(8.dp))
            NeonLabel("PEER MESSAGE", neon.textDim, neon)
            Spacer(Modifier.width(6.dp))
            Text(
                PeerMessage.displayLabel(peer),
                style = MaterialTheme.typography.labelMedium,
                fontFamily = neon.sans,
                fontWeight = FontWeight.SemiBold,
                color = neon.blue,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.weight(1f))
            if (knownSession != null) {
                Icon(
                    Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = null,
                    tint = neon.textFaint,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
        if (peer.body.isNotBlank()) {
            MarkdownBlock(text = peer.body, role = ConversationRole.System)
        }
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
            // Task K send-state cue (NO text): while a message is sent-but-not-
            // yet-broker-acked (`pending` = queued/pre-write, `sent` = WS write
            // ok / awaiting chat_ack, `retrying` = manual retry in-flight), the
            // bubble renders faded + dotted; it goes solid once the broker acks
            // (status → done). Reads `ev.status` so a flip rebuilds the row.
            val sendState = ev.status.lowercase()
            val inFlight = sendState == "pending" || sendState == "sent" || sendState == "retrying"
            val clipboard = LocalClipboardManager.current
            // Right-aligned, content-sized pill. `neon.accent` fill +
            // `neon.accentText` foreground, pill radius — the §2 user
            // bubble. `fillMaxWidth(0.82f)` caps long turns; `wrapContentWidth`
            // shrinks to content + pins trailing so short turns hug the right.
            Box(
                modifier = Modifier
                    .fillMaxWidth(0.82f)
                    .wrapContentWidth(Alignment.End)
                    .graphicsLayer { this.alpha = if (inFlight) 0.55f else 1f }
                    .clip(RoundedCornerShape(18.dp))
                    // Device feedback v0.0.68: fill with `accent`, NOT `accent2`.
                    // `accentText` is the guaranteed-contrast partner of `accent`
                    // (in light mode `accent2` is a bright tint, e.g. Matrix lime,
                    // and `accentText` is white → white-on-lime was unreadable).
                    .background(neon.accent)
                    .pointerInput(ev.content) {
                        detectTapGestures(onLongPress = {
                            clipboard.setText(AnnotatedString(ev.content))
                        })
                    }
                    .then(
                        if (inFlight) {
                            val dashColor = neon.accentText.copy(alpha = 0.7f)
                            Modifier.drawBehind {
                                val stroke = 1.dp.toPx()
                                drawRoundRect(
                                    color = dashColor,
                                    cornerRadius = CornerRadius(18.dp.toPx(), 18.dp.toPx()),
                                    style = Stroke(
                                        width = stroke,
                                        pathEffect = PathEffect.dashPathEffect(
                                            floatArrayOf(4.dp.toPx(), 3.dp.toPx()),
                                            0f,
                                        ),
                                    ),
                                )
                            }
                        } else {
                            Modifier
                        },
                    ),
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
        // Task K: the in-flight states (`pending`/`sent`/`retrying`) carry NO
        // text — the bubble's faded + dotted treatment (in the user-bubble Box
        // above) is the only cue, and it clears to solid once the broker acks
        // (status → done). Only the failed terminus keeps a tappable affordance.
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
        // The broker no longer knows this session (restart/redeploy/GC): the
        // send path stopped retrying (it would never recover into a dead
        // session) and marked the echo `expired`. Offer a tappable Resume that
        // re-attaches the session via the existing recoverable-resume flow.
        // Mirror of iOS `sessionExpiredFooter`.
        "expired" -> {
            val store = LocalSessionStore.current
            val sessionId = LocalSessionId.current
            val doResume: () -> Unit = resume@{
                if (store == null || sessionId == null) return@resume
                val assistant = store.sessions.value
                    .firstOrNull { it.id == sessionId }?.assistant ?: "claude"
                store.resumeRecoverableSession(sessionId, assistant)
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                modifier = Modifier
                    .semantics { role = Role.Button }
                    .clickable(enabled = store != null && sessionId != null) { doResume() },
            ) {
                Icon(
                    Icons.Outlined.Refresh,
                    contentDescription = null,
                    tint = neon.red,
                    modifier = Modifier.size(12.dp),
                )
                Text(
                    "session expired — Resume to continue",
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
 * Lightweight "agent is working" row shown at the bottom of the message list
 * while the agent is busy (Bug 3 / iOS `isAgentWorking` parity).
 *
 * [turnPhase] drives distinct visual states:
 *   "working"  = pre-output tool execution -> ConduitWorkingIndicator (new 4-style indicator).
 *   "thinking" = pre-output thinking       -> ConduitWorkingIndicator.
 *   "writing" / null / "" -> three animated bouncing dots (active streaming, unchanged).
 */
@Composable
private fun TypingIndicatorRow(
    assistant: String,
    @Suppress("UNUSED_PARAMETER") accent: Color,
    turnPhase: String? = null,
    workingIndicatorStyleRaw: String = "Spine",
    thinkingPeek: String? = null,
) {
    val neon = LocalNeonTheme.current
    if (turnPhase == "working" || turnPhase == "thinking") {
        // Pre-output phases: the new four-style working indicator (debug-toggle driven);
        // supersedes the legacy WORKING.../THINKING... label + single dot.
        // When phase is "thinking" and a live reasoning line is available, pass it as
        // status so ALL styles show the live thinking line instead of the canned verb.
        sh.nikhil.conduit.ui.components.ConduitWorkingIndicator(
            style = sh.nikhil.conduit.ui.components.ConduitWorkingStyle.from(workingIndicatorStyleRaw),
            modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
            agent = assistant,
            status = if (turnPhase == "thinking") thinkingPeek else null,
        )
    } else {
        // "writing" / null -> three bouncing dots under the ASSISTANT label (no robot icon,
        // #828 parity). Active streaming — unchanged by the working-indicator handoff.
        val writingTransition = androidx.compose.animation.core.rememberInfiniteTransition(label = "typing")
        Column(
            modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                "ASSISTANT",
                fontFamily = neon.mono,
                fontWeight = FontWeight.Bold,
                fontSize = 11.sp,
                color = neon.textDim,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                repeat(3) { i ->
                    val dotAlpha by writingTransition.animateFloat(
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
                            .size(7.dp)
                            .graphicsLayer { alpha = dotAlpha }
                            .background(neon.accent, CircleShape),
                    )
                }
            }
        }
    }
}

// ── Thinking disclosure + peek helper ─────────────────────────────────────────

/**
 * Returns the last non-empty, trimmed line of [text] for use as the
 * working-indicator status override while the agent is in a thinking phase.
 * Returns null when text is null, empty, or contains only whitespace lines.
 * The result is capped at 80 characters (trailing ellipsis appended if needed).
 * Mirror of iOS ConduitUI.thinkingPeekLine.
 */
internal fun thinkingPeekLine(text: String?): String? {
    if (text.isNullOrEmpty()) return null
    val line = text.lines().reversed()
        .firstOrNull { it.isNotBlank() }
        ?.trim() ?: return null
    if (line.isEmpty()) return null
    return if (line.length <= 80) line else line.take(79) + "…"
}

/**
 * Collapsible reasoning-text block rendered above the streaming prose while
 * the agent is in a thinking phase (thinking_streaming view_events).
 *
 * Collapsed by default: a one-line header row (chevron + "Thinking..." in mono/dim).
 * Tapping the header expands to show the full accumulated reasoning text.
 * Respects reduced-motion (no animation when enabled).
 * Mirror of iOS ConduitUI.ThinkingDisclosure.
 */
@Composable
private fun ThinkingDisclosure(text: String) {
    val neon = LocalNeonTheme.current
    var isExpanded by remember { mutableStateOf(false) }

    Column(modifier = Modifier.fillMaxWidth()) {
        // Header row: chevron + "Thinking..." label.
        Row(
            modifier = Modifier
                .clickable(
                    indication = null,
                    interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() },
                ) {
                    val next = !isExpanded
                    isExpanded = next
                    Telemetry.breadcrumb(
                        "thinking",
                        if (next) "expand" else "collapse",
                        mapOf("len" to text.length.toString()),
                    )
                }
                .fillMaxWidth()
                .semantics { contentDescription = if (isExpanded) "Collapse thinking" else "Expand thinking" },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(
                imageVector = if (isExpanded) {
                    Icons.Default.KeyboardArrowDown
                } else {
                    Icons.AutoMirrored.Filled.KeyboardArrowRight
                },
                contentDescription = null,
                tint = neon.ghost,
                modifier = Modifier.size(14.dp),
            )
            Text(
                "Thinking…",
                fontFamily = neon.mono,
                fontSize = 12.sp,
                color = neon.textFaint,
            )
        }
        // Expanded body: full reasoning text in dim mono.
        androidx.compose.animation.AnimatedVisibility(visible = isExpanded) {
            Text(
                text,
                fontFamily = neon.mono,
                fontSize = 12.sp,
                lineHeight = (12f * 1.5f).sp,
                color = neon.textDim,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 6.dp),
            )
        }
    }
}

// ── Direction C streaming spine ───────────────────────────────────────────────

/**
 * Streaming assistant turn on the spine (Direction C — "Flowing conduit").
 *
 * Replaces the legacy StreamingOverlayRow. Shows the in-progress partial
 * assistant content on the same conduit spine used by finished turns:
 *   - 24dp mark head (radius 7, bg rgba(255,255,255,0.03), 1dp border)
 *     containing ConduitMark at 15dp. While streaming: breathes (glow
 *     accent<->green, 2.1s). Done: no glow.
 *   - 2dp rail (radius 2) starting 6dp below the mark, fills turn height.
 *     While streaming: downward-flowing codex->green->codex->green gradient
 *     (1.4s, linear). Done: static codex->green at alpha 0.5.
 *   - Prose in body column (neon.sans, ~15.5sp, line-height 1.62, neon.text).
 *     While streaming: blinking accent caret (7x1em block, 1s step). Done: no caret.
 *   - No "assistant" label; text is never full-bleed.
 *   - All animations stop under reduced-motion (renders done end-state).
 *
 * The streaming turn carries no tool steps here — those arrive as settled
 * ConversationItem clusters via ToolLedger. This composable handles the
 * prose-streaming phase only.
 */
@Composable
private fun StreamingSpineRow(content: String, thinking: String? = null) {
    val neon = LocalNeonTheme.current
    val context = androidx.compose.ui.platform.LocalContext.current
    val reduceMotion = remember {
        android.provider.Settings.Global.getFloat(
            context.contentResolver,
            android.provider.Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        ) == 0f
    }

    Telemetry.breadcrumb(
        "chat",
        "streaming_spine_render",
        mapOf("contentLen" to content.length.toString(), "reduceMotion" to reduceMotion.toString()),
    )

    // Continuous draw-down: drawFraction loops 0 -> 1 so the rail perpetually
    // redraws itself downward from the mark head (not just once as prose grows).
    // The Canvas maps this to railEndY = railStartY + (fullHeight - railStartY) * f,
    // so the drawn endpoint sweeps down, snaps back to the head, and repeats. Under
    // reduceMotion the fraction is pinned to 1 (static full-height rail).
    val drawTransition = if (!reduceMotion) {
        androidx.compose.animation.core.rememberInfiniteTransition(label = "railDraw")
    } else null
    val drawFraction = if (drawTransition != null) {
        val d by drawTransition.animateFloat(
            initialValue = 0f,
            targetValue = 1f,
            animationSpec = androidx.compose.animation.core.infiniteRepeatable(
                animation = androidx.compose.animation.core.tween(
                    durationMillis = 1300,
                    easing = androidx.compose.animation.core.FastOutSlowInEasing,
                ),
                repeatMode = androidx.compose.animation.core.RepeatMode.Restart,
            ),
            label = "railDrawFraction",
        )
        d
    } else 1f

    // Breathe: mark head glow pulsing accent <-> green, 2.1s ease-in-out.
    val breatheTransition = if (!reduceMotion) {
        androidx.compose.animation.core.rememberInfiniteTransition(label = "breathe")
    } else null
    val breatheAlpha = if (breatheTransition != null) {
        val a by breatheTransition.animateFloat(
            initialValue = 0f,
            targetValue = 1f,
            animationSpec = androidx.compose.animation.core.infiniteRepeatable(
                animation = androidx.compose.animation.core.tween(
                    durationMillis = 2100,
                    easing = androidx.compose.animation.core.FastOutSlowInEasing,
                ),
                repeatMode = androidx.compose.animation.core.RepeatMode.Reverse,
            ),
            label = "breatheAlpha",
        )
        a
    } else 0f

    // Flow: rail gradient offset scrolling downward, 1.4s linear.
    val flowTransition = if (!reduceMotion) {
        androidx.compose.animation.core.rememberInfiniteTransition(label = "railFlow")
    } else null
    val flowOffset = if (flowTransition != null) {
        val f by flowTransition.animateFloat(
            initialValue = 0f,
            targetValue = 1f,
            animationSpec = androidx.compose.animation.core.infiniteRepeatable(
                animation = androidx.compose.animation.core.tween(
                    durationMillis = 1400,
                    easing = androidx.compose.animation.core.LinearEasing,
                ),
            ),
            label = "flowOffset",
        )
        f
    } else 0f

    // Blink caret: 1s step, 50% duty.
    val caretTransition = if (!reduceMotion) {
        androidx.compose.animation.core.rememberInfiniteTransition(label = "caret")
    } else null
    val caretVisible = if (caretTransition != null) {
        val c by caretTransition.animateFloat(
            initialValue = 1f,
            targetValue = 0f,
            animationSpec = androidx.compose.animation.core.infiniteRepeatable(
                animation = androidx.compose.animation.core.tween(
                    durationMillis = 500,
                    easing = androidx.compose.animation.core.LinearEasing,
                ),
                repeatMode = androidx.compose.animation.core.RepeatMode.Reverse,
            ),
            label = "caretAlpha",
        )
        c > 0.5f
    } else false

    // IntrinsicSize.Max lets the left rail column stretch to match the prose column.
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(androidx.compose.foundation.layout.IntrinsicSize.Max)
            .padding(vertical = 4.dp),
    ) {
        // Rail column: fixed 24dp wide, centered. Stretches to full Row height via
        // fillMaxHeight() which works because the Row uses IntrinsicSize.Max.
        val glowColor = androidx.compose.ui.graphics.lerp(neon.accent, neon.green, breatheAlpha)
        Box(
            modifier = Modifier
                .width(24.dp)
                .fillMaxHeight()
                .drawBehind {
                    // Soft glow around the mark head area (top ~24dp).
                    if (!reduceMotion && breatheAlpha > 0f) {
                        drawCircle(
                            color = glowColor.copy(alpha = 0.30f * breatheAlpha),
                            radius = 18.dp.toPx(),
                            center = Offset(size.width / 2f, 12.dp.toPx()),
                        )
                    }

                    // Mark head background (radius 7) and border.
                    val headSize = 24.dp.toPx()
                    drawRoundRect(
                        color = Color.White.copy(alpha = 0.03f),
                        topLeft = Offset((size.width - headSize) / 2f, 0f),
                        size = androidx.compose.ui.geometry.Size(headSize, headSize),
                        cornerRadius = CornerRadius(7.dp.toPx()),
                    )
                    drawRoundRect(
                        color = neon.border,
                        topLeft = Offset((size.width - headSize) / 2f, 0f),
                        size = androidx.compose.ui.geometry.Size(headSize, headSize),
                        cornerRadius = CornerRadius(7.dp.toPx()),
                        style = Stroke(width = 1.dp.toPx()),
                    )

                    // Rail: 2dp wide from 6dp below mark top to the LOOPING drawn
                    // endpoint. drawFraction sweeps 0 -> 1 continuously, so railEndY
                    // draws downward from the head to the full row height, snaps back,
                    // and repeats. The flow brush and tile logic are unchanged; only the
                    // drawn endpoint moves. Clamp to size.height to never exceed the Box.
                    val railStartY = headSize + 6.dp.toPx()
                    val railEndY = (railStartY + (size.height - railStartY) * drawFraction)
                        .coerceIn(railStartY, size.height)
                    if (railEndY > railStartY) {
                        val railH = railEndY - railStartY
                        val tilePx = 46.dp.toPx()
                        val railBrush = if (!reduceMotion && flowTransition != null) {
                            // phase shifts downward 0 -> tilePx over 1.4s; TileMode.Repeated
                            // makes the gradient wrap seamlessly at every tile boundary.
                            val phase = flowOffset * tilePx
                            Brush.linearGradient(
                                colors = listOf(neon.accentBright, neon.green),
                                start = Offset(0f, phase),
                                end = Offset(0f, phase + tilePx),
                                tileMode = TileMode.Repeated,
                            )
                        } else {
                            Brush.verticalGradient(
                                listOf(neon.accentBright, neon.green),
                                startY = railStartY,
                                endY = railEndY,
                            )
                        }
                        val railAlpha = if (reduceMotion) 0.5f else 0.95f
                        drawRoundRect(
                            brush = railBrush,
                            topLeft = Offset((size.width - 2.dp.toPx()) / 2f, railStartY),
                            size = androidx.compose.ui.geometry.Size(2.dp.toPx(), railH),
                            cornerRadius = CornerRadius(2.dp.toPx()),
                            alpha = railAlpha,
                        )
                    }
                },
            contentAlignment = Alignment.TopCenter,
        ) {
            // ConduitMark inside the head area.
            ConduitMark(size = 15.dp, modifier = Modifier.padding(top = 4.5.dp))
        }

        Spacer(Modifier.width(13.dp))

        // Body column: optional thinking disclosure + prose + caret.
        Column(
            modifier = Modifier
                .weight(1f)
                .padding(bottom = 4.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            // Thinking disclosure: shown while the agent is in the reasoning phase.
            // Collapses to a one-line header by default; tap the chevron to expand.
            if (!thinking.isNullOrEmpty()) {
                ThinkingDisclosure(text = thinking)
            }
            // Prose: neon.sans, 15.5sp, line-height 1.62, neon.text.
            // Caret is appended INLINE as an AnnotatedString span so it trails the last
            // character and wraps naturally with the text (not pinned to the right margin).
            // A thin-space ( ) before the block glyph (▌) provides a small gap.
            // The caret suffix is ALWAYS present in the layout while streaming so width is
            // stable; it blinks by toggling between accentBright and Color.Transparent (not
            // by swapping glyph/space). Under reduceMotion: no caret suffix appended at all.
            // Inline markdown: parse content for bold/italic/code spans via
            // ConduitMarkdownHeadingScaler.inlineAnnotated, cached by content hash in
            // LocalParsedMarkdownCache so each unique content string is parsed once.
            // Unclosed markers (partial stream) are emitted as literal text, not consumed.
            // remember() is always called (no conditional composable) with content as key;
            // empty content returns an empty AnnotatedString (placeholder).
            val cache = LocalParsedMarkdownCache.current
            val hasContent = content.isNotEmpty()
            val contentAnnotated = remember(content) {
                if (hasContent) {
                    cache.getOrPut(id = "stream-inline:${content.hashCode()}", revision = 0) {
                        ConduitMarkdownHeadingScaler.inlineAnnotated(content)
                    }
                } else null
            }
            val proseText = buildAnnotatedString {
                if (contentAnnotated != null) {
                    append(contentAnnotated)
                } else {
                    append("​")
                }
                if (hasContent && !reduceMotion) {
                    // Thin-space gap + block glyph, always in layout; color toggles for blink.
                    val caretColor = if (caretVisible) neon.accentBright else Color.Transparent
                    pushStyle(SpanStyle(color = caretColor))
                    append(" ▌")
                    pop()
                }
            }
            Text(
                proseText,
                style = MaterialTheme.typography.bodyMedium.copy(
                    fontSize = 15.5.sp,
                    lineHeight = (15.5f * 1.62f).sp,
                    color = neon.text,
                ),
                fontFamily = neon.sans,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

// ── Typed-step ToolLedger (streaming-states redesign) ─────────────────────────

/**
 * Classifies a ConversationItem for the ledger display.
 * Edits (files non-empty or toolName resolves EDIT) show as pencil + filename.
 * Runs/reads show as $ + command. Returns a triple of (kind, label, files).
 */
private fun ledgerStepClassify(ev: ConversationItem): Triple<NeonToolKind, String, List<ViewEventFile>> {
    val kind = neonToolKind(ev.toolName)
    val files = ev.files
    // If there are attached files and no command, treat as edit.
    return if ((kind == NeonToolKind.EDIT || (files.isNotEmpty() && ev.command.isNullOrBlank()))) {
        Triple(NeonToolKind.EDIT, files.firstOrNull()?.path.orEmpty(), files)
    } else {
        val label = clusterRowLabel(ev)
        Triple(kind, label, files)
    }
}

/**
 * Returns true when a step is a "navigational noise" cd-only command that
 * should be coalesced. Consecutive identical cd commands are deduplicated.
 */
private fun isNavigationalNoise(label: String): Boolean =
    label.trim().lowercase().let { it.startsWith("cd ") || it == "cd" }

/**
 * Coalesce the ledger items: drop consecutive duplicate navigational commands
 * (repeated cd ...) — keep only the first of each unique run.
 * Returns the deduplicated list.
 */
private fun coalesceSteps(items: List<ConversationItem>): List<ConversationItem> {
    val result = mutableListOf<ConversationItem>()
    var lastNavLabel: String? = null
    for (ev in items) {
        val (_, label, _) = ledgerStepClassify(ev)
        if (isNavigationalNoise(label)) {
            if (label == lastNavLabel) continue // drop duplicate cd
            lastNavLabel = label
        } else {
            lastNavLabel = null
        }
        result.add(ev)
    }
    return result
}

/**
 * Collapsed one-line footnote for a finished tool cluster.
 * Rounded rect, 1dp lineSoft border, semi-transparent bg, padding 11x14:
 *   "{n} steps" (mono 12.5, faint) · check(green) passed(faint) — or "{k} failed"(red) — trailing chevron-right.
 * Tap to expand.
 */
@Composable
private fun LedgerFootnote(
    totalSteps: Int,
    failCount: Int,
    onExpand: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .border(1.dp, neon.lineSoft, RoundedCornerShape(12.dp))
            .background(Color.White.copy(alpha = 0.018f))
            .clickable(onClick = onExpand)
            .padding(horizontal = 14.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            "$totalSteps steps",
            style = MaterialTheme.typography.bodySmall.copy(fontSize = 12.5.sp),
            fontFamily = neon.mono,
            color = neon.textFaint,
        )
        Spacer(Modifier.width(6.dp))
        Text(
            "·",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = neon.mono,
            color = neon.ghost,
        )
        Spacer(Modifier.width(6.dp))
        if (failCount == 0) {
            Icon(
                Icons.Filled.Check,
                contentDescription = null,
                tint = neon.green,
                modifier = Modifier.size(13.dp),
            )
            Text(
                "passed",
                style = MaterialTheme.typography.bodySmall.copy(fontSize = 12.5.sp),
                fontFamily = neon.mono,
                color = neon.textFaint,
            )
        } else {
            Text(
                "$failCount failed",
                style = MaterialTheme.typography.bodySmall.copy(fontSize = 12.5.sp),
                fontFamily = neon.mono,
                color = neon.red,
            )
        }
        Spacer(Modifier.weight(1f))
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = "Expand steps",
            tint = neon.ghost,
            modifier = Modifier.size(14.dp),
        )
    }
}

/**
 * One row in the typed-step ledger.
 * Grid: [16dp status | 1f middle | auto trailing], gap 10, pad 8x13.
 * Hairline above (except first row).
 * - done: 6dp green dot (steady).
 * - running: 6dp amber dot (pulse) + row tinted accent ~4%.
 * - failed: red X icon.
 * Middle: edit = pencil(accent) + filename mono 12.5; run/read = $ (faint) + command mono 12.5.
 * Trailing: edit = diff chip if available; running = "running"(amber); failed = "exit N"(red).
 * In live mode, rows animate in with rowin (fade+4dp rise, 0.28s ease-out, once each).
 */
@Composable
private fun LedgerRow(
    ev: ConversationItem,
    isFirst: Boolean,
    liveMode: Boolean,
    reduceMotion: Boolean,
    rowIndex: Int,
) {
    val neon = LocalNeonTheme.current
    val (kind, label, files) = remember(ev) { ledgerStepClassify(ev) }
    val isRunning = ev.status.equals("running", true) || ev.status.equals("pending", true)
    val exit = ev.exitCode?.toInt()
    val isFailed = ev.status.equals("failed", true) || (exit != null && exit != 0)
    val isEdit = kind == NeonToolKind.EDIT

    // Rowin animation: fade+4dp rise, 0.28s ease-out, once per row in live mode.
    var appeared by remember(rowIndex) { mutableStateOf(reduceMotion || !liveMode) }
    val rowAlpha by androidx.compose.animation.core.animateFloatAsState(
        targetValue = if (appeared) 1f else 0f,
        animationSpec = androidx.compose.animation.core.tween(
            durationMillis = if (reduceMotion) 0 else 280,
            easing = androidx.compose.animation.core.FastOutSlowInEasing,
        ),
        label = "ledgerRowAlpha",
    )
    val rowRise by androidx.compose.animation.core.animateFloatAsState(
        targetValue = if (appeared) 0f else 4f,
        animationSpec = androidx.compose.animation.core.tween(
            durationMillis = if (reduceMotion) 0 else 280,
            easing = androidx.compose.animation.core.FastOutSlowInEasing,
        ),
        label = "ledgerRowRise",
    )
    LaunchedEffect(rowIndex) {
        if (!appeared) appeared = true
    }

    // Running dot pulse animation (1.25s ease-in-out, infinite).
    val pulseTransition = if (isRunning && liveMode && !reduceMotion) {
        androidx.compose.animation.core.rememberInfiniteTransition(label = "dotPulse$rowIndex")
    } else null
    val dotAlpha = if (pulseTransition != null) {
        val a by pulseTransition.animateFloat(
            initialValue = 0.35f,
            targetValue = 1f,
            animationSpec = androidx.compose.animation.core.infiniteRepeatable(
                animation = androidx.compose.animation.core.tween(
                    durationMillis = 625,
                    easing = androidx.compose.animation.core.FastOutSlowInEasing,
                ),
                repeatMode = androidx.compose.animation.core.RepeatMode.Reverse,
            ),
            label = "dotAlpha",
        )
        a
    } else 1f

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .graphicsLayer {
                alpha = rowAlpha
                translationY = rowRise.dp.toPx()
            },
    ) {
        // Row tint for running state (~4% accent).
        if (isRunning && liveMode) {
            Box(
                modifier = Modifier
                    .matchParentSize()
                    .background(neon.accent.copy(alpha = 0.04f)),
            )
        }
        Column {
            if (!isFirst) {
                HorizontalDivider(color = neon.grid, thickness = 0.5.dp)
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 13.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                // Status column: 16dp wide, centered.
                Box(
                    modifier = Modifier.width(16.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    when {
                        isFailed -> Icon(
                            Icons.Outlined.Close,
                            contentDescription = "Failed",
                            tint = neon.red,
                            modifier = Modifier.size(12.dp),
                        )
                        isRunning -> Box(
                            modifier = Modifier
                                .size(6.dp)
                                .graphicsLayer { alpha = dotAlpha }
                                .background(neon.yellow, CircleShape),
                        )
                        else -> Box(
                            modifier = Modifier
                                .size(6.dp)
                                .background(neon.green, CircleShape),
                        )
                    }
                }

                // Middle column: 1f weight.
                Row(
                    modifier = Modifier.weight(1f),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    if (isEdit) {
                        Icon(
                            Icons.Outlined.Create,
                            contentDescription = null,
                            tint = neon.accent,
                            modifier = Modifier.size(13.dp),
                        )
                        val filename = remember(label, files) {
                            // Show just the filename portion of the path.
                            val f = files.firstOrNull()?.path ?: label
                            f.substringAfterLast('/').takeIf { it.isNotBlank() } ?: f
                        }
                        Text(
                            filename,
                            style = MaterialTheme.typography.bodySmall.copy(fontSize = 12.5.sp),
                            fontFamily = neon.mono,
                            color = if (isRunning) neon.text else neon.textDim,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    } else {
                        Text(
                            "$",
                            style = MaterialTheme.typography.bodySmall.copy(fontSize = 12.5.sp),
                            fontFamily = neon.mono,
                            color = neon.textFaint,
                        )
                        Text(
                            label,
                            style = MaterialTheme.typography.bodySmall.copy(fontSize = 12.5.sp),
                            fontFamily = neon.mono,
                            color = if (isRunning) neon.text else neon.textDim,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }

                // Trailing column: auto width.
                when {
                    isFailed -> Text(
                        if (exit != null) "exit $exit" else "failed",
                        style = MaterialTheme.typography.bodySmall.copy(fontSize = 11.sp),
                        fontFamily = neon.mono,
                        color = neon.red,
                    )
                    isRunning -> Text(
                        "running",
                        style = MaterialTheme.typography.bodySmall.copy(fontSize = 10.5.sp),
                        fontFamily = neon.mono,
                        color = neon.yellow,
                    )
                    // Edit diff chip: omitted today (no line-delta in ViewEventFile).
                    // Will render when core adds add/del counts. See PR body data-gap note.
                    else -> { /* nothing */ }
                }
            }
        }
    }
}

/**
 * Typed-step ToolLedger — the arm-B standard command-block render.
 *
 * Replaces NeonMonoCommandCluster / MonoCommandBlockInline /
 * MonoCommandBlockCollapsible / CommandRunTicker / ToolClusterCard.
 *
 * Modes:
 *   - Live (any item running): spinner + "{done}/{total} steps"; rows animate in.
 *   - Done-expanded: terminal icon + "{total} steps" + check + "passed"; up-chevron to collapse.
 *   - Collapsed footnote (default resting): "{n} steps" · check passed, chevron-right to expand.
 *
 * Expansion state is remembered per cluster (keyed by first item id).
 * Consecutive identical cd commands are coalesced before display.
 */
@Composable
private fun ToolLedger(items: List<ConversationItem>) {
    val neon = LocalNeonTheme.current
    val context = androidx.compose.ui.platform.LocalContext.current
    val reduceMotion = remember {
        android.provider.Settings.Global.getFloat(
            context.contentResolver,
            android.provider.Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        ) == 0f
    }

    val clusterId = items.firstOrNull()?.id ?: "empty"
    val anyRunning = remember(items) { clusterAnyRunning(items) }
    val liveMode = anyRunning
    val coalesced = remember(items) { coalesceSteps(items) }
    val totalSteps = coalesced.size
    val doneSteps = remember(coalesced) {
        coalesced.count { ev ->
            !ev.status.equals("running", true) &&
            !ev.status.equals("pending", true) &&
            ev.status.isNotBlank()
        }
    }
    val failCount = remember(coalesced) { clusterFailCount(coalesced) }

    // Expanded state persisted per cluster id. Default: collapsed (footnote).
    var expanded by remember(clusterId) { mutableStateOf(false) }

    LaunchedEffect(clusterId, liveMode) {
        Telemetry.breadcrumb(
            "chat",
            "tool_ledger_render",
            mapOf(
                "total" to totalSteps.toString(),
                "done" to doneSteps.toString(),
                "live" to liveMode.toString(),
                "failCount" to failCount.toString(),
            ),
        )
    }

    // Spinner animation for live mode header (0.9s linear, infinite).
    val spinTransition = if (liveMode && !reduceMotion) {
        androidx.compose.animation.core.rememberInfiniteTransition(label = "ledgerSpin")
    } else null
    val spinAngle = if (spinTransition != null) {
        val s by spinTransition.animateFloat(
            initialValue = 0f,
            targetValue = 360f,
            animationSpec = androidx.compose.animation.core.infiniteRepeatable(
                animation = androidx.compose.animation.core.tween(
                    durationMillis = 900,
                    easing = androidx.compose.animation.core.LinearEasing,
                ),
            ),
            label = "spinAngle",
        )
        s
    } else 0f

    // While live mode: show full expanded ledger (no footnote, no collapse).
    // When done: show collapsed footnote (default) or expanded ledger.
    val showFootnote = !liveMode && !expanded

    if (showFootnote) {
        LedgerFootnote(
            totalSteps = totalSteps,
            failCount = failCount,
            onExpand = {
                expanded = true
                Telemetry.breadcrumb(
                    "chat",
                    "tool_ledger_expand",
                    mapOf("via" to "footnote_tap"),
                )
            },
        )
        return
    }

    // Expanded or live mode: full ledger container.
    val shape = RoundedCornerShape(12.dp)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .border(1.dp, neon.lineSoft, shape)
            .background(neon.codeBg),
    ) {
        // Header row.
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .then(
                    if (!liveMode) {
                        Modifier.clickable {
                            expanded = false
                            Telemetry.breadcrumb("chat", "tool_ledger_collapse", mapOf("via" to "header_chevron"))
                        }
                    } else Modifier,
                )
                .padding(horizontal = 13.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (liveMode) {
                // Spinning accent ring (12dp).
                Box(
                    modifier = Modifier
                        .size(12.dp)
                        .graphicsLayer { rotationZ = spinAngle }
                        .drawBehind {
                            val stroke = androidx.compose.ui.graphics.drawscope.Stroke(
                                width = 2.dp.toPx(),
                                cap = androidx.compose.ui.graphics.StrokeCap.Round,
                            )
                            // Ring track.
                            drawArc(
                                color = neon.accent.copy(alpha = 0.20f),
                                startAngle = 0f,
                                sweepAngle = 360f,
                                useCenter = false,
                                style = stroke,
                            )
                            // Active arc (~270 degrees).
                            drawArc(
                                color = neon.accent,
                                startAngle = -90f,
                                sweepAngle = 270f,
                                useCenter = false,
                                style = stroke,
                            )
                        },
                )
            } else {
                Icon(
                    Icons.Outlined.Terminal,
                    contentDescription = null,
                    tint = neon.textFaint,
                    modifier = Modifier.size(14.dp),
                )
            }
            Spacer(Modifier.width(9.dp))
            // Step count label.
            Text(
                if (liveMode) "$doneSteps/$totalSteps steps" else "$totalSteps steps",
                style = MaterialTheme.typography.bodySmall.copy(fontSize = 12.sp),
                fontFamily = neon.mono,
                color = neon.textDim,
            )
            Spacer(Modifier.weight(1f))
            // Trailing (done mode only).
            if (!liveMode) {
                if (failCount > 0) {
                    Text(
                        "$failCount failed",
                        style = MaterialTheme.typography.bodySmall.copy(fontSize = 11.5.sp),
                        fontFamily = neon.mono,
                        color = neon.red,
                    )
                } else {
                    Icon(
                        Icons.Filled.Check,
                        contentDescription = null,
                        tint = neon.green,
                        modifier = Modifier.size(13.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        "passed",
                        style = MaterialTheme.typography.bodySmall.copy(fontSize = 11.5.sp),
                        fontFamily = neon.mono,
                        color = neon.textFaint,
                    )
                }
                Spacer(Modifier.width(4.dp))
                Icon(
                    Icons.Filled.KeyboardArrowUp,
                    contentDescription = "Collapse",
                    tint = neon.ghost,
                    modifier = Modifier.size(13.dp),
                )
            }
        }

        // Hairline below header.
        HorizontalDivider(color = neon.grid, thickness = 0.5.dp)

        // Step rows.
        coalesced.forEachIndexed { idx, ev ->
            LedgerRow(
                ev = ev,
                isFirst = idx == 0,
                liveMode = liveMode,
                reduceMotion = reduceMotion,
                rowIndex = idx,
            )
        }
    }
}

@Composable
fun MarkdownBlock(text: String, role: ConversationRole) {
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

// ── §10 Mono block helpers (pure, internal, testable) ───────────────────────

/**
 * Returns true when the cluster is still running (any item has status
 * "running" or "pending"). Used to switch between ticker and settled rendering.
 */
internal fun clusterAnyRunning(items: List<ConversationItem>): Boolean =
    items.any { it.status.equals("running", true) || it.status.equals("pending", true) }

/**
 * Returns the count of failed items in a cluster. A row is failed when its
 * status is "failed" or its exitCode is non-zero.
 */
internal fun clusterFailCount(items: List<ConversationItem>): Int =
    items.count { ev ->
        val exit = ev.exitCode?.toInt()
        ev.status.equals("failed", true) || (exit != null && exit != 0)
    }

/**
 * Returns the subset of [items] that failed. Used by §10b to surface failed
 * rows inline even when collapsed.
 */
internal fun clusterFailedRows(items: List<ConversationItem>): List<ConversationItem> =
    items.filter { ev ->
        val exit = ev.exitCode?.toInt()
        ev.status.equals("failed", true) || (exit != null && exit != 0)
    }

/**
 * Ticker progress fraction: completed / total where completed = items whose
 * status is NOT running/pending and NOT empty; total = cluster size. Clamps
 * to [0f, 1f]. Returns 0f when all are still running.
 */
internal fun clusterTickerFraction(items: List<ConversationItem>): Float {
    if (items.isEmpty()) return 0f
    val done = items.count {
        !it.status.equals("running", true) && !it.status.equals("pending", true) && it.status.isNotBlank()
    }
    return (done.toFloat() / items.size.toFloat()).coerceIn(0f, 1f)
}

// ── Legacy §10 threshold constant (kept for unit test compatibility) ──────────

/** Small runs (1-9 steps) historically used the inline block; kept for tests. */
internal const val MONO_COLLAPSE_THRESHOLD = 9

// NOTE: CommandRunTicker, MonoCommandRow, MonoCommandBlockInline,
// MonoCommandBlockCollapsible, MonoCommandLedger, NeonMonoCommandCluster,
// and ToolClusterCard have been removed. The ToolLedger composable (above)
// is the arm-B standard replacement for all users.

// CommandRunTicker, MonoCommandRow, MonoCommandBlockInline,
// MonoCommandBlockCollapsible, MonoCommandLedger, NeonMonoCommandCluster,
// and ToolClusterCard have been removed (streaming-states redesign).
// ToolLedger (above) is the arm-B standard replacement for all users.

/** Icon + tint for a tool family (§4.5 tile colours). */
@Composable
private fun toolTileIcon(kind: NeonToolKind, neon: NeonTheme): Pair<ImageVector, Color> = when (kind) {
    NeonToolKind.SEARCH -> Icons.Outlined.Search to neon.purple
    NeonToolKind.READ -> Icons.Outlined.Visibility to neon.blue
    NeonToolKind.EDIT -> Icons.Outlined.Create to neon.claude
    NeonToolKind.BASH -> Icons.Outlined.Terminal to neon.green
    NeonToolKind.GENERIC -> Icons.Outlined.Build to neon.accent
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
                // Trailing slot: voice/send/stop. The Box pins height to 42.dp
                // so the row doesn't shrink when the mic (42.dp) swaps for the
                // smaller send/stop button (36.dp) — device bug workaround.
                // When the agent is working with an empty draft, show mic+stop
                // side-by-side so the user can dictate while the turn runs.
                if (agentWorking && !hasDraft) {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        InlineVoiceButton { transcript ->
                            val trimmed = transcript.trim()
                            if (trimmed.isNotEmpty()) {
                                onDraftChange(if (draft.isBlank()) trimmed else "$draft $trimmed")
                            }
                        }
                        FilledIconButton(
                            onClick = onStop,
                            colors = androidx.compose.material3.IconButtonDefaults.filledIconButtonColors(
                                containerColor = neon.accent,
                                contentColor = neon.accentText,
                            ),
                            modifier = Modifier.size(36.dp),
                        ) {
                            Icon(Icons.Default.Stop, contentDescription = "Stop")
                        }
                    }
                } else {
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
                            else -> InlineVoiceButton { transcript ->
                                val trimmed = transcript.trim()
                                if (trimmed.isNotEmpty()) {
                                    onDraftChange(if (draft.isBlank()) trimmed else "$draft $trimmed")
                                }
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
