package sh.nikhil.swekitty.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.outlined.AccountCircle
import androidx.compose.material.icons.outlined.ArrowDownward
import androidx.compose.material.icons.outlined.Build
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Fullscreen
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.SmartToy
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import sh.nikhil.swekitty.PinnedContext
import sh.nikhil.swekitty.SessionStore
import kotlinx.coroutines.launch
import uniffi.swe_kitty_core.ChatEvent
import uniffi.swe_kitty_core.ConversationItem
import uniffi.swe_kitty_core.ProjectSession
import uniffi.swe_kitty_core.ViewEventFile

private sealed class ConversationRole(
    val label: String,
    val accent: Color,
) {
    data object User : ConversationRole("You", Color(0xFF00A56A))
    data object Assistant : ConversationRole("Assistant", Color(0xFF4F8CFF))
    data object Tool : ConversationRole("Tool", Color(0xFFF39C3D))
    data object System : ConversationRole("System", Color(0xFF8C8C94))

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
fun ChatPage(store: SessionStore, session: ProjectSession, readOnly: Boolean = false) {
    val agentAccent = SweKittyTheme.accent(forAgent = session.assistant)
    val typedLog by store.conversationLog.collectAsState()
    val fallbackLog by store.chatLog.collectAsState()
    val aiQuickReplies by store.quickReplies.collectAsState()
    // PR #111 + iOS ChatViewModel parity: render a SINGLE chronologically
    // sorted list, merging the typed `conversationLog` with the broker's
    // raw `chatLog`. Picking one source or the other (the prior
    // `typedLog ?: fallbackLog`) dropped codex assistant replies — which
    // arrive via `on_chat_event` into `chatLog` only — and, because
    // server items were concatenated ahead of locally-echoed user turns,
    // sank every user message to the bottom. `mergedConversation` dedupes
    // by role+content and sorts by `ts`, interleaving user and assistant
    // turns correctly. Mirror of iOS `LitterUI.ChatViewModel.mergedEvents`.
    val events = remember(typedLog, fallbackLog, session.id) {
        mergedConversation(
            conversation = typedLog[session.id] ?: emptyList(),
            chatLog = fallbackLog[session.id] ?: emptyList(),
        )
    }
    var draft by remember { mutableStateOf("") }
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
    val showTyping = !readOnly && typing.isStreaming(typingTick)

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

    CompositionLocalProvider(LocalParsedMarkdownCache provides markdownCache) {
    Column(modifier = Modifier.fillMaxSize()) {
        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
            LazyColumn(
                state = listState,
                modifier = Modifier
                    .fillMaxSize()
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
                    items(events.size) { index ->
                        ConversationEventRow(events[index], agentAccent) { reply ->
                            draft = if (draft.trim().isEmpty()) reply else "$draft\n$reply"
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
                FilledIconButton(
                    onClick = {
                        autoScroll = autoScroll.onScrollToBottomRequested()
                        scope.launch { scrollToTrueBottom(listState) }
                    },
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .padding(12.dp)
                        .size(40.dp)
                        .graphicsLayer {
                            alpha = buttonAlpha
                            scaleX = 0.85f + 0.15f * buttonAlpha
                            scaleY = 0.85f + 0.15f * buttonAlpha
                        },
                    colors = androidx.compose.material3.IconButtonDefaults.filledIconButtonColors(
                        containerColor = MaterialTheme.colorScheme.secondaryContainer,
                        contentColor = MaterialTheme.colorScheme.onSecondaryContainer,
                    ),
                ) {
                    Icon(Icons.Outlined.ArrowDownward, contentDescription = "Scroll to latest")
                }
            }
        }

        // Read-only (exited/archived) sessions are a frozen transcript —
        // no live WS to send into — so the composer + quick-reply bar are
        // suppressed entirely (mirrors iOS `LitterChatView` read-only mode).
        if (!readOnly) {
            HorizontalDivider()
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
            )
        }
    }
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
 * Resolve the single chronologically-ordered event stream the chat
 * surface renders, merging the typed [conversation] log with the
 * broker's raw [chatLog]. Mirror of iOS
 * `LitterUI.ChatViewModel.mergedEvents`.
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
        val key = "${ev.role.lowercase()}|${ev.content}"
        if (key in typedFingerprints) {
            null
        } else {
            ConversationItem(
                id = "chatlog-${ev.ts}-$idx",
                role = ev.role,
                kind = if (ev.role.lowercase() == "tool") "tool" else "message",
                status = "done",
                content = ev.content,
                ts = ev.ts,
                files = ev.files,
                toolName = null,
                command = null,
                exitCode = null,
                durationMs = null,
                diffSummary = null,
                pendingOptions = emptyList(),
            )
        }
    }
    if (synthetic.isEmpty()) return conversation
    // Sort by ts (PR #111 contract — typed log is ts-sorted).
    return (conversation + synthetic).sortedBy { it.ts }
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
    fontChoice: sh.nikhil.swekitty.AppearanceStore.FontFamily,
): Int {
    var result = text.hashCode()
    result = 31 * result + bodyPointSize.toRawBits()
    result = 31 * result + fontChoice.ordinal
    return result
}

@Composable
private fun EmptyConversationCard(assistant: String) {
    Surface(
        shape = RoundedCornerShape(18.dp),
        color = MaterialTheme.colorScheme.secondaryContainer.copy(alpha = 0.45f),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 18.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("No conversation yet", style = MaterialTheme.typography.titleMedium)
            Text(
                "Send a message to $assistant. Replies appear here as structured turns; the Terminal tab still shows the raw TUI if you want to peek at the unparsed stream.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun ConversationEventRow(
    ev: ConversationItem,
    agentAccent: Color,
    onQuickReply: (String) -> Unit,
) {
    if (ev.kind == "pending_input") {
        PendingInputCard(ev, agentAccent, onQuickReply)
        return
    }
    if (ev.kind == "handoff") {
        HandoffCard(ev)
        return
    }
    if (ev.kind == "subagent") {
        SubagentCard(ev)
        return
    }
    when (ConversationRole.from(ev.role)) {
        ConversationRole.User ->
            ConversationBubble(ev, ConversationRole.User, agentAccent, Modifier, alignEnd = true)
        ConversationRole.Assistant ->
            ConversationBubble(ev, ConversationRole.Assistant, agentAccent, Modifier, alignEnd = false)
        ConversationRole.Tool -> ConversationToolCard(ev)
        ConversationRole.System -> Row(
            modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Outlined.Info,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.outline,
                modifier = Modifier.size(12.dp),
            )
            Spacer(Modifier.width(6.dp))
            Text(
                ev.content,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.outline,
                maxLines = 2,
            )
        }
    }
}

@Composable
private fun PendingInputCard(
    ev: ConversationItem,
    agentAccent: Color,
    onQuickReply: (String) -> Unit,
) {
    val options = remember(ev) {
        ev.pendingOptions.takeIf { it.isNotEmpty() }
            ?: ConversationRenderer.extractPendingOptions(ev.content)
    }
    Card(
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer.copy(alpha = 0.28f)),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.Info, null, tint = agentAccent, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(8.dp))
                Text("INPUT NEEDED", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, fontWeight = FontWeight.Bold)
                Spacer(Modifier.width(6.dp))
                StatusChip(ev.status)
            }
            MarkdownBlock(ev.content, ConversationRole.Assistant)
            if (options.isNotEmpty()) {
                Row(
                    modifier = Modifier.horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    options.forEach { option ->
                        AssistChip(onClick = { onQuickReply(option) }, label = { Text(option) })
                        Spacer(Modifier.width(2.dp))
                    }
                }
            }
        }
    }
}

@Composable
private fun HandoffCard(ev: ConversationItem) {
    Card(
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.28f)),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Outlined.Info,
                    null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(16.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    "AGENT HANDOFF",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontWeight = FontWeight.Bold,
                )
                Spacer(Modifier.weight(1f))
                if (ev.ts.isNotEmpty()) {
                    Text(ConversationTimestamp.relative(ev.ts), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.outline)
                }
            }
            Text(
                ev.content,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface,
            )
        }
    }
}

@Composable
private fun SubagentCard(ev: ConversationItem) {
    var expanded by remember { mutableStateOf(false) }
    Card(
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.tertiaryContainer.copy(alpha = 0.28f)),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    Icons.Outlined.SmartToy,
                    null,
                    tint = MaterialTheme.colorScheme.tertiary,
                    modifier = Modifier.size(16.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    "SUBAGENT",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontWeight = FontWeight.Bold,
                )
                Spacer(Modifier.width(6.dp))
                StatusChip(ev.status)
                Spacer(Modifier.weight(1f))
                if (ev.ts.isNotEmpty()) {
                    Text(
                        ev.ts,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.outline,
                    )
                    Spacer(Modifier.width(8.dp))
                }
                AssistChip(
                    onClick = { expanded = !expanded },
                    label = { Text(if (expanded) "Hide" else "Show") },
                )
            }
            if (expanded) {
                Text(
                    ev.content,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                )
            } else {
                Text(
                    ev.content.lineSequence().firstOrNull()?.trim()?.takeIf { it.isNotEmpty() } ?: "Subagent activity",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
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
) {
    // Mirror of iOS `LitterChatMessageRow`: a monospaced uppercase role
    // label ("YOU" in the brand accent, "ASSISTANT" in secondary) above
    // the body. USER messages right-align (trailing) and carry a subtle
    // rounded surface; ASSISTANT messages flow full-width with no
    // container. `alignEnd` drives the horizontal alignment so the
    // dispatch site stays the source of truth for which role trails.
    val roleLabel = when (role) {
        ConversationRole.User -> "YOU"
        ConversationRole.Assistant -> "ASSISTANT"
        ConversationRole.Tool -> "TOOL"
        ConversationRole.System -> "SYSTEM"
    }
    val labelColor = when (role) {
        ConversationRole.User -> agentAccent
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    Column(
        modifier = modifier.fillMaxWidth(),
        horizontalAlignment = if (alignEnd) Alignment.End else Alignment.Start,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            roleLabel,
            style = MaterialTheme.typography.labelSmall,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Bold,
            color = labelColor,
        )
        if (role == ConversationRole.User) {
            // Right-aligned, content-sized surface. `fillMaxWidth(0.82f)`
            // caps long turns at ~82% so they don't span edge-to-edge;
            // `wrapContentWidth(End)` shrinks the surface to its content and
            // pins it to the trailing edge so short turns hug the right.
            Surface(
                shape = RoundedCornerShape(14.dp),
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
                modifier = Modifier.fillMaxWidth(0.82f).wrapContentWidth(Alignment.End),
            ) {
                Column(
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    ConversationRenderer.blocks(ev.content).forEach { block ->
                        when (block) {
                            is ConversationBlock.Markdown -> MarkdownBlock(block.text, role)
                            is ConversationBlock.Code -> CodeBlock(block.language, block.content)
                        }
                    }
                    if (ev.files.isNotEmpty()) FileStrip(ev.files)
                }
            }
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
 * Lightweight "agent is typing…" row: an animated three-dot pulse plus
 * the agent name. Shown at the bottom of the message list while the
 * agent streams (Bug 3 / iOS `isStreaming` parity). Three dots pulse
 * out of phase via an infinite transition.
 */
@Composable
private fun TypingIndicatorRow(assistant: String, accent: Color) {
    val transition = androidx.compose.animation.core.rememberInfiniteTransition(label = "typing")
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            Icons.Outlined.SmartToy,
            contentDescription = null,
            tint = accent,
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
                        .background(MaterialTheme.colorScheme.onSurfaceVariant, CircleShape),
                )
            }
        }
        Text(
            "$assistant is typing…",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun RoleIcon(role: ConversationRole, tint: Color = role.accent) {
    val icon = when (role) {
        ConversationRole.User -> Icons.Outlined.AccountCircle
        ConversationRole.Assistant -> Icons.Outlined.SmartToy
        ConversationRole.Tool -> Icons.Outlined.Build
        ConversationRole.System -> Icons.Outlined.Info
    }
    Icon(icon, null, modifier = Modifier.size(14.dp), tint = tint)
}

@Composable
private fun MarkdownBlock(text: String, role: ConversationRole) {
    val appearance = sh.nikhil.swekitty.LocalAppearanceStore.current
    val fontChoice by appearance.fontFamily.collectAsState()
    val bodyPointSize by appearance.bodyPointSize.collectAsState()
    val resolvedFont = if (fontChoice == sh.nikhil.swekitty.AppearanceStore.FontFamily.Monospaced) {
        FontFamily.Monospace
    } else {
        FontFamily.Default
    }
    val onColor = if (role == ConversationRole.System) {
        MaterialTheme.colorScheme.onSurfaceVariant
    } else {
        MaterialTheme.colorScheme.onSurface
    }

    // Android parity of the iOS chat-polish change: agent markdown was
    // rendering cramped + structurally collapsed — a whole reply went
    // into one `Text`, so GFM tables came out as run-on `| a | b |`
    // text, headings jammed into the following line, and blocks had no
    // vertical rhythm. We now split into typed [LitterMarkdownBlocks]
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
    val blocks = remember(text) { LitterMarkdownBlocks.parse(text) }
    SelectionContainer {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            blocks.forEach { block ->
                when (block) {
                    is LitterMarkdownBlocks.MdBlock.Heading ->
                        MarkdownHeading(block, bodyPointSize, resolvedFont, onColor)
                    is LitterMarkdownBlocks.MdBlock.Paragraph ->
                        MarkdownProse(block.text, bodyPointSize, fontChoice, resolvedFont, onColor, cache)
                    is LitterMarkdownBlocks.MdBlock.ListBlock ->
                        MarkdownList(block, bodyPointSize, resolvedFont, onColor)
                    is LitterMarkdownBlocks.MdBlock.Quote ->
                        MarkdownQuote(block.text, bodyPointSize, resolvedFont)
                    is LitterMarkdownBlocks.MdBlock.Table ->
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
    block: LitterMarkdownBlocks.MdBlock.Heading,
    bodyPointSize: Float,
    font: FontFamily,
    onColor: Color,
) {
    val mult = LitterMarkdownHeadingScaler.multiplier(block.level) ?: 1f
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
    fontChoice: sh.nikhil.swekitty.AppearanceStore.FontFamily,
    font: FontFamily,
    onColor: Color,
    cache: ParsedMarkdownCache,
) {
    val revision = remember(text, bodyPointSize, fontChoice) {
        markdownRevision(text, bodyPointSize, fontChoice)
    }
    val annotated = remember(text, revision) {
        cache.getOrPut(id = text.hashCode().toString(), revision = revision) {
            LitterMarkdownHeadingScaler.scaledAnnotated(text, basePointSize = bodyPointSize)
        }
    }
    Text(
        text = annotated,
        style = MaterialTheme.typography.bodyMedium.copy(
            fontSize = androidx.compose.ui.unit.TextUnit(
                bodyPointSize,
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
    block: LitterMarkdownBlocks.MdBlock.ListBlock,
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
    Row(modifier = Modifier.height(IntrinsicSize.Min)) {
        Box(
            modifier = Modifier
                .width(3.dp)
                .fillMaxHeight()
                .background(MaterialTheme.colorScheme.outline.copy(alpha = 0.6f), RoundedCornerShape(2.dp)),
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
            color = MaterialTheme.colorScheme.onSurfaceVariant,
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
    block: LitterMarkdownBlocks.MdBlock.Table,
    bodyPointSize: Float,
    font: FontFamily,
    onColor: Color,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        block.rows.forEach { row ->
            Surface(
                shape = RoundedCornerShape(12.dp),
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f),
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
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (!language.isNullOrBlank()) {
            Text(
                language.uppercase(),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontWeight = FontWeight.Bold,
            )
        }
        SelectionContainer {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(
                        MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
                        RoundedCornerShape(14.dp),
                    )
                    .padding(12.dp)
                    .horizontalScroll(rememberScrollState()),
            ) {
                Text(
                    text = content,
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurface,
                )
            }
        }
    }
}

@Composable
private fun ConversationToolCard(ev: ConversationItem) {
    // Tool/bash cards start COLLAPSED (iOS #236 parity): the header row
    // alone — label · status · command one-liner · time + chevron — until
    // the user taps to reveal the full COMMAND box + output. Per-card
    // state, so expanding one keeps it open for the session while every
    // new card still arrives collapsed.
    var expanded by remember { mutableStateOf(false) }
    val sections = remember(ev) { ConversationRenderer.toolSections(ev) }
    val summary = remember(ev) {
        val cmd = ev.command?.takeIf { it.isNotBlank() }?.take(80)
        cmd ?: ev.content.lineSequence().firstOrNull()?.trim()?.takeIf { it.isNotEmpty() }?.take(80)
            ?: "Tool activity"
    }
    val headerLabel = ev.toolName?.takeIf { it.isNotBlank() }?.uppercase() ?: ev.kind.uppercase()

    Card(
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.32f)),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Outlined.Build, null, tint = ConversationRole.Tool.accent, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(8.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            headerLabel,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            fontWeight = FontWeight.Bold,
                        )
                        Spacer(Modifier.width(6.dp))
                        StatusChip(ev.status)
                        ev.diffSummary?.takeIf { it.isNotBlank() }?.let { ds ->
                            Spacer(Modifier.width(6.dp))
                            Surface(
                                shape = RoundedCornerShape(50),
                                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.65f),
                            ) {
                                Text(
                                    ds.uppercase(),
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    fontWeight = FontWeight.Bold,
                                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
                                )
                            }
                        }
                    }
                    // The command one-liner lives in the collapsed header
                    // only; once expanded the COMMAND box (below) already
                    // shows it verbatim, so we drop the plain duplicate
                    // (iOS #236 parity).
                    if (!expanded) {
                        Text(summary, style = MaterialTheme.typography.bodyMedium, maxLines = 1)
                    }
                }
                if (ev.ts.isNotEmpty()) {
                    Text(ConversationTimestamp.relative(ev.ts), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.outline)
                    Spacer(Modifier.width(8.dp))
                }
                AssistChip(
                    onClick = { expanded = !expanded },
                    label = { Text(if (expanded) "Hide" else "Show") },
                )
            }

            androidx.compose.animation.AnimatedVisibility(
                visible = expanded,
                enter = fadeIn() + expandVertically(),
                exit = fadeOut() + shrinkVertically(),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    sections.forEach { section ->
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
                }
            }
        }
    }
}

@Composable
private fun CommandBlock(command: String) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            "COMMAND",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontWeight = FontWeight.Bold,
        )
        Surface(
            shape = RoundedCornerShape(12.dp),
            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
        ) {
            SelectionContainer {
                Text(
                    command,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 8.dp),
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurface,
                )
            }
        }
    }
}

@Composable
private fun ToolMetaRow(exitCode: Int?, duration: String?) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        if (exitCode != null) {
            val ok = exitCode == 0
            Surface(shape = CircleShape, color = if (ok) Color(0x2222C55E) else Color(0x22EF4444)) {
                Text(
                    "EXIT $exitCode",
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
                    style = MaterialTheme.typography.labelSmall,
                    color = if (ok) Color(0xFF22C55E) else Color(0xFFEF4444),
                    fontWeight = FontWeight.Bold,
                )
            }
        }
        if (!duration.isNullOrBlank()) {
            Surface(shape = CircleShape, color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f)) {
                Text(
                    "DURATION $duration",
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontWeight = FontWeight.Bold,
                )
            }
        }
    }
}

@Composable
private fun LabeledOutputBlock(title: String, text: String) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            title,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontWeight = FontWeight.Bold,
        )
        CodeBlock(language = null, content = text)
    }
}

@Composable
private fun StatusChip(status: String) {
    val normalized = status.lowercase().ifEmpty { "done" }
    val bg = when (normalized) {
        "running" -> Color(0x22F39C3D)
        "pending" -> Color(0x2238BDF8)
        "failed" -> Color(0x22EF4444)
        else -> Color(0x2222C55E)
    }
    val fg = when (normalized) {
        "running" -> Color(0xFFF39C3D)
        "pending" -> Color(0xFF38BDF8)
        "failed" -> Color(0xFFEF4444)
        else -> Color(0xFF22C55E)
    }
    Surface(shape = CircleShape, color = bg) {
        Text(
            normalized.uppercase(),
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
            style = MaterialTheme.typography.labelSmall,
            color = fg,
            fontWeight = FontWeight.Bold,
        )
    }
}

@Composable
private fun FileStrip(files: List<ViewEventFile>) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            "FILES",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontWeight = FontWeight.Bold,
        )
        files.forEach { file ->
            Surface(
                shape = RoundedCornerShape(12.dp),
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Outlined.Info, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(14.dp))
                    Spacer(Modifier.width(8.dp))
                    Column {
                        Text(file.path, style = MaterialTheme.typography.labelMedium, fontFamily = FontFamily.Monospace)
                        if (file.rev.isNotEmpty()) {
                            Text("@${file.rev.take(7)}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
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
        Text(
            "DIFF",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontWeight = FontWeight.Bold,
        )
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
    var expanded by remember(file.id) { mutableStateOf(true) }
    Surface(
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                AssistChip(
                    onClick = { expanded = !expanded },
                    label = { Text(if (expanded) "Hide" else "Show") },
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    file.path,
                    style = MaterialTheme.typography.labelMedium,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.weight(1f),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    "${file.lines.size} lines",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            if (expanded) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    file.lines.forEach { line ->
                        Text(
                            line,
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = FontFamily.Monospace,
                            color = when {
                                line.startsWith("+") -> Color(0xFF2E7D32)
                                line.startsWith("-") -> MaterialTheme.colorScheme.error
                                line.startsWith("@@") -> Color(0xFFE65100)
                                else -> MaterialTheme.colorScheme.onSurface
                            },
                        )
                    }
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
 * Litter-style composer (Stage 2):
 *  - Single rounded-rect with leading `+`, message field, trailing mic/send
 *  - Send button only appears when draft is non-empty (mic otherwise)
 *  - Agent selector moved to the chat header dropdown, not per-row
 */
@Composable
private fun ConversationComposer(
    draft: String,
    quickReplies: List<String>,
    agentAccent: Color,
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
) {
    val hasDraft = draft.trim().isNotEmpty()
    Column(
        modifier = Modifier
            .fillMaxWidth()
            // No color seam where chat meets the keyboard (iOS #236
            // parity): paint the composer cluster with the SAME backdrop
            // as the chat surface (the wrapping `surfaceVariant 0.35f`
            // Surface in ProjectScreen) and do it BEFORE `imePadding()`,
            // so the fill extends down through the IME-inset band. Without
            // this the band above the keyboard showed the bare window
            // background — a visible mismatched stripe between the chat
            // list and the keyboard.
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f))
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
                    AssistChip(
                        onClick = { onQuickReply(reply) },
                        label = { Text(reply) },
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

        Surface(
            shape = RoundedCornerShape(24.dp),
            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.32f),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Row(
                verticalAlignment = Alignment.Bottom,
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                FilledIconButton(
                    onClick = onAttachClick,
                    colors = androidx.compose.material3.IconButtonDefaults.filledIconButtonColors(
                        containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.7f),
                        contentColor = MaterialTheme.colorScheme.onSurface,
                    ),
                    modifier = Modifier.size(36.dp),
                ) {
                    Icon(Icons.Default.Add, contentDescription = "Attach")
                }
                BasicTextField(
                    value = draft,
                    onValueChange = onDraftChange,
                    textStyle = MaterialTheme.typography.bodyMedium.copy(
                        color = MaterialTheme.colorScheme.onSurface,
                    ),
                    cursorBrush = androidx.compose.ui.graphics.SolidColor(agentAccent),
                    decorationBox = { inner ->
                        Box(modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp, horizontal = 4.dp)) {
                            if (draft.isEmpty()) {
                                Text(
                                    "Message $currentAssistant…",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
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
                        containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.7f),
                        contentColor = MaterialTheme.colorScheme.onSurface,
                    ),
                    modifier = Modifier.size(36.dp),
                ) {
                    Icon(Icons.Outlined.Fullscreen, contentDescription = "Expand composer")
                }
                if (!hasDraft) {
                    InlineVoiceButton { transcript ->
                        val trimmed = transcript.trim()
                        if (trimmed.isNotEmpty()) {
                            val next = if (draft.isBlank()) trimmed else "$draft $trimmed"
                            onDraftChange(next)
                        }
                    }
                } else {
                    FilledIconButton(
                        onClick = onSend,
                        colors = androidx.compose.material3.IconButtonDefaults.filledIconButtonColors(
                            containerColor = agentAccent,
                        ),
                        modifier = Modifier.size(36.dp),
                    ) {
                        Icon(Icons.Default.KeyboardArrowUp, contentDescription = "Send")
                    }
                }
            }
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

/**
 * Compact agent switcher pill — mirror of iOS ChatTab's inline Menu.
 * Reachable while the keyboard is up.
 */
@Composable
private fun AgentSwitchChip(
    currentAssistant: String,
    tint: Color,
    onSwitch: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        AssistChip(
            onClick = { expanded = true },
            label = { Text(currentAssistant, style = MaterialTheme.typography.labelMedium) },
            leadingIcon = {
                Icon(
                    Icons.Outlined.SmartToy,
                    contentDescription = null,
                    tint = tint,
                    modifier = Modifier.size(14.dp),
                )
            },
        )
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            DropdownMenuItem(
                text = { Text("Switch to Claude") },
                enabled = currentAssistant != "claude",
                onClick = { expanded = false; onSwitch("claude") },
            )
            DropdownMenuItem(
                text = { Text("Switch to Codex") },
                enabled = currentAssistant != "codex",
                onClick = { expanded = false; onSwitch("codex") },
            )
        }
    }
}

/**
 * Render an ISO-8601 timestamp as a relative string ("just now",
 * "5 min ago"). Falls back to the raw text when unparseable.
 * Mirrors iOS `ConversationTimestamp.relative`.
 */
internal object ConversationTimestamp {
    fun relative(rawTimestamp: String): String {
        val trimmed = rawTimestamp.trim()
        if (trimmed.isEmpty()) return ""
        val instant = runCatching { java.time.Instant.parse(trimmed) }.getOrNull() ?: return trimmed
        val nowMs = System.currentTimeMillis()
        val tsMs = instant.toEpochMilli()
        return android.text.format.DateUtils.getRelativeTimeSpanString(
            tsMs,
            nowMs,
            android.text.format.DateUtils.MINUTE_IN_MILLIS,
            android.text.format.DateUtils.FORMAT_ABBREV_RELATIVE,
        ).toString()
    }
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
