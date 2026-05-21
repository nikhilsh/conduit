package sh.nikhil.swekitty.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import sh.nikhil.swekitty.SessionStore
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
fun ChatPage(store: SessionStore, session: ProjectSession) {
    val agentAccent = SweKittyTheme.accent(forAgent = session.assistant)
    val typedLog by store.conversationLog.collectAsState()
    val fallbackLog by store.chatLog.collectAsState()
    val events = typedLog[session.id]
        ?: fallbackLog[session.id]?.mapIndexed { idx, ev ->
            ConversationItem(
                id = "${ev.ts}-$idx",
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
        ?: emptyList()
    var draft by remember { mutableStateOf("") }
    var autoFollow by remember { mutableStateOf(true) }
    val listState = rememberLazyListState()

    LaunchedEffect(events.size, autoFollow) {
        if (autoFollow && events.isNotEmpty()) {
            listState.animateScrollToItem(events.size)
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
            LazyColumn(
                state = listState,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = 12.dp, vertical = 10.dp)
                    .pointerInput(Unit) {
                        detectDragGestures { _, _ -> autoFollow = false }
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
                item { Spacer(Modifier.height(1.dp)) }
            }

            androidx.compose.animation.AnimatedVisibility(
                visible = !autoFollow && events.isNotEmpty(),
                modifier = Modifier.align(Alignment.BottomEnd).padding(12.dp),
                enter = fadeIn() + expandVertically(),
                exit = fadeOut() + shrinkVertically(),
            ) {
                AssistChip(
                    onClick = { autoFollow = true },
                    label = { Text("Latest") },
                    leadingIcon = { Icon(Icons.Outlined.ArrowDownward, null) },
                )
            }
        }

        HorizontalDivider()
        ConversationComposer(
            draft = draft,
            quickReplies = remember(events) { QuickReplyDetector.suggestions(events) },
            agentAccent = agentAccent,
            currentAssistant = session.assistant,
            onSwitchAgent = { next -> store.switchAgent(session.id, next) },
            onDraftChange = { draft = it },
            onQuickReply = { reply ->
                draft = if (draft.trim().isEmpty()) reply else "$draft\n$reply"
            },
            onSend = {
                val msg = draft.trim()
                if (msg.isNotEmpty()) {
                    store.sendChat(session.id, msg)
                    draft = ""
                    autoFollow = true
                }
            },
        )
    }
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
            ConversationBubble(ev, ConversationRole.User, agentAccent, Modifier, alignEnd = false)
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
    // Litter pattern: subtle light-gray rounded rect for USER messages
    // (right-aligned), assistant messages flow as plain text full
    // width with no container at all.
    when (role) {
        ConversationRole.User -> Row(modifier = modifier.fillMaxWidth()) {
            Spacer(Modifier.weight(0.18f))
            Surface(
                shape = RoundedCornerShape(14.dp),
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
                modifier = Modifier.weight(0.82f, fill = false),
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
        }
        else -> Column(
            modifier = modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            ConversationRenderer.blocks(ev.content).forEach { block ->
                when (block) {
                    is ConversationBlock.Markdown -> MarkdownBlock(block.text, role)
                    is ConversationBlock.Code -> CodeBlock(block.language, block.content)
                }
            }
        }
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
    val resolvedFont = if (fontChoice == sh.nikhil.swekitty.AppearanceStore.FontFamily.Monospaced) {
        FontFamily.Monospace
    } else {
        FontFamily.Default
    }
    SelectionContainer {
        Text(
            text = text,
            style = MaterialTheme.typography.bodyMedium,
            // Body font driven by AppearanceStore — defaults to monospace
            // (litter / codex aesthetic), switchable via Settings → Font.
            fontFamily = resolvedFont,
            color = if (role == ConversationRole.System) {
                MaterialTheme.colorScheme.onSurfaceVariant
            } else {
                MaterialTheme.colorScheme.onSurface
            },
        )
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
    var expanded by remember { mutableStateOf(true) }
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
                    Text(summary, style = MaterialTheme.typography.bodyMedium, maxLines = 1)
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
    @Suppress("UNUSED_PARAMETER") onSwitchAgent: (String) -> Unit,
    onDraftChange: (String) -> Unit,
    onQuickReply: (String) -> Unit,
    onSend: () -> Unit,
) {
    val hasDraft = draft.trim().isNotEmpty()
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(10.dp)
            .windowInsetsPadding(WindowInsets.navigationBars),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (quickReplies.isNotEmpty()) {
            Row(
                modifier = Modifier.horizontalScroll(rememberScrollState()),
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
                    // Reserved `+` affordance for file attach / snippets;
                    // wired in Stage 5.
                    onClick = {},
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
