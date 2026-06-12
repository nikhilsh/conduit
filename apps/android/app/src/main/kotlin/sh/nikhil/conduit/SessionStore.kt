package sh.nikhil.conduit

import android.content.Context
import android.net.ConnectivityManager
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import sh.nikhil.conduit.auth.OAuthCredential
import sh.nikhil.conduit.auth.OAuthRequest
import sh.nikhil.conduit.state.NetworkReachabilityObserver
import sh.nikhil.conduit.state.ReachabilityEvent
import sh.nikhil.conduit.state.ReachabilityStatus
import sh.nikhil.conduit.ui.SlashCommandClass
import sh.nikhil.conduit.ui.SlashCommandRegistry
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.time.Instant
import java.time.OffsetDateTime
import java.util.UUID
import uniffi.conduit_core.ChatEvent
import uniffi.conduit_core.ConnectionHealth
import uniffi.conduit_core.ConversationItem
import uniffi.conduit_core.PreviewInfo
import uniffi.conduit_core.ProjectSession
import uniffi.conduit_core.SessionStatus
import uniffi.conduit_core.SshCredentials
import uniffi.conduit_core.SshException
import uniffi.conduit_core.SshHostKeyDelegate
import uniffi.conduit_core.SshProgressDelegate
import uniffi.conduit_core.ConduitClient
import sh.nikhil.conduit.auth.AgentLoginCoordinator
import uniffi.conduit_core.ConduitDelegate
import uniffi.conduit_core.ViewEventFile
import uniffi.conduit_core.sshBootstrap as ffiSshBootstrap
import uniffi.conduit_core.sshBootstrapTunneled as ffiSshBootstrapTunneled
import uniffi.conduit_core.SshTunnel
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import java.util.concurrent.CountDownLatch

/**
 * Harness reachability state. The Rust `connect()` only stores a delegate
 * — it doesn't prove the server is reachable — so we distinguish:
 *  - [Linked]: handshake done, no traffic yet
 *  - [Live]:   at least one round-trip succeeded
 * A network error during operations turns us into [Failed].
 */
sealed class HarnessState {
    data object Disconnected : HarnessState()
    data object Connecting : HarnessState()
    data object Linked : HarnessState()
    data object Live : HarnessState()
    /** Transient drop, Rust core is auto-retrying. */
    data class Reconnecting(val attempt: UInt, val maxAttempts: UInt) : HarnessState()
    data class Failed(val reason: String) : HarnessState()

    val isReachable: Boolean get() = this is Linked || this is Live
    /** Keep allowing input through a reconnect — outbound is queued. */
    val canIssueCommands: Boolean get() = isReachable || this is Reconnecting
    val badgeLabel: String get() = when (this) {
        is Disconnected -> "Disconnected"
        is Connecting   -> "Connecting…"
        is Linked       -> "Paired"
        is Live         -> "Live"
        is Reconnecting -> "Reconnecting (${attempt}/${maxAttempts})…"
        is Failed       -> "Offline"
    }
    val failureReason: String? get() = (this as? Failed)?.reason
}

/**
 * UI-level status for the SSH-bootstrap flow. Independent of [HarnessState]:
 * bootstrap runs *before* we have an endpoint, so the progress line lives in
 * the SSH login sheet, not the main pairing status.
 */
sealed class SshBootstrapState {
    data object Idle : SshBootstrapState()
    data class Running(val message: String) : SshBootstrapState()
    data class Failed(val reason: String) : SshBootstrapState()
}

/** Outstanding TOFU prompt. The bridge blocks until the user resolves it. */
data class HostKeyPrompt(
    val host: String,
    val port: UShort,
    val fingerprint: String,
)

/** Per-session lifecycle state, kept separately from the overall harness state. */
sealed class SessionLifecycle {
    data object Creating : SessionLifecycle()
    data object Live : SessionLifecycle()
    data class Exited(val code: Int) : SessionLifecycle()
    data class FailedToStart(val reason: String) : SessionLifecycle()
}

/** Either a confirmed session or an in-flight placeholder for the sidebar. */
sealed class VisibleSession {
    abstract val id: String
    data class Real(val session: ProjectSession) : VisibleSession() {
        override val id: String get() = session.id
    }
    data class Creating(val pendingId: String, val reason: String? = null) : VisibleSession() {
        override val id: String get() = pendingId
    }
}

data class Endpoint(val url: String = "", val token: String = "") {
    val isComplete get() = url.isNotBlank() && token.isNotBlank()

    /** Sanitized host display (strips ws[s]:// scheme and trailing slash). */
    val displayHost: String
        get() {
            var s = url.trim()
            listOf("wss://", "ws://", "https://", "http://").forEach { p ->
                if (s.lowercase().startsWith(p)) {
                    s = s.substring(p.length)
                    return@forEach
                }
            }
            s = s.trimEnd('/')
            return s.ifEmpty { "(no endpoint)" }
        }

    /**
     * http(s) base for resolving relative server paths (`/preview/<uuid>/`,
     * `/memory/sessions/<uuid>.html`). ws → http, wss → https; host + port
     * preserved.
     */
    val httpBaseUrl: String?
        get() {
            val trimmed = url.trim().trimEnd('/')
            if (trimmed.isEmpty()) return null
            val (scheme, rest) = trimmed.split("://", limit = 2).let {
                if (it.size == 2) it[0].lowercase() to it[1] else return null
            }
            val newScheme = when (scheme) {
                "ws"   -> "http"
                "wss"  -> "https"
                "http", "https" -> scheme
                else   -> return null
            }
            val authority = rest.substringBefore('/').substringBefore('?').substringBefore('#')
            return "$newScheme://$authority"
        }
}

/** One-shot UI cue triggered after a successful pairing. AppRoot
 *  observes this and presents the agent-picker bottom sheet. */
data class PendingAgentPick(val hostNote: String)

/**
 * AI-generated quick replies for a session (task #233). [replies] are the
 * short tap-able strings the broker's one-shot model produced;
 * [forMessageId] ties them to the assistant message they were generated
 * for. Parsed from the core's flattened `quick_replies` `onViewEvent`
 * payload (`replies` is a JSON-array string, `for_message_id` plain).
 * Mirror of iOS `AIQuickReplies`.
 */
data class AIQuickReplies(
    val replies: List<String>,
    val forMessageId: String,
) {
    companion object {
        /** Decode the flattened payload, or null when no usable replies. */
        fun from(payload: Map<String, String>): AIQuickReplies? {
            val raw = payload["replies"] ?: return null
            val cleaned = runCatching {
                val arr = JSONArray(raw)
                (0 until arr.length())
                    .mapNotNull { arr.optString(it, "").trim().ifEmpty { null } }
            }.getOrNull() ?: return null
            if (cleaned.isEmpty()) return null
            return AIQuickReplies(
                replies = cleaned.take(4),
                forMessageId = payload["for_message_id"] ?: "",
            )
        }
    }
}

/**
 * One subagent entry as delivered by the broker's `view:"agents"`
 * view_event. Exact JSON keys from the spec: task_id, name, description,
 * status, last_tool, tokens, tool_uses, duration_ms, started_at, ended_at.
 * Mirror of iOS `SubagentEntry`.
 */
data class SubagentEntry(
    val taskId: String,
    val name: String,
    val description: String,
    val status: String,      // "working" | "done" | "failed"
    val lastTool: String,
    val tokens: Long,
    val toolUses: Int,
    val durationMs: Long,
    val startedAt: String,
    val endedAt: String,
) {
    companion object {
        /**
         * Decode the `agents[]` JSON array from the view_event payload
         * (`payload["agents"]` is a JSON-array string). Returns an empty
         * list on any parse error so callers stay resilient to partial
         * broker payloads.
         */
        fun listFrom(payload: Map<String, String>): List<SubagentEntry> {
            val raw = payload["agents"] ?: return emptyList()
            return runCatching {
                val arr = JSONArray(raw)
                (0 until arr.length()).mapNotNull { i ->
                    val obj = arr.optJSONObject(i) ?: return@mapNotNull null
                    SubagentEntry(
                        taskId = obj.optString("task_id", ""),
                        name = obj.optString("name", ""),
                        description = obj.optString("description", ""),
                        status = obj.optString("status", "working"),
                        lastTool = obj.optString("last_tool", ""),
                        tokens = obj.optLong("tokens", 0L),
                        toolUses = obj.optInt("tool_uses", 0),
                        durationMs = obj.optLong("duration_ms", 0L),
                        startedAt = obj.optString("started_at", ""),
                        endedAt = obj.optString("ended_at", ""),
                    )
                }
            }.getOrElse { emptyList() }
        }
    }
}

/**
 * Pairs the in-flight [OAuthRequest] (PKCE verifier + state, kept in
 * memory only) with the redirect [android.net.Uri] delivered to
 * MainActivity by the `conduit://oauth/...` intent filter. The
 * [AgentLoginSheet] observes [SessionStore.oauthCallback] and drives
 * the token exchange when both halves are present.
 */
data class PendingOAuthCallback(
    val request: OAuthRequest,
    val uri: android.net.Uri,
)

/**
 * Non-secret SSH coordinates for a saved server. Stored alongside SavedServer
 * so self-heal can look up the credential without asking the user again.
 * The secret itself lives in SshCredentialStore (EncryptedSharedPreferences).
 */
data class SshEndpointRef(
    val host: String,
    val port: UShort,
    val username: String,
)

data class SavedServer(
    val id: String,
    val name: String,
    val endpoint: Endpoint,
    val isDefault: Boolean,
    /** Non-null when this server was paired via SSH; null for token-paired boxes. */
    val ssh: SshEndpointRef? = null,
)

data class RemoteDirectoryEntry(
    val name: String,
    val path: String,
    val isDir: Boolean,
)

data class RemoteDirectoryListing(
    val path: String,
    val parent: String,
    val entries: List<RemoteDirectoryEntry>,
)

/**
 * Wire shape of `GET /api/fs/harness-status?path=` — whether a directory
 * already carries an agent harness (CLAUDE.md / AGENTS.md). Powers the
 * "Set up agent harness" chip (Part B); `fs/list` is dirs-only so it can't
 * surface these files. Mirror of iOS `RemoteHarnessStatus`.
 */
data class RemoteHarnessStatus(
    val hasClaudeMd: Boolean,
    val hasAgentsMd: Boolean,
    val hasHarness: Boolean,
)

/**
 * Raised by [SessionStore.fetchConversation] when the broker has no
 * persisted transcript for the session — either the session predates
 * the #196 redeploy (no `conversation.jsonl` was written) or the id is
 * unknown. The transcript viewer renders a friendly "no saved
 * transcript" state for this case. Mirrors iOS `ConversationNotFoundError`.
 */
class ConversationNotFoundException : Exception("No saved transcript for this session.")

/**
 * Kind of pinned context attached above the composer. Mirror of iOS
 * `PinnedContext.Kind` in `apps/ios/Sources/SessionStore.swift`.
 */
enum class PinnedContextKind {
    File,
    Url,
    Snippet,
}

/**
 * One pinned context (file, URL, or snippet) that the composer
 * surfaces as a chip above the text field. `payload` is what the next
 * `sendChat` should fold into the outgoing message; `label` is the
 * short string the chip renders. Identifiable so chip rows can animate
 * inserts/removes cleanly. Mirror of iOS `PinnedContext`.
 */
data class PinnedContext(
    val id: String = UUID.randomUUID().toString(),
    val kind: PinnedContextKind,
    val label: String,
    val payload: String,
)

/**
 * Pure-data reducers for pin/unpin on the per-session pinned-context
 * map. Pulled out of [SessionStore] so JUnit tests can exercise the
 * dedupe + per-session isolation rules without instantiating the
 * ViewModel (and therefore without Robolectric). Mirror of the
 * `pinContext(_:for:)` / `unpinContext(_:from:)` semantics on iOS.
 */
internal object PinnedContextReducer {
    /**
     * Append `ctx` to the list for `sessionId`. No-op when an existing
     * entry already matches on (kind, payload) — the iOS reference
     * treats those as duplicates.
     */
    fun pin(
        map: Map<String, List<PinnedContext>>,
        sessionId: String,
        ctx: PinnedContext,
    ): Map<String, List<PinnedContext>> {
        val current = map[sessionId] ?: emptyList()
        if (current.any { it.kind == ctx.kind && it.payload == ctx.payload }) return map
        return map + (sessionId to (current + ctx))
    }

    /**
     * Remove the entry with `id` from the list for `sessionId`. Drops
     * the session key entirely when the list ends up empty so observers
     * see an honest absence rather than `[]`.
     */
    fun unpin(
        map: Map<String, List<PinnedContext>>,
        sessionId: String,
        id: String,
    ): Map<String, List<PinnedContext>> {
        val list = map[sessionId] ?: return map
        val next = list.filterNot { it.id == id }
        return if (next.isEmpty()) map - sessionId else map + (sessionId to next)
    }
}

/**
 * Normalize a conversation `ts` string to epoch millis for ordering.
 * The local user echo stamps ISO_INSTANT ("…Z") while broker items may
 * use an offset form, so comparing the raw strings lexicographically can
 * put a later assistant reply above an earlier user turn (device bug:
 * agent replies appearing before user messages). Tries [Instant.parse]
 * then [OffsetDateTime.parse]; unparseable → 0L (sorts first, with the
 * caller's original index breaking the tie so arrival order is kept).
 */
fun tsEpochMillis(ts: String): Long =
    try {
        Instant.parse(ts).toEpochMilli()
    } catch (_: Exception) {
        try {
            OffsetDateTime.parse(ts).toInstant().toEpochMilli()
        } catch (_: Exception) {
            0L
        }
    }

/**
 * Order conversation items chronologically by `ts`, correctly placing
 * live in-flight items that don't carry a timestamp yet.
 *
 * The previous `compareBy({ tsEpochMillis(ts) }, { index })` re-sort
 * collapsed an unparseable / empty `ts` to `0L` — the SMALLEST possible
 * key — which shoved the agent's freshly-streamed reply (and its command
 * card) to the TOP of the log, above the user's own prompt that triggered
 * it (device bug: agent chat appears before the user chat).
 *
 * The data model is the key insight: every PERSISTED item carries a real
 * nanosecond RFC3339 timestamp, and the only items with an empty/unparseable
 * `ts` are the LIVE, not-yet-persisted items of the in-flight turn — i.e.
 * the newest things in the log. So an unparseable `ts` sorts as
 * [Long.MAX_VALUE] ("just now / still arriving"), which keeps the local user
 * echo (a real, slightly-earlier ISO timestamp) ahead of the streaming reply
 * it kicked off, while persisted history stays in true chronological order.
 * Stable: equal keys break the tie on original arrival index.
 */
fun <T> List<T>.sortedByConversationTs(ts: (T) -> String): List<T> =
    withIndex()
        .sortedWith(
            compareBy(
                { val ms = tsEpochMillis(ts(it.value)); if (ms > 0L) ms else Long.MAX_VALUE },
                { it.index },
            ),
        )
        .map { it.value }

/**
 * Remove the broker's pending-input sentinel line from raw transcript content
 * (the HTTP [SessionStore.fetchConversation] replay bypasses the core
 * classifier, which strips it on the live path). Byte-identical to the broker /
 * core constant; mirrors core `strip_pending_sentinel` and iOS
 * `SessionStore.stripPendingSentinel`.
 */
fun stripPendingSentinel(text: String): String {
    val sentinel = sh.nikhil.conduit.ui.PendingQuestions.PENDING_INPUT_SENTINEL
    if (!text.contains(sentinel)) return text
    return text.split("\n")
        .filter { it.trim() != sentinel }
        .joinToString("\n")
}

/**
 * v1 store: wraps ConduitClient and bridges Rust delegate callbacks back onto
 * the main dispatcher as StateFlow updates. Replaced by Hilt-style DI in v2.
 */
class SessionStore : ViewModel(), ConduitDelegate {

    private val _endpoint = MutableStateFlow(Endpoint())
    val endpoint: StateFlow<Endpoint> = _endpoint.asStateFlow()

    private val _harness = MutableStateFlow<HarnessState>(HarnessState.Disconnected)
    val harness: StateFlow<HarnessState> = _harness.asStateFlow()

    private val _sessions = MutableStateFlow<List<ProjectSession>>(emptyList())
    val sessions: StateFlow<List<ProjectSession>> = _sessions.asStateFlow()

    private val _selectedId = MutableStateFlow<String?>(null)
    val selectedId: StateFlow<String?> = _selectedId.asStateFlow()
    private val _savedServers = MutableStateFlow<List<SavedServer>>(emptyList())
    val savedServers: StateFlow<List<SavedServer>> = _savedServers.asStateFlow()
    private val _recentDirectories = MutableStateFlow<List<String>>(emptyList())
    val recentDirectories: StateFlow<List<String>> = _recentDirectories.asStateFlow()

    private val _statusBySession = MutableStateFlow<Map<String, SessionStatus>>(emptyMap())
    val statusBySession: StateFlow<Map<String, SessionStatus>> = _statusBySession.asStateFlow()

    private val _sessionLifecycle = MutableStateFlow<Map<String, SessionLifecycle>>(emptyMap())
    val sessionLifecycle: StateFlow<Map<String, SessionLifecycle>> = _sessionLifecycle.asStateFlow()

    /**
     * Persisted tombstones for sessions the user has explicitly deleted.
     * Android's lists are driven directly by the broker's [listSessions],
     * and the deployed broker keeps tmux-backed PTYs alive (#199), so a
     * just-deleted session keeps getting reported and would reappear
     * (reading as live → interactive). [refreshSessions] filters
     * [listSessions] against this set so a deleted id NEVER shows again,
     * even across relaunches, regardless of broker state. Ordered
     * newest-last so we can cap the set and evict the oldest. Mirror of
     * iOS `SavedSessionsStore.deletedIDs`.
     */
    private val _deletedIds = MutableStateFlow<List<String>>(emptyList())
    val deletedIds: StateFlow<List<String>> = _deletedIds.asStateFlow()

    /**
     * Persisted archived-session index. Android's History
     * ([SessionSearchScreen]) used to list only the LIVE [sessions], so a
     * session that ended (and dropped out of the broker's active list)
     * disappeared from History with nowhere to live. This index mirrors
     * iOS `SavedSessionsStore`: every live session is upserted here (from
     * [onStatus] / [onExit]) so an ended/archived chat remains visible in
     * History read-only — its transcript stays fetchable from the broker's
     * `archived-sessions/<id>` via [fetchConversation]. Archiving keeps the
     * row; permanent delete tombstones the id and removes the row.
     */
    private val _savedSessions = MutableStateFlow<List<SavedSession>>(emptyList())
    val savedSessions: StateFlow<List<SavedSession>> = _savedSessions.asStateFlow()

    /** Banner-style error for the most recent session-creation failure. */
    private val _sessionCreationError = MutableStateFlow<String?>(null)
    val sessionCreationError: StateFlow<String?> = _sessionCreationError.asStateFlow()

    private val _terminalBuffer = MutableStateFlow<Map<String, ByteArray>>(emptyMap())
    val terminalBuffer: StateFlow<Map<String, ByteArray>> = _terminalBuffer.asStateFlow()

    private val _chatLog = MutableStateFlow<Map<String, List<ChatEvent>>>(emptyMap())
    val chatLog: StateFlow<Map<String, List<ChatEvent>>> = _chatLog.asStateFlow()
    private val _conversationLog = MutableStateFlow<Map<String, List<ConversationItem>>>(emptyMap())
    val conversationLog: StateFlow<Map<String, List<ConversationItem>>> = _conversationLog.asStateFlow()

    /**
     * Per-session optimistic-send queue: messages the user has sent that
     * haven't been acked by a successful WS write yet. Persisted to
     * EncryptedSharedPreferences so a backgrounding-mid-send (or a
     * kill/relaunch) never silently drops a typed message — the
     * device-reported "send then background -> never delivered" bug. Flushed
     * on connect / foreground / reconnect. The transcript echo reads this to
     * draw the clock / "failed" indicator. Mirror of iOS `pendingChats`.
     */
    private val _pendingChats = MutableStateFlow(PendingChatQueue())
    val pendingChats: StateFlow<PendingChatQueue> = _pendingChats.asStateFlow()

    /**
     * Box (SavedServer.id) each session was last reconciled from.
     * Populated when [connect] / [refreshSessions] runs and sessions
     * come from the broker. Survives box switches — entries are only
     * added/updated, never wiped on disconnect. Used to:
     *   1. Show which box a session belongs to on the home list.
     *   2. Gate [attemptDeliver] so a message is never sent to the wrong
     *      broker (root cause of ConduitError: UnknownSession).
     * Mirror of iOS [SessionStore.sessionBox].
     */
    private val _sessionBox = MutableStateFlow<Map<String, String>>(emptyMap())
    val sessionBox: StateFlow<Map<String, String>> = _sessionBox.asStateFlow()

    /** Mutate the pending queue and persist it in one step. */
    private fun updatePendingChats(transform: (PendingChatQueue) -> PendingChatQueue) {
        val next = transform(_pendingChats.value)
        _pendingChats.value = next
        prefs?.edit()?.putString(KEY_PENDING_CHATS, PendingChatQueue.encode(next))?.apply()
    }

    /**
     * AI-generated quick replies per session (task #233). The broker
     * emits a `view:"quick_replies"` view_event when an assistant turn
     * completes; the chat composer renders these as tap-able chips,
     * replacing the old client-side heuristic. Cleared on send / when a
     * fresh turn arrives. Mirror of iOS `SessionStore.quickReplies`.
     */
    private val _quickReplies = MutableStateFlow<Map<String, AIQuickReplies>>(emptyMap())
    val quickReplies: StateFlow<Map<String, AIQuickReplies>> = _quickReplies.asStateFlow()

    /**
     * Per-session subagent roster. Keyed by session id; value is the
     * full snapshot of [SubagentEntry] items delivered by the broker's
     * `view:"agents"` view_event. Entries are retained for the whole
     * session (working + done + failed) ordered by arrival so the panel
     * shows a complete history. In-memory only — rehydrated on reconnect
     * via the broker's PublishText record+replay. Mirror of iOS
     * `SessionStore.subagentRoster`.
     */
    private val _subagentRoster = MutableStateFlow<Map<String, List<SubagentEntry>>>(emptyMap())
    val subagentRoster: StateFlow<Map<String, List<SubagentEntry>>> = _subagentRoster.asStateFlow()

    private val _previews = MutableStateFlow<Map<String, PreviewInfo>>(emptyMap())
    val previews: StateFlow<Map<String, PreviewInfo>> = _previews.asStateFlow()

    /** Per-session connection health from the Rust reconnect worker. */
    private val _connectionHealth = MutableStateFlow<Map<String, ConnectionHealth>>(emptyMap())
    val connectionHealth: StateFlow<Map<String, ConnectionHealth>> = _connectionHealth.asStateFlow()

    /**
     * Last known turnActive value per session. Tracked to detect the
     * active->idle transition and trigger [flushOnTurnComplete]. Not
     * persisted -- the live status frames rebuild this on reconnect.
     * ConcurrentHashMap because [onStatus] arrives on UniFFI worker threads.
     */
    private val _lastTurnActive = java.util.concurrent.ConcurrentHashMap<String, Boolean>()

    /** SSH-bootstrap progress, observed by the SSH login sheet. */
    private val _sshBootstrap = MutableStateFlow<SshBootstrapState>(SshBootstrapState.Idle)
    val sshBootstrap: StateFlow<SshBootstrapState> = _sshBootstrap.asStateFlow()

    /**
     * Sheet-independent error string surfaced after the SSH bootstrap fails.
     * Persists even when the SSH login sheet is dismissed so the main screen can
     * show a banner. Cleared when a new bootstrap attempt starts.
     */
    private val _sshBootstrapError = MutableStateFlow<String?>(null)
    val sshBootstrapError: StateFlow<String?> = _sshBootstrapError.asStateFlow()

    /**
     * Live SSH tunnel for an SSH-bootstrapped session (core #451). Held for
     * the session's lifetime so the russh session — and therefore the loopback
     * port-forward the WS dials — stays up. It's an AutoCloseable-style
     * object; we [SshTunnel.stop] + release it on disconnect / re-bootstrap so
     * we never leak the russh session. `null` for token-paired boxes and when
     * the SSH-tunnel flag is off (legacy fire-and-forget path).
     */
    private var sshTunnel: SshTunnel? = null

    /** Liveness watcher for [sshTunnel]; cancelled when the tunnel is replaced. */
    private var sshTunnelWatcher: Job? = null

    /** Single-flight guard for SSH self-heal. Prevents concurrent reconnect attempts. */
    @Volatile private var isReconnecting: Boolean = false

    /**
     * True once the held tunnel reported `isAlive() == false` (the SSH session
     * died: network flap, server reboot, idle kill, app suspend). Drives a
     * "connection lost — reconnect" affordance. Reset on a fresh tunnel.
     * Token-paired boxes never set this (no tunnel).
     */
    private val _sshTunnelLost = MutableStateFlow(false)
    val sshTunnelLost: StateFlow<Boolean> = _sshTunnelLost.asStateFlow()

    /** Outstanding TOFU prompt; MainActivity observes this and shows a dialog. */
    private val _pendingHostKey = MutableStateFlow<HostKeyPrompt?>(null)
    val pendingHostKey: StateFlow<HostKeyPrompt?> = _pendingHostKey.asStateFlow()

    /**
     * Set after a fresh pairing (deep link, QR scan). AppRoot observes
     * this and presents the agent-picker bottom sheet so the user lands
     * on "pick Claude or Codex" instead of an empty session list.
     */
    private val _pendingAgentPick = MutableStateFlow<PendingAgentPick?>(null)
    val pendingAgentPick: StateFlow<PendingAgentPick?> = _pendingAgentPick.asStateFlow()

    fun setPendingAgentPick(pick: PendingAgentPick?) {
        _pendingAgentPick.value = pick
    }

    /**
     * In-flight [OAuthRequest], armed by [armOAuth] when the
     * AgentLoginSheet launches Chrome Custom Tabs. Held in memory only
     * — leaking the PKCE verifier to disk would defeat the purpose of
     * PKCE. Cleared once [oauthCallback] is consumed.
     */
    @Volatile private var pendingOAuthRequest: OAuthRequest? = null

    private val _oauthCallback = MutableStateFlow<PendingOAuthCallback?>(null)
    val oauthCallback: StateFlow<PendingOAuthCallback?> = _oauthCallback.asStateFlow()

    /** Called from AgentLoginSheet before launching Custom Tabs. */
    fun armOAuth(request: OAuthRequest) {
        pendingOAuthRequest = request
    }

    /**
     * Routed in from MainActivity when an `conduit://oauth/...`
     * intent arrives. Pairs the URI with the in-memory request and
     * publishes the pair so the sheet's LaunchedEffect picks it up
     * and runs the token exchange.
     *
     * Returns `true` if the URI looks like an OAuth callback we
     * have a pending request for (and was routed); `false` if it
     * should fall through to the existing pairing-URL handling.
     */
    fun handleOAuthCallback(uri: android.net.Uri): Boolean {
        val req = pendingOAuthRequest ?: return false
        if (uri.host?.lowercase() != "oauth") return false
        // Only consume the request once.
        pendingOAuthRequest = null
        _oauthCallback.value = PendingOAuthCallback(request = req, uri = uri)
        return true
    }

    fun clearOAuthCallback() {
        _oauthCallback.value = null
    }

    /**
     * Build the `set_agent_credentials` envelope (PLAN §D.1) and ship
     * it over the existing authenticated WS. Mirror of iOS
     * `ConduitClient.setAgentCredentials(_:blob:)`.
     *
     * Status note (Stage 0/1 spike): the Rust core hasn't yet
     * exposed an arbitrary-control-message send path
     * (`ConduitClient.send_input` / `send_chat` are per-session
     * only — there's no `send_json` on the public surface). Until
     * that lands we log the envelope JSON to logcat so on-device
     * QA can eyeball the wire format. The envelope-builder + the
     * call site are both load-bearing for the eventual broker
     * round-trip — they just don't transit a socket yet. Mirrors
     * iOS, which currently `print()`s the credential and defers
     * the WS send to Stage 2.
     */
    suspend fun sendAgentCredentials(credential: OAuthCredential) {
        val c = client ?: throw IllegalStateException("no active conduit client")
        // The broker's set_agent_credentials handler keys the blob by
        // bearer-token identity, not per-session — the core carries it
        // over any live session WS. We ship the credential's native
        // on-disk JSON (auth.json / .credentials.json) so the broker
        // writes it through verbatim. Mirrors iOS sendAgentCredentials.
        c.setAgentCredentials(credential.provider.raw, credential.toJson())
    }

    // Agent OAuth login v2 (outbound) — forward the three control frames
    // through the Rust client. Identity-scoped, carried over any live
    // session WS. Throw if no client is connected so the coordinator
    // surfaces a `.Failed`. Mirror of iOS SessionStore.sendAgentLogin*.

    suspend fun sendAgentLoginStart(provider: String) {
        val c = client ?: throw IllegalStateException("no active conduit client")
        c.startAgentLogin(provider)
    }

    suspend fun sendAgentLoginCallback(sessionToken: String, queryString: String) {
        val c = client ?: throw IllegalStateException("no active conduit client")
        c.agentLoginCallback(sessionToken, queryString)
    }

    suspend fun sendAgentLoginCancel(sessionToken: String) {
        val c = client ?: throw IllegalStateException("no active conduit client")
        c.cancelAgentLogin(sessionToken)
    }

    /**
     * Local rename map — keyed by session id. Persisted to the same
     * EncryptedSharedPreferences blob as the endpoint. Display names are
     * not secrets; using the existing store avoids an extra prefs file.
     */
    private val _displayNames = MutableStateFlow<Map<String, String>>(emptyMap())
    val displayNames: StateFlow<Map<String, String>> = _displayNames.asStateFlow()

    /**
     * Model alias each session was created with (`--model` override), keyed
     * by session id. The broker doesn't report a live model string, so this
     * client-side record is the only honest source for the title menu's
     * identity header (Round-2 fix 2). Absent for sessions that inherited
     * the agent default — the UI says "default model", never a fabrication.
     * Mirror of iOS `SessionStore.modelBySession`.
     */
    private val _modelBySession = MutableStateFlow<Map<String, String>>(emptyMap())
    val modelBySession: StateFlow<Map<String, String>> = _modelBySession.asStateFlow()

    /**
     * Broker AI-generated session titles (task: ai-session-titles), keyed
     * by session id. Delivered as a `view:"session_title"` view_event and
     * folded in by [ingestSessionTitle]. SEPARATE from [_displayNames] so a
     * manual rename always wins; the AI title sits just below it, above the
     * first-message fallback. Persisted so a history row shows the AI name
     * even before the broker re-emits it on attach. Mirror of iOS
     * `SessionStore.brokerTitles`.
     */
    private val _brokerTitles = MutableStateFlow<Map<String, String>>(emptyMap())
    val brokerTitles: StateFlow<Map<String, String>> = _brokerTitles.asStateFlow()

    /**
     * Manually pinned context per session — rendered above the
     * composer as removable chips. Mirror of iOS
     * `SessionStore.pinnedContexts`. In-memory only; the iOS ref also
     * keeps these per-process, so we match the lifetime.
     */
    private val _pinnedContexts = MutableStateFlow<Map<String, List<PinnedContext>>>(emptyMap())
    val pinnedContexts: StateFlow<Map<String, List<PinnedContext>>> = _pinnedContexts.asStateFlow()

    /**
     * Pin a context chip onto `sessionId`. No-op if an identical chip
     * (same kind + payload) is already pinned — keeps the UI from
     * accumulating duplicates when the same file is dragged in twice.
     */
    fun pinContext(ctx: PinnedContext, sessionId: String) {
        _pinnedContexts.value = PinnedContextReducer.pin(_pinnedContexts.value, sessionId, ctx)
    }

    /**
     * Remove a pinned context by id. Used by ContextBar's tap-to-dismiss
     * affordance.
     */
    fun unpinContext(id: String, sessionId: String) {
        _pinnedContexts.value = PinnedContextReducer.unpin(_pinnedContexts.value, sessionId, id)
    }

    /**
     * Friendly, never-a-raw-UUID label for a session. Priority order
     * (Android parity of the iOS list/naming work):
     *  1. user-set custom name ([_displayNames]) — wins.
     *  2. first user chat message (from [_conversationLog]), condensed to
     *     a single ~40-char ellipsized line, ChatGPT/Claude style.
     *  3. a broker-supplied label (folded into [_displayNames] by
     *     [onStatus]) when it isn't itself the raw id.
     *  4. fallback "<agent> · <relative start time>" from `startedAt`.
     *
     * The raw UUID `session.name` is NEVER returned as a user-facing label
     * — it stays in Session Info only. See [SessionNaming.friendly].
     */
    fun displayName(session: ProjectSession): String =
        SessionNaming.friendlyFor(
            session = session,
            custom = _displayNames.value[session.id],
            firstUserMessage = firstUserMessageOf(_conversationLog.value[session.id]),
            aiTitle = _brokerTitles.value[session.id],
        )

    /** Friendly label resolved from loose fields — used where the caller
     *  only has the bits, not a full [ProjectSession] (e.g. a search hit). */
    fun displayName(
        sessionId: String,
        rawName: String,
        agent: String,
        serverLabel: String?,
        startedAt: String?,
    ): String =
        SessionNaming.friendly(
            sessionId = sessionId,
            rawName = rawName,
            agent = agent,
            custom = _displayNames.value[sessionId],
            firstUserMessage = firstUserMessageOf(_conversationLog.value[sessionId]),
            serverLabel = serverLabel,
            startedAt = startedAt,
            aiTitle = _brokerTitles.value[sessionId],
        )

    fun renameSession(sessionId: String, newName: String) {
        val trimmed = newName.trim()
        val next = _displayNames.value.toMutableMap()
        if (trimmed.isEmpty()) {
            next.remove(sessionId)
        } else {
            next[sessionId] = trimmed
        }
        _displayNames.value = next
        prefs?.edit()?.putString(KEY_DISPLAY_NAMES, encodeDisplayNames(next))?.apply()
    }

    /**
     * Fork — create a new session with the same agent + branch, seed
     * the new conversation with a hand-off note. Fully client-side;
     * docs/PLAN-CONDUIT-UI.md Stage 3 flagged a Rust `fork_session`
     * UDL method as a future optimization, but client-side is enough.
     */
    /**
     * Fork onto a (possibly) different reasoning effort and/or model.
     * [reasoningEffort] / [model] are optional overrides applied to the
     * NEW session's agent (via core create_session → broker WS query
     * params → agent CLI flags). null for either = keep the original's
     * (the broker falls back to the adapter default). Effort can't change
     * mid-session — that's why forking is the path, not a live switch.
     */
    fun forkSession(sessionId: String, reasoningEffort: String? = null, model: String? = null, permissionMode: String? = null, fastMode: Boolean? = null) {
        val c = client ?: return
        val original = _sessions.value.firstOrNull { it.id == sessionId } ?: return
        val pickedMode = permissionMode?.trim()?.takeIf { it.isNotEmpty() }
        val modeCrumb = pickedMode ?: "auto"
        Telemetry.breadcrumb("session", "fork override", mapOf(
            "assistant" to original.assistant,
            "permission_mode" to modeCrumb,
            "session_id" to sessionId,
        ))
        viewModelScope.launch {
            try {
                val newId = withContext(Dispatchers.IO) {
                    c.createSession(original.assistant, original.branch, reasoningEffort, model, null, pickedMode, fastMode)
                }
                val seed = "Forked from ${original.name} (id $sessionId). Pick up where the previous session left off."
                runCatching { withContext(Dispatchers.IO) { c.sendChat(newId, seed) } }
                updateLifecycle { it + (newId to SessionLifecycle.Live) }
                refreshSessions()
                _selectedId.value = newId
                renameSession(newId, "Fork: ${displayName(original)}")
            } catch (t: Throwable) {
                val detail = describe(t)
                _sessionCreationError.value = "fork: $detail"
                Telemetry.capture(
                    error = t,
                    message = "Android fork session failed",
                    tags = mapOf("surface" to "android", "phase" to "fork_session"),
                    extras = mapOf("endpoint" to _endpoint.value.displayHost, "session_id" to sessionId, "detail" to detail),
                )
            }
        }
    }

    /**
     * Parse a `conduit://...` URL, save the endpoint, connect, and
     * arm `pendingAgentPick` so the picker sheet shows automatically.
     * Called from MainActivity on intent.data arrival.
     */
    fun applyDeepLink(raw: String) {
        val parsed = sh.nikhil.conduit.PairingURL.parse(raw) ?: return
        val ep = Endpoint(url = parsed.endpoint, token = parsed.token)
        Telemetry.breadcrumb("onboarding", sh.nikhil.conduit.ui.OnboardingStep.PAIRING_SUCCEEDED,
            mapOf("transport" to "deep_link", "host" to ep.displayHost))
        setEndpoint(ep.url, ep.token)
        upsertSavedServer(name = ep.displayHost, endpoint = ep, makeDefault = true)
        disconnect()
        connect()
        _pendingAgentPick.value = PendingAgentPick(hostNote = ep.displayHost)
    }

    /** Wired by the bridge; consumed by the dialog's Accept/Reject buttons. */
    @Volatile private var hostKeyResolver: ((Boolean) -> Unit)? = null

    private var hostKeyTrustStore: SshHostKeyTrustStore? = null
    private var sshCredentialStore: SshCredentialStore? = null

    private var client: ConduitClient? = null
    private var prefs: android.content.SharedPreferences? = null
    private var reachability: NetworkReachabilityObserver? = null

    /// Directory holding per-session terminal scrollback for cold-launch
    /// restore (set in [hydrate]). See the persistence section below.
    private var scrollbackDir: java.io.File? = null
    private val terminalPersistDirty =
        java.util.Collections.synchronizedSet(mutableSetOf<String>())
    private val terminalPersistScheduled =
        java.util.concurrent.atomic.AtomicBoolean(false)

    private val lifecycleObserver = object : DefaultLifecycleObserver {
        override fun onResume(owner: LifecycleOwner) {
            // App came back from background — local sockets may be
            // silently dead. Nudge every worker into reconnect, and
            // re-pull every session's conversation: a reply that landed
            // while suspended only exists in the broker's
            // conversation.jsonl (live events aren't replayed on
            // re-attach), so without this the transcript stays stale and
            // the typing indicator spins forever. Mirror of iOS.
            client?.notifyNetworkChange()
            refreshSessions()
            // Foregrounding may have re-armed a socket that died while
            // suspended — flush any message the user sent right before they
            // backgrounded the app (the lost-send bug).
            flushPendingChats()
        }

        override fun onStop(owner: LifecycleOwner) {
            // App is backgrounding — flush dirty terminal scrollback NOW so a
            // subsequent process death still leaves the last-known terminal on
            // disk for an instant cold-launch restore.
            flushTerminalPersist()
        }
    }

    fun hydrate(ctx: Context) {
        if (prefs == null) {
            val master = MasterKey.Builder(ctx)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            prefs = EncryptedSharedPreferences.create(
                ctx,
                "conduit-endpoint",
                master,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
            val p = prefs!!
            _endpoint.value = Endpoint(
                url = p.getString(KEY_URL, "") ?: "",
                token = p.getString(KEY_TOKEN, "") ?: "",
            )
            _savedServers.value = decodeSavedServers(p.getString(KEY_SAVED_SERVERS, null))
            _displayNames.value = decodeDisplayNames(p.getString(KEY_DISPLAY_NAMES, null))
            _brokerTitles.value = decodeDisplayNames(p.getString(KEY_BROKER_TITLES, null))
            _deletedIds.value = decodeDeletedIds(p.getString(KEY_DELETED_IDS, null))
            _savedSessions.value = SavedSessionsReducer.decode(p.getString(KEY_SAVED_SESSIONS, null))
            _pendingChats.value = PendingChatQueue.decode(p.getString(KEY_PENDING_CHATS, null))
            refreshRecentDirectories()
            if (_endpoint.value.isComplete && _savedServers.value.none { it.endpoint == _endpoint.value }) {
                upsertSavedServer(_endpoint.value.displayHost, _endpoint.value, makeDefault = true)
            }
            scrollbackDir = java.io.File(ctx.applicationContext.cacheDir, "terminal-scrollback")
            installNetworkAndLifecycleHooks(ctx.applicationContext)
            hostKeyTrustStore = SshHostKeyTrustStore.forContext(ctx.applicationContext)
            sshCredentialStore = SshCredentialStore.forContext(ctx.applicationContext)
        }
    }

    private fun installNetworkAndLifecycleHooks(appCtx: Context) {
        ProcessLifecycleOwner.get().lifecycle.addObserver(lifecycleObserver)

        val cm = appCtx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return
        // A.9 ("reachability-observer") hoisted the raw NetworkCallback
        // wiring into [NetworkReachabilityObserver]. We collect its
        // status flow and reduce each transition to "should we nudge
        // the Rust core?" via the shared `classifyTransition` policy —
        // same vocabulary the iOS surface uses.
        val observer = NetworkReachabilityObserver(cm)
        reachability = observer
        var lastStatus: ReachabilityStatus = ReachabilityStatus.Unknown
        viewModelScope.launch {
            observer.status.collect { next ->
                val prev = lastStatus
                lastStatus = next
                val event = NetworkReachabilityObserver.classifyTransition(prev, next)
                if (event == ReachabilityEvent.BecameReachable ||
                    event == ReachabilityEvent.InterfaceChanged) {
                    client?.notifyNetworkChange()
                }
            }
        }
        observer.start()
    }

    override fun onCleared() {
        super.onCleared()
        ProcessLifecycleOwner.get().lifecycle.removeObserver(lifecycleObserver)
        reachability?.stop()
        reachability = null
        // Never leak the russh session / loopback listener when the VM dies.
        teardownSshTunnel()
    }

    fun setEndpoint(url: String, token: String) {
        val e = Endpoint(url.trim(), token.trim())
        _endpoint.value = e
        prefs?.edit()
            ?.putString(KEY_URL, e.url)
            ?.putString(KEY_TOKEN, e.token)
            ?.apply()
        refreshRecentDirectories()
    }

    fun upsertSavedServer(name: String, endpoint: Endpoint, makeDefault: Boolean, sshRef: SshEndpointRef? = null) {
        val current = _savedServers.value.toMutableList()
        val existing = current.indexOfFirst { it.endpoint == endpoint }
        if (existing >= 0) {
            val defaultFlag = if (makeDefault) true else current[existing].isDefault
            val updatedSsh = sshRef ?: current[existing].ssh
            current[existing] = current[existing].copy(name = name, isDefault = defaultFlag, ssh = updatedSsh)
        } else {
            current += SavedServer(
                id = UUID.randomUUID().toString(),
                name = if (name.isBlank()) endpoint.displayHost else name,
                endpoint = endpoint,
                isDefault = makeDefault || current.isEmpty(),
                ssh = sshRef,
            )
        }
        if (makeDefault) {
            val defaultId = current.firstOrNull { it.endpoint == endpoint }?.id
            for (i in current.indices) current[i] = current[i].copy(isDefault = current[i].id == defaultId)
        }
        _savedServers.value = current
        persistSavedServers(current)
    }

    /**
     * Rename a saved server in-place (Fix 4). Writes the new [name] into the
     * [SavedServer] entry and persists immediately. No-op when the id is unknown.
     */
    fun renameSavedServer(serverId: String, name: String) {
        val current = _savedServers.value.toMutableList()
        val idx = current.indexOfFirst { it.id == serverId }
        if (idx < 0) return
        current[idx] = current[idx].copy(name = name.trim().ifEmpty { current[idx].name })
        _savedServers.value = current
        persistSavedServers(current)
        Telemetry.breadcrumb("boxes", "server renamed", mapOf("id" to serverId))
    }

    fun selectSavedServer(serverId: String, autoConnect: Boolean) {
        val server = _savedServers.value.firstOrNull { it.id == serverId } ?: return
        val next = _savedServers.value.map { it.copy(isDefault = it.id == serverId) }
        _savedServers.value = next
        persistSavedServers(next)
        val endpointChanged = server.endpoint != _endpoint.value
        setEndpoint(server.endpoint.url, server.endpoint.token)
        if (autoConnect) {
            if (server.ssh != null) {
                // SSH box: the persisted endpoint is a loopback ws://127.0.0.1:<port>
                // that is only valid while THAT box's russh tunnel is running. Switching
                // to an SSH box (or re-selecting one whose tunnel dropped) must
                // re-bootstrap the tunnel rather than dialing a dead loopback port.
                // If the held tunnel is still alive and the endpoint hasn't changed
                // (same box, still live) we can skip bootstrap and just bounce the WS.
                val tunnelAlive = sshTunnel?.isAlive() == true
                if (tunnelAlive && !endpointChanged) {
                    // Tunnel is up — just bounce the WebSocket layer.
                    disconnect()
                    connect()
                } else {
                    // No live tunnel for the target box — re-bootstrap.
                    // attemptSshSelfHeal uses _endpoint.value (already updated above)
                    // to look up the SSH ref and re-run the full tunnel bootstrap.
                    Telemetry.breadcrumb(
                        "ssh_tunnel",
                        "selectSavedServer triggering re-bootstrap",
                        mapOf(
                            "server" to serverId,
                            "endpointChanged" to endpointChanged.toString(),
                            "tunnelAlive" to tunnelAlive.toString(),
                        ),
                    )
                    attemptSshSelfHeal()
                }
            } else {
                // Token-paired (conduit://) box — plain disconnect+reconnect.
                disconnect()
                connect()
            }
        }
    }

    /**
     * Switch to [serverId]'s endpoint, reconnect, and create a session on
     * it once the harness can issue commands again. Mirror of iOS
     * `connectAndStart`; drives the new-session sheet's box picker
     * (round 3: "I can't choose where to start the session in").
     */
    fun connectAndStart(
        serverId: String,
        assistant: String,
        cwd: String?,
        reasoningEffort: String? = null,
        model: String? = null,
        permissionMode: String? = null,
        fastMode: Boolean? = null,
        initialPrompt: String? = null,
    ) {
        Telemetry.breadcrumb(
            "session",
            "connect+start",
            mapOf("server" to serverId, "assistant" to assistant, "hasCwd" to (!cwd.isNullOrBlank()).toString()),
        )
        selectSavedServer(serverId, autoConnect = true)
        viewModelScope.launch {
            val ready = withTimeoutOrNull(15_000L) {
                harness.first { it.canIssueCommands }
            }
            if (ready != null) {
                createSession(assistant = assistant, startupCwd = cwd, reasoningEffort = reasoningEffort, model = model, permissionMode = permissionMode, fastMode = fastMode, initialPrompt = initialPrompt)
            } else {
                Telemetry.capture(
                    IllegalStateException("connect+start timed out"),
                    "connect+start failed",
                    tags = mapOf("surface" to "android", "phase" to "connect_and_start"),
                    extras = mapOf("server" to serverId, "assistant" to assistant),
                )
                _harness.value = HarnessState.Failed("Connect/start failed: box never became ready")
            }
        }
    }

    fun removeSavedServer(serverId: String) {
        val wasCurrent = _savedServers.value.firstOrNull { it.id == serverId }?.endpoint == _endpoint.value
        val next = _savedServers.value.filterNot { it.id == serverId }.toMutableList()
        if (next.isNotEmpty() && next.none { it.isDefault }) {
            next[0] = next[0].copy(isDefault = true)
        }
        _savedServers.value = next
        persistSavedServers(next)
        if (next.isEmpty()) {
            forgetEndpoint()
        } else if (wasCurrent) {
            setEndpoint(next[0].endpoint.url, next[0].endpoint.token)
        }
    }

    /**
     * Drop a saved server entirely — removes the row from
     * [savedServers], clears any locally-stored display-name override
     * keyed by that id, and persists both to disk
     * (EncryptedSharedPreferences). Idempotent; safe to call with an
     * unknown id.
     *
     * Mirror of iOS `SessionStore.forgetServer(_:)` (PR #128). This is
     * the entry point UI affordances (swipe-to-dismiss in Settings,
     * "Forget" long-press on the server pill) call. It builds on
     * [removeSavedServer] for the savedServers + endpoint bookkeeping
     * but additionally sweeps the display-name override — without that
     * step a stale rename for a `SavedServer.id` we just dropped would
     * linger in EncryptedSharedPreferences forever.
     */
    fun forgetServer(id: String) {
        removeSavedServer(id)
        if (_displayNames.value.containsKey(id)) {
            val next = _displayNames.value.toMutableMap()
            next.remove(id)
            _displayNames.value = next
            prefs?.edit()?.putString(KEY_DISPLAY_NAMES, encodeDisplayNames(next))?.apply()
        }
    }

    fun forgetEndpoint() {
        disconnect()
        _endpoint.value = Endpoint()
        prefs?.edit()
            ?.remove(KEY_URL)
            ?.remove(KEY_TOKEN)
            ?.apply()
    }

    fun connect() {
        val e = _endpoint.value
        if (!e.isComplete) {
            _harness.value = HarnessState.Failed("Set an endpoint and token in Settings.")
            return
        }
        _harness.value = HarnessState.Connecting
        val c = ConduitClient(e.url, e.token)
        client = c
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { c.connect(this@SessionStore) }
                _harness.value = HarnessState.Linked
                Telemetry.breadcrumb("onboarding", "endpoint_connected",
                    mapOf("host" to _endpoint.value.displayHost,
                          "first_server" to (_savedServers.value.size == 1).toString()))
                refreshSessions()
                // Connection is live again — re-deliver any messages queued
                // while disconnected (reconnect window / backgrounded
                // mid-send / killed before the WS flushed).
                flushPendingChats()
            } catch (t: Throwable) {
                val detail = describe(t)
                _harness.value = HarnessState.Failed(detail)
                Telemetry.capture(
                    error = t,
                    message = "Android harness connect failed",
                    tags = mapOf("surface" to "android", "phase" to "connect"),
                    extras = mapOf("endpoint" to _endpoint.value.displayHost, "detail" to detail),
                )
            }
        }
    }

    fun disconnect() {
        disconnectClient()
        // Tear down any held SSH tunnel so we never leak the russh session /
        // loopback listener. No-op for token-paired boxes (tunnel is null).
        teardownSshTunnel()
    }

    /**
     * Tear down only the WS client, leaving any held SSH tunnel intact. Used
     * by [reconnect] so a WS-only blip on an SSH-tunneled box re-dials the
     * SAME live loopback port instead of killing (and leaking) the russh
     * session it depends on.
     */
    private fun disconnectClient() {
        client?.disconnect()
        client = null
        _harness.value = HarnessState.Disconnected
    }

    /**
     * Re-establish the link using the currently stored endpoint.
     *
     * If an SSH tunnel is held AND still alive, this is a WS-only restart: the
     * tunnel is preserved so we re-dial the same live loopback port. If the
     * tunnel is nil/dead AND the current server has an SSH ref, route through
     * [attemptSshSelfHeal] (full re-bootstrap with backoff). Otherwise
     * (token-paired box) do a plain disconnect+reconnect.
     */
    fun reconnect() {
        val tunnel = sshTunnel
        if (tunnel != null && tunnel.isAlive()) {
            disconnectClient()
            connect()
        } else if (_savedServers.value.firstOrNull { it.endpoint == _endpoint.value }?.ssh != null) {
            // Dead or null tunnel on an SSH-paired server — self-heal.
            attemptSshSelfHeal()
        } else {
            disconnect()
            connect()
        }
    }

    // MARK: - SSH tunnel lifecycle (core #451)

    /** Whether SSH-paired boxes route through the held tunnel. Default ON;
     *  flip off to fall back to the legacy public path for one release. */
    private fun sshTunnelTransportEnabled(): Boolean =
        prefs?.getBoolean(KEY_SSH_TUNNEL, true) ?: true

    /**
     * Install a freshly-bootstrapped tunnel (or clear to the legacy path when
     * null) and start the liveness watcher. Always stops the prior tunnel
     * first so a re-bootstrap never leaks the old russh session.
     */
    private fun adoptSshTunnel(tunnel: SshTunnel?) {
        teardownSshTunnel()
        sshTunnel = tunnel
        _sshTunnelLost.value = false
        if (tunnel == null) return
        startSshTunnelWatcher()
    }

    /** Stop + release the held tunnel and cancel its watcher. Idempotent. */
    private fun teardownSshTunnel() {
        sshTunnelWatcher?.cancel()
        sshTunnelWatcher = null
        sshTunnel?.let { tunnel ->
            Telemetry.breadcrumb("ssh_tunnel", "tunnel stop", mapOf("local_port" to tunnel.localPort().toInt().toString()))
            tunnel.stop()
            tunnel.close()
        }
        sshTunnel = null
    }

    /**
     * Poll the held tunnel's `isAlive()` on a slow cadence. On the first
     * `false` (SSH session died) hand off to [attemptSshSelfHeal] which retries
     * with exponential backoff before falling back to the terminal Failed state.
     */
    private fun startSshTunnelWatcher() {
        sshTunnelWatcher = viewModelScope.launch {
            // ~3s cadence: cheap, non-blocking `is_closed()` check. The WS
            // reconnect worker usually notices the dead loopback dial first;
            // this is the authoritative SSH-level signal.
            while (isActive) {
                delay(3_000)
                val tunnel = sshTunnel ?: return@launch
                if (!withContext(Dispatchers.IO) { tunnel.isAlive() }) {
                    val portStr = tunnel.localPort().toInt().toString()
                    Telemetry.breadcrumb("ssh_tunnel", "tunnel lost", mapOf("local_port" to portStr))
                    Telemetry.capture(
                        error = IllegalStateException("ssh tunnel lost"),
                        message = "Android SSH tunnel lost",
                        tags = mapOf("surface" to "android", "phase" to "ssh_tunnel"),
                        extras = mapOf("local_port" to portStr),
                    )
                    attemptSshSelfHeal()
                    return@launch
                }
            }
        }
    }

    /**
     * Exponential-backoff self-heal for a dropped SSH tunnel. Looks up the
     * persisted credential for the current server (stored unconditionally on
     * every successful bootstrap), re-runs the bootstrap, and retries up to
     * [maxAttempts] times before surfacing the terminal Failed state.
     *
     * Single-flight: [isReconnecting] prevents the liveness watcher and
     * [reconnect] from both firing concurrently.
     */
    private fun attemptSshSelfHeal() {
        if (isReconnecting) {
            Telemetry.breadcrumb("ssh_tunnel", "self-heal skipped (already reconnecting)")
            return
        }

        // Require a saved SSH ref on the current server — token-paired boxes
        // have no SSH ref and must never trigger self-heal.
        val ref = _savedServers.value.firstOrNull { it.endpoint == _endpoint.value }?.ssh
        if (ref == null) {
            Telemetry.breadcrumb("ssh_tunnel", "self-heal aborted — no ssh ref for current server")
            _sshTunnelLost.value = true
            _harness.value = HarnessState.Failed("Connection to your server was lost. Reconnect to continue.")
            return
        }

        isReconnecting = true
        _sshBootstrap.value = SshBootstrapState.Running("Reconnecting…")

        viewModelScope.launch {
            try {
                val maxAttempts = 6
                var delaySecs = 2_000L
                val credStore = sshCredentialStore

                for (attempt in 1..maxAttempts) {
                    if (!isActive) break

                    Telemetry.breadcrumb("ssh_tunnel", "self-heal attempt",
                        mapOf("attempt" to attempt.toString(), "host" to ref.host))

                    val saved = credStore?.load()?.firstOrNull {
                        it.host == ref.host && it.port == ref.port && it.username == ref.username
                    }
                    if (saved == null) {
                        Telemetry.breadcrumb("ssh_tunnel", "self-heal aborted — no saved credential",
                            mapOf("host" to ref.host, "attempt" to attempt.toString()))
                        break
                    }

                    val auth = when (saved.kind) {
                        SavedSshCredential.Kind.Password ->
                            uniffi.conduit_core.SshAuth.Password(saved.secret)
                        SavedSshCredential.Kind.PrivateKey ->
                            uniffi.conduit_core.SshAuth.PrivateKey(saved.secret, saved.passphrase)
                    }
                    val credentials = SshCredentials(
                        host = ref.host,
                        port = ref.port,
                        username = ref.username,
                        auth = auth,
                    )

                    val hostKeyBridge = SshHostKeyBridge(this@SessionStore, ref.host, ref.port)
                    val progressBridge = SshProgressBridge(this@SessionStore, ref.host)
                    val preToken = java.util.UUID.randomUUID().toString()
                    val useTunnel = sshTunnelTransportEnabled()

                    try {
                        val (result, tunnel) = if (useTunnel) {
                            Telemetry.breadcrumb("ssh_tunnel", "self-heal bootstrap start",
                                mapOf("host" to ref.host))
                            val bootstrap = withContext(Dispatchers.IO) {
                                ffiSshBootstrapTunneled(
                                    credentials, preToken, "", "", null,
                                    BuildConfig.VERSION_NAME, hostKeyBridge, progressBridge,
                                )
                            }
                            Pair(bootstrap.result, bootstrap.tunnel)
                        } else {
                            val r = withContext(Dispatchers.IO) {
                                ffiSshBootstrap(
                                    credentials, preToken, "", "", null,
                                    BuildConfig.VERSION_NAME, hostKeyBridge, progressBridge,
                                )
                            }
                            Pair(r, null)
                        }

                        // Success: update the saved server entry for this SSH ref to
                        // point at the new loopback port, then swap in + reconnect.
                        val newUrl = "ws://127.0.0.1:${result.localPort.toInt()}"
                        val newEndpoint = Endpoint(newUrl, result.token)
                        val current = _savedServers.value.toMutableList()
                        val idx = current.indexOfFirst { it.ssh == ref }
                        if (idx >= 0) {
                            for (i in current.indices) current[i] = current[i].copy(isDefault = i == idx)
                            current[idx] = current[idx].copy(endpoint = newEndpoint, isDefault = true)
                        } else {
                            for (i in current.indices) current[i] = current[i].copy(isDefault = false)
                            current += SavedServer(
                                id = java.util.UUID.randomUUID().toString(),
                                name = "${ref.username}@${ref.host}",
                                endpoint = newEndpoint,
                                isDefault = true,
                                ssh = ref,
                            )
                        }
                        _savedServers.value = current
                        persistSavedServers(current)
                        setEndpoint(newUrl, result.token)
                        disconnect()
                        adoptSshTunnel(tunnel)
                        connect()
                        _sshBootstrap.value = SshBootstrapState.Idle
                        _sshTunnelLost.value = false
                        Telemetry.breadcrumb("ssh_tunnel", "self-heal succeeded",
                            mapOf("attempt" to attempt.toString(), "host" to ref.host))
                        return@launch
                    } catch (e: Exception) {
                        Telemetry.breadcrumb("ssh_tunnel", "self-heal attempt failed",
                            mapOf("attempt" to attempt.toString(), "host" to ref.host,
                                  "error" to (e.message ?: e.toString())))
                    }

                    if (attempt < maxAttempts) {
                        delay(delaySecs)
                        delaySecs = minOf(delaySecs * 2, 30_000L)
                    }
                }

                // Exhausted — terminal failure.
                Telemetry.capture(
                    error = IllegalStateException("ssh self-heal exhausted"),
                    message = "Android SSH self-heal exhausted",
                    tags = mapOf("surface" to "android", "phase" to "ssh_self_heal"),
                    extras = mapOf("host" to ref.host, "attempts" to "6"),
                )
                _sshTunnelLost.value = true
                _sshBootstrap.value = SshBootstrapState.Idle
                _harness.value = HarnessState.Failed("Connection to your server was lost. Reconnect to continue.")
            } finally {
                isReconnecting = false
            }
        }
    }

    // MARK: - SSH bootstrap

    /**
     * Drive the UniFFI `sshBootstrap` from a credential the user typed in the
     * SSH login sheet. On success, swap in the new ws://127.0.0.1:<port>
     * endpoint and call [connect]. Errors and progress are surfaced through
     * [sshBootstrap].
     */
    fun connectViaSSH(
        credentials: SshCredentials,
        serverName: String? = null,
        anthropicApiKey: String = "",
        openaiApiKey: String = "",
        imageRef: String? = null,
    ) {
        val host = credentials.host
        val port = credentials.port
        val user = credentials.username

        // Single-flight guard: if a bootstrap is already in progress, ignore
        // the duplicate call (belt-and-suspenders beyond the UI disabledReasons check).
        if (_sshBootstrap.value is SshBootstrapState.Running) {
            Telemetry.breadcrumb("ssh_addbox", "connect ignored (already running)")
            return
        }

        // Clear any prior sheet-independent error so stale messages don't linger.
        _sshBootstrapError.value = null

        // Breadcrumb before anything else so we can confirm this function was
        // reached even if the coroutine or bootstrap throws before the first await.
        Telemetry.breadcrumb(
            "ssh_addbox",
            "connectViaSSH reached",
            mapOf("host" to host, "port" to port.toInt().toString(), "user" to user),
        )
        _sshBootstrap.value = SshBootstrapState.Running("Connecting to $user@$host:$port…")
        val hostKeyBridge = SshHostKeyBridge(this, host, port)
        val progressBridge = SshProgressBridge(this, host)
        viewModelScope.launch {
            val preToken = java.util.UUID.randomUUID().toString()
            try {
                // SSH-tunnel transport (core #451): hold the returned
                // [SshTunnel] for the session's lifetime so the bearer token
                // rides the SSH-encrypted channel and the box needs no public
                // port. Gated behind a flag so the legacy fire-and-forget path
                // stays available as a one-release fallback. Token-paired boxes
                // never reach here — this is the SSH-bootstrap flow only.
                val useTunnel = sshTunnelTransportEnabled()

                // Helper that runs the actual bootstrap call — extracted so the
                // ECONNRESET retry can call it twice without duplication.
                suspend fun runBootstrap(): Pair<uniffi.conduit_core.SshBootstrapResult, SshTunnel?> {
                    return if (useTunnel) {
                        Telemetry.breadcrumb("ssh_tunnel", "bootstrap (tunneled) start", mapOf("host" to host))
                        val bootstrap = withContext(Dispatchers.IO) {
                            ffiSshBootstrapTunneled(
                                credentials,
                                preToken,
                                anthropicApiKey,
                                openaiApiKey,
                                imageRef,
                                BuildConfig.VERSION_NAME,
                                hostKeyBridge,
                                progressBridge,
                            )
                        }
                        Telemetry.breadcrumb(
                            "ssh_tunnel",
                            "tunnel open",
                            mapOf("host" to host, "local_port" to bootstrap.tunnel.localPort().toInt().toString()),
                        )
                        Pair(bootstrap.result, bootstrap.tunnel)
                    } else {
                        val r = withContext(Dispatchers.IO) {
                            ffiSshBootstrap(
                                credentials,
                                preToken,
                                anthropicApiKey,
                                openaiApiKey,
                                imageRef,
                                BuildConfig.VERSION_NAME,
                                hostKeyBridge,
                                progressBridge,
                            )
                        }
                        Pair(r, null)
                    }
                }

                // Run bootstrap; on ECONNRESET, wait 1.5s and retry once.
                val (result, tunnel) = try {
                    runBootstrap()
                } catch (e: SshException.Handshake) {
                    val msg = e.message?.lowercase() ?: ""
                    if (msg.contains("reset by peer") || msg.contains("os error 54")
                            || msg.contains("connection reset")) {
                        Telemetry.breadcrumb("ssh_addbox", "ECONNRESET on first attempt — retrying once",
                            mapOf("host" to host))
                        _sshBootstrap.value = SshBootstrapState.Running("Retrying connection…")
                        delay(1_500)
                        runBootstrap()
                    } else {
                        throw e
                    }
                }

                val url = "ws://127.0.0.1:${result.localPort.toInt()}"
                val token = result.token
                val endpoint = Endpoint(url, token)
                val name = serverName?.takeIf { it.isNotBlank() } ?: "$user@$host"
                val sshRef = SshEndpointRef(host = host, port = port, username = user)
                setEndpoint(url, token)
                upsertSavedServer(name = name, endpoint = endpoint, makeDefault = true, sshRef = sshRef)
                // Unconditionally persist the credential so self-heal always has it —
                // not gated on the "Remember" checkbox in the login sheet.
                val credKind = when (credentials.auth) {
                    is uniffi.conduit_core.SshAuth.Password -> SavedSshCredential.Kind.Password
                    is uniffi.conduit_core.SshAuth.PrivateKey -> SavedSshCredential.Kind.PrivateKey
                    else -> SavedSshCredential.Kind.Password
                }
                val credSecret = when (val a = credentials.auth) {
                    is uniffi.conduit_core.SshAuth.Password -> a.password
                    is uniffi.conduit_core.SshAuth.PrivateKey -> a.keyPem
                    else -> ""
                }
                val credPassphrase = when (val a = credentials.auth) {
                    is uniffi.conduit_core.SshAuth.PrivateKey -> a.passphrase
                    else -> null
                }
                sshCredentialStore?.save(SavedSshCredential(
                    host = host,
                    port = port,
                    username = user,
                    kind = credKind,
                    secret = credSecret,
                    passphrase = credPassphrase,
                ))
                disconnect()
                // `disconnect()` stops + releases any prior tunnel; install the
                // new one (if tunneled) and start watching its liveness before
                // dialing so a drop during connect is observed.
                adoptSshTunnel(tunnel)
                connect()
                _sshBootstrap.value = SshBootstrapState.Idle
                Telemetry.breadcrumb("onboarding", sh.nikhil.conduit.ui.OnboardingStep.PAIRING_SUCCEEDED,
                    mapOf("transport" to "ssh", "host" to host))
            } catch (e: SshException) {
                val detail = describeSsh(e)
                _sshBootstrap.value = SshBootstrapState.Failed(detail)
                // Also persist the error outside the sheet so it's visible even
                // after the user dismissed the SSH login sheet.
                _sshBootstrapError.value = detail
                Telemetry.capture(
                    error = e,
                    message = "Android SSH bootstrap failed",
                    tags = mapOf("surface" to "android", "phase" to "ssh_bootstrap", "code" to sshCode(e)),
                    extras = mapOf("host" to host, "user" to user, "detail" to detail),
                )
            } catch (t: Throwable) {
                val detail = t.message ?: t.toString()
                _sshBootstrap.value = SshBootstrapState.Failed(detail)
                _sshBootstrapError.value = detail
                Telemetry.capture(
                    error = t,
                    message = "Android SSH bootstrap failed",
                    tags = mapOf("surface" to "android", "phase" to "ssh_bootstrap", "code" to "unknown"),
                    extras = mapOf("host" to host, "user" to user, "detail" to detail),
                )
            }
        }
    }

    /** Called by [SshHostKeyBridge] on a worker thread; UI thread shows the dialog. */
    internal fun requestHostKeyDecision(
        host: String,
        port: UShort,
        fingerprint: String,
        onResolved: (Boolean) -> Unit,
    ) {
        val store = hostKeyTrustStore
        if (store != null) {
            val known = store.known(host, port)
            if (known != null && known == fingerprint) {
                onResolved(true)
                return
            }
        }
        hostKeyResolver = onResolved
        _pendingHostKey.value = HostKeyPrompt(host, port, fingerprint)
    }

    fun resolveHostKeyPrompt(accept: Boolean) {
        val prompt = _pendingHostKey.value ?: return
        if (accept) {
            hostKeyTrustStore?.trust(prompt.host, prompt.port, prompt.fingerprint)
        }
        _pendingHostKey.value = null
        val resolver = hostKeyResolver
        hostKeyResolver = null
        resolver?.invoke(accept)
    }

    fun clearSshBootstrap() {
        _sshBootstrap.value = SshBootstrapState.Idle
    }

    /** Called by [SshProgressBridge] on the main thread to update bootstrap progress. */
    internal fun updateSshBootstrapProgress(message: String) {
        _sshBootstrap.value = SshBootstrapState.Running(message)
    }

    private fun describeSsh(e: SshException): String = when (e) {
        is SshException.Dial                -> "Couldn't reach the host: ${e.message}"
        is SshException.Handshake           -> "SSH handshake failed: ${e.message}"
        is SshException.HostKeyRejected     -> "Host key rejected: ${e.message}"
        is SshException.AuthFailed          -> "Authentication failed: ${e.message}"
        // Dead variants — bare-binary bootstrap never emits these.
        is SshException.DockerMissing       -> "This box isn't supported: Docker-based setup is no longer used."
        is SshException.DockerPermission    -> "This box isn't supported: Docker-based setup is no longer used."
        is SshException.PortConflict        -> "Server port is already in use: ${e.message}"
        is SshException.HarnessStartTimeout -> "Server took too long to come up: ${e.message}"
        is SshException.BrokerInstallFailed -> "Couldn't download the conduit broker — this box can't reach the release host (firewall/proxy?), or the download failed. Check egress and reconnect. (${e.message})"
        is SshException.CurlMissing         -> "This box has no curl or wget — install one and reconnect."
        is SshException.UnsupportedPlatform -> "conduit doesn't support this box (${e.message}). Supported: Linux x86_64 / arm64."
        is SshException.BrokerExecFailed    -> "The conduit broker won't run on this box (architecture mismatch, noexec home, or a security policy). This box isn't supported. (${e.message})"
        is SshException.HomeUnwritable      -> "Can't write to the home directory on this box (read-only or out of disk)."
        is SshException.BootstrapExitCode   -> "Bootstrap script failed: ${e.message}"
        is SshException.BootstrapParse      -> "Couldn't parse bootstrap output: ${e.message}"
        is SshException.PortForward         -> "Port forward failed: ${e.message}"
        is SshException.Io                  -> "I/O error: ${e.message}"
    }

    private fun sshCode(e: SshException): String = when (e) {
        is SshException.Dial                -> "dial"
        is SshException.Handshake           -> "handshake"
        is SshException.HostKeyRejected     -> "host_key_rejected"
        is SshException.AuthFailed          -> "auth_failed"
        is SshException.DockerMissing       -> "docker_missing"
        is SshException.DockerPermission    -> "docker_permission"
        is SshException.PortConflict        -> "port_conflict"
        is SshException.HarnessStartTimeout -> "harness_start_timeout"
        is SshException.BrokerInstallFailed -> "broker_install_failed"
        is SshException.CurlMissing         -> "curl_missing"
        is SshException.UnsupportedPlatform -> "unsupported_platform"
        is SshException.BrokerExecFailed    -> "broker_exec_failed"
        is SshException.HomeUnwritable      -> "home_unwritable"
        is SshException.BootstrapExitCode   -> "bootstrap_exit"
        is SshException.BootstrapParse      -> "bootstrap_parse"
        is SshException.PortForward         -> "port_forward"
        is SshException.Io                  -> "io"
    }

    fun connectAndStart(endpoint: Endpoint? = null, assistant: String, cwd: String) {
        endpoint?.let {
            setEndpoint(it.url, it.token)
            upsertSavedServer(name = it.displayHost, endpoint = it, makeDefault = true)
        }
        disconnect()
        connect()
        viewModelScope.launch {
            val ready = waitUntilCommandReady()
            if (!ready) {
                _harness.value = HarnessState.Failed("Connect/start failed: server did not become ready in time.")
                return@launch
            }
            createSession(assistant = assistant, startupCwd = cwd)
        }
    }

    fun clearSessionCreationError() {
        _sessionCreationError.value = null
    }

    fun select(sessionId: String?) { _selectedId.value = sessionId }

    /**
     * Switch the active session — drives `AppRoot`'s selection-based
     * navigation (the `selectedId` StateFlow swaps the rendered
     * `ProjectScreen`). No reducer / Rust-core call; the existing
     * `AppRoot` observer picks this up and re-binds the destination.
     *
     * Lives here (not in the multi-thread sheet) so the thread switcher
     * and any future "jump to thread" deep link share one entry point.
     * Mirrors iOS `SessionStore.switchTo(sessionID:)`. PR H owns the
     * reducer path; this is the navigation-level setter only. No-op if
     * the target session is unknown to the client, guarding against a
     * stale row tap after a session exited and was reaped.
     */
    fun switchTo(sessionID: String) {
        val known = _sessions.value.any { it.id == sessionID } ||
            _sessionLifecycle.value.containsKey(sessionID)
        if (!known) return
        _selectedId.value = sessionID
    }

    /**
     * Whether a session is read-only — there's no live WS to interact
     * with, so the `ProjectScreen` collapses to a chat-only,
     * composer-less transcript (hide the Terminal/Chat/Browser tab strip
     * + the in-session dock). Mirrors iOS `SessionStore.isReadOnly`.
     *
     * READ-ONLY IS THE DEFAULT. A session opens interactive only when we
     * can positively confirm it is *currently live on the broker* — i.e.
     * [isConfirmedLive]. Everything else (exited, failed,
     * recovered-but-not-running, archived, or a stale row we merely
     * listed without a fresh running status) is read-only.
     *
     * This inversion fixes the "History still interactive" bug (iOS
     * PR #214): the old logic defaulted to interactive and only flipped
     * read-only on a *confirmed-exited* signal (lifecycle [Exited] or a
     * status phase of `exited…`). But [refreshSessions] / [onStatus]
     * blanket-marked every listed or status-bearing session [Live], so a
     * dead session the broker never explicitly reported as exited (app
     * disconnected when it died, a recovered session, a non-running
     * phase) stayed interactive forever. We now require proof of
     * liveness rather than proof of death.
     */
    fun isReadOnly(sessionID: String): Boolean = !isConfirmedLive(sessionID)

    /**
     * True only when the session is positively known to be running on
     * the broker *right now*. Requires BOTH:
     *   1. a non-terminal local lifecycle ([SessionLifecycle.Live] /
     *      [SessionLifecycle.Creating] — never [SessionLifecycle.Exited]
     *      / [SessionLifecycle.FailedToStart]), and
     *   2. a current broker status whose `phase` is a live/running phase
     *      (see [isLivePhase]). A session with no status at all is
     *      treated as not-confirmed-live: we listed it but the broker
     *      hasn't told us it's running.
     *
     * [SessionLifecycle.Creating] is honored without a status because a
     * brand-new session we just spun up locally has no broker status yet
     * but is genuinely on its way live — the create round-trip owns that
     * state. A confirmed-exited phase (raced ahead) still wins.
     */
    fun isConfirmedLive(sessionID: String): Boolean {
        return when (_sessionLifecycle.value[sessionID]) {
            is SessionLifecycle.Exited,
            is SessionLifecycle.FailedToStart -> false
            null -> {
                // No local lifecycle entry — e.g. a session restored from
                // the saved list or re-listed after a reconnect, before any
                // create round-trip recorded a lifecycle. Trust the broker:
                // a current running phase means it's interactive. Without
                // this a reconnected "running" session opened read-only
                // (device bug: codex listed as running but the chat had no
                // composer until re-created). Fails closed with no status.
                val phase = _statusBySession.value[sessionID]?.phase
                if (phase != null) isLivePhase(phase) else false
            }
            is SessionLifecycle.Creating -> {
                // Newly-created session mid-handshake: interactive, even
                // before the first status frame. A confirmed-exited phase
                // (raced ahead) still demotes.
                val phase = _statusBySession.value[sessionID]?.phase
                phase == null || isLivePhase(phase)
            }
            is SessionLifecycle.Live -> {
                // `Live` is necessary but not sufficient — it can be a
                // stale default. Demand a current running phase if we
                // have a status; if we somehow have a `Live` lifecycle
                // with no status (e.g. a freshly-created session promoted
                // by the create path) trust the lifecycle.
                val phase = _statusBySession.value[sessionID]?.phase ?: return true
                isLivePhase(phase)
            }
        }
    }

    /**
     * Attach to a session still LIVE on the broker but not yet in our
     * local live set — the "open a historical row" path from the
     * Sessions screen. Mirrors iOS `attachLiveSession`.
     *
     * A fresh client's [listSessions] is empty until status frames
     * arrive, so we can't [switchTo] synchronously. Instead we
     * `joinSession` (which opens the WS for an existing id, the same
     * `open_session` route `createSession` takes) and poll until the
     * row materializes before navigating.
     *
     * Idempotent: if the session is already live locally we [switchTo]
     * and return. Assumes the caller already selected the right server.
     */
    fun attachLiveSession(sessionID: String, assistant: String) {
        if (_sessions.value.any { it.id == sessionID }) {
            switchTo(sessionID)
            return
        }
        // Cold-launch restore: seed the terminal from the last persisted
        // scrollback so the view paints instantly instead of waiting for the
        // socket. The broker's authoritative snapshot REPLACES this once
        // [joinSession] lands ([onSnapshot]).
        hydrateTerminalBuffer(sessionID)
        viewModelScope.launch {
            try {
                if (!waitUntilCommandReady()) return@launch
                val c = client ?: return@launch
                // Mark creating so the home list shows the row attaching
                // rather than vanishing during the round-trip.
                if (_sessionLifecycle.value[sessionID] == null) {
                    updateLifecycle { it + (sessionID to SessionLifecycle.Creating) }
                }
                withContext(Dispatchers.IO) { c.joinSession(sessionID, assistant) }
                refreshSessions()
                // Poll briefly for the joined session to surface in
                // listSessions(); status frames can lag the WS open.
                val deadline = System.currentTimeMillis() + 6_000L
                while (_sessions.value.none { it.id == sessionID } &&
                    System.currentTimeMillis() < deadline
                ) {
                    delay(100)
                    refreshSessions()
                }
                if (_sessions.value.any { it.id == sessionID }) {
                    // Promote the placeholder using the broker's reported
                    // phase, not a blanket `Live` (iOS PR #214). Joining an
                    // existing id can resolve to a session that already
                    // exited; in that case [onStatus] has set `Exited` (so
                    // we're no longer `Creating` and skip this), or — if no
                    // status landed yet but the cached phase is terminal —
                    // we lock it read-only here. Otherwise promote to live
                    // and the destination opens interactive. Either way
                    // navigate so the user lands on the (correctly read-only
                    // or live) session rather than a dead-end.
                    if (_sessionLifecycle.value[sessionID] is SessionLifecycle.Creating) {
                        val phase = _statusBySession.value[sessionID]?.phase
                        if (phase != null && phase.lowercase().startsWith("exited")) {
                            val code = exitCode(phase) ?: 0
                            updateLifecycle { it + (sessionID to SessionLifecycle.Exited(code)) }
                        } else if (phase == null || isLivePhase(phase)) {
                            // Live phase, or no status yet (a join we
                            // initiated — trust it as live until a status
                            // frame says otherwise).
                            updateLifecycle { it + (sessionID to SessionLifecycle.Live) }
                        }
                        // A non-live, non-exited phase leaves `Creating` in
                        // place; the next status frame resolves it.
                    }
                    _selectedId.value = sessionID
                } else if (_sessionLifecycle.value[sessionID] is SessionLifecycle.Creating) {
                    // Never showed up — clear the placeholder so the list
                    // doesn't keep a stuck "attaching" row.
                    updateLifecycle { it - sessionID }
                }
            } catch (t: Throwable) {
                if (_sessionLifecycle.value[sessionID] is SessionLifecycle.Creating) {
                    updateLifecycle { it - sessionID }
                }
                Telemetry.capture(
                    error = t,
                    message = "Android attach live session failed",
                    tags = mapOf("surface" to "android", "phase" to "attach_session"),
                    extras = mapOf("endpoint" to _endpoint.value.displayHost, "session_id" to sessionID),
                )
            }
        }
    }

    fun createSession(
        assistant: String,
        branch: String? = null,
        startupCwd: String? = null,
        reasoningEffort: String? = null,
        model: String? = null,
        permissionMode: String? = null,
        fastMode: Boolean? = null,
        initialPrompt: String? = null,
    ) {
        val c = client ?: return
        _sessionCreationError.value = null
        val pendingId = "pending-${UUID.randomUUID()}"
        updateLifecycle { it + (pendingId to SessionLifecycle.Creating) }
        // Log the ACTUAL model slug, not just a bool — codex `--model` is
        // passed to the backend unvalidated, so a bad slug (a model the backend
        // doesn't know) lets the session spawn fine but fails every turn.
        // Without the slug here that failure is undiagnosable from Sentry.
        // "inherit" = no override.
        val modelCrumb = model?.trim()?.takeIf { it.isNotEmpty() } ?: "inherit"
        val effortCrumb = reasoningEffort?.trim()?.takeIf { it.isNotEmpty() } ?: "default"
        val modeCrumb = permissionMode?.trim()?.takeIf { it.isNotEmpty() } ?: "auto"
        Telemetry.breadcrumb("session", "create start", mapOf("assistant" to assistant, "hasCwd" to (startupCwd?.isNotBlank() == true).toString(), "model" to modelCrumb, "effort" to effortCrumb, "mode" to modeCrumb))
        viewModelScope.launch {
            try {
                // Pass the selected folder as the agent's cwd so the broker
                // spawns the agent *in* it. (Previously this cd'd the PTY
                // shell as a workaround, which only moved the Terminal tab —
                // the headless agent still started in the broker's default
                // .conduit work dir.)
                val startup = startupCwd?.trim()?.takeIf { it.isNotEmpty() }
                val pickedModel = model?.trim()?.takeIf { it.isNotEmpty() }
                val pickedEffort = reasoningEffort?.trim()?.takeIf { it.isNotEmpty() }
                val pickedMode = permissionMode?.trim()?.takeIf { it.isNotEmpty() }
                val id = withContext(Dispatchers.IO) { c.createSession(assistant, branch, pickedEffort, pickedModel, startup, pickedMode, fastMode) }
                Telemetry.breadcrumb("session", "created", mapOf("assistant" to assistant, "id" to id))
                // Funnel: first-ever session creation (no prior sessions on any launch).
                if (_sessions.value.isEmpty()) {
                    Telemetry.breadcrumb("onboarding", sh.nikhil.conduit.ui.OnboardingStep.FIRST_SESSION_CREATED,
                        mapOf("assistant" to assistant, "host" to _endpoint.value.displayHost))
                }
                // Record the explicit --model override for the title menu's
                // identity header (inherit stays absent on purpose).
                pickedModel?.let { picked -> _modelBySession.value = _modelBySession.value + (id to picked) }
                startup?.let { rememberRecentDirectory(it) }
                updateLifecycle { (it - pendingId) + (id to SessionLifecycle.Live) }
                _harness.value = HarnessState.Live
                refreshSessions()
                _selectedId.value = id
                // Seed the first turn (e.g. a voice-dictated prompt) through the
                // same path as a normal composer send: optimistic local echo so
                // the user sees their prompt + slash-command handling. The old
                // fire-and-forget `runCatching { c.sendChat }` here silently
                // dropped the prompt on any transient — the device-reported
                // "talk on home, start a session, prompt never sent".
                initialPrompt?.trim()?.takeIf { it.isNotEmpty() }?.let { prompt ->
                    Telemetry.breadcrumb("session", "seed prompt", mapOf("id" to id, "chars" to prompt.length.toString()))
                    sendChat(id, prompt)
                }
            } catch (t: Throwable) {
                val reason = describe(t)
                updateLifecycle { it + (pendingId to SessionLifecycle.FailedToStart(reason)) }
                _sessionCreationError.value = reason
                if (isAuth(t)) {
                    // SSH boxes: token mismatch is recoverable via re-bootstrap.
                    // Token-paired boxes: the pairing QR is genuinely expired.
                    if (_savedServers.value.firstOrNull { it.endpoint == _endpoint.value }?.ssh != null) {
                        Telemetry.breadcrumb("session", "auth failure on SSH box — triggering self-heal",
                            mapOf("phase" to "create_session", "endpoint" to _endpoint.value.displayHost))
                        _harness.value = HarnessState.Reconnecting(1u, 3u)
                        attemptSshSelfHeal()
                    } else {
                        _harness.value = HarnessState.Failed("Pairing expired. Scan a new QR code from the server.")
                    }
                }
                Telemetry.capture(
                    error = t,
                    message = "Android create session failed",
                    tags = mapOf("surface" to "android", "phase" to "create_session", "assistant" to assistant, "model" to modelCrumb),
                    extras = mapOf("endpoint" to _endpoint.value.displayHost, "detail" to reason),
                )
                // Sweep the placeholder after a short delay so the user can
                // see *why* without having a stuck row forever.
                launch {
                    delay(4_000)
                    updateLifecycle { it - pendingId }
                }
            }
        }
    }

    fun switchAgent(sessionId: String, assistant: String) {
        val c = client ?: return
        viewModelScope.launch {
            try { withContext(Dispatchers.IO) { c.switchAgent(sessionId, assistant) } }
            catch (t: Throwable) {
                val detail = describe(t)
                _sessionCreationError.value = "switch_agent: $detail"
                if (isAuth(t)) {
                    if (_savedServers.value.firstOrNull { it.endpoint == _endpoint.value }?.ssh != null) {
                        Telemetry.breadcrumb("session", "auth failure on SSH box — triggering self-heal",
                            mapOf("phase" to "switch_agent", "endpoint" to _endpoint.value.displayHost))
                        _harness.value = HarnessState.Reconnecting(1u, 3u)
                        attemptSshSelfHeal()
                    } else {
                        _harness.value = HarnessState.Failed("Pairing expired. Scan a new QR code from the server.")
                    }
                }
                Telemetry.capture(
                    error = t,
                    message = "Android switch agent failed",
                    tags = mapOf("surface" to "android", "phase" to "switch_agent", "assistant" to assistant),
                    extras = mapOf("endpoint" to _endpoint.value.displayHost, "session_id" to sessionId, "detail" to detail),
                )
            }
        }
    }

    /**
     * TWO-TIER delete, tier 1 — ARCHIVE (the active-list swipe/long-press
     * action). Ends the live session on the broker to free resources but
     * KEEPS it viewable read-only in History. Concretely:
     *  - persist a snapshot into the archived index ([recordSavedSession]
     *    with `isExited = true`) BEFORE we drop the live row, so there's
     *    data to show in History even though the broker will stop listing
     *    the session;
     *  - drop it from the live [sessions] + clear lifecycle so the home row
     *    disappears immediately (optimistic);
     *  - issue the authoritative broker DELETE (kills agent + tmux, archives
     *    the dir server-side under `archived-sessions/<id>` so the
     *    transcript stays fetchable via [fetchConversation]);
     *  - DO NOT tombstone — the session must still appear in History.
     *
     * Because the archived session is no longer live, [isReadOnly] returns
     * true for it, so opening it from History yields the read-only
     * transcript surface. Mirror of the iOS two-tier delete's archive path.
     */
    fun archive(sessionId: String) {
        // Snapshot into History before the live row + status are gone.
        recordSavedSession(sessionId, isExited = true)
        // Optimistic removal so the row disappears immediately.
        _sessions.value = _sessions.value.filterNot { it.id == sessionId }
        updateLifecycle { it - sessionId }
        if (_selectedId.value == sessionId) _selectedId.value = null
        viewModelScope.launch {
            // WS `exit` closes the live socket + flushes a checkpoint when a
            // session is attached. Best-effort: an exited session has no live
            // handle, and the HTTP DELETE below is the authoritative teardown.
            client?.let { c -> runCatching { withContext(Dispatchers.IO) { c.exitSession(sessionId) } } }
            // Authoritative broker-side delete: kills the agent process +
            // tmux, removes the session from the broker's active set, and
            // archives its dir. Without this the broker kept recovering the
            // session on disk and the row reappeared / sessions piled up. The
            // broker preserves the transcript under `archived-sessions/<id>`,
            // so History stays read-only-viewable. No live WS handle required.
            runCatching { deleteSession(sessionId) }.onFailure { t ->
                Telemetry.capture(
                    error = t,
                    message = "Android session archive failed",
                    tags = mapOf("surface" to "android", "phase" to "session_archive"),
                    extras = mapOf("endpoint" to _endpoint.value.displayHost, "session_id" to sessionId),
                )
            }
            refreshSessions()
        }
    }

    /**
     * TWO-TIER delete, tier 2 — PERMANENT DELETE (the History-only
     * action). Erases the session from the app entirely:
     *  - [tombstone] the id (persisted `deleted_session_ids`) so a status /
     *    list refresh — the broker keeps tmux-backed PTYs alive (#199) —
     *    can NEVER resurrect it in the live list ([refreshSessions]) or the
     *    archived index ([SavedSessionsReducer.upsert] suppresses
     *    tombstoned ids);
     *  - remove it from the archived index so it stops showing in History;
     *  - drop any live row (covers permanent-deleting a still-live session).
     *
     * Kept app-side: we do NOT add a new broker endpoint. The active-list
     * archive already issued the broker DELETE; purging the broker's
     * `archived-sessions/<id>` dir is deferred (no endpoint for it yet).
     */
    fun deletePermanently(sessionId: String) {
        tombstone(sessionId)
        removeSavedSession(sessionId)
        _sessions.value = _sessions.value.filterNot { it.id == sessionId }
        updateLifecycle { it - sessionId }
        if (_selectedId.value == sessionId) _selectedId.value = null
        viewModelScope.launch {
            client?.let { c -> runCatching { withContext(Dispatchers.IO) { c.exitSession(sessionId) } } }
            runCatching { deleteSession(sessionId) }.onFailure { t ->
                Telemetry.capture(
                    error = t,
                    message = "Android session delete failed",
                    tags = mapOf("surface" to "android", "phase" to "session_delete"),
                    extras = mapOf("endpoint" to _endpoint.value.displayHost, "session_id" to sessionId),
                )
            }
            refreshSessions()
        }
    }

    /**
     * Record a delete tombstone for [sessionId] and persist it.
     * Idempotent. Capped at [TOMBSTONE_CAP] newest-first so the set
     * can't grow forever; by the time that many sessions have been
     * deleted the broker has long reaped the early ones, so evicting an
     * old tombstone is harmless. Mirror of iOS
     * `SavedSessionsStore.remove(id:)`.
     *
     * `internal` (not `private`) so `SessionStoreTombstoneTest` can
     * drive the tombstone contract directly without going through
     * [exit] — `exit` launches a best-effort network coroutine on
     * `viewModelScope`, which needs `Dispatchers.Main` (absent on the
     * JVM unit-test classpath). Same testability rationale as the
     * `internal` ingest entry points.
     */
    internal fun tombstone(sessionId: String) {
        val current = _deletedIds.value
        if (sessionId in current) return
        var next = current + sessionId
        if (next.size > TOMBSTONE_CAP) {
            next = next.takeLast(TOMBSTONE_CAP)
        }
        _deletedIds.value = next
        prefs?.edit()?.putString(KEY_DELETED_IDS, encodeDeletedIds(next))?.apply()
    }

    /**
     * Stable server id for the archived index — prefers the saved-server
     * row's UUID for the active endpoint, falling back to the sanitized
     * host (or `(unsaved)`). Mirror of iOS `savedHistoryServerID`.
     */
    private fun savedHistoryServerId(): String {
        _savedServers.value.firstOrNull { it.endpoint == _endpoint.value }?.let { return it.id }
        val host = _endpoint.value.displayHost
        return if (host.isEmpty() || host == "(no endpoint)") "(unsaved)" else host
    }

    /**
     * Fold the latest snapshot of [sessionId] into the persisted archived
     * index. Invoked from [onStatus] (every status frame) and [onExit] /
     * [archive] (with `isExited = true` so the row locks terminal).
     * Idempotent — [SavedSessionsReducer.upsert] suppresses no-op writes.
     * `internal` so unit tests can drive it without `Dispatchers.Main`.
     * Mirror of iOS `recordSavedSession`.
     */
    internal fun recordSavedSession(sessionId: String, isExited: Boolean = false) {
        val session = _sessions.value.firstOrNull { it.id == sessionId } ?: return
        val exitedFromLifecycle = _sessionLifecycle.value[sessionId] is SessionLifecycle.Exited
        val messageCount = _conversationLog.value[sessionId]?.size
            ?: _chatLog.value[sessionId]?.size
            ?: 0
        val nowIso = java.time.OffsetDateTime.now(java.time.ZoneOffset.UTC)
            .format(java.time.format.DateTimeFormatter.ISO_INSTANT)
        val next = SavedSessionsReducer.upsert(
            current = _savedSessions.value,
            session = session,
            serverId = savedHistoryServerId(),
            status = _statusBySession.value[sessionId],
            firstUserMessage = firstUserMessageOf(_conversationLog.value[sessionId]),
            messageCount = messageCount,
            isExited = isExited || exitedFromLifecycle,
            deleted = _deletedIds.value.toSet(),
            nowIso = nowIso,
        )
        if (next !== _savedSessions.value) {
            _savedSessions.value = next
            persistSavedSessions(next)
        }
    }

    /**
     * Remove every archived-index row for [sessionId] (permanent-delete
     * path). `internal` for the same testability reason as [tombstone].
     */
    internal fun removeSavedSession(sessionId: String) {
        val next = SavedSessionsReducer.remove(_savedSessions.value, sessionId)
        if (next !== _savedSessions.value) {
            _savedSessions.value = next
            persistSavedSessions(next)
        }
    }

    /**
     * Test seam: register a live [ProjectSession] in the in-memory list so
     * unit tests can drive [recordSavedSession] (and thus the archive-vs-
     * permanent contract) without a live broker/WS. Production code only
     * ever populates [_sessions] via [refreshSessions]/[listSessions].
     */
    internal fun registerSessionForTest(session: ProjectSession) {
        _sessions.value = _sessions.value.filterNot { it.id == session.id } + session
    }

    /**
     * Latest-first archived rows for History, tombstoned ids excluded.
     * Mirror of iOS `SavedSessionsStore.recent`.
     */
    fun savedSessionsRecent(limit: Int = 500): List<SavedSession> =
        SavedSessionsReducer.recent(_savedSessions.value, _deletedIds.value.toSet(), limit)

    private fun persistSavedSessions(rows: List<SavedSession>) {
        prefs?.edit()?.putString(KEY_SAVED_SESSIONS, SavedSessionsReducer.encode(rows))?.apply()
    }

    fun sendInput(sessionId: String, data: ByteArray) {
        val c = client ?: return
        viewModelScope.launch { runCatching { withContext(Dispatchers.IO) { c.sendInput(sessionId, data) } } }
    }

    // On-demand /usage: ask the broker to re-fetch the account-level Claude
    // subscription usage (5-hour + weekly). Fresh numbers arrive on the next
    // status callback and land on the session via apply_status. Backs the
    // refresh button in the Session Info account-usage card.
    fun refreshAccountUsage(sessionId: String) {
        val c = client ?: return
        viewModelScope.launch { runCatching { withContext(Dispatchers.IO) { c.refreshAccountUsage(sessionId) } } }
    }

    /**
     * Stop the agent's current turn (the composer Stop button) without ending
     * the session. Fire-and-forget: the broker interrupts the running turn
     * (claude stream-json interrupt / codex turn-interrupt / codex-exec kill)
     * and the turn winding down arrives on the normal chat/status stream, which
     * clears the typing indicator. A no-op broker-side when nothing is running.
     */
    fun stopTurn(sessionId: String) {
        val c = client ?: return
        Telemetry.breadcrumb("chat", "stop turn requested", mapOf("session" to sessionId))
        viewModelScope.launch { runCatching { withContext(Dispatchers.IO) { c.stopTurn(sessionId) } } }
    }

    // Session-independent refresh for the ambient usage surfaces (Home strip /
    // Settings card, design handoff §3b) — drives the broker fetch via any
    // Claude session. No-op when none is connected. Usage is per-account and
    // Claude-only, so any claude session yields the account-wide numbers.
    fun refreshAccountUsage() {
        val id = _sessions.value.firstOrNull { it.assistant == "claude" }?.id ?: return
        refreshAccountUsage(id)
    }

    /**
     * True when the session is blocked on a pending AskUserQuestion: the last
     * non-user item in the typed conversation log is an unanswered
     * `pending_input` kind. Used to bypass the turn-queue gate so the answer
     * reaches the broker immediately instead of deadlocking in the queue.
     */
    fun hasPendingAsk(sessionId: String): Boolean {
        val items = _conversationLog.value[sessionId] ?: return false
        val last = items.lastOrNull { it.role.lowercase() != "user" } ?: return false
        return last.kind.lowercase() == "pending_input"
    }

    fun sendChat(sessionId: String, msg: String) {
        // Funnel: first ever turn sent — first session, no prior server-side conversation items.
        val priorItems = _conversationLog.value[sessionId].orEmpty().filter { !it.id.startsWith("local-") }
        if (_sessions.value.size <= 1 && priorItems.isEmpty()) {
            Telemetry.breadcrumb("onboarding", sh.nikhil.conduit.ui.OnboardingStep.FIRST_TURN_SENT,
                mapOf("session" to sessionId, "chars" to msg.length.toString()))
        }
        // The user has answered — clear the AI quick-reply chips so they
        // don't linger over the next turn (task #233). Done before the
        // client guard so the chips drop even mid-reconnect.
        clearQuickReplies(sessionId)
        // Slash-command routing: intercept recognised `/`-commands before
        // they reach the agent. Pass-through commands (Claude only) fall
        // through to the normal send below; app-handled ones are handled
        // here and we return early. See docs/SLASH-COMMANDS.md.
        if (handleSlashCommand(sessionId, msg)) return
        // ELICITATION BYPASS: if the session is blocked on a pending
        // AskUserQuestion, the answer MUST bypass the turn-queue gate and
        // reach the broker immediately. Routing through the turnActive queue
        // deadlocks: the answer is held until the turn ends, but the turn
        // can only end once the answer is delivered.
        val pendingAsk = hasPendingAsk(sessionId)
        if (pendingAsk) {
            Telemetry.breadcrumb("chat", "answer_pending_ask",
                mapOf("session" to sessionId, "chars" to msg.length.toString()))
        }
        // Build the optimistic echo timestamp (anchored to the server clock domain).
        // Timestamp must be ANCHORED to the server clock domain, not the
        // device wall-clock. Every persisted item already in the log is
        // broker-stamped; the assistant reply this message triggers will be
        // broker-stamped too. If we stamp the echo with the *device* clock and
        // it runs even slightly ahead of the broker, the echo sorts AFTER the
        // reply -> the agent's answer renders above the user's prompt (device
        // bug, "brought up many times"). Stamping it one ms past the newest
        // known item keeps it ahead of any reply (whose broker ts is
        // necessarily later) regardless of how far the device clock drifts.
        // For the very first turn there's no prior item to anchor to. Anchor
        // to the broker-stamped session start instead of the device clock:
        // the reply this message triggers is broker-stamped and necessarily
        // *after* session start, so start+1 keeps the echo ahead of it even
        // when the device clock runs ahead of the broker. This is the codex
        // case -- a one-shot reply with a tiny user->reply gap, where the old
        // device-now() fallback flipped the order. Device now() is the last
        // resort (status not yet received). See [sortedByConversationTs].
        val nowMs = System.currentTimeMillis()
        val lastKnownMs = (
            (_conversationLog.value[sessionId].orEmpty().map { it.ts }) +
                (_chatLog.value[sessionId].orEmpty().map { it.ts })
            ).map { tsEpochMillis(it) }.filter { it > 0L }.maxOrNull()
        val startedMs = _statusBySession.value[sessionId]?.startedAt
            ?.let { tsEpochMillis(it) }?.takeIf { it > 0L }
        val echoMs = when {
            lastKnownMs != null -> lastKnownMs + 1
            startedMs != null -> startedMs + 1
            else -> nowMs
        }
        val ts = java.time.Instant.ofEpochMilli(echoMs)
            .atOffset(java.time.ZoneOffset.UTC)
            .format(java.time.format.DateTimeFormatter.ISO_INSTANT)
        val localId = "local-${java.util.UUID.randomUUID()}"
        // "Queued Next" gate (spec PR #481): if a turn is currently active,
        // queue the message in the "Queued Next" panel instead of delivering
        // immediately. For codex (supports.steer): queue AND immediately attempt
        // a steer into the running turn. For others: hold; auto-send on turn end.
        //
        // CRITICAL: this echo + enqueue happens BEFORE any `client` guard.
        // The old `val c = client ?: return` here dropped the message
        // entirely (no echo, no record) if the user sent during a reconnect
        // window -- the device-reported lost-send bug. Now the message is
        // always queued and persisted; the flush re-delivers it on connect /
        // foreground.
        val turnActive = _statusBySession.value[sessionId]?.turnActive == true
        val item = ConversationItem(
            id = localId,
            role = "user",
            kind = "message",
            // PENDING until a successful WS write acks it (flushPendingChats
            // flips it to "done"). The user bubble draws a clock while
            // pending and a retry affordance if it ultimately fails.
            status = "pending",
            content = msg,
            ts = ts,
            files = emptyList(),
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
        _conversationLog.value = _conversationLog.value.toMutableMap().also { m ->
            m[sessionId] = (m[sessionId] ?: emptyList()) + item
        }
        _chatLog.value = _chatLog.value.toMutableMap().also { m ->
            m[sessionId] = (m[sessionId] ?: emptyList()) +
                ChatEvent(role = "user", content = msg, ts = ts, files = emptyList())
        }
        // Elicitation bypass: skip the turnActive queue gate and deliver
        // directly. The broker already routes a message-during-pending-ask
        // to the control channel (takePendingAsk / encodeAskAnswer).
        if (pendingAsk) {
            updatePendingChats { it.enqueue(sessionId, localId, msg, ts) }
            Telemetry.breadcrumb("chat", "answer_pending_ask_deliver",
                mapOf("session" to sessionId, "chars" to msg.length.toString()))
            attemptDeliver(sessionId, localId, msg)
            return
        }
        if (turnActive) {
            val agent = _sessions.value.firstOrNull { it.id == sessionId }?.assistant ?: ""
            val supportsSteer = descriptorFor(agent, _agentDescriptors.value).supportsSteer
            // Register as queuedTurn (not normal) so flushable() skips it and
            // only flushOnTurnComplete delivers it.
            updatePendingChats { it.enqueueQueued(sessionId, localId, msg, ts) }
            Telemetry.breadcrumb(
                "chat",
                "queued_turn",
                mapOf("session" to sessionId, "chars" to msg.length.toString(), "steer" to supportsSteer.toString()),
            )
            if (supportsSteer) {
                // Codex: immediately attempt a steer into the running turn.
                attemptSteer(sessionId, localId, msg)
            }
            // For non-steer agents: the entry stays queuedTurn until
            // flushOnTurnComplete delivers it when the turn ends.
            return
        }
        // Normal (no active turn): register as pending + persist BEFORE
        // attempting any WS write, so a backgrounding-mid-send or a null client
        // during reconnect never drops it. The flush re-delivers it on connect /
        // foreground.
        updatePendingChats { it.enqueue(sessionId, localId, msg, ts) }
        Telemetry.breadcrumb("chat", "queued", mapOf("session" to sessionId, "chars" to msg.length.toString()))
        attemptDeliver(sessionId, localId, msg)
    }

    /**
     * Attempt to deliver one queued message over the live WS, reporting the
     * outcome back to [pendingChats] (ack on success, attempt-bump on
     * failure) and flipping the transcript echo's status. Safe when [client]
     * is null — it just leaves the entry queued for a later flush. Shared by
     * the send path and [flushPendingChats]. Mirror of iOS `attemptDeliver`.
     */

    private fun attemptDeliver(sessionId: String, localId: String, msg: String, manualRetry: Boolean = false) {
        val c = client ?: run {
            // No live client. On a manual retry the user is watching, so don't
            // leave the spinner spinning forever — surface failed immediately.
            if (manualRetry) {
                setEchoStatus(sessionId, localId, "failed")
                Telemetry.breadcrumb("chat", "retry_result",
                    mapOf("session" to sessionId, "local_id" to localId, "ok" to "false", "reason" to "not_connected"))
            }
            return
        }
        // Box-identity gate: if the session was stamped to a different box
        // than the one we are currently connected to, sending into this
        // client is wrong — it would reach the wrong broker and produce
        // ConduitError: UnknownSession. Surface the mismatch and remove
        // the entry from the queue so it is not retried into the wrong broker.
        val currentBoxId = savedHistoryServerId()
        val stampedBox = _sessionBox.value[sessionId]
        if (stampedBox != null && stampedBox != currentBoxId) {
            val boxName = _savedServers.value.firstOrNull { it.id == stampedBox }?.name
                ?: stampedBox
            Telemetry.breadcrumb("chat", "blocked — session on different box",
                mapOf("session" to sessionId, "session_box" to stampedBox,
                    "current_box" to currentBoxId))
            setEchoStatus(sessionId, localId, "failed")
            updatePendingChats { it.markDelivered(sessionId, localId) }
            _sessionCreationError.value = "Session is on '$boxName'. Switch to that box to send."
            return
        }
        viewModelScope.launch {
            val result = runCatching { withContext(Dispatchers.IO) { c.sendChat(sessionId, msg) } }

            if (result.isSuccess) {
                // Ack: drop from the queue and flip the echo to "done".
                updatePendingChats { it.markDelivered(sessionId, localId) }
                setEchoStatus(sessionId, localId, "done")
                if (manualRetry) {
                    Telemetry.breadcrumb("chat", "retry_result",
                        mapOf("session" to sessionId, "local_id" to localId, "ok" to "true"))
                }
            } else {
                updatePendingChats { it.markAttemptFailed(sessionId, localId) }
                if (_pendingChats.value.isFailed(localId, sessionId) || manualRetry) {
                    // Hard fail, or a manual retry the user is watching: surface
                    // failed so the spinner resolves to the retry affordance.
                    setEchoStatus(sessionId, localId, "failed")
                    if (manualRetry) {
                        Telemetry.breadcrumb("chat", "retry_result",
                            mapOf("session" to sessionId, "local_id" to localId, "ok" to "false"))
                    }
                    Telemetry.capture(
                        error = result.exceptionOrNull() ?: RuntimeException("chat send failed"),
                        message = "chat send to agent failed (gave up after retries)",
                        tags = mapOf("surface" to "android", "phase" to "chat_send"),
                        extras = mapOf("session" to sessionId),
                    )
                } else {
                    // Transient: stays queued + pending for the next flush.
                    Telemetry.breadcrumb("chat", "send attempt failed — keeping queued",
                        mapOf("session" to sessionId))
                }
            }
        }
    }

    /**
     * Attempt to steer a queued codex entry into the RUNNING turn (spec PR
     * #481). Flips the entry to [PendingChatKind.steering], sends via the
     * normal chat path (broker sees turn active -> turn/steer; broker falls back
     * to turn/start if the turn already ended), then acks on success (removes
     * the card) or flips to [PendingChatKind.retrying] on failure. Safe when
     * [client] is null -- entry stays in queuedTurn/retrying for the next
     * flush-on-turn-complete.
     */
    private fun attemptSteer(sessionId: String, localId: String, msg: String) {
        val c = client ?: return
        updatePendingChats { it.markSteering(sessionId, localId) }
        Telemetry.breadcrumb(
            "chat",
            "steer_attempt",
            mapOf("session" to sessionId, "local_id" to localId),
        )
        viewModelScope.launch {
            val result = runCatching { withContext(Dispatchers.IO) { c.sendChat(sessionId, msg) } }
            if (result.isSuccess) {
                // Steer acked: remove the panel card and flip echo to done.
                updatePendingChats { it.markDelivered(sessionId, localId) }
                setEchoStatus(sessionId, localId, "done")
                Telemetry.breadcrumb(
                    "chat",
                    "steer_ack",
                    mapOf("session" to sessionId, "local_id" to localId),
                )
            } else {
                // Steer failed: flip to retrying so the user can re-tap Steer.
                updatePendingChats { it.markSteeringFailed(sessionId, localId) }
                Telemetry.breadcrumb(
                    "chat",
                    "steer_failed",
                    mapOf("session" to sessionId, "local_id" to localId),
                )
                Telemetry.capture(
                    error = result.exceptionOrNull() ?: RuntimeException("steer failed"),
                    message = "codex steer attempt failed",
                    tags = mapOf("surface" to "android", "phase" to "chat_steer"),
                    extras = mapOf("session" to sessionId),
                )
            }
        }
    }

    /**
     * User tapped the "Steer" button on a retrying codex card -- re-attempt
     * the steer into the running turn. Mirror of iOS `retrySteer`.
     */
    fun retrySteer(sessionId: String, localId: String) {
        val entry = _pendingChats.value.entries(sessionId).firstOrNull { it.localId == localId } ?: return
        Telemetry.breadcrumb(
            "chat",
            "steer_retry",
            mapOf("session" to sessionId, "local_id" to localId),
        )
        attemptSteer(sessionId, localId, entry.message)
    }

    /**
     * User tapped X on a "Queued Next" panel card -- remove the entry so it
     * is never auto-sent. Mirror of iOS `cancelQueued`.
     */
    fun cancelQueued(sessionId: String, localId: String) {
        // Capture the ts before removing from the queue (for chatLog cleanup).
        val entryTs = _pendingChats.value.entries(sessionId).firstOrNull { it.localId == localId }?.ts
        Telemetry.breadcrumb(
            "chat",
            "queued_cancel",
            mapOf("session" to sessionId, "local_id" to localId),
        )
        updatePendingChats { it.cancel(sessionId, localId) }
        // Remove the optimistic echo so the message disappears from the log.
        _conversationLog.value = _conversationLog.value.toMutableMap().also { m ->
            val list = m[sessionId] ?: return@also
            m[sessionId] = list.filterNot { it.id == localId }
        }
        if (entryTs != null) {
            _chatLog.value = _chatLog.value.toMutableMap().also { m ->
                val list = m[sessionId] ?: return@also
                m[sessionId] = list.filterNot { it.role == "user" && it.ts == entryTs }
            }
        }
    }

    /**
     * Called when a turn transitions from active to idle (turnActive false in
     * a status frame). Delivers the OLDEST queued-turn entry via the normal
     * [sendChat] path (which starts a new turn); remaining entries stay
     * queued and will flush on the NEXT turn-complete (natural serialization
     * -- one at a time, not a blast). No-op when nothing is queued.
     * Mirror of iOS `flushOnTurnComplete`.
     */
    internal fun flushOnTurnComplete(sessionId: String) {
        val entry = _pendingChats.value.flushOnTurnComplete(sessionId) ?: return
        Telemetry.breadcrumb(
            "chat",
            "flush_turn_complete",
            mapOf("session" to sessionId, "local_id" to entry.localId, "chars" to entry.message.length.toString()),
        )
        // Flip the kind back to normal so attemptDeliver (the existing send path)
        // treats this as a regular deliver and the echo shows as pending again.
        updatePendingChats { q ->
            q.markDelivered(sessionId, entry.localId)
        }
        // Deliver directly -- sendChat would re-check turnActive (which may
        // already be false or race); use attemptDeliver so we don't double-echo.
        // The echo was already appended to the log when the message was first
        // queued, so we need only (re-)register it as a normal pending entry and
        // attempt delivery.
        val ts = entry.ts
        updatePendingChats { it.enqueue(sessionId, entry.localId, entry.message, ts) }
        attemptDeliver(sessionId, entry.localId, entry.message)
    }

    /**
     * Re-deliver every still-pending message for a session — called when the
     * connection/agent becomes ready again (connect success, app foreground,
     * reconnect). Failed entries are skipped until the user retries them.
     * Pass null to flush every session. Mirror of iOS `flushPendingChats`.
     */
    fun flushPendingChats(sessionId: String? = null) {
        val ids = sessionId?.let { listOf(it) } ?: _pendingChats.value.bySession.keys.toList()
        for (sid in ids) {
            val due = _pendingChats.value.flushable(sid)
            if (due.isEmpty()) continue
            Telemetry.breadcrumb("chat", "flush pending",
                mapOf("session" to sid, "count" to due.size.toString()))
            due.forEach { entry -> attemptDeliver(sid, entry.localId, entry.message) }
        }
    }

    /**
     * User tapped retry on a failed message bubble — re-arm the entry and
     * attempt delivery again immediately. Mirror of iOS `retryPendingChat`.
     */

    fun retryPendingChat(sessionId: String, localId: String) {
        val entry = _pendingChats.value.entries(sessionId).firstOrNull { it.localId == localId } ?: return
        Telemetry.breadcrumb(
            "chat",
            "retry_resend",
            mapOf("session" to sessionId, "local_id" to localId),
        )
        updatePendingChats { it.retry(sessionId, localId) }
        // "retrying" drives the spinner footer; attemptDeliver flips it to
        // done/failed on the genuine WS result. manualRetry=true makes even a
        // single transient failure surface as failed (the user is watching).
        setEchoStatus(sessionId, localId, "retrying")
        attemptDeliver(sessionId, localId, entry.message, manualRetry = true)
    }

    /**
     * Flip the `status` of a `local-…` transcript echo in place (pending ->
     * done / failed). Drives the user-bubble indicator without touching the
     * message content or its log position. Mirror of iOS `setEchoStatus`.
     */
    private fun setEchoStatus(sessionId: String, localId: String, status: String) {
        _conversationLog.value = _conversationLog.value.toMutableMap().also { m ->
            val list = m[sessionId] ?: return@also
            m[sessionId] = list.map { if (it.id == localId) it.copy(status = status) else it }
        }
    }

    /**
     * Routes a recognised `/`-command. Returns true when the command was
     * handled here (caller must NOT send it to the agent); false when the
     * text is not a command, or is a supported pass-through that should be
     * delivered verbatim. See [SlashCommandRegistry] / docs/SLASH-COMMANDS.md.
     */
    private fun handleSlashCommand(sessionId: String, msg: String): Boolean {
        val agent = _sessions.value.firstOrNull { it.id == sessionId }?.assistant ?: "claude"
        // When we have live descriptors, pass the explicit supportsCompact flag so
        // the registry uses the broker's answer rather than the static name check.
        // null = fall back to the static "agent == claude" check (old broker).
        val supportsCompact = _agentDescriptors.value
            .takeIf { it.isNotEmpty() }
            ?.let { descriptorFor(agent, it).supportsCompact }
        val match = SlashCommandRegistry.classify(msg, agent, supportsCompact) ?: return false
        if (match.command.clazz == SlashCommandClass.PASS_THROUGH) {
            if (match.supported) return false // deliver verbatim to the agent
            postSystemMessage(sessionId, "“/${match.command.name}” only works with Claude — this session is running $agent.")
            return true
        }
        when (match.command.name) {
            "help" -> postSystemMessage(sessionId, slashHelpText())
            "model" -> if (match.args.isBlank()) {
                postSystemMessage(sessionId, "Usage: /model <name> — forks this session onto a different model.")
            } else {
                forkSession(sessionId, model = match.args)
                postSystemMessage(sessionId, "Forking onto model “${match.args}”…")
            }
            "effort" -> if (match.args.isBlank()) {
                postSystemMessage(sessionId, "Usage: /effort <minimal|low|medium|high> — forks with a different reasoning effort.")
            } else {
                forkSession(sessionId, reasoningEffort = match.args)
                postSystemMessage(sessionId, "Forking with reasoning effort “${match.args}”…")
            }
            // The live repeat-a-prompt loop is intentionally not wired yet —
            // an untested auto-sender hammering the agent is a bad blind ship.
            // Lands in a follow-up with on-device verification.
            "loop" -> postSystemMessage(sessionId, "“/loop” is recognised; the repeat-a-prompt loop ships in a follow-up update.")
            "usage", "context" -> postSystemMessage(sessionId, "“/${match.command.name}” is a Claude Code terminal-only panel — it isn’t available in chat yet.")
            else -> return false
        }
        return true
    }

    /** Appends a client-only `role:"system"` chat line (e.g. /help output,
     *  a "not supported" note). Mirrors the optimistic-echo pattern in
     *  [sendChat]; the `local-` id survives the next conversation refresh. */
    private fun postSystemMessage(sessionId: String, text: String) {
        val ts = java.time.OffsetDateTime.now(java.time.ZoneOffset.UTC)
            .format(java.time.format.DateTimeFormatter.ISO_INSTANT)
        val item = ConversationItem(
            id = "local-${java.util.UUID.randomUUID()}",
            role = "system",
            kind = "message",
            status = "done",
            content = text,
            ts = ts,
            files = emptyList(),
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
        _conversationLog.value = _conversationLog.value.toMutableMap().also { m ->
            m[sessionId] = (m[sessionId] ?: emptyList()) + item
        }
        _chatLog.value = _chatLog.value.toMutableMap().also { m ->
            m[sessionId] = (m[sessionId] ?: emptyList()) +
                ChatEvent(role = "system", content = text, ts = ts, files = emptyList())
        }
    }

    private fun slashHelpText(): String = buildString {
        append("Slash commands\n")
        SlashCommandRegistry.commands.forEach { append("/${it.name} — ${it.description}\n") }
    }.trim()

    /**
     * Upload a composer attachment to the session via the 0x01 binary WS
     * frame (core `send_file` → broker writes
     * `<workspace>/uploads/<sessionID>/<filename>`). The send path calls
     * this for each pending attachment before/with the chat message that
     * references the landed paths. Mirror of iOS `SessionStore.sendFile`.
     *
     * Suspends until the frame is enqueued so the caller can sequence the
     * chat message after the uploads complete. Failures are swallowed
     * (best-effort, same as `sendChat`) — the agent simply won't find the
     * referenced path if the upload didn't land.
     */
    suspend fun sendFile(sessionId: String, filename: String, mime: String, payload: ByteArray) {
        val c = client ?: return
        runCatching { withContext(Dispatchers.IO) { c.sendFile(sessionId, filename, mime, payload) } }
    }

    suspend fun listDirectories(path: String?): RemoteDirectoryListing = withContext(Dispatchers.IO) {
        // MUST run on Dispatchers.IO: the caller is a `LaunchedEffect`, which
        // runs on the Main dispatcher, and the blocking HttpURLConnection
        // calls below (`responseCode` / `getInputStream`) perform network on
        // whatever thread they're on. On Main that throws
        // `NetworkOnMainThreadException` — a RuntimeException with a NULL
        // message — which AgentPickerSheet rendered as the bare "Couldn't
        // list this folder." (no broker detail), making the folder browser
        // look broken on Android while iOS (async URLSession) worked fine.
        val base = _endpoint.value.httpBaseUrl ?: error("Invalid endpoint URL")
        val url = if (path.isNullOrBlank()) {
            URL("$base/api/fs/list")
        } else {
            URL("$base/api/fs/list?path=${java.net.URLEncoder.encode(path, "UTF-8")}")
        }
        val conn = (url.openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            setRequestProperty("Authorization", "Bearer ${_endpoint.value.token}")
            connectTimeout = 7_000
            readTimeout = 7_000
        }
        // Android's HttpURLConnection.getInputStream() THROWS on any non-2xx,
        // which swallowed the broker's real error (e.g. permission denied /
        // bad path) into the generic "Couldn't list this folder" message in
        // AgentPickerSheet. Check the status first (iOS parity), read
        // errorStream on failure, and surface the broker's body so the
        // failure is diagnosable on-device.
        val code = conn.responseCode
        if (code !in 200..299) {
            val errBody = conn.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
            conn.disconnect()
            error("Harness replied $code: ${errBody.take(300)}")
        }
        conn.inputStream.bufferedReader().use { reader ->
            val raw = reader.readText()
            val obj = JSONObject(raw)
            val arr = obj.optJSONArray("entries") ?: JSONArray()
            val entries = buildList {
                for (i in 0 until arr.length()) {
                    val e = arr.getJSONObject(i)
                    add(
                        RemoteDirectoryEntry(
                            name = e.optString("name", ""),
                            path = e.optString("path", ""),
                            isDir = e.optBoolean("is_dir", true),
                        )
                    )
                }
            }
            RemoteDirectoryListing(
                path = obj.optString("path", path ?: "~"),
                parent = obj.optString("parent", path ?: "~"),
                entries = entries,
            )
        }
    }

    /**
     * Whether a directory already has an agent harness (CLAUDE.md / AGENTS.md).
     * Returns null on any failure so callers default to NOT nagging (the chip
     * only shows on a definite hasHarness=false). Best-effort; never throws.
     * Mirror of iOS `harnessStatus(path:)`.
     */
    suspend fun harnessStatus(path: String?): RemoteHarnessStatus? = withContext(Dispatchers.IO) {
        if (path.isNullOrBlank()) return@withContext null
        val base = _endpoint.value.httpBaseUrl ?: return@withContext null
        try {
            val url = URL("$base/api/fs/harness-status?path=${java.net.URLEncoder.encode(path, "UTF-8")}")
            val conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                setRequestProperty("Authorization", "Bearer ${_endpoint.value.token}")
                connectTimeout = 7_000
                readTimeout = 7_000
            }
            if (conn.responseCode !in 200..299) {
                conn.disconnect()
                return@withContext null
            }
            conn.inputStream.bufferedReader().use { reader ->
                val obj = JSONObject(reader.readText())
                RemoteHarnessStatus(
                    hasClaudeMd = obj.optBoolean("has_claude_md", false),
                    hasAgentsMd = obj.optBoolean("has_agents_md", false),
                    hasHarness = obj.optBoolean("has_harness", false),
                )
            }
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Host health snapshot from `GET /api/host/metrics` (broker v0.0.111+,
     * `broker/internal/hostmetrics`). Percentages are 0–100. Mirror of iOS
     * `SessionStore.HostMetrics`.
     */
    data class HostMetrics(
        val cpuPct: Double,
        val memPct: Double,
        val diskPct: Double,
        val load1: Double?,
        val uptimeSecs: Long?,
    )

    /** Box-broker feature probe result. Mirror of iOS `BoxFeatures`. */
    data class BoxFeatures(
        val hostMetrics: Boolean,
        val shellSessions: Boolean,
        /** Broker supports push registration (`features.push`). WS-P.1. */
        val push: Boolean = false,
        /**
         * URL of the ntfy server co-located on this box, or null when the
         * broker does not advertise one (`features.ntfy_url` absent/empty).
         * Older brokers that omit the key parse as null — no regression.
         */
        val ntfyUrl: String? = null,
    )

    /**
     * One model an agent advertises, discovered live by the broker from the
     * agent CLI (capabilities "models", broker modelcatalog.go). `id` is the
     * value sent as the session-create model override; "" is the
     * inherit/default sentinel. Mirror of iOS `ConduitUI.AgentModel`.
     */
    data class AgentModel(
        val id: String,
        val displayName: String,
        val description: String = "",
        val isDefault: Boolean = false,
        val defaultEffort: String = "",
        val efforts: List<String> = emptyList(),
        /** True when the claude CLI advertises supportsFastMode for this model. */
        val supportsFastMode: Boolean = false,
    )

    /**
     * Per-assistant model catalogs from the active box. Empty until the
     * first successful [refreshModelCatalog] — the pickers then fall back
     * to the static fork option lists. Kept across failures so a flaky
     * refresh never downgrades an already-populated picker.
     */
    private val _modelCatalog = MutableStateFlow<Map<String, List<AgentModel>>>(emptyMap())
    val modelCatalog: StateFlow<Map<String, List<AgentModel>>> = _modelCatalog.asStateFlow()

    /**
     * Per-assistant capability descriptors from the active broker (PR #440).
     * Empty until [refreshModelCatalog] succeeds on a broker that serves the
     * `agents` map — callers fall back to [staticAgentDescriptors] via
     * [descriptorFor]. Kept across failures so a flaky refresh never loses
     * a previously-populated descriptor set.
     */
    private val _agentDescriptors = MutableStateFlow<Map<String, AgentDescriptor>>(emptyMap())
    val agentDescriptors: StateFlow<Map<String, AgentDescriptor>> = _agentDescriptors.asStateFlow()

    /**
     * Broker readiness block from `/api/capabilities` (WS-H.1, broker #450).
     * Null until the first successful fetch or on older brokers that omit the
     * block — every WS-H.2/H.3 consumer treats null as "unknown".
     * Mirror of iOS `SessionStore.brokerReadiness`.
     */
    private val _brokerReadiness = MutableStateFlow<BrokerReadiness?>(null)
    val brokerReadiness: StateFlow<BrokerReadiness?> = _brokerReadiness.asStateFlow()

    /**
     * Refresh [modelCatalog] and [agentDescriptors] from the active
     * endpoint's capabilities in one request. Old brokers (missing keys)
     * and failures are no-ops for the affected flow.
     */
    suspend fun refreshModelCatalog() = withContext(Dispatchers.IO) {
        val ep = _endpoint.value
        Telemetry.breadcrumb("model_catalog", "refresh start", mapOf("host" to ep.displayHost))
        val raw = getJsonOrNull(ep, "/api/capabilities")
        if (raw == null) {
            Telemetry.breadcrumb("model_catalog", "capabilities fetch failed", mapOf("host" to ep.displayHost))
            return@withContext
        }
        // Parse model catalog (existing).
        val parsed = runCatching { parseModelCatalog(raw) }.getOrNull()
        if (parsed.isNullOrEmpty()) {
            Telemetry.breadcrumb(
                "model_catalog", "no models in capabilities (old broker or discovery pending)",
                mapOf("host" to ep.displayHost),
            )
        } else {
            _modelCatalog.value = parsed
            Telemetry.breadcrumb("onboarding", sh.nikhil.conduit.ui.OnboardingStep.CAPABILITIES_FETCHED,
                mapOf("host" to ep.displayHost,
                      "agents" to parsed.keys.sorted().joinToString(",")))
            Telemetry.breadcrumb(
                "model_catalog", "refreshed",
                mapOf("counts" to parsed.entries.sortedBy { it.key }.joinToString(",") { "${it.key}=${it.value.size}" }),
            )
        }
        // Parse agent descriptors (PR #440 — agents map).
        val descriptors = runCatching { parseAgentDescriptors(raw) }.getOrNull()
        if (descriptors.isNullOrEmpty()) {
            Telemetry.breadcrumb(
                "agent_descriptors", "no agents in capabilities (old broker)",
                mapOf("host" to ep.displayHost),
            )
        } else {
            _agentDescriptors.value = descriptors
            Telemetry.breadcrumb(
                "agent_descriptors", "refreshed",
                mapOf("agents" to descriptors.keys.sorted().joinToString(",")),
            )
        }
        // WS-H.1: parse the readiness block; null on old brokers → consumers treat as unknown.
        val readiness = runCatching { parseReadiness(raw) }.getOrNull()
        if (readiness != null) {
            _brokerReadiness.value = readiness
            Telemetry.breadcrumb(
                "broker_readiness", "refreshed",
                mapOf(
                    "version" to readiness.brokerVersion,
                    "node" to if (readiness.nodePresent) "1" else "0",
                    "tmux" to if (readiness.tmuxPresent) "1" else "0",
                    "git" to if (readiness.gitPresent) "1" else "0",
                    "agents" to readiness.agents.keys.sorted().joinToString(","),
                ),
            )
        } else {
            Telemetry.breadcrumb(
                "broker_readiness", "no readiness block (old broker)",
                mapOf("host" to ep.displayHost),
            )
        }
    }

    /**
     * Probe `GET /api/capabilities` on a specific saved endpoint (works for
     * non-active boxes — plain authed GET, no WS needed). Null on any
     * failure (old broker, unreachable, 401): the Box health screen hides
     * the dependent affordances rather than erroring.
     */
    suspend fun fetchBoxFeatures(endpoint: Endpoint): BoxFeatures? = withContext(Dispatchers.IO) {
        val raw = getJsonOrNull(endpoint, "/api/capabilities")
        if (raw == null) {
            Telemetry.breadcrumb("box_health", "capabilities probe failed", mapOf("host" to endpoint.displayHost))
            return@withContext null
        }
        runCatching {
            val features = JSONObject(raw).optJSONObject("features")
            val rawNtfyUrl = features?.optString("ntfy_url", null)
            BoxFeatures(
                hostMetrics = features?.optBoolean("host_metrics", false) ?: false,
                shellSessions = features?.optBoolean("shell_sessions", false) ?: false,
                push = features?.optBoolean("push", false) ?: false,
                ntfyUrl = if (rawNtfyUrl.isNullOrBlank()) null else rawNtfyUrl,
            )
        }.getOrNull()
    }

    /**
     * Live CPU/MEM/DISK for a box. Null = box doesn't report metrics (old
     * broker 404, non-Linux 503, unreachable) → the health section is
     * hidden (honest-state rule). Mirror of iOS `fetchHostMetrics`.
     */
    suspend fun fetchHostMetrics(endpoint: Endpoint): HostMetrics? = withContext(Dispatchers.IO) {
        val raw = getJsonOrNull(endpoint, "/api/host/metrics")
        if (raw == null) {
            Telemetry.breadcrumb("box_health", "metrics fetch failed", mapOf("host" to endpoint.displayHost))
            return@withContext null
        }
        runCatching {
            val obj = JSONObject(raw)
            val metrics = HostMetrics(
                cpuPct = obj.optDouble("cpu_pct", 0.0),
                memPct = obj.optDouble("mem_pct", 0.0),
                diskPct = obj.optDouble("disk_pct", 0.0),
                load1 = if (obj.has("load1")) obj.optDouble("load1") else null,
                uptimeSecs = if (obj.has("uptime_secs")) obj.optLong("uptime_secs") else null,
            )
            Telemetry.breadcrumb(
                "box_health", "metrics fetched",
                mapOf(
                    "cpu" to "%.0f".format(metrics.cpuPct),
                    "mem" to "%.0f".format(metrics.memPct),
                    "disk" to "%.0f".format(metrics.diskPct),
                ),
            )
            metrics
        }.getOrNull()
    }

    /**
     * Authed GET against an arbitrary stored endpoint — [listDirectories]'
     * direct-HTTP pattern, parameterized on endpoint so Box health can
     * probe boxes that aren't the active connection. Blocking; call on
     * Dispatchers.IO. Null on any failure.
     */
    private fun getJsonOrNull(endpoint: Endpoint, path: String): String? {
        val base = endpoint.httpBaseUrl ?: return null
        return runCatching {
            val conn = (URL("$base$path").openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                setRequestProperty("Authorization", "Bearer ${endpoint.token}")
                connectTimeout = 7_000
                readTimeout = 10_000
            }
            try {
                if (conn.responseCode !in 200..299) return@runCatching null
                conn.inputStream.bufferedReader().use { it.readText() }
            } finally {
                conn.disconnect()
            }
        }.getOrNull()
    }

    /**
     * Fetch a session's persisted transcript read-only over HTTP
     * (`GET /api/session/conversation/<id>`, broker PR #196). Mirrors
     * [listDirectories]' direct-HTTP + bearer-auth pattern, and iOS
     * `fetchConversation`. Used by the Sessions screen to open an
     * *exited* session: there's no live WS to replay from, so we read
     * the broker's `conversation.jsonl` instead.
     *
     * The persisted rows are role/content/ts/files only; we map them
     * into [ConversationItem] (kind `message` / `tool`, status `done`)
     * so the existing chat renderer can display them unchanged.
     *
     * Throws [ConversationNotFoundException] on 404 — sessions created
     * before the #196 redeploy never wrote a `conversation.jsonl`.
     */
    suspend fun fetchConversation(sessionID: String): List<ConversationItem> = withContext(Dispatchers.IO) {
        // Dispatchers.IO for the same reason as [listDirectories]: the
        // blocking HttpURLConnection calls below must never run on the Main
        // dispatcher (NetworkOnMainThreadException).
        val base = _endpoint.value.httpBaseUrl ?: error("Invalid endpoint URL")
        val url = URL("$base/api/session/conversation/${java.net.URLEncoder.encode(sessionID, "UTF-8")}")
        val conn = (url.openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            setRequestProperty("Authorization", "Bearer ${_endpoint.value.token}")
            connectTimeout = 7_000
            readTimeout = 7_000
        }
        val code = conn.responseCode
        if (code == 404) {
            conn.disconnect()
            throw ConversationNotFoundException()
        }
        if (code !in 200..299) {
            conn.disconnect()
            error("Conversation fetch failed ($code)")
        }
        conn.inputStream.bufferedReader().use { reader ->
            val raw = reader.readText()
            val obj = JSONObject(raw)
            val arr = obj.optJSONArray("items") ?: JSONArray()
            return@withContext buildList {
                for (i in 0 until arr.length()) {
                    val e = arr.getJSONObject(i)
                    val role = e.optString("role", "")
                    val kind = if (role.lowercase() == "tool") "tool" else "message"
                    // Strip the broker's pending-input sentinel: the live path
                    // runs the core classifier (which strips it), but this raw
                    // HTTP replay does not — so without this the sentinel line
                    // both shows as raw chat text AND fails to dedupe against
                    // the live, stripped card (different role+content), leaving
                    // a duplicate card body under the real card on reattach.
                    val content = stripPendingSentinel(e.optString("content", ""))
                    val filesArr = e.optJSONArray("files") ?: JSONArray()
                    val files = buildList {
                        for (j in 0 until filesArr.length()) {
                            val f = filesArr.getJSONObject(j)
                            add(
                                ViewEventFile(
                                    path = f.optString("path", ""),
                                    rev = f.optString("rev", ""),
                                )
                            )
                        }
                    }
                    add(
                        ConversationItem(
                            id = "saved-$sessionID-$i",
                            role = role,
                            kind = kind,
                            status = "done",
                            content = content,
                            ts = e.optString("ts", ""),
                            files = files,
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
                    )
                }
            }
        }
    }

    /**
     * Terminate AND remove a session on the broker over HTTP
     * (`DELETE /api/session/<id>`). Mirrors [fetchConversation]'s
     * direct-HTTP + bearer-auth pattern, and iOS `deleteSession`.
     *
     * Unlike the WS `exit` control (which only kills the agent process and
     * leaves the session recoverable on disk — the bug that made broker
     * sessions accumulate), this endpoint stops the process, kills the
     * per-session tmux session, drops the session from the broker's live
     * set, and archives the on-disk dir out of the active list. Idempotent
     * server-side: a 200 also covers already-gone sessions.
     *
     * Works for exited sessions too — no live WS handle required, just the
     * endpoint + bearer token. The transcript stays reachable via
     * [fetchConversation] (the broker preserves it under
     * `archived-sessions/<id>`).
     */
    suspend fun deleteSession(sessionId: String) {
        val base = _endpoint.value.httpBaseUrl ?: error("Invalid endpoint URL")
        val url = URL("$base/api/session/${java.net.URLEncoder.encode(sessionId, "UTF-8")}")
        withContext(Dispatchers.IO) {
            val conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "DELETE"
                setRequestProperty("Authorization", "Bearer ${_endpoint.value.token}")
                connectTimeout = 7_000
                readTimeout = 7_000
            }
            try {
                val code = conn.responseCode
                if (code !in 200..299) error("Session delete failed ($code)")
            } finally {
                conn.disconnect()
            }
        }
        // Session is gone server-side — drop its cached scrollback so a
        // recycled id can't resurrect a stale terminal on next launch.
        discardPersistedTerminal(sessionId)
        // Drop any unsent queued messages for the deleted session.
        updatePendingChats { it.clear(sessionId) }
    }

    fun resize(sessionId: String, rows: UShort, cols: UShort) {
        val c = client ?: return
        viewModelScope.launch { runCatching { withContext(Dispatchers.IO) { c.resize(sessionId, rows, cols) } } }
    }

    /** Sessions + creating placeholders, placeholders first so users see progress immediately. */
    fun visibleSessions(): List<VisibleSession> {
        val real = _sessions.value.map { VisibleSession.Real(it) }
        val placeholders = _sessionLifecycle.value
            .filter { (id, lc) ->
                lc is SessionLifecycle.Creating && _sessions.value.none { it.id == id }
            }
            .keys
            .sorted()
            .map { id ->
                val reason = (_sessionLifecycle.value[id] as? SessionLifecycle.FailedToStart)?.reason
                VisibleSession.Creating(id, reason)
            }
        return placeholders + real
    }

    private fun refreshSessions() {
        val c = client ?: return
        // Drop any session the user has explicitly deleted. The deployed
        // broker keeps tmux-backed PTYs alive (#199) and keeps reporting a
        // just-deleted session; without this filter it would reappear in
        // the list and (because its tmux is live) read as interactive. The
        // tombstone set is the guarantee that delete stays terminal.
        val deleted = _deletedIds.value.toSet()
        val list = c.listSessions().filterNot { it.id in deleted }
        // Stamp each listed session with the currently-connected box so we
        // can (a) group by box on the home list and (b) gate sends to avoid
        // routing into the wrong broker (UnknownSession root cause).
        // Always stamp, even when the list is empty, so the box identity is
        // established for subsequent calls.
        val currentBoxId = savedHistoryServerId()
        val updates = list.associate { it.id to currentBoxId }
        if (updates.isNotEmpty()) {
            _sessionBox.value = _sessionBox.value + updates
        }
        Telemetry.breadcrumb("session", "refreshSessions",
            mapOf("count" to list.size.toString(), "box" to currentBoxId))
        // Per-box merge: keep sessions whose sessionBox stamp points to a
        // DIFFERENT box (they stay visible as dimmed history rows per #522),
        // and replace this box's session entries with the freshly-listed ones.
        // This fixes the box-switch bug: switching A->B now shows box B's
        // sessions once the broker responds (even if box B has zero sessions),
        // while keeping box A's sessions visible (stamped boxA). The old
        // "if isNotEmpty" guard prevented box B from ever populating because
        // the Rust client returns [] until status frames land -- which never
        // happens for sessions we haven't joined yet.
        // Mirror of iOS `SessionStore.refreshSessions`.
        val otherBoxSessions = _sessions.value.filter { s ->
            val stamp = _sessionBox.value[s.id] ?: return@filter false
            stamp != currentBoxId
        }
        _sessions.value = otherBoxSessions + list
        for (s in _sessions.value) {
            // Do NOT blanket-default listed sessions to `Live`.
            // `listSessions` can include recovered / exited /
            // not-currently-running rows, and a default of `Live` made
            // every one of them open interactive (the "History still
            // interactive" bug, iOS PR #214). Liveness is now proven by a
            // live-phase status delta ([onStatus]) or the create/attach
            // round-trip — never by mere presence in the list. We seed a
            // terminal lifecycle from the listed phase when we can already
            // see the session is dead, so [isReadOnly] is correct on first
            // paint even before a fresh status frame arrives.
            if (_sessionLifecycle.value[s.id] == null) {
                val phase = _statusBySession.value[s.id]?.phase
                if (phase != null && phase.lowercase().startsWith("exited")) {
                    val code = exitCode(phase) ?: 0
                    updateLifecycle { it + (s.id to SessionLifecycle.Exited(code)) }
                }
            }
            refreshConversation(s.id)
        }
    }

    private fun refreshConversation(sessionId: String) {
        val c = client ?: return
        runCatching { c.listConversationItems(sessionId) }
            .onSuccess { items ->
                // Preserve locally-echoed `local-*` items not yet reflected
                // by the server (matched by role+content). Once the harness
                // mirrors the same text back under a server id, the local
                // copy drops.
                //
                // The broker doesn't loop user messages back as
                // `on_chat_event`, so the user's `local-*` echo lives
                // forever in `stillPending`. Appending it *after* `items`
                // would render the assistant's reply above the user's
                // prompt — confusing. Splice by timestamp so the order stays
                // chronological. Mirror of iOS `SessionStore.refreshConversation`.
                val existing = _conversationLog.value[sessionId] ?: emptyList()
                val serverFingerprints = items.map { "${it.role}|${it.content}" }.toSet()
                val stillPending = existing.filter {
                    it.id.startsWith("local-") && "${it.role}|${it.content}" !in serverFingerprints
                }
                // Splice the local user echo into the server log in true
                // chronological order. Carry-forward sort: an item whose ts
                // we can't parse keeps its arrival position instead of
                // collapsing to 0L and jumping above the user turn that
                // preceded it (device bug: agent reply rendered before the
                // user's prompt). See [sortedByConversationTs].
                val merged = (items + stillPending).sortedByConversationTs { it.ts }
                _conversationLog.value = _conversationLog.value + (sessionId to merged)
            }
    }

    private fun updateLifecycle(transform: (Map<String, SessionLifecycle>) -> Map<String, SessionLifecycle>) {
        _sessionLifecycle.value = transform(_sessionLifecycle.value)
    }

    /**
     * Active v2 agent-login coordinator, set by the login sheet while a
     * flow is in progress. Inbound `agent_login_*` view_events route
     * here. Mirrors iOS `SessionStore.activeLoginCoordinator`.
     */
    @Volatile
    var activeLoginCoordinator: AgentLoginCoordinator? = null

    /**
     * Route an inbound `agent_login_*` view_event (delivered by the
     * core's `on_view_event`) to the active coordinator. No-op when no
     * flow is active — late deliveries after cancel are dropped. Mirror
     * of iOS `routeAgentLoginViewEvent`.
     */
    fun routeAgentLoginViewEvent(kind: String, payload: Map<String, String>) {
        val coordinator = activeLoginCoordinator ?: return
        when (kind) {
            "agent_login_url" -> {
                val port = payload["loopback_port"]?.toIntOrNull() ?: return
                val token = payload["session_token"] ?: return
                val url = payload["url"]?.let { runCatching { java.net.URI.create(it) }.getOrNull() } ?: return
                coordinator.handleAgentLoginURL(port, token, url)
            }
            "agent_login_complete" -> {
                coordinator.handleAgentLoginComplete()
                activeLoginCoordinator = null
            }
            "agent_login_failed" -> {
                coordinator.handleAgentLoginFailed(payload["reason"] ?: "broker reported failure")
                activeLoginCoordinator = null
            }
        }
    }

    // --- Terminal scrollback disk persistence (cold-launch restore) ---
    //
    // The broker keeps the authoritative scrollback and replays it on
    // re-attach, but the client's `terminalBuffer` is in-memory only — after a
    // process death a reopened session shows a BLANK terminal until the socket
    // reconnects. We mirror the buffer to a small per-session cache file so a
    // cold launch paints the last-known terminal instantly; the live snapshot
    // then REPLACES it. Mirror of iOS `SessionStore.swift`.

    /**
     * Mark a session dirty and schedule a coalesced disk flush. Debounced
     * (~3s) so a streaming PTY doesn't thrash I/O — the broker is
     * authoritative on reconnect, so a slightly-stale on-disk copy is fine.
     * Callbacks arrive on UniFFI worker threads, so the dirty set is
     * synchronized and the flush hops to [Dispatchers.IO].
     */
    private fun scheduleTerminalPersist(sessionId: String) {
        terminalPersistDirty.add(sessionId)
        if (terminalPersistScheduled.compareAndSet(false, true)) {
            viewModelScope.launch(Dispatchers.IO) {
                delay(3_000)
                terminalPersistScheduled.set(false)
                flushTerminalPersist()
            }
        }
    }

    /** Write every dirty session's tail-capped buffer to disk. */
    fun flushTerminalPersist() {
        val dir = scrollbackDir ?: return
        val dirty: List<String>
        synchronized(terminalPersistDirty) {
            dirty = terminalPersistDirty.toList()
            terminalPersistDirty.clear()
        }
        val buffers = _terminalBuffer.value
        for (id in dirty) {
            val data = buffers[id] ?: continue
            TerminalScrollbackCache.write(dir, id, data)
        }
    }

    /**
     * Load a session's persisted scrollback into the in-memory buffer when we
     * don't already hold live bytes. Called on (re)attach so a cold launch
     * shows the last-known terminal instantly; the broker's live snapshot
     * later REPLACES it ([onSnapshot]).
     */
    fun hydrateTerminalBuffer(sessionId: String) {
        val existing = _terminalBuffer.value[sessionId]
        if (existing != null && existing.isNotEmpty()) return
        val dir = scrollbackDir ?: return
        val data = TerminalScrollbackCache.read(dir, sessionId) ?: return
        _terminalBuffer.value = _terminalBuffer.value + (sessionId to data)
    }

    /** Drop a session's persisted scrollback (session deleted server-side). */
    fun discardPersistedTerminal(sessionId: String) {
        terminalPersistDirty.remove(sessionId)
        scrollbackDir?.let { TerminalScrollbackCache.delete(it, sessionId) }
    }

    // ConduitDelegate — callbacks arrive on UniFFI worker threads; mutate
    // StateFlows directly (they're thread-safe) but no UI assumptions here.

    override fun onPtyData(sessionId: String, data: ByteArray) {
        _terminalBuffer.value = _terminalBuffer.value.toMutableMap().also { m ->
            val prev = m[sessionId] ?: ByteArray(0)
            m[sessionId] = prev + data
        }
        scheduleTerminalPersist(sessionId)
    }

    override fun onChatEvent(sessionId: String, event: ChatEvent) {
        // Funnel: first assistant reply on the very first session.
        if (event.role == "assistant") {
            val priorAssistant = _chatLog.value[sessionId].orEmpty().filter { it.role == "assistant" }
            if (_sessions.value.size <= 1 && priorAssistant.isEmpty()) {
                Telemetry.breadcrumb("onboarding", sh.nikhil.conduit.ui.OnboardingStep.FIRST_REPLY_RECEIVED,
                    mapOf("session" to sessionId, "chars" to event.content.length.toString()))
            }
        }
        _chatLog.value = _chatLog.value.toMutableMap().also { m ->
            m[sessionId] = (m[sessionId] ?: emptyList()) + event
        }
        // A fresh turn invalidates the previous turn's AI chips (task
        // #233); the broker emits a new set after this turn completes.
        clearQuickReplies(sessionId)
        refreshConversation(sessionId)
    }

    override fun onViewEvent(sessionId: String, kind: String, payload: Map<String, String>) {
        when (kind) {
            "quick_replies" -> ingestQuickReplies(sessionId, payload)
            "session_title" -> ingestSessionTitle(sessionId, payload)
            "agents" -> ingestSubagents(sessionId, payload)
            else -> routeAgentLoginViewEvent(kind, payload)
        }
    }

    /**
     * Ingest a broker AI session title (task: ai-session-titles). Stores
     * the title so every title surface picks it up live; a blank/empty
     * title is ignored so we never clobber a good name. Persisted so a
     * history row keeps the AI name across relaunch. Mirror of iOS
     * `SessionStore.ingestSessionTitle`.
     */
    fun ingestSessionTitle(sessionId: String, payload: Map<String, String>) {
        val title = payload["title"]?.trim()
        if (title.isNullOrEmpty()) return
        val next = _brokerTitles.value.toMutableMap().also { it[sessionId] = title }
        _brokerTitles.value = next
        prefs?.edit()?.putString(KEY_BROKER_TITLES, encodeDisplayNames(next))?.apply()
    }

    /**
     * Ingest a broker-generated quick-reply set for a session (task
     * #233). Replaces any prior set; an unusable payload (no replies)
     * clears the chips. Mirror of iOS `SessionStore.ingestQuickReplies`.
     */
    fun ingestQuickReplies(sessionId: String, payload: Map<String, String>) {
        val parsed = AIQuickReplies.from(payload)
        _quickReplies.value = _quickReplies.value.toMutableMap().also { m ->
            if (parsed != null) m[sessionId] = parsed else m.remove(sessionId)
        }
    }

    /**
     * Ingest a full subagent roster snapshot from the broker's
     * `view:"agents"` view_event. The broker sends the FULL snapshot on
     * every task_* frame so reconnecting clients catch up via record+replay.
     * Emits a Telemetry breadcrumb the first time a non-empty roster arrives
     * for a session. Mirror of iOS `SessionStore.ingestSubagents`.
     */
    fun ingestSubagents(sessionId: String, payload: Map<String, String>) {
        val entries = SubagentEntry.listFrom(payload)
        val prior = _subagentRoster.value[sessionId]
        val isFirstPopulate = prior.isNullOrEmpty() && entries.isNotEmpty()
        _subagentRoster.value = _subagentRoster.value.toMutableMap().also { m ->
            if (entries.isNotEmpty()) m[sessionId] = entries else m.remove(sessionId)
        }
        if (isFirstPopulate) {
            Telemetry.breadcrumb(
                "agents_panel",
                "subagent roster first populate",
                mapOf("session" to sessionId, "count" to entries.size.toString()),
            )
        }
    }

    /** Clear a session's AI quick-reply chips (on send / fresh turn). */
    private fun clearQuickReplies(sessionId: String) {
        if (_quickReplies.value[sessionId] == null) return
        _quickReplies.value = _quickReplies.value.toMutableMap().also { it.remove(sessionId) }
    }

    override fun onPreviewReady(sessionId: String, preview: PreviewInfo) {
        _previews.value = _previews.value + (sessionId to preview)
    }

    override fun onStatus(status: SessionStatus) {
        _statusBySession.value = _statusBySession.value + (status.session to status)
        status.preview?.let { _previews.value = _previews.value + (status.session to it) }
        // Promote lifecycle from the phase the broker actually reported —
        // NOT a blanket `Live` (iOS PR #214). A status frame for a
        // recovered/exited session carries `phase: "exited…"`; that must
        // lock the row read-only, not resurrect it as interactive.
        // [SessionLifecycle.Exited] / [SessionLifecycle.FailedToStart] are
        // terminal and never downgraded here.
        when (_sessionLifecycle.value[status.session]) {
            null, is SessionLifecycle.Creating -> {
                if (isLivePhase(status.phase)) {
                    updateLifecycle { it + (status.session to SessionLifecycle.Live) }
                } else if (status.phase.lowercase().startsWith("exited")) {
                    // Surface an explicit exit even if we never saw an
                    // `exit` frame — e.g. joining an already-dead session.
                    val code = exitCode(status.phase) ?: 0
                    updateLifecycle { it + (status.session to SessionLifecycle.Exited(code)) }
                }
                // A non-live, non-exited phase (empty / unknown) leaves the
                // lifecycle unset → [isReadOnly] returns true (fail closed).
            }
            is SessionLifecycle.Live -> {
                // Already live: a later exited phase still demotes to terminal.
                if (status.phase.lowercase().startsWith("exited")) {
                    val code = exitCode(status.phase) ?: 0
                    updateLifecycle { it + (status.session to SessionLifecycle.Exited(code)) }
                }
            }
            is SessionLifecycle.Exited, is SessionLifecycle.FailedToStart -> {
                // terminal — never revived by a status delta
            }
        }
        // Fold a broker-supplied display label (`rename_session` per
        // protocol §3.3) into the local displayNames map so every
        // existing surface — title, ThreadSwitcher, HomeScreen — sees
        // the renamed label without each having to read the status
        // bag separately. Prefer the new `displayName` field; fall
        // back to the legacy `sessionName` mirror for older brokers.
        // Skip a label that's just the raw session id/UUID — the broker
        // echoes the id as the "name" for unnamed sessions, and folding
        // that into displayNames (priority #1) would clobber the friendly
        // chat-derived name. A real `rename_session` label still lands.
        val serverLabel = (status.displayName?.trim()?.takeIf { it.isNotEmpty() }
            ?: status.sessionName?.trim()?.takeIf { it.isNotEmpty() })
            ?.takeUnless { it == status.session || SessionNaming.UUID_REGEX.matches(it) }
        if (serverLabel != null && _displayNames.value[status.session] != serverLabel) {
            val next = _displayNames.value.toMutableMap()
            next[status.session] = serverLabel
            _displayNames.value = next
            prefs?.edit()?.putString(KEY_DISPLAY_NAMES, encodeDisplayNames(next))?.apply()
        }
        _harness.value = HarnessState.Live
        // Fold this snapshot into the persisted archived index so the
        // session survives in History after it ends (Android used to list
        // only live sessions). Idempotent; tombstoned ids are suppressed.
        recordSavedSession(status.session)
        refreshSessions()
        // "Queued Next" flush-on-turn-complete: detect the active -> idle
        // transition and auto-deliver the oldest queued entry. Only fire
        // when turnActive is explicitly false and was previously true (edge
        // trigger); null turnActive (old broker) is ignored.
        val nowActive = status.turnActive
        if (nowActive != null) {
            val wasActive = _lastTurnActive[status.session]
            _lastTurnActive[status.session] = nowActive
            if (wasActive == true && !nowActive) {
                flushOnTurnComplete(status.session)
            }
        }
    }

    override fun onSnapshot(sessionId: String, gunzipped: ByteArray) {
        _terminalBuffer.value = _terminalBuffer.value + (sessionId to gunzipped)
        scheduleTerminalPersist(sessionId)
    }

    override fun onExit(sessionId: String, code: Int) {
        updateLifecycle { it + (sessionId to SessionLifecycle.Exited(code)) }
        _statusBySession.value[sessionId]?.let { prev ->
            _statusBySession.value = _statusBySession.value + (sessionId to prev.copy(
                phase = "exited($code)",
                health = "red",
            ))
        }
        // Lock the archived-index row terminal so History shows it exited.
        recordSavedSession(sessionId, isExited = true)
    }

    override fun onDisconnected(reason: String) {
        // Preserve an existing "Pairing expired" diagnosis — the server tearing
        // down the socket right after an auth rejection is part of the same
        // failure, not a new one. Also preserve a self-heal already in progress
        // (Reconnecting state) so we don't clobber it with a Failed state.
        val current = _harness.value
        if (current is HarnessState.Failed &&
            current.reason.lowercase().contains("pairing expired")
        ) {
            return
        }
        if (current is HarnessState.Reconnecting) {
            // SSH self-heal triggered from onConnectionHealth; don't clobber.
            return
        }
        val lower = reason.lowercase()
        val isAuthReason = lower.contains("auth") || lower.contains("401") || lower.contains("unauthorized")
        if (isAuthReason) {
            // SSH boxes: token mismatch is recoverable via re-bootstrap.
            // Token-paired boxes: the pairing QR is genuinely expired.
            val isSSH = _savedServers.value.firstOrNull { it.endpoint == _endpoint.value }?.ssh != null
            if (isSSH) {
                Telemetry.breadcrumb("session", "auth failure on SSH box — triggering self-heal",
                    mapOf("phase" to "on_disconnected", "endpoint" to _endpoint.value.displayHost))
                _harness.value = HarnessState.Reconnecting(1u, 3u)
                attemptSshSelfHeal()
                return
            }
        }
        _harness.value = if (isAuthReason) {
            HarnessState.Failed("Pairing expired. Scan a new QR code from the server.")
        } else {
            HarnessState.Failed("Disconnected: $reason")
        }
        // Routine disconnects (code 0 / clean close, network loss, server
        // restart) are expected lifecycle — downgraded to breadcrumb so the
        // reason is still attached to the next real error without burning a
        // Sentry quota event each time.
        // Auth failures are NOT downgraded: those land in onConnectionHealth
        // above as genuine ERROR-level events (auth_expired).
        Telemetry.breadcrumb(
            category = "connect",
            message = "disconnected from harness",
            data = mapOf(
                "reason_code" to connectionReasonCode(reason),
                "endpoint" to _endpoint.value.displayHost,
                "detail" to reason,
            ),
        )
    }

    override fun onConnectionHealth(sessionId: String, health: ConnectionHealth) {
        _connectionHealth.value = _connectionHealth.value + (sessionId to health)
        when (health) {
            is ConnectionHealth.Connected -> {
                _harness.value = if (_sessionLifecycle.value.isNotEmpty()) {
                    HarnessState.Live
                } else {
                    HarnessState.Linked
                }
            }
            is ConnectionHealth.Connecting -> {
                _harness.value = HarnessState.Reconnecting(health.attempt, health.maxAttempts)
            }
            is ConnectionHealth.Disconnected -> {
                if (health.auth) {
                    val isSSH = _savedServers.value.firstOrNull { it.endpoint == _endpoint.value }?.ssh != null
                    if (isSSH) {
                        Telemetry.breadcrumb("session", "auth failure on SSH box — triggering self-heal",
                            mapOf("phase" to "connection_health", "endpoint" to _endpoint.value.displayHost,
                                  "session_id" to sessionId))
                        _harness.value = HarnessState.Reconnecting(1u, 3u)
                        attemptSshSelfHeal()
                    } else {
                        _harness.value = HarnessState.Failed("Pairing expired. Scan a new QR code from the server.")
                    }
                    Telemetry.capture(
                        error = IllegalStateException(health.reason),
                        message = "Android connection health auth failure",
                        tags = mapOf(
                            "surface" to "android",
                            "phase" to "connection_health",
                            "reason_code" to "auth_expired",
                            "is_ssh" to isSSH.toString(),
                        ),
                        extras = mapOf(
                            "endpoint" to _endpoint.value.displayHost,
                            "session_id" to sessionId,
                            "detail" to health.reason,
                        ),
                    )
                } else {
                    onDisconnected(health.reason)
                }
            }
        }
    }

    private fun describe(t: Throwable): String {
        if (isAuth(t)) {
            return "Authentication failed. This pairing token has expired; scan a fresh QR code from the server."
        }
        return t.message ?: t.toString()
    }

    private fun isAuth(t: Throwable): Boolean {
        val text = (t.message ?: t.toString()).lowercase()
        return text.contains("auth(") || text == "auth" || text.contains("unauthorized")
    }

    private fun connectionReasonCode(reason: String): String {
        val lower = reason.lowercase()
        return when {
            lower.contains("auth") || lower.contains("401") || lower.contains("unauthorized") -> "auth_expired"
            lower.contains("timed out") || lower.contains("timeout") -> "timeout"
            lower.contains("refused") -> "ws_refused"
            lower.contains("network") -> "network_unavailable"
            else -> "disconnected"
        }
    }

    companion object {
        private const val KEY_URL = "conduit.endpoint.url"
        private const val KEY_TOKEN = "conduit.endpoint.token"
        private const val KEY_SAVED_SERVERS = "conduit.saved_servers"
        private const val KEY_RECENT_DIRS = "conduit.recent_dirs_by_server"
        private const val KEY_DISPLAY_NAMES = "conduit.session_display_names"
        private const val KEY_BROKER_TITLES = "conduit.session_broker_titles"
        private const val KEY_DELETED_IDS = "conduit.deleted_session_ids"
        private const val KEY_SAVED_SESSIONS = "conduit.saved_sessions"
        private const val KEY_PENDING_CHATS = "conduit.pending_chats"

        /** SSH-tunnel transport toggle (connection-critical). Default ON;
         *  flip off to fall back to the legacy public path for one release. */
        private const val KEY_SSH_TUNNEL = "conduit.transport.ssh_tunnel"

        /** Upper bound on retained delete tombstones. */
        private const val TOMBSTONE_CAP = 500

        /**
         * The curated bootstrap prompt seeded when the user taps "Set up agent
         * harness" (Part B). Audits the repo and writes a CLAUDE.md + AGENTS.md
         * with VERIFIED gate commands, asking before committing. Mirror of iOS
         * `SessionStore.harnessBootstrapPrompt`.
         */
        const val HARNESS_BOOTSTRAP_PROMPT =
            "Audit this repository and set up its agent harness. Identify the real " +
                "build, test, and lint commands by inspecting the project (do not guess) " +
                "and verify each one actually runs. Then write a concise CLAUDE.md and " +
                "AGENTS.md documenting those verified gate commands and the project " +
                "layout, and propose sensible CI gates. Ask me before committing anything."

        /**
         * Classify a broker `SessionStatus.phase` as live/running vs
         * terminal/unknown. The broker reports `running` for an active
         * agent and `exited` (optionally `exited(N)` after our own
         * [onExit] rewrites it) for a dead one; recovered sessions
         * restore whatever phase was persisted. We treat anything that
         * isn't an affirmatively-running phase as NOT live so an
         * unfamiliar or empty phase fails closed (read-only) rather than
         * open. Mirror of iOS `SessionStore.isLivePhase`.
         */
        fun isLivePhase(phase: String): Boolean {
            val p = phase.trim().lowercase()
            if (p.isEmpty()) return false
            if (p.startsWith("exited") || p.startsWith("failed") || p.startsWith("dead")) {
                return false
            }
            // Known running/active phases emitted by the broker + adapters.
            return p in LIVE_PHASES
        }

        private val LIVE_PHASES = setOf(
            "running", "ready", "idle", "thinking", "working",
            "starting", "booting", "swapping",
        )

        /**
         * Pull the exit code out of an `exited(N)` phase string. The
         * broker emits a bare `exited`; our own [onExit] rewrites the
         * cached status to `exited(<code>)`. Returns null when there's no
         * parseable code (caller defaults to 0). Mirror of iOS
         * `SessionStore.exitCode(fromPhase:)`.
         */
        fun exitCode(fromPhase: String): Int? {
            val open = fromPhase.indexOf('(')
            val close = fromPhase.indexOf(')')
            if (open < 0 || close < 0 || open >= close) return null
            return fromPhase.substring(open + 1, close).trim().toIntOrNull()
        }
    }

    private fun encodeDeletedIds(ids: List<String>): String {
        val arr = JSONArray()
        ids.forEach { arr.put(it) }
        return arr.toString()
    }

    private fun decodeDeletedIds(raw: String?): List<String> {
        if (raw.isNullOrBlank()) return emptyList()
        return runCatching {
            val arr = JSONArray(raw)
            val seen = LinkedHashSet<String>()
            for (i in 0 until arr.length()) {
                arr.optString(i, "").takeIf { it.isNotEmpty() }?.let { seen.add(it) }
            }
            seen.toList()
        }.getOrDefault(emptyList())
    }

    private fun encodeDisplayNames(names: Map<String, String>): String {
        val obj = JSONObject()
        names.forEach { (k, v) -> obj.put(k, v) }
        return obj.toString()
    }

    private fun decodeDisplayNames(raw: String?): Map<String, String> {
        if (raw.isNullOrBlank()) return emptyMap()
        return runCatching {
            val obj = JSONObject(raw)
            buildMap {
                obj.keys().forEach { k -> put(k, obj.optString(k, "")) }
            }
        }.getOrDefault(emptyMap())
    }

    private fun persistSavedServers(servers: List<SavedServer>) {
        val p = prefs ?: return
        val arr = JSONArray()
        servers.forEach { s ->
            val o = JSONObject()
            o.put("id", s.id)
            o.put("name", s.name)
            o.put("url", s.endpoint.url)
            o.put("token", s.endpoint.token)
            o.put("default", s.isDefault)
            s.ssh?.let { ref ->
                val ssh = JSONObject()
                ssh.put("host", ref.host)
                ssh.put("port", ref.port.toInt())
                ssh.put("username", ref.username)
                o.put("ssh", ssh)
            }
            arr.put(o)
        }
        p.edit().putString(KEY_SAVED_SERVERS, arr.toString()).apply()
    }

    private fun decodeSavedServers(raw: String?): List<SavedServer> {
        if (raw.isNullOrBlank()) return emptyList()
        return runCatching {
            val arr = JSONArray(raw)
            buildList {
                for (i in 0 until arr.length()) {
                    val o = arr.getJSONObject(i)
                    val sshObj = o.optJSONObject("ssh")
                    val sshRef = if (sshObj != null) {
                        SshEndpointRef(
                            host = sshObj.optString("host", ""),
                            port = sshObj.optInt("port", 22).coerceIn(1, 65535).toUShort(),
                            username = sshObj.optString("username", ""),
                        )
                    } else null
                    add(
                        SavedServer(
                            id = o.optString("id", UUID.randomUUID().toString()),
                            name = o.optString("name", ""),
                            endpoint = Endpoint(
                                o.optString("url", ""),
                                o.optString("token", ""),
                            ),
                            isDefault = o.optBoolean("default", false),
                            ssh = sshRef,
                        )
                    )
                }
            }
        }.getOrElse { emptyList() }
    }

    private fun refreshRecentDirectories() {
        val all = decodeRecentDirectories(prefs?.getString(KEY_RECENT_DIRS, null))
        _recentDirectories.value = all[_endpoint.value.displayHost] ?: emptyList()
    }

    private fun rememberRecentDirectory(path: String) {
        val trimmed = path.trim()
        if (trimmed.isEmpty()) return
        val all = decodeRecentDirectories(prefs?.getString(KEY_RECENT_DIRS, null)).toMutableMap()
        val key = _endpoint.value.displayHost
        val current = (all[key] ?: emptyList()).toMutableList().apply {
            removeAll { it == trimmed }
            add(0, trimmed)
            if (size > 12) subList(12, size).clear()
        }
        all[key] = current
        persistRecentDirectories(all)
        _recentDirectories.value = current
    }

    private fun persistRecentDirectories(value: Map<String, List<String>>) {
        val obj = JSONObject()
        value.forEach { (server, dirs) ->
            val arr = JSONArray()
            dirs.forEach { arr.put(it) }
            obj.put(server, arr)
        }
        prefs?.edit()?.putString(KEY_RECENT_DIRS, obj.toString())?.apply()
    }

    private fun decodeRecentDirectories(raw: String?): Map<String, List<String>> {
        if (raw.isNullOrBlank()) return emptyMap()
        return runCatching {
            val obj = JSONObject(raw)
            buildMap {
                obj.keys().forEach { key ->
                    val arr = obj.optJSONArray(key) ?: JSONArray()
                    val dirs = buildList {
                        for (i in 0 until arr.length()) add(arr.optString(i, ""))
                    }.filter { it.isNotBlank() }
                    put(key, dirs)
                }
            }
        }.getOrElse { emptyMap() }
    }

    private suspend fun waitUntilCommandReady(timeoutMs: Long = 6_000L): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            val h = _harness.value
            if (h is HarnessState.Linked || h is HarnessState.Live || h is HarnessState.Reconnecting) {
                return true
            }
            if (h is HarnessState.Failed) {
                return false
            }
            delay(100)
        }
        return false
    }
}

/**
 * Bridges the Rust SSH layer's TOFU callback into the Compose dialog. The
 * Rust side calls `acceptHostKey` synchronously on a worker thread; we
 * either short-circuit on a previously trusted fingerprint (handled inside
 * `requestHostKeyDecision`) or block this worker on a [CountDownLatch]
 * while the user taps Accept/Reject on the UI thread.
 */
class SshHostKeyBridge(
    private val store: SessionStore,
    private val host: String,
    private val port: UShort,
) : SshHostKeyDelegate {
    override fun `acceptHostKey`(`fingerprint`: String): Boolean {
        val latch = CountDownLatch(1)
        var decision = false
        store.requestHostKeyDecision(host, port, fingerprint) { accepted ->
            decision = accepted
            latch.countDown()
        }
        latch.await()
        return decision
    }
}

/**
 * Bridges the Rust SSH bootstrap progress callbacks into UI state.
 * Called synchronously on the russh worker thread; posts to the main
 * thread via [SessionStore]'s [MutableStateFlow] to update
 * [SessionStore.sshBootstrap] with a friendly human-readable message.
 * The mapping covers both the Rust connect-sequence phases and the STEP
 * markers emitted by remote-bootstrap.sh.
 */
class SshProgressBridge(
    private val store: SessionStore,
    private val host: String,
) : SshProgressDelegate {
    override fun `onProgress`(`phase`: String, `detail`: String?) {
        val message = friendlyMessage(phase, detail) ?: return
        store.viewModelScope.launch {
            store.updateSshBootstrapProgress(message)
        }
    }

    private fun friendlyMessage(phase: String, detail: String?): String? = when (phase) {
        "connecting"    -> "Connecting to ${detail ?: host}…"
        "handshake"     -> "Securing connection…"
        "authenticating" -> "Authenticating…"
        "tunnel"        -> "Opening secure tunnel…"
        "bootstrap"     -> when (detail) {
            "STEP reuse_check"    -> "Checking for existing server…"
            "STEP download_broker" -> "Downloading server…"
            "STEP start_broker"   -> "Starting server…"
            "STEP install_agent"  -> "Installing agent…"
            "STEP wait_ready"     -> "Waiting for server…"
            else -> null  // suppress other human-readable stderr lines
        }
        else -> null
    }
}
