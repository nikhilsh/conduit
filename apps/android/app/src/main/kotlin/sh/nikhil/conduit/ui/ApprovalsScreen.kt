package sh.nikhil.conduit.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material.icons.filled.Warning

import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

import sh.nikhil.conduit.ApprovalResolvePhase
import sh.nikhil.conduit.SessionNaming
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry
import sh.nikhil.conduit.firstUserMessageOf
import sh.nikhil.conduit.isAwaitingInput
import uniffi.conduit_core.ConversationItem

/**
 * "Approvals inbox" surface (design handoff §B.5, image 06), Android mirror
 * of iOS `ConduitUI.ApprovalsView`. A dedicated queue of the sessions whose
 * agent is currently BLOCKED on the user — each row shows agent + session
 * name + branch, the exact pending prompt / command, a risk chip
 * (safe / writes files / destructive), and `Approve · Deny · open-chat`.
 *
 * DATA SOURCE — real signal only, no fabrication. The queue is built from
 * the SAME "awaiting input" signal the Home "needs-you" banner uses (see
 * [needsYouBanner] / [isAwaitingInput] in SessionNaming.kt): a session whose
 * LAST [ConversationItem] is a non-user item with `kind == "pending_input"`
 * (Codex `[A]pprove/[E]dit/[R]eject`, numbered menus, `request_user_input`,
 * classified in `core/src/conversation.rs`). We REUSE [isAwaitingInput]
 * verbatim for the gate rather than re-deriving it, and never synthesize an
 * approval item that isn't actually pending.
 *
 * APPROVE / DENY — there is no broker endpoint to programmatically
 * approve/deny an agent prompt; the user normally answers inside the chat.
 * So every action here — Approve, Deny, and the open-chat affordance — calls
 * [onOpenSession] to OPEN THE SESSION'S CHAT, where the user actually
 * responds. We don't fabricate an approve API. (If the broker ever gains a
 * programmatic approve/deny, wire it into [ApprovalAction] here.)
 *
 * PRESENTATION (wired later by the caller): present full-screen (pushed from
 * a Home toolbar / needs-you tap) or inside a sheet. The entry-point's count
 * badge should reflect `approvalQueue(...).size` — the same number as the
 * Home banner. This file does NOT wire any entry point, badge, or push
 * notification; it only renders the queue and exposes the pure helpers.
 */
@Composable
fun ApprovalsScreen(
    store: SessionStore,
    onOpenSession: (String) -> Unit = {},
    onDismiss: () -> Unit = {},
) {

    val neon = LocalNeonTheme.current
    val sessions by store.sessions.collectAsState()
    val conversationLog by store.conversationLog.collectAsState()
    val displayNames by store.displayNames.collectAsState()
    val resolvePhases by store.approvalResolve.collectAsState()
    val autoApprove by store.autoApproveSessions.collectAsState()

    // Build the queue from the live store the same way the Home banner is:
    // each session's last transcript item gates inclusion via the shared
    // [isAwaitingInput]; the same item supplies the prompt + risk.
    val queue = remember(sessions, conversationLog, displayNames) {
        approvalQueue(
            sessions.map { s ->
                val log = conversationLog[s.id]
                ApprovalCandidate(
                    id = s.id,
                    title = SessionNaming.friendlyFor(
                        session = s,
                        custom = displayNames[s.id],
                        firstUserMessage = firstUserMessageOf(log),
                    ),
                    agent = s.assistant,
                    branch = s.branch,
                    conversation = log,
                )
            },
        )
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(neon.bg)
            .windowInsetsPadding(WindowInsets.navigationBars),
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            // Header: back/close + title + count badge.
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
                Column(Modifier.weight(1f)) {
                    Text(
                        "Approvals",
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.Bold,
                        fontSize = 18.sp,
                        color = neon.text,
                    )
                    Text(
                        if (queue.isEmpty()) "nothing waiting on you" else "${queue.size} waiting on you",
                        fontFamily = neon.mono,
                        fontSize = 11.sp,
                        color = neon.textDim,
                    )
                }
                if (queue.isNotEmpty()) {
                    Box(
                        modifier = Modifier
                            .size(28.dp)
                            .background(neon.yellow.copy(alpha = 0.16f), CircleShape)
                            .border(1.dp, neon.yellow.copy(alpha = 0.4f), CircleShape),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            "${queue.size}",
                            fontFamily = neon.mono,
                            fontWeight = FontWeight.Bold,
                            fontSize = 12.sp,
                            color = neon.yellow,
                        )
                    }
                }
            }

            if (queue.isEmpty()) {
                EmptyApprovals(neon)
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(
                        start = 14.dp, end = 14.dp, top = 4.dp, bottom = 18.dp,
                    ),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {

                    items(queue, key = { it.id }) { item ->
                        ApprovalCard(
                            item = item,
                            neon = neon,
                            phase = resolvePhases[item.id] ?: ApprovalResolvePhase.Idle,
                            autoApprove = item.id in autoApprove,
                            onApprove = { store.resolveApprovalInApp(item.id, "approve") },
                            onDeny = { store.resolveApprovalInApp(item.id, "deny") },
                            onToggleAuto = { enabled -> store.setAutoApprove(item.id, enabled) },
                            onOpenSession = onOpenSession,
                            onAnswerPendingAsk = { answer ->
                                Telemetry.breadcrumb("approvals", "pending-ask option tapped",
                                    mapOf("session" to item.id, "option" to answer))
                                store.sendChat(item.id, answer)
                                store.resolvePendingInput(item.id)
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun EmptyApprovals(neon: NeonTheme) {
    Column(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(Icons.Default.VerifiedUser, null, tint = neon.green, modifier = Modifier.size(40.dp))
        Spacer(Modifier.height(12.dp))
        Text(
            "Nothing waiting on you",
            fontFamily = neon.sans,
            fontWeight = FontWeight.SemiBold,
            fontSize = 16.sp,
            color = neon.text,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            "When an agent pauses for a command, file write, or a choice, it shows up here.",
            fontFamily = neon.mono,
            fontSize = 11.5.sp,
            color = neon.textDim,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            modifier = Modifier.padding(horizontal = 40.dp),
        )
    }
}


@Composable
private fun ApprovalCard(
    item: ApprovalItem,
    neon: NeonTheme,
    phase: ApprovalResolvePhase,
    autoApprove: Boolean,
    onApprove: () -> Unit,
    onDeny: () -> Unit,
    onToggleAuto: (Boolean) -> Unit,
    onOpenSession: (String) -> Unit,
    onAnswerPendingAsk: (String) -> Unit = {},
) {
    val tint = neonAgentColor(item.agent, neon)
    val resolving = phase == ApprovalResolvePhase.Resolving
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = RoundedCornerShape(16.dp), fill = neon.surface)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // Header: avatar · name · agent·branch · risk chip
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier
                    .size(38.dp)
                    .background(tint.copy(alpha = if (neon.dark) 0.14f else 0.10f), RoundedCornerShape(11.dp))
                    .border(1.dp, tint.copy(alpha = 0.35f), RoundedCornerShape(11.dp)),
                contentAlignment = Alignment.Center,
            ) { ConduitMark(size = 22.dp, color = tint) }
            Spacer(Modifier.width(11.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    item.title,
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.Bold,
                    fontSize = 15.sp,
                    color = neon.text,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        item.agent.lowercase(),
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 11.sp,
                        color = tint,
                    )
                    item.branch?.takeIf { it.isNotBlank() }?.let { b ->
                        Text("·", fontFamily = neon.mono, fontSize = 11.sp, color = neon.textFaint)
                        Text(
                            b,
                            fontFamily = neon.mono,
                            fontSize = 11.sp,
                            color = neon.textDim,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
            Spacer(Modifier.width(8.dp))
            RiskChip(item.risk, neon)
        }

        // "wants to <ask>" + the exact command / prompt in a code tile.
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                "wants to ${if (item.pendingOptions.isEmpty()) intentPhrase(item.risk) else "ask you something"}",
                fontFamily = neon.sans,
                fontSize = 12.5.sp,
                color = neon.textDim,
            )
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(neon.codeBg, RoundedCornerShape(9.dp))
                    .border(1.dp, neon.border, RoundedCornerShape(9.dp))
                    .padding(10.dp),
            ) {
                Text(
                    item.prompt,
                    fontFamily = neon.mono,
                    fontSize = 12.sp,
                    color = neon.codeText,
                    maxLines = 4,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }


        // Actions: for AskUserQuestion items show tappable option buttons;
        // for command-approval items show the standard Approve / Deny row.
        if (item.pendingOptions.isEmpty()) {
            // Command-approval: Approve / Deny resolve over HTTP.
            Row(horizontalArrangement = Arrangement.spacedBy(9.dp), modifier = Modifier.fillMaxWidth()) {
                ApprovalActionButton("Approve", Icons.Default.Check, neon.green, filled = true, neon = neon, enabled = !resolving, modifier = Modifier.weight(1f)) {
                    onApprove()
                }
                ApprovalActionButton("Deny", Icons.Default.Close, neon.textDim, filled = false, neon = neon, enabled = !resolving, modifier = Modifier.weight(1f)) {
                    onDeny()
                }
                Box(
                    modifier = Modifier
                        .size(width = 44.dp, height = 38.dp)
                        .neonCardSurface(neon = neon, shape = RoundedCornerShape(11.dp), fill = neon.surface, borderColor = neon.border)
                        .clickable { onOpenSession(item.id) },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.AutoMirrored.Filled.Chat, "Open chat", tint = neon.accent, modifier = Modifier.size(16.dp))
                }
            }
        } else {
            // AskUserQuestion: tappable option buttons + chat bubble.
            Row(
                horizontalArrangement = Arrangement.spacedBy(9.dp),
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.Top,
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    item.pendingOptions.forEach { option ->
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(40.dp)
                                .background(neon.accent, RoundedCornerShape(11.dp))
                                .clickable(enabled = !resolving) { onAnswerPendingAsk(option) },
                            contentAlignment = Alignment.CenterStart,
                        ) {
                            Text(
                                option,
                                fontFamily = neon.sans,
                                fontWeight = FontWeight.SemiBold,
                                fontSize = 13.sp,
                                color = neon.accentText,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.padding(horizontal = 14.dp),
                            )
                        }
                    }
                }
                Box(
                    modifier = Modifier
                        .size(width = 44.dp, height = 38.dp)
                        .neonCardSurface(neon = neon, shape = RoundedCornerShape(11.dp), fill = neon.surface, borderColor = neon.border)
                        .clickable { onOpenSession(item.id) },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.AutoMirrored.Filled.Chat, "Open chat", tint = neon.accent, modifier = Modifier.size(16.dp))
                }
            }
        }

        // Honest resolve state — never a fabricated outcome. Stale = broker had
        // nothing pending (open the chat); Failed = couldn't reach the box.
        when (phase) {
            ApprovalResolvePhase.Resolving ->
                ResolveStatusLine("Resolving…", neon.textDim, neon)
            ApprovalResolvePhase.Resolved ->
                ResolveStatusLine("Resolved — agent continuing", neon.green, neon)
            ApprovalResolvePhase.Stale ->
                ResolveStatusLine("Nothing pending — open the chat", neon.textDim, neon)
            ApprovalResolvePhase.Failed ->
                ResolveStatusLine("Couldn't reach the box — try again or open the chat", neon.red, neon)
            ApprovalResolvePhase.Idle -> Unit
        }

        // Per-session "auto-approve in this session" toggle (local, in-memory).
        // While on AND connected, incoming approvals auto-resolve with a quiet
        // audited transcript line.
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.weight(1f)) {
                Text(
                    "Auto-approve in this session",
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 12.5.sp,
                    color = neon.text,
                )
                Text(
                    "Resolves future approvals here automatically while connected.",
                    fontFamily = neon.mono,
                    fontSize = 10.5.sp,
                    color = neon.textDim,
                )
            }
            Spacer(Modifier.width(8.dp))
            Switch(
                checked = autoApprove,
                onCheckedChange = onToggleAuto,
            )
        }
    }
}

@Composable
private fun ResolveStatusLine(text: String, color: Color, neon: NeonTheme) {
    Text(
        text,
        fontFamily = neon.mono,
        fontSize = 11.sp,
        color = color,
    )
}

@Composable

private fun ApprovalActionButton(
    label: String,
    icon: ImageVector,
    tint: Color,
    filled: Boolean,
    neon: NeonTheme,
    enabled: Boolean = true,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val alpha = if (enabled) 1f else 0.5f
    Box(
        modifier = modifier
            .height(40.dp)
            .background(
                (if (filled) tint else tint.copy(alpha = 0.12f)).copy(alpha = if (filled) alpha else 0.12f * alpha),
                RoundedCornerShape(11.dp),
            )
            .border(1.dp, if (filled) Color.Transparent else tint.copy(alpha = 0.3f * alpha), RoundedCornerShape(11.dp))
            .clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(icon, null, tint = if (filled) neon.accentText else tint, modifier = Modifier.size(14.dp))
            Text(
                label,
                fontFamily = neon.sans,
                fontWeight = FontWeight.SemiBold,
                fontSize = 13.sp,
                color = if (filled) neon.accentText else tint,
            )
        }
    }
}

@Composable
private fun RiskChip(risk: ApprovalRisk, neon: NeonTheme) {
    val color = when (risk) {
        ApprovalRisk.DESTRUCTIVE -> neon.red
        ApprovalRisk.WRITES_FILES -> neon.blue
        ApprovalRisk.SAFE -> neon.green
    }
    val icon = when (risk) {
        ApprovalRisk.DESTRUCTIVE -> Icons.Default.Warning
        ApprovalRisk.WRITES_FILES -> Icons.Default.Edit
        ApprovalRisk.SAFE -> Icons.Default.VerifiedUser
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        modifier = Modifier
            .background(color.copy(alpha = 0.12f), RoundedCornerShape(50))
            .border(1.dp, color.copy(alpha = 0.3f), RoundedCornerShape(50))
            .padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
        Icon(icon, null, tint = color, modifier = Modifier.size(10.dp))
        Text(
            risk.label,
            fontFamily = neon.mono,
            fontWeight = FontWeight.SemiBold,
            fontSize = 10.sp,
            color = color,
        )
    }
}

private fun intentPhrase(risk: ApprovalRisk): String = when (risk) {
    ApprovalRisk.DESTRUCTIVE -> "run a destructive command"
    ApprovalRisk.WRITES_FILES -> "write files"
    ApprovalRisk.SAFE -> "run a command"
}

// MARK: - Pure helpers (Compose-free, unit-testable)

/**
 * Honest, heuristic risk for a pending command — derived from the command /
 * prompt text. Clearly best-effort; defaults to [SAFE] when nothing risky is
 * detected (never invents danger). Mirror of iOS `ConduitUI.ApprovalRisk`.
 */
enum class ApprovalRisk(val label: String) {
    /** Irreversible / data-losing (`rm -rf`, `git push --force`, `DROP TABLE`). */
    DESTRUCTIVE("destructive"),

    /** Mutates the working tree / filesystem (writes, moves, installs). */
    WRITES_FILES("writes files"),

    /** Nothing risky detected (or no command to inspect). */
    SAFE("safe"),
}

/** One actionable item in the Approvals queue (pure data). */
data class ApprovalItem(
    val id: String,
    val title: String,
    val agent: String,
    val branch: String?,
    val prompt: String,
    val risk: ApprovalRisk,
    /**
     * Non-empty for AskUserQuestion items (content contains the
     * [[conduit:needs-input]] sentinel). Each entry is a tappable answer
     * option. Empty for command-approval items.
     */
    val pendingOptions: List<String> = emptyList(),
)

/** A per-session candidate fed into [approvalQueue] (carries the raw log). */
data class ApprovalCandidate(
    val id: String,
    val title: String,
    val agent: String,
    val branch: String?,
    val conversation: List<ConversationItem>?,
)

/**
 * Build the Approvals queue. A candidate is included ONLY when it is
 * genuinely awaiting input — gated by the SHARED [isAwaitingInput] (last
 * transcript item is a non-user `pending_input`), the same gate that drives
 * the Home needs-you banner. Input order is preserved. The pending item's
 * `command` / `content` supply the prompt + risk.
 */
fun approvalQueue(candidates: List<ApprovalCandidate>): List<ApprovalItem> =
    candidates.mapNotNull { c ->
        if (!isAwaitingInput(c.conversation)) return@mapNotNull null
        val last = c.conversation?.lastOrNull()
        val content = last?.content ?: ""
        // Detect AskUserQuestion items via the broker sentinel.
        // These must answer via sendChat, not the approval endpoint.
        val isPendingAsk = content.contains(PendingQuestions.PENDING_INPUT_SENTINEL)
        val pendingOptions = if (isPendingAsk) {
            PendingQuestions.parse(content).flatMap { it.options }
        } else {
            emptyList()
        }
        ApprovalItem(
            id = c.id,
            title = c.title,
            agent = c.agent,
            branch = c.branch,
            prompt = approvalPrompt(last?.command, content),
            risk = classifyApprovalRisk(last?.command, content),
            pendingOptions = pendingOptions,
        )
    }

/**
 * Text to surface for a pending item: the structured `command` when present,
 * else the raw prompt body; never empty (falls back to a generic ask).
 */
fun approvalPrompt(command: String?, content: String): String {
    command?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
    val body = content.trim()
    return if (body.isEmpty()) "Agent is waiting for your input" else body
}

/**
 * Heuristic risk from the command (preferred) or prompt body. Destructive
 * patterns win, then file-writing patterns, else [ApprovalRisk.SAFE].
 * Case-insensitive substring match — a transparent heuristic, not a shell
 * parser. Mirror of iOS `ApprovalsViewModel.classifyRisk`.
 */
fun classifyApprovalRisk(command: String?, content: String): ApprovalRisk {
    val haystack = ("${command ?: ""} $content").lowercase()
    if (haystack.isBlank()) return ApprovalRisk.SAFE
    if (DESTRUCTIVE_PATTERNS.any { haystack.contains(it) }) return ApprovalRisk.DESTRUCTIVE
    if (WRITE_PATTERNS.any { haystack.contains(it) }) return ApprovalRisk.WRITES_FILES
    return ApprovalRisk.SAFE
}

private val DESTRUCTIVE_PATTERNS = listOf(
    "rm -rf", "rm -fr", "rm -r ", "git push --force", "git push -f",
    "push --force", "force-push", "force push",
    "drop table", "drop database", "truncate ", "mkfs", "dd if=",
    ":(){", "git reset --hard", "git clean -", "shutdown", "reboot",
    "> /dev/", "chmod -r 777", "kubectl delete", "terraform destroy",
)

private val WRITE_PATTERNS = listOf(
    "git commit", "git add", "git push", "git merge", "git rebase",
    "git checkout", "git stash", "write_file", "writefile",
    "create file", "edit file", "apply patch", "applypatch",
    "npm install", "yarn add", "pnpm add", "pip install", "cargo add",
    "mkdir", "touch ", "mv ", "cp ", "tee ", ">>", "sed -i", "chmod",
)
