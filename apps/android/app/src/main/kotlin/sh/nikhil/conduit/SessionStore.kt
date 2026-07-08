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
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import sh.nikhil.conduit.auth.OAuthClient
import sh.nikhil.conduit.auth.OAuthCredential
import sh.nikhil.conduit.auth.OAuthProvider
import sh.nikhil.conduit.auth.OAuthStore
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
import uniffi.conduit_core.ConduitException
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
import sh.nikhil.conduit.demo.DemoData
import sh.nikhil.conduit.push.PushStore
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

/**
 * Status of a [SavedServer] that was added via SSH. Null on a token-paired
 * box (status is not tracked) or an SSH box that has not yet encountered a
 * failure. Serialised as an optional "status" key in the saved-servers JSON
 * so older builds that lack the key still decode correctly.
 */
sealed class SavedServerStatus {
    /** Bootstrap completed successfully; box is usable. */
    data object Ready : SavedServerStatus()
    /** Bootstrap failed with [reason]; box is not yet usable. */
    data class Failed(val reason: String) : SavedServerStatus()
}

/**
 * Non-secret SSH coordinates to prefill the SSH login sheet on a Retry
 * (Part B). Carries no password/key -- the user must re-enter credentials.
 */
data class SshLoginPrefill(
    val host: String,
    val port: UShort,
    val username: String,
    val serverName: String,
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


/**
 * Phase of an in-app approval resolve (Fix 9). [Stale] is the broker's 404
 * "nothing pending" — surfaced honestly rather than as a false success.
 */
enum class ApprovalResolvePhase { Idle, Resolving, Resolved, Stale, Failed }

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
    /**
     * Non-null when this is a failed SSH add that has not yet succeeded.
     * Null means either not-an-SSH-box or the bootstrap completed normally.
     * Decoded with optString/optBoolean so old JSON (without the key) parses fine.
     */
    val status: SavedServerStatus? = null,
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
 * The local user echo stamps ISO_INSTANT ("Z") while broker items may
 * use an offset form, so comparing the raw strings lexicographically can
 * put a later assistant reply above an earlier user turn (device bug:
 * agent replies appearing before user messages). Tries [Instant.parse]
 * then [OffsetDateTime.parse]; unparseable -> 0L (sorts first, with the
 * caller's original index breaking the tie so arrival order is kept).
 *
 * Memoized: the same ts strings re-appear on every refresh (every streamed
 * delta re-merges the full transcript). [ConcurrentHashMap] collapses
 * repeated JVM datetime parses to a map lookup, eliminating the equivalent
 * of the iOS main-thread hang (Sentry: sortedByConversationTs / ICU parse).
 * Thread-safe: called from UniFFI worker threads (onStatus/onChatEvent).
 */
private val tsEpochMillisCache = java.util.concurrent.ConcurrentHashMap<String, Long>()

fun tsEpochMillis(ts: String): Long {
    if (ts.isEmpty()) return 0L
    tsEpochMillisCache[ts]?.let { return it }
    val epoch = try {
        Instant.parse(ts).toEpochMilli()
    } catch (_: Exception) {
        try {
            OffsetDateTime.parse(ts).toInstant().toEpochMilli()
        } catch (_: Exception) {
            0L
        }
    }
    tsEpochMillisCache[ts] = epoch
    return epoch
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
 * Pure per-box merge for [SessionStore.refreshSessions]. Extracted so it can be
 * unit-tested on the JVM classpath (the store's [refreshSessions] is private and
 * needs the Rust client).
 *
 * Rules:
 *  - Sessions stamped to a DIFFERENT box than [currentBoxId] are kept verbatim
 *    (dimmed history rows per #522).
 *  - The freshly [listed] sessions for the current box replace this box's
 *    entries (fresh list wins on overlap for status/fields).
 *  - DATA-LOSS GUARD: existing current-box sessions the fresh list OMITTED are
 *    PRESERVED unless they are known-[deleted] or in [recentlyArchived]. This
 *    stops a transient empty/partial `listSessions()` (which happens right
 *    after a resume/adopt join, before status frames land) from wiping the
 *    whole home list ("No sessions yet" / "all sessions vanish" bug). A real
 *    deletion still propagates once the id lands in `deleted`/`archived`.
 *
 * Mirror of iOS `SessionStore.refreshSessions`' per-box merge intent.
 */
internal fun <T> mergeRefreshedSessions(
    existing: List<T>,
    listed: List<T>,
    sessionBox: Map<String, String?>,
    currentBoxId: String?,
    deleted: Set<String>,
    recentlyArchived: Set<String>,
    idOf: (T) -> String,
): List<T> {
    val otherBoxSessions = existing.filter { s ->
        val stamp = sessionBox[idOf(s)] ?: return@filter false
        stamp != currentBoxId
    }
    val listedIds = listed.map(idOf).toSet()
    val preservedCurrentBox = existing.filter { s ->
        val id = idOf(s)
        val stamp = sessionBox[id]
        stamp == currentBoxId &&
            id !in listedIds &&
            id !in deleted &&
            id !in recentlyArchived
    }
    return otherBoxSessions + listed + preservedCurrentBox
}

/**
 * v1 store: wraps ConduitClient and bridges Rust delegate callbacks back onto
 * the main dispatcher as StateFlow updates. Replaced by Hilt-style DI in v2.
 */
class SessionStore : ViewModel(), ConduitDelegate {

    // MARK: - Demo mode
    private val _isDemoMode = MutableStateFlow(false)
    val isDemoMode: StateFlow<Boolean> = _isDemoMode.asStateFlow()

    fun activateDemo() {
        prefs?.edit()?.putBoolean("conduit.isDemoMode", true)?.apply()
        _isDemoMode.value = true
        // Seed the store so real Usage / Recap / Activity screens light up.
        _sessions.value = DemoData.sessions
        _statusBySession.value = _statusBySession.value + DemoData.statusBySession
        _conversationLog.value = _conversationLog.value + DemoData.conversationBySession
        updateLifecycle { map ->
            map + DemoData.sessions.associate { it.id to SessionLifecycle.Live }
        }
        // Demo mode never fetches /api/capabilities (no network), so this
        // stays false by default and PipelineMonitorScreen would render the
        // generic gate card instead of the rich handoff-preview markdown
        // block the demo-flow-1 fixture carries. Flip it on so the demo
        // shows the real Flow gate-review UI, matching what a broker that
        // supports it renders.
        _pipelineGatePreview.value = true
        Telemetry.breadcrumb("demo", "activated", mapOf("sessions" to DemoData.sessions.size.toString()))
    }

    fun deactivateDemo() {
        prefs?.edit()?.putBoolean("conduit.isDemoMode", false)?.apply()
        _isDemoMode.value = false
        // Remove all demo entries so no residue leaks into a real session.
        val demoIds = DemoData.sessions.map { it.id }.toSet()
        _sessions.value = _sessions.value.filterNot { it.id in demoIds }
        _statusBySession.value = _statusBySession.value - demoIds
        _conversationLog.value = _conversationLog.value - demoIds
        updateLifecycle { map -> map - demoIds }
        // Reset the demo-only capability override (see activateDemo()) --
        // the next real /api/capabilities fetch re-derives the true value.
        _pipelineGatePreview.value = false
        // Drop any locally-created fake flow(s) from the Flow wizard so
        // re-entering demo starts fresh.
        _demoExtraPipelines.value = emptyList()
        _demoExtraPipelineStatus.value = emptyMap()
        Telemetry.breadcrumb("demo", "deactivated")
    }

    // MARK: - Demo fake flows (Flow wizard "Start flow", no network)

    /** Locally-created flows started from the Flow wizard while in demo
     *  mode -- prepended to [sh.nikhil.conduit.demo.DemoData.pipelines] for
     *  the Home FLOWS section. Reset on activate/deactivateDemo. */
    private val _demoExtraPipelines = MutableStateFlow<List<sh.nikhil.conduit.ui.PipelineSummary>>(emptyList())
    val demoExtraPipelines: StateFlow<List<sh.nikhil.conduit.ui.PipelineSummary>> = _demoExtraPipelines.asStateFlow()

    private val _demoExtraPipelineStatus = MutableStateFlow<Map<String, sh.nikhil.conduit.ui.Pipeline>>(emptyMap())
    val demoExtraPipelineStatus: StateFlow<Map<String, sh.nikhil.conduit.ui.Pipeline>> = _demoExtraPipelineStatus.asStateFlow()

    /** Looks up detail for a demo flow id -- a locally-created fake flow
     *  first, falling back to the static
     *  [sh.nikhil.conduit.demo.DemoData.pipelineStatus] fixtures. */
    fun demoPipelineStatus(id: String): sh.nikhil.conduit.ui.Pipeline? =
        _demoExtraPipelineStatus.value[id] ?: DemoData.pipelineStatus(id)

    /** Builds a local fake "running" flow from the Flow wizard's task +
     *  steps (step 0 running, the rest queued) -- no network, mirrors the
     *  shape `/api/pipeline` would return. Prepends it to the demo FLOWS
     *  list and returns its id + status; the Monitor picks it back up via
     *  [demoPipelineStatus] since `isDemoMode` is on. */
    fun demoStartFlow(
        title: String,
        task: String,
        cwd: String,
        steps: List<sh.nikhil.conduit.ui.PipelineStepDraft>,
    ): Pair<String, sh.nikhil.conduit.ui.Pipeline> {
        val agentSteps = steps.filter { it.kind.isEmpty() }
        val id = "demo-fake-${_demoExtraPipelines.value.size + 1}"
        val now = Instant.now().toString()
        val effectiveTitle = title.ifEmpty { "Flow" }
        val summarySteps = agentSteps.mapIndexed { i, s ->
            sh.nikhil.conduit.ui.PipelineSummaryStep(
                agent = s.agentType, role = s.role,
                status = if (i == 0) "running" else "queued", gateAfter = s.gateAfter,
            )
        }
        val summary = sh.nikhil.conduit.ui.PipelineSummary(
            id = id, title = effectiveTitle, state = "running", currentStep = 0,
            stepCount = agentSteps.size, created = now, steps = summarySteps, result = null,
        )
        val statusSteps = agentSteps.mapIndexed { i, s ->
            sh.nikhil.conduit.ui.PipelineStep(
                index = i, agentType = s.agentType, role = s.role,
                promptTemplate = s.promptTemplate, inputFromPrev = s.inputFromPrev, gateAfter = s.gateAfter,
                sessionId = if (i == 0) "$id-step-0" else null,
                phase = if (i == 0) "running" else null,
                started = if (i == 0) now else null, ended = null,
            )
        }
        val status = sh.nikhil.conduit.ui.Pipeline(
            id = id, title = effectiveTitle, task = task,
            cwd = cwd.ifEmpty { "/home/user/projects/demo" }, base = "main",
            state = "running", currentStep = 0, steps = statusSteps, gate = null, result = null,
        )
        _demoExtraPipelines.value = listOf(summary) + _demoExtraPipelines.value
        _demoExtraPipelineStatus.value = _demoExtraPipelineStatus.value + (id to status)
        Telemetry.breadcrumb("demo", "fake_flow_started", mapOf("id" to id, "steps" to agentSteps.size.toString()))
        return id to status
    }

    private val _endpoint = MutableStateFlow(Endpoint())
    val endpoint: StateFlow<Endpoint> = _endpoint.asStateFlow()

    private val _harness = MutableStateFlow<HarnessState>(HarnessState.Disconnected)
    val harness: StateFlow<HarnessState> = _harness.asStateFlow()

    // MARK: Foreground refresh + grace-window state (Changes 1-4)

    /** Epoch-millis timestamp of the most recent app-foreground (onResume). Set
     *  by [lifecycleObserver.onResume]; read by [onConnectionHealth] to decide
     *  whether to start the "assume connected" grace window.
     *  `internal` so unit tests can set it directly as a seam. */
    @Volatile internal var foregroundedAt: Long? = null

    /** Timer job for the 4s grace window; cancelled when [.Connected] arrives. */
    private var graceWindowJob: Job? = null

    /** Last [HarnessState] that was [HarnessState.Live] or [HarnessState.Linked];
     *  returned by [visibleHarness] during the grace window. */
    @Volatile private var lastReachableHarness: HarnessState = HarnessState.Linked

    /** True during the ~4s grace window. [visibleHarness] returns
     *  [lastReachableHarness] when this is true and harness is Reconnecting. */
    private val _suppressGraceReconnecting = MutableStateFlow(false)

    /** Read-only view of the grace-window suppression flag. Exposed for unit tests. */
    val suppressGraceReconnecting: StateFlow<Boolean> = _suppressGraceReconnecting.asStateFlow()

    /** Sessions that had hydrated content at foreground time. Drained by
     *  [onConnectionHealth] Connected to fire a forced post-replay re-read. */
    private val sessionsNeedingPostConnectRefresh = mutableSetOf<String>()

    /** Backing store for [visibleHarness]. Updated via [updateVisibleHarness] to
     *  avoid a combine+stateIn that requires Dispatchers.Main at init time. */
    private val _visibleHarness = MutableStateFlow<HarnessState>(HarnessState.Disconnected)

    /** Display-only harness: during the ~4s post-foreground grace window returns
     *  [lastReachableHarness] instead of the actual Reconnecting state, so the
     *  banner stays "connected" for fast reconnects. The real [harness] is always
     *  used for functional gating (send gates, [HarnessState.canIssueCommands]). */
    val visibleHarness: StateFlow<HarnessState> = _visibleHarness.asStateFlow()

    /** Recompute [visibleHarness] from current [_harness] and [_suppressGraceReconnecting].
     *  Must be called whenever either input changes. */
    private fun updateVisibleHarness() {
        val h = _harness.value
        _visibleHarness.value = if (_suppressGraceReconnecting.value && h is HarnessState.Reconnecting) {
            lastReachableHarness
        } else h
    }

    /** Internal seam for unit tests: flip suppression without going through the
     *  foreground path (which would need Dispatchers.Main for the timer launch). */
    internal fun setSuppressGraceReconnectingForTesting(suppress: Boolean) {
        _suppressGraceReconnecting.value = suppress
        updateVisibleHarness()
    }

    private val _sessions = MutableStateFlow<List<ProjectSession>>(emptyList())
    val sessions: StateFlow<List<ProjectSession>> = _sessions.asStateFlow()

    // Sessions whose WS worker has been parked. Cleared on foreground so
    // notifyNetworkChange reconnects them automatically.
    private val pausedSessionIds = mutableSetOf<String>()

    private val _selectedId = MutableStateFlow<String?>(null)
    val selectedId: StateFlow<String?> = _selectedId.asStateFlow()
    private val _savedServers = MutableStateFlow<List<SavedServer>>(emptyList())
    val savedServers: StateFlow<List<SavedServer>> = _savedServers.asStateFlow()
    private val _recentDirectories = MutableStateFlow<List<String>>(emptyList())
    val recentDirectories: StateFlow<List<String>> = _recentDirectories.asStateFlow()

    /**
     * Best-effort default working directory for a new session/flow's
     * "Where" row -- the selected session's cwd when one is active, else
     * the most-recently-used directory on the current box
     * ([_recentDirectories]'s head, populated by [rememberRecentDirectory]
     * on every session/flow start that specified a cwd), else "" (no
     * folder). Shared by [sh.nikhil.conduit.ui.FlowStartSheet]'s compact
     * Session tab and [sh.nikhil.conduit.ui.FlowWizardScreen]'s Task screen
     * so both prefill the same way instead of one of them always showing
     * "no folder" when opened from Home with no session selected (device
     * feedback). Mirrors iOS `SessionStore.defaultSessionCwd`.
     */
    fun defaultSessionCwd(): String {
        if (_isDemoMode.value) {
            return DemoData.sessions.firstOrNull()?.cwd ?: ""
        }
        val activeId = _selectedId.value
        val sessionCwd = activeId?.let { _statusBySession.value[it]?.cwd }
        if (!sessionCwd.isNullOrEmpty()) return sessionCwd
        return _recentDirectories.value.firstOrNull() ?: ""
    }

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

    /**
     * One-shot error surfaced when [archive] fails so the UI can show a
     * snackbar. Cleared by the UI after display. Mirrors the pattern used
     * by [_sessionCreationError].
     */
    private val _archiveError = MutableStateFlow<String?>(null)
    val archiveError: StateFlow<String?> = _archiveError.asStateFlow()

    /**
     * IDs archived by this session but whose broker tmux may still linger
     * (#199). Suppressed in [refreshSessions] for [ARCHIVE_SUPPRESS_MS] to
     * prevent the row from flickering back immediately after archive.
     * Values are the System.currentTimeMillis() of the archive call.
     */
    private val _recentlyArchivedAt = mutableMapOf<String, Long>()
    private val ARCHIVE_SUPPRESS_MS = 5_000L

    private val _terminalBuffer = MutableStateFlow<Map<String, ByteArray>>(emptyMap())
    val terminalBuffer: StateFlow<Map<String, ByteArray>> = _terminalBuffer.asStateFlow()

    private val _chatLog = MutableStateFlow<Map<String, List<ChatEvent>>>(emptyMap())
    val chatLog: StateFlow<Map<String, List<ChatEvent>>> = _chatLog.asStateFlow()
    private val _conversationLog = MutableStateFlow<Map<String, List<ConversationItem>>>(emptyMap())
    val conversationLog: StateFlow<Map<String, List<ConversationItem>>> = _conversationLog.asStateFlow()

    /**
     * In-memory streaming overlay: partial assistant content streamed via
     * chat_streaming view_events, keyed by sessionId. Cleared when the final
     * onChatEvent arrives (the permanent message is then in the Rust store).
     * Old brokers never send chat_streaming so this stays empty.
     */
    private val _streamingMessage = MutableStateFlow<Map<String, String>>(emptyMap())
    val streamingMessage: StateFlow<Map<String, String>> = _streamingMessage.asStateFlow()

    /**
     * Current turn phase per session, sourced from the broker's turn_phase
     * view_event. Values: "writing" (streaming text), "working" (tool calls),
     * "" (thinking/waiting). Absent = no phase info from broker yet (old broker).
     */
    private val _turnPhaseBySession = MutableStateFlow<Map<String, String>>(emptyMap())
    val turnPhaseBySession: StateFlow<Map<String, String>> = _turnPhaseBySession.asStateFlow()

    /**
     * Accumulated thinking/reasoning text for the current turn per sessionId,
     * sourced from the broker's thinking_streaming view_event (Claude only).
     * Ephemeral: cleared alongside [_streamingMessage] when the turn ends.
     * Never persisted into the transcript or conversationLog.
     * Mirror of iOS [SessionStore.thinkingBySession].
     */
    private val _thinkingBySession = MutableStateFlow<Map<String, String>>(emptyMap())
    val thinkingBySession: StateFlow<Map<String, String>> = _thinkingBySession.asStateFlow()

    /**
     * The `turn_ts` of the actively-streaming turn per sessionId. Set by
     * [ingestChatStreaming] and used by [onChatEvent] to distinguish the
     * final current-turn message from broker-replayed older transcript entries.
     * On WS reconnect the broker replays the last 200 settled messages; each
     * replayed assistant event must NOT evict live streaming state. Cleared
     * alongside [_streamingMessage]. Mirror of iOS [SessionStore.streamingTurnTs].
     */
    private val _streamingTurnTs = MutableStateFlow<Map<String, String>>(emptyMap())

    /**
     * Sticky HTTP-fetched history base per session. Seeded once by
     * [hydrateChatConversation] (idempotent) and never overwritten by the
     * live [refreshConversation] path. On cold restart the Rust core's
     * [listConversationItems] returns empty until status frames arrive;
     * without this base [refreshConversation] would clobber the HTTP-fetched
     * history with an empty list. [refreshConversation] merges UNDER this
     * base so past items always survive. Mirror of iOS
     * [SessionStore.hydratedChat].
     */
    private val _hydratedChat = mutableMapOf<String, List<ConversationItem>>()

    /**
     * Backward-pagination state per session. Populated by [fetchConversation]
     * (initial tail=80 load) and updated by [fetchOlderConversation]. Only
     * present for sessions that have been opened as archived transcripts; live
     * sessions do not set this.
     */
    data class ConversationPaginationState(
        val hasMoreHistory: Boolean,
        val oldestLoadedTs: Long,
    )

    private val _paginationState = MutableStateFlow<Map<String, ConversationPaginationState>>(emptyMap())
    val paginationState: StateFlow<Map<String, ConversationPaginationState>> = _paginationState.asStateFlow()

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
     * Fix 9 — per-session "auto-approve in this session" toggle. Local +
     * session-scoped (in-memory only, intentionally NOT persisted: an
     * auto-approve grant should not silently survive a relaunch). While a
     * session id is in this set AND we are connected, an incoming approval is
     * auto-resolved with a quiet audited transcript line instead of prompting.
     */
    private val _autoApproveSessions = MutableStateFlow<Set<String>>(emptySet())
    val autoApproveSessions: StateFlow<Set<String>> = _autoApproveSessions.asStateFlow()

    /**
     * Fix 9 — transient in-app approval-resolve state per session, so the
     * Approvals surface can show resolving/approved/denied/failed without
     * fabricating an outcome. Cleared on session open / next pending item.
     */
    private val _approvalResolve = MutableStateFlow<Map<String, ApprovalResolvePhase>>(emptyMap())
    val approvalResolve: StateFlow<Map<String, ApprovalResolvePhase>> = _approvalResolve.asStateFlow()

    /** Flip the per-session auto-approve grant. */
    fun setAutoApprove(sessionId: String, enabled: Boolean) {
        _autoApproveSessions.value = if (enabled) {
            _autoApproveSessions.value + sessionId
        } else {
            _autoApproveSessions.value - sessionId
        }
        Telemetry.breadcrumb(
            "approval", "auto-approve toggled",
            mapOf("session" to sessionId, "enabled" to enabled.toString()),
        )
    }

    /**
     * Resolve an approval from the in-app surface (Fix 9). POSTs to the same
     * /api/session/approval endpoint the push action uses, authed off the
     * active endpoint. Drives [approvalResolve] so the row can show visible
     * state, and on success appends a quiet audited transcript line. A 404
     * (nothing pending) is surfaced as Stale, not a false success.
     */
    fun resolveApprovalInApp(sessionId: String, decision: String) {
        val endpoint = _endpoint.value
        if (!endpoint.isComplete) {
            _approvalResolve.value = _approvalResolve.value + (sessionId to ApprovalResolvePhase.Failed)
            return
        }
        Telemetry.breadcrumb(
            "approval", "resolve start (in-app)",
            mapOf("session" to sessionId, "decision" to decision),
        )
        _approvalResolve.value = _approvalResolve.value + (sessionId to ApprovalResolvePhase.Resolving)
        viewModelScope.launch {
            val phase = withContext(Dispatchers.IO) { postApprovalResolve(endpoint, sessionId, decision) }
            Telemetry.breadcrumb(
                "approval", "resolve result (in-app)",
                mapOf("session" to sessionId, "decision" to decision, "phase" to phase.name),
            )
            if (phase == ApprovalResolvePhase.Failed) {
                Telemetry.capture(
                    error = IllegalStateException("in-app approval resolve failed"),
                    message = "Android in-app approval resolve failed",
                    tags = mapOf("surface" to "android", "phase" to "approval_resolve_inapp"),
                    extras = mapOf("session" to sessionId, "decision" to decision),
                )
            }
            if (phase == ApprovalResolvePhase.Resolved) {
                appendAuditedApprovalLine(sessionId, decision, auto = false)
                resolvePendingInput(sessionId)
            }
            _approvalResolve.value = _approvalResolve.value + (sessionId to phase)
        }
    }

    /**
     * Compute an anchor timestamp string one ms past the newest known item
     * in the conversation/chat log for [sessionId]. Used by both
     * [resolvePendingInput] (to backfill the answered card's `ts`) and
     * [sendChat] (to stamp the optimistic user echo). Mirrors the iOS
     * helper `anchorEpoch(sessionID:)`.
     *
     * Resolution order:
     *   1. max parseable ms across conversationLog + chatLog + 1
     *   2. session startedAt ms + 1
     *   3. System.currentTimeMillis() (last resort)
     */
    private fun anchorEpochMillis(sessionId: String): Long {
        val lastKnownMs = (
            (_conversationLog.value[sessionId].orEmpty().map { it.ts }) +
                (_chatLog.value[sessionId].orEmpty().map { it.ts })
            ).map { tsEpochMillis(it) }.filter { it > 0L }.maxOrNull()
        val startedMs = _statusBySession.value[sessionId]?.startedAt
            ?.let { tsEpochMillis(it) }?.takeIf { it > 0L }
        return when {
            lastKnownMs != null -> lastKnownMs + 1
            startedMs != null -> startedMs + 1
            else -> System.currentTimeMillis()
        }
    }

    /** Format an epoch-millis value as an RFC3339 / ISO-8601 timestamp string. */
    private fun epochMillisToTs(ms: Long): String =
        java.time.Instant.ofEpochMilli(ms)
            .atOffset(java.time.ZoneOffset.UTC)
            .format(java.time.format.DateTimeFormatter.ISO_INSTANT)

    /**
     * Optimistically mark the last unanswered `pending_input` item for
     * [sessionId] as resolved so the inline chat card flips to answered
     * immediately on decision success — without waiting for the broker's
     * WS echo (which may arrive seconds later). Called from every
     * out-of-band decision path (ApprovalsScreen, notification action).
     * Idempotent; no-op when no unresolved pending item exists. Mirror of
     * iOS `SessionStore.resolvePendingInput(sessionID:)`.
     *
     * Also backfills the card's `ts` if it is currently empty or
     * unparseable (tsEpochMillis <= 0). Without the backfill the chip
     * stays pinned to the bottom of the transcript after later assistant
     * turns arrive — the sort treats an empty `ts` as Long.MAX_VALUE
     * (newest). Stamping it one ms past the max known epoch anchors it
     * in chronological order.
     */
    fun resolvePendingInput(sessionId: String) {
        val items = _conversationLog.value[sessionId] ?: return
        val resolved = _resolvedPendingInputIDs.value
        val item = items.lastOrNull {
            it.kind.lowercase() == "pending_input" && it.id !in resolved
        } ?: return
        _resolvedPendingInputIDs.value = resolved + item.id
        // Backfill ts if the card has no real broker timestamp so the chip
        // sorts into its chronological position rather than floating to the
        // bottom of the transcript.
        if (tsEpochMillis(item.ts) <= 0L) {
            val stampedTs = epochMillisToTs(anchorEpochMillis(sessionId))
            item.ts = stampedTs
            _conversationLog.value = _conversationLog.value.toMutableMap().also { m ->
                m[sessionId] = items
            }
            Telemetry.breadcrumb(
                "approvals", "pending_input ts backfilled on resolve",
                mapOf("session" to sessionId, "item_id" to item.id, "ts" to stampedTs),
            )
        }
        Telemetry.breadcrumb(
            "approvals", "pending_input optimistically resolved",
            mapOf("session" to sessionId, "item_id" to item.id),
        )
    }

    /**
     * Auto-resolve an incoming approval for a session that has the
     * "auto-approve in this session" grant active AND a live connection
     * (Fix 9). No-op when the grant is off or we are offline. Renders a quiet
     * audited transcript line so the auto-grant is never silent.
     */

    private val _autoApprovedItems = mutableSetOf<String>()

    fun maybeAutoApprove(sessionId: String) {
        if (sessionId !in _autoApproveSessions.value) return
        if (!hasPendingAsk(sessionId)) return
        if (!_harness.value.canIssueCommands) return
        val endpoint = _endpoint.value
        if (!endpoint.isComplete) return
        // Fire once per distinct pending item — refreshConversation runs on
        // every frame, so without this we would POST the same approval
        // repeatedly while it stays pending.
        val pendingId = _conversationLog.value[sessionId]?.lastOrNull()?.id ?: return
        if (!_autoApprovedItems.add("$sessionId|$pendingId")) return
        Telemetry.breadcrumb("approval", "auto-approve resolving", mapOf("session" to sessionId))
        viewModelScope.launch {
            val phase = withContext(Dispatchers.IO) { postApprovalResolve(endpoint, sessionId, "approve") }
            Telemetry.breadcrumb(
                "approval", "auto-approve result",
                mapOf("session" to sessionId, "phase" to phase.name),
            )
            if (phase == ApprovalResolvePhase.Resolved) {
                appendAuditedApprovalLine(sessionId, "approve", auto = true)
            }
        }
    }

    /**
     * The blocking POST shared by [resolveApprovalInApp] and [maybeAutoApprove].
     * Authed exactly like /api/push/register. Call on Dispatchers.IO.
     */
    private fun postApprovalResolve(endpoint: Endpoint, sessionId: String, decision: String): ApprovalResolvePhase {
        val base = endpoint.httpBaseUrl ?: return ApprovalResolvePhase.Failed
        val body = JSONObject().apply {
            put("session_id", sessionId)
            put("decision", decision)
        }.toString()
        return runCatching {
            val conn = (URL("$base/api/session/approval").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                doOutput = true
                setRequestProperty("Authorization", "Bearer ${endpoint.token}")
                setRequestProperty("Content-Type", "application/json")
                connectTimeout = 7_000
                readTimeout = 10_000
            }
            try {
                conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                val code = conn.responseCode
                when {
                    code == 404 -> ApprovalResolvePhase.Stale
                    code in 200..299 -> {
                        val resp = conn.inputStream.bufferedReader().use { it.readText() }
                        val ok = runCatching { JSONObject(resp).optBoolean("ok", false) }.getOrDefault(false)
                        if (ok) ApprovalResolvePhase.Resolved else ApprovalResolvePhase.Failed
                    }
                    else -> ApprovalResolvePhase.Failed
                }
            } finally {
                conn.disconnect()
            }
        }.getOrDefault(ApprovalResolvePhase.Failed)
    }

    /** Append a quiet, audited transcript line recording an approval decision. */
    private fun appendAuditedApprovalLine(sessionId: String, decision: String, auto: Boolean) {
        val verb = if (decision == "approve") "Approved" else "Denied"
        val suffix = if (auto) " (auto-approve in this session)" else ""
        val line = "$verb$suffix"
        val ts = java.time.OffsetDateTime.now(java.time.ZoneOffset.UTC)
            .format(java.time.format.DateTimeFormatter.ISO_INSTANT)
        val item = ConversationItem(
            id = "local-approval-${java.util.UUID.randomUUID()}",
            role = "system",
            kind = "message",
            status = "done",
            content = line,
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
    }

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

    /**
     * Per-session credential source. Populated when the broker emits a
     * `view:"credential_source"` view_event. Value is "box" (box-local
     * credential) or "app_forwarded" (the app credential is being forwarded
     * because the box is not logged in). The chat view shows a subtle inline
     * banner for "app_forwarded". Mirror of iOS `SessionStore.credentialSource`.
     */
    private val _credentialSource = MutableStateFlow<Map<String, String>>(emptyMap())
    val credentialSource: StateFlow<Map<String, String>> = _credentialSource.asStateFlow()

    /**
     * Per-session agent-auth failure flag. Set when a 401 / auth-failure
     * is detected in an assistant/result chat event (the "Sign in on this
     * box" banner). Value is the [OAuthProvider] to pre-select in the
     * AgentLoginSheet. Cleared bidirectionally: when the user sends a new
     * turn (sendChat) OR when an incoming assistant event is NOT a 401
     * (the agent recovered out-of-band). Mirror of iOS
     * `SessionStore.agentAuthFailure`.
     */
    private val _agentAuthFailure = MutableStateFlow<Map<String, OAuthProvider>>(emptyMap())
    val agentAuthFailure: StateFlow<Map<String, OAuthProvider>> = _agentAuthFailure.asStateFlow()

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

    /**
     * Consecutive reconcile-miss count per session. Incremented each time a
     * saved-live session is absent from both aliveIDs and recoverableIDs during
     * [reconcileLiveSessions]. Reset when the session IS confirmed alive.
     * A session is only demoted to History after 2 consecutive misses so that
     * a broker startup window (session not yet in RecoverableSessions) does NOT
     * prematurely move it out of the Active list on the first reconnect.
     * Mirror of iOS [SessionStore.reconcileMisses].
     */
    private val reconcileMisses = java.util.concurrent.ConcurrentHashMap<String, Int>()

    /**
     * FIX 2 (mirrors iOS App Hang 17-17.8s, v0.0.214): [refreshSessions]'s
     * fan-out used to re-pull EVERY session's conversation on EVERY status
     * delta once that session's log was merely non-null-but-empty (which
     * most sessions with no chat content stay forever). Now only the
     * selected (visible) session + genuinely-never-pulled sessions refresh
     * eagerly; everyone else is recorded here and refreshed lazily the
     * moment it's opened (see [setSelectedId]). ConcurrentHashMap key-set
     * because [onStatus] -> [refreshSessions] runs on UniFFI worker threads.
     */
    private val staleConversations: MutableSet<String> =
        java.util.Collections.newSetFromMap(java.util.concurrent.ConcurrentHashMap())

    /** At most one debounced eager refresh of the selected session in
     * flight (coalesces bursty status deltas to ~1 merge / 300ms). Same
     * idiom as [terminalPersistScheduled] above. */
    private val eagerSelectedRefreshScheduled =
        java.util.concurrent.atomic.AtomicBoolean(false)

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
     * At-most-once-per-launch guard for the post-connect broker auto-update
     * (Fix: broker stale on reconnect). Keyed by "boxId@brokerVersion" so a
     * single re-bootstrap is attempted per box per stale broker version, and we
     * stop nagging once the box reports the matching version. In-flight guard
     * prevents two connects from racing the same re-bootstrap.
     */
    private val attemptedBrokerUpdate: MutableSet<String> = java.util.Collections.synchronizedSet(mutableSetOf())
    @Volatile private var brokerUpdateInFlight: Boolean = false

    /**
     * Non-null when the silent auto-update was deferred because the box has
     * live sessions. The UI shows a warning banner; the user must confirm.
     * Mirror of iOS [SessionStore.pendingBrokerUpdate].
     */
    private val _pendingBrokerUpdate = MutableStateFlow<PendingBrokerUpdate?>(null)
    val pendingBrokerUpdate: StateFlow<PendingBrokerUpdate?> = _pendingBrokerUpdate.asStateFlow()

    /**
     * Session IDs to auto-resume after the broker restarts. Keyed by boxId.
     * Populated at confirm-time (before restart); consumed in
     * [reconcileLiveSessions] once the broker reconnects and reports
     * recoverable IDs. Mirror of iOS [SessionStore.pendingResume].
     */
    private val pendingResume: MutableMap<String, Set<String>> =
        java.util.Collections.synchronizedMap(mutableMapOf())

    /**
     * True once the held tunnel reported `isAlive() == false` (the SSH session
     * died: network flap, server reboot, idle kill, app suspend). Drives a
     * "connection lost — reconnect" affordance. Reset on a fresh tunnel.
     * Token-paired boxes never set this (no tunnel).
     */
    private val _sshTunnelLost = MutableStateFlow(false)
    val sshTunnelLost: StateFlow<Boolean> = _sshTunnelLost.asStateFlow()

    /** Debug: SSH-tunnel transport enabled (default ON). Exposed for the
     *  staff-only Debug menu; not shown in regular Settings. */
    private val _debugSshTunnelEnabled = MutableStateFlow(true)
    val debugSshTunnelEnabled: StateFlow<Boolean> = _debugSshTunnelEnabled.asStateFlow()

    /** Toggle SSH-tunnel transport from the staff Debug menu. Takes effect on
     *  the next connect/reconnect (does not interrupt a live connection). */
    fun setDebugSshTunnelEnabled(enabled: Boolean) {
        _debugSshTunnelEnabled.value = enabled
        prefs?.edit()?.putBoolean(KEY_SSH_TUNNEL, enabled)?.apply()
    }

    /** Outstanding TOFU prompt; MainActivity observes this and shows a dialog. */
    private val _pendingHostKey = MutableStateFlow<HostKeyPrompt?>(null)
    val pendingHostKey: StateFlow<HostKeyPrompt?> = _pendingHostKey.asStateFlow()

    /**
     * True while the SSH-login sheet (SSHLoginSheet) is composed on screen.
     * AppRoot uses this to suppress the root-level HostKeyPromptDialog during
     * an active add-via-SSH flow -- the sheet shows its own inline TOFU panel
     * instead.
     */
    private val _sshLoginSheetActive = MutableStateFlow(false)
    val sshLoginSheetActive: StateFlow<Boolean> = _sshLoginSheetActive.asStateFlow()

    fun setSshLoginSheetActive(active: Boolean) {
        _sshLoginSheetActive.value = active
    }

    /**
     * Non-null when Settings is requesting that the SSH login sheet reopen
     * prefilled with saved (non-secret) SSH coordinates for a failed box.
     * Cleared by the sheet after it reads and applies the prefill.
     */
    private val _pendingSshLoginPrefill = MutableStateFlow<SshLoginPrefill?>(null)
    val pendingSshLoginPrefill: StateFlow<SshLoginPrefill?> = _pendingSshLoginPrefill.asStateFlow()

    fun requestSshLoginPrefill(prefill: SshLoginPrefill) {
        _pendingSshLoginPrefill.value = prefill
    }

    fun consumeSshLoginPrefill(): SshLoginPrefill? {
        val v = _pendingSshLoginPrefill.value
        _pendingSshLoginPrefill.value = null
        return v
    }

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

    /**
     * Push every stored agent credential to a box over HTTP
     * (POST /api/agent/credentials), independent of any live session.
     *
     * This is the auto-propagate seam: a box connected AFTER sign-in
     * (classically an SSH box) never received the in-session push, so a
     * claude/codex session there 401s. We POST each device-stored
     * credential, keyed by the box bearer the same way the broker store
     * keys it. Best-effort: 503 (old broker, no store) and any non-2xx
     * are swallowed after a breadcrumb; never fails the connect.
     *
     * The `credential` field is a NESTED JSON OBJECT (the native blob),
     * not a stringified blob — a quoted string re-breaks auth.
     */
    suspend fun propagateStoredAgentCredentials(endpoint: Endpoint) = withContext(Dispatchers.IO) {
        val base = endpoint.httpBaseUrl ?: return@withContext
        val ctx = appContext ?: return@withContext
        for (provider in listOf(OAuthProvider.OPENAI, OAuthProvider.ANTHROPIC)) {
            val cred = runCatching { OAuthStore.load(ctx, provider) }.getOrNull() ?: continue

            // Refresh Anthropic tokens that are near or past expiry before
            // pushing — a stale access token silently breaks agent auth.
            var credToPush = cred
            if (cred is OAuthCredential.Anthropic) {
                val nowMs = System.currentTimeMillis()
                if (cred.blob.claudeAiOauth.expiresAt - nowMs < 5 * 60 * 1000L) {
                    Telemetry.breadcrumb(
                        "agent-credentials",
                        "anthropic token near expiry — refreshing",
                        mapOf("host" to endpoint.displayHost),
                    )
                    val refreshed = OAuthClient(OAuthProvider.ANTHROPIC)
                        .refreshAnthropicCredential(cred.blob.claudeAiOauth.refreshToken)
                    if (refreshed != null) {
                        runCatching { OAuthStore.save(ctx, refreshed) }
                        credToPush = refreshed
                        Telemetry.breadcrumb(
                            "agent-credentials",
                            "anthropic refresh ok before push",
                            mapOf("host" to endpoint.displayHost),
                        )
                    } else {
                        Telemetry.breadcrumb(
                            "agent-credentials",
                            "anthropic refresh failed — pushing stale",
                            mapOf("host" to endpoint.displayHost),
                        )
                    }
                }
            }

            Telemetry.breadcrumb(
                "agent-credentials",
                "propagate start",
                mapOf("provider" to provider.raw, "host" to endpoint.displayHost),
            )
            runCatching {
                val body = JSONObject().apply {
                    put("provider", provider.raw)
                    put("kind", "oauth")
                    // Nest the native blob as a JSON object, not a string.
                    put("credential", JSONObject(credToPush.toJson()))
                }.toString()
                val conn = (URL("$base/api/agent/credentials").openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"
                    doOutput = true
                    setRequestProperty("Authorization", "Bearer ${endpoint.token}")
                    setRequestProperty("Content-Type", "application/json")
                    connectTimeout = 7_000
                    readTimeout = 10_000
                }
                try {
                    conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                    val code = conn.responseCode
                    if (code in 200..299) {
                        Telemetry.breadcrumb(
                            "agent-credentials",
                            "propagate ok",
                            mapOf("provider" to provider.raw),
                        )
                    } else {
                        Telemetry.breadcrumb(
                            "agent-credentials",
                            "propagate non-2xx",
                            mapOf("provider" to provider.raw, "code" to code.toString()),
                        )
                    }
                } finally {
                    conn.disconnect()
                }
            }.onFailure { e ->
                Telemetry.breadcrumb(
                    "agent-credentials",
                    "propagate failed",
                    mapOf("provider" to provider.raw, "error" to (e.message ?: e.javaClass.simpleName)),
                )
            }
        }
    }

    /**
     * Per-box sign-out: POST `/api/agent/credentials/clear` to the given
     * endpoint with `{"provider": <anthropic|openai>}`. Removes the pushed
     * agent credential from THAT box only (idempotent, 200). Does NOT touch
     * the device-local [OAuthStore] and does NOT revoke the box owner's shell
     * login. Best-effort + breadcrumbs; never throws. Mirror of the Stage-1
     * [propagateStoredAgentCredentials] HTTP shape, sans `credential`.
     *
     * [provider] must be the wire provider value ("anthropic" / "openai").
     */
    suspend fun clearAgentCredential(provider: String, endpoint: Endpoint) = withContext(Dispatchers.IO) {
        val base = endpoint.httpBaseUrl ?: return@withContext
        Telemetry.breadcrumb(
            "agent-credentials",
            "clear start",
            mapOf("provider" to provider, "host" to endpoint.displayHost),
        )
        runCatching {
            val body = JSONObject().apply { put("provider", provider) }.toString()
            val conn = (URL("$base/api/agent/credentials/clear").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                doOutput = true
                setRequestProperty("Authorization", "Bearer ${endpoint.token}")
                setRequestProperty("Content-Type", "application/json")
                connectTimeout = 7_000
                readTimeout = 10_000
            }
            try {
                conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                val code = conn.responseCode
                if (code in 200..299) {
                    Telemetry.breadcrumb("agent-credentials", "clear ok", mapOf("provider" to provider))
                } else {
                    Telemetry.breadcrumb(
                        "agent-credentials",
                        "clear non-2xx",
                        mapOf("provider" to provider, "code" to code.toString()),
                    )
                }
            } finally {
                conn.disconnect()
            }
        }.onFailure { e ->
            Telemetry.breadcrumb(
                "agent-credentials",
                "clear failed",
                mapOf("provider" to provider, "error" to (e.message ?: e.javaClass.simpleName)),
            )
        }
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
                    val devId = appContext?.let { PushStore.getOrCreateDeviceId(it) }
                    c.createSession(original.assistant, original.branch, reasoningEffort, model, null, pickedMode, fastMode, devId)
                }
                val seed = "Forked from ${original.name} (id $sessionId). Pick up where the previous session left off."
                // Fire-and-forget seed: not outbox-tracked, but still carries a
                // stable client_msg_id so the broker dedups/acks it (task K).
                runCatching { withContext(Dispatchers.IO) { c.sendChat(newId, seed, "local-fork-seed-$newId") } }
                updateLifecycle { it + (newId to SessionLifecycle.Live) }
                refreshSessions()
                setSelectedId(newId)
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

    /**
     * Monotonic counter incremented each time [connect] creates a new
     * [ConduitClient]. Captured at connect time and handed to a per-connection
     * [GenerationGuardedDelegate]; once a newer [connect] bumps the counter the
     * old client's callbacks (notably a stale `onDisconnected` fired AFTER
     * [connect] already reached [HarnessState.Linked]) are dropped so they
     * cannot clobber the new connection's state with [HarnessState.Failed]
     * (box-switch flicker fix, mirrors iOS `StoreDelegate.clientGeneration`).
     */
    @Volatile private var clientGeneration: Long = 0

    /**
     * Per-connection [ConduitDelegate] that forwards to the live store only
     * while its [generation] is current. SessionStore implements
     * [ConduitDelegate] directly, so without this every superseded
     * [ConduitClient]'s teardown callbacks would reach the store and clobber
     * the freshly-connected box (box-switch flicker). Gating on the generation
     * — rather than on harness reachability — means a GENUINE disconnect of the
     * CURRENT client still matches and is handled normally.
     */
    private inner class GenerationGuardedDelegate(private val generation: Long) : ConduitDelegate {
        private fun ifCurrent(block: () -> Unit) {
            if (generation == clientGeneration) block()
        }

        override fun onPtyData(sessionId: String, data: ByteArray) =
            ifCurrent { this@SessionStore.onPtyData(sessionId, data) }

        override fun onChatEvent(sessionId: String, event: ChatEvent) =
            ifCurrent { this@SessionStore.onChatEvent(sessionId, event) }

        override fun onPreviewReady(sessionId: String, preview: PreviewInfo) =
            ifCurrent { this@SessionStore.onPreviewReady(sessionId, preview) }

        override fun onStatus(status: SessionStatus) =
            ifCurrent { this@SessionStore.onStatus(status) }

        override fun onSnapshot(sessionId: String, gunzipped: ByteArray) =
            ifCurrent { this@SessionStore.onSnapshot(sessionId, gunzipped) }

        override fun onExit(sessionId: String, code: Int) =
            ifCurrent { this@SessionStore.onExit(sessionId, code) }

        override fun onDisconnected(reason: String) =
            ifCurrent { this@SessionStore.onDisconnected(reason) }

        override fun onConnectionHealth(sessionId: String, health: ConnectionHealth) =
            ifCurrent { this@SessionStore.onConnectionHealth(sessionId, health) }

        override fun onChatDelivered(sessionId: String, clientMsgId: String) =
            ifCurrent { this@SessionStore.onChatDelivered(sessionId, clientMsgId) }

        override fun onViewEvent(sessionId: String, kind: String, payload: Map<String, String>) =
            ifCurrent { this@SessionStore.onViewEvent(sessionId, kind, payload) }
    }

    /**
     * IDs of `pending_input` conversation items resolved via an
     * out-of-band path (ApprovalsScreen, notification action) that should
     * render as ANSWERED in the inline chat card immediately — without
     * waiting for the broker's WS echo. Mirror of iOS
     * `SessionStore.resolvedPendingInputIDs`.
     */
    private val _resolvedPendingInputIDs = MutableStateFlow<Set<String>>(emptySet())
    val resolvedPendingInputIDs: StateFlow<Set<String>> = _resolvedPendingInputIDs.asStateFlow()

    /**
     * Fingerprints of pending-input cards the user has answered in this app launch,
     * keyed by sessionId -> set of fingerprints. Persists across chat view dismissals
     * (unlike the remember{} state in ChatPage). Reset on app restart — the HTTP
     * transcript covers the restart path via the persisted resolution marker.
     * Mirror of iOS SessionStore.answeredPendingBySession.
     */
    private val _answeredPendingBySession = MutableStateFlow<Map<String, Set<String>>>(emptyMap())
    val answeredPendingBySession: StateFlow<Map<String, Set<String>>> = _answeredPendingBySession.asStateFlow()

    /**
     * Answer text per pending-input fingerprint, keyed sessionId -> fingerprint -> answer.
     * Used to show "Sent . <answer>" on the chip after close+reopen.
     */
    private val _answeredPendingTextBySession = MutableStateFlow<Map<String, Map<String, String>>>(emptyMap())
    val answeredPendingTextBySession: StateFlow<Map<String, Map<String, String>>> = _answeredPendingTextBySession.asStateFlow()

    fun markPendingInputAnswered(sessionId: String, fingerprint: String, answer: String) {
        val currentSets = _answeredPendingBySession.value
        val set = (currentSets[sessionId] ?: emptySet()) + fingerprint
        _answeredPendingBySession.value = currentSets + (sessionId to set)
        if (answer.isNotEmpty()) {
            val currentTexts = _answeredPendingTextBySession.value
            val inner = (currentTexts[sessionId] ?: emptyMap()) + (fingerprint to answer)
            _answeredPendingTextBySession.value = currentTexts + (sessionId to inner)
        }
    }

    private var prefs: android.content.SharedPreferences? = null
    /** Application context cached at hydrate() for OAuthStore credential reads. */
    private var appContext: Context? = null
    /** Sessions we've already fired a 401 auto-recover propagate for, so a
     *  burst of auth-error assistant frames doesn't re-POST every frame. */
    private val agentAuthRecoveredSessions = java.util.Collections.synchronizedSet(mutableSetOf<String>())
    private var reachability: NetworkReachabilityObserver? = null

    /// Directory holding per-session terminal scrollback for cold-launch
    /// restore (set in [hydrate]). See the persistence section below.
    private var scrollbackDir: java.io.File? = null
    private val terminalPersistDirty =
        java.util.Collections.synchronizedSet(mutableSetOf<String>())
    private val terminalPersistScheduled =
        java.util.concurrent.atomic.AtomicBoolean(false)

    /** Park the WS worker for one session (it's left the foreground UI). */
    fun pauseSession(sessionId: String) {
        if (pausedSessionIds.contains(sessionId)) return
        val c = client ?: return
        pausedSessionIds.add(sessionId)
        runCatching { c.pauseSession(sessionId) }
        Telemetry.breadcrumb("ws", "session paused", mapOf("session" to sessionId))
    }

    /** Re-arm a paused session (it's returned to the foreground UI). */
    fun resumeSession(sessionId: String) {
        if (!pausedSessionIds.contains(sessionId)) return
        val c = client ?: return
        pausedSessionIds.remove(sessionId)
        runCatching { c.resumeSession(sessionId) }
        Telemetry.breadcrumb("ws", "session resumed", mapOf("session" to sessionId))
    }

    private fun pauseAllSessions() {
        _sessions.value.forEach { pauseSession(it.id) }
    }

    private fun clearPausedSessions() {
        pausedSessionIds.clear()
    }

    /**
     * POST /api/device/presence so the broker knows this device is online.
     * Fire-and-forget; never surfaces errors to the caller.
     */
    private suspend fun reportDevicePresence() {
        val ctx = appContext ?: return
        val devId = PushStore.getOrCreateDeviceId(ctx)
        val ep = _endpoint.value
        if (!ep.isComplete) return
        val base = ep.httpBaseUrl ?: return
        runCatching {
            withContext(Dispatchers.IO) {
                val body = JSONObject().apply { put("device_id", devId) }.toString()
                val conn = (URL("$base/api/device/presence").openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"
                    doOutput = true
                    setRequestProperty("Authorization", "Bearer ${ep.token}")
                    setRequestProperty("Content-Type", "application/json")
                    connectTimeout = 10_000
                    readTimeout = 10_000
                }
                try {
                    conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                    val code = conn.responseCode
                    Telemetry.breadcrumb(
                        "device_presence", "heartbeat",
                        mapOf("host" to ep.displayHost, "status" to code.toString())
                    )
                } finally {
                    conn.disconnect()
                }
            }
        }.getOrElse { e ->
            Telemetry.breadcrumb(
                "device_presence", "heartbeat error",
                mapOf("host" to ep.displayHost, "error" to (e.message ?: "unknown"))
            )
        }
    }

    private val lifecycleObserver = object : DefaultLifecycleObserver {
        override fun onResume(owner: LifecycleOwner) {
            // Record foreground timestamp for grace window (Change 4).
            foregroundedAt = System.currentTimeMillis()
            Telemetry.breadcrumb("session", "foreground_refresh_start")
            // App came back from background -- local sockets may be
            // silently dead. Nudge every worker into reconnect, and
            // re-pull every session's conversation: a reply that landed
            // while suspended only exists in the broker's
            // conversation.jsonl (live events aren't replayed on
            // re-attach), so without this the transcript stays stale and
            // the typing indicator spins forever. Mirror of iOS.
            // Clear paused set BEFORE nudge so all workers reconnect cleanly.
            clearPausedSessions()
            client?.notifyNetworkChange()
            refreshSessions()
            // Foregrounding may have re-armed a socket that died while
            // suspended -- flush any message the user sent right before they
            // backgrounded the app (the lost-send bug).
            flushPendingChats()
            // Report presence so the broker knows the device is online.
            viewModelScope.launch { reportDevicePresence() }
            // Change 1: proactive HTTP fetch for the currently-open session.
            // Runs in parallel with the WS redial so the transcript is fresh
            // before the replay lands. Mirrors iOS foregroundRefreshConversation.
            _selectedId.value?.let { sid ->
                viewModelScope.launch { foregroundRefreshConversation(sid) }
            }
            // Change 2: reconcile live sessions on foreground. Guard against
            // an in-flight reconcile (reconcileLiveSessions checks readiness).
            viewModelScope.launch { foregroundReconcileLiveSessions() }
            // Change 3: mark sessions with hydrated content for a forced
            // post-connect re-read once WS replay has settled.
            markSessionsForPostConnectRefresh()
        }

        override fun onStop(owner: LifecycleOwner) {
            // App is backgrounding — flush dirty terminal scrollback NOW so a
            // subsequent process death still leaves the last-known terminal on
            // disk for an instant cold-launch restore. Also pause all WS workers
            // so N idle heartbeat loops don't drain the battery.
            flushTerminalPersist()
            pauseAllSessions()
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
            _debugSshTunnelEnabled.value = p.getBoolean(KEY_SSH_TUNNEL, true)
            _isDemoMode.value = p.getBoolean("conduit.isDemoMode", false)
            refreshRecentDirectories()
            if (_endpoint.value.isComplete && _savedServers.value.none { it.endpoint == _endpoint.value }) {
                upsertSavedServer(_endpoint.value.displayHost, _endpoint.value, makeDefault = true)
            }
            appContext = ctx.applicationContext
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

    fun upsertSavedServer(
        name: String,
        endpoint: Endpoint,
        makeDefault: Boolean,
        sshRef: SshEndpointRef? = null,
        status: SavedServerStatus? = null,
    ) {
        val current = _savedServers.value.toMutableList()
        val existing = current.indexOfFirst { it.endpoint == endpoint }
        if (existing >= 0) {
            val defaultFlag = if (makeDefault) true else current[existing].isDefault
            val updatedSsh = sshRef ?: current[existing].ssh
            val updatedStatus = status ?: current[existing].status
            current[existing] = current[existing].copy(name = name, isDefault = defaultFlag, ssh = updatedSsh, status = updatedStatus)
        } else {
            current += SavedServer(
                id = UUID.randomUUID().toString(),
                name = if (name.isBlank()) endpoint.displayHost else name,
                endpoint = endpoint,
                isDefault = makeDefault || current.isEmpty(),
                ssh = sshRef,
                status = status,
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
                updateVisibleHarness()
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
            updateVisibleHarness()
            return
        }
        _harness.value = HarnessState.Connecting
        updateVisibleHarness()
        clientGeneration++
        val myGeneration = clientGeneration
        val c = ConduitClient(e.url, e.token)
        client = c
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { c.connect(GenerationGuardedDelegate(myGeneration)) }
                _harness.value = HarnessState.Linked
                updateVisibleHarness()
                Telemetry.breadcrumb("onboarding", "endpoint_connected",
                    mapOf("host" to _endpoint.value.displayHost,
                          "first_server" to (_savedServers.value.size == 1).toString()))
                // Auto-propagate stored agent credentials to this box. Boxes
                // connected after sign-in (esp. SSH boxes) never received the
                // in-session push, so a claude/codex session there 401s. This
                // is the single chokepoint: connect()/reconnect()/
                // selectSavedServer()/connectViaSSH()/attemptSshSelfHeal() all
                // land here. Fire-and-forget; never fails the connect.
                viewModelScope.launch { propagateStoredAgentCredentials(e) }
                refreshSessions()
                // Connection is live again — re-deliver any messages queued
                // while disconnected (reconnect window / backgrounded
                // mid-send / killed before the WS flushed).
                flushPendingChats()
                // Re-discover sessions that were running on the broker before
                // this app process launched (app update / cold restart). The
                // Rust core's in-memory session map is empty on a fresh
                // ConduitClient, so refreshSessions() returns nothing even
                // though the broker still owns live sessions. Mirror of iOS
                // reconcileLiveSessions(). Fire-and-forget; never fails connect.
                viewModelScope.launch { reconcileLiveSessions() }
                // Fix: the tunnelAlive fast path in reconnect()/selectSavedServer()
                // bounces only the WS, so the bootstrap script's broker
                // version-update (reuse path) never runs on a reconnect. Probe the
                // broker's reported version here and trigger a one-shot re-bootstrap
                // when stale. Fire-and-forget; never fails the connect.
                viewModelScope.launch { updateBrokerIfStale() }
            } catch (t: Throwable) {
                // Drop failures that belong to a superseded connect attempt.
                if (myGeneration != clientGeneration) return@launch
                val detail = describe(t)
                _harness.value = HarnessState.Failed(detail)
                updateVisibleHarness()
                Telemetry.capture(
                    error = t,
                    message = "Android harness connect failed",
                    tags = mapOf("surface" to "android", "phase" to "connect"),
                    extras = mapOf("endpoint" to _endpoint.value.displayHost, "detail" to detail),
                )
            }
        }
    }

    /**
     * Re-discover sessions that are still running on the broker after a cold
     * app launch (update / process restart). The Rust core's in-memory session
     * map is empty on a freshly-constructed ConduitClient, so [refreshSessions]
     * returns nothing even though the broker still owns live sessions. This
     * mirrors iOS [reconcileLiveSessions]:
     *
     * 1. HTTP GET /api/sessions to learn what the broker is actually running.
     * 2. For each running session not already in our local set, stamp its box,
     *    seed [SessionLifecycle.Creating] so the home row appears immediately,
     *    hydrate the terminal buffer from scrollback, call [joinSession] to
     *    open the live WS, then seed chat via [fetchConversation].
     * 3. Demote saved-LIVE rows for THIS box that the broker no longer lists.
     * 4. [refreshSessions] to reflect the joined rows.
     *
     * Best-effort: any exception breadcrumbs and returns — never blocks connect.
     * Called once per connect (the single chokepoint covering reconnect /
     * selectSavedServer / SSH paths).
     */
    suspend fun refreshLiveSessions() { reconcileLiveSessions() }

    private suspend fun reconcileLiveSessions() {
        val base = _endpoint.value.httpBaseUrl ?: return
        val token = _endpoint.value.token
        val serverID = savedHistoryServerId()
        Telemetry.breadcrumb("session", "reconcile_live_begin", mapOf("server" to serverID))
        try {
            if (!waitUntilCommandReady()) {
                Telemetry.breadcrumb("session", "reconcile_live_not_ready", mapOf("server" to serverID))
                return
            }
            val c = client ?: return

            // -- 1. Fetch the broker's live session list --
            val raw = withContext(Dispatchers.IO) {
                val url = URL("$base/api/sessions")
                val conn = (url.openConnection() as HttpURLConnection).apply {
                    requestMethod = "GET"
                    setRequestProperty("Authorization", "Bearer $token")
                    connectTimeout = 7_000
                    readTimeout = 7_000
                }
                val code = conn.responseCode
                if (code !in 200..299) {
                    val body = conn.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
                    conn.disconnect()
                    error("GET /api/sessions replied $code: ${body.take(200)}")
                }
                conn.inputStream.bufferedReader().use { it.readText() }
            }
            val obj = JSONObject(raw)
            val sessions = obj.optJSONArray("sessions") ?: JSONArray()
            // Cold sessions the broker can respawn on /ws open (not currently
            // running but recoverable on attach). Present on broker >= #700;
            // absent on older brokers (null treated as empty).
            val recoverableArr = obj.optJSONArray("recoverable") ?: JSONArray()
            val recoverableIDs = mutableSetOf<String>()
            for (ri in 0 until recoverableArr.length()) {
                val rid = recoverableArr.getJSONObject(ri).optString("id", "")
                if (rid.isNotEmpty()) recoverableIDs += rid
            }

            val aliveIDs = mutableSetOf<String>()
            val deleted = _deletedIds.value

            // -- 2. Join each running session not already live locally --
            var joined = 0
            for (i in 0 until sessions.length()) {
                val item = sessions.getJSONObject(i)
                val running = item.optBoolean("running", false)
                if (!running) continue
                val id = item.optString("id", "") .takeIf { it.isNotEmpty() } ?: continue
                val assistant = item.optString("assistant", "claude")
                aliveIDs += id
                reconcileMisses.remove(id)  // seen alive; reset demotion-grace counter
                if (id in deleted) continue
                if (_sessions.value.any { it.id == id }) continue
                // Stamp box before joining so home-list grouping is correct.
                _sessionBox.value = _sessionBox.value + (id to serverID)
                if (_sessionLifecycle.value[id] == null) {
                    updateLifecycle { it + (id to SessionLifecycle.Creating) }
                }
                // Seed terminal scrollback so the row paints before the WS
                // broker snapshot arrives (same as attachLiveSession).
                hydrateTerminalBuffer(id)
                try {
                    withContext(Dispatchers.IO) { c.joinSession(id, assistant) }
                    joined++
                    // Seed chat via the sticky hydration path so a fresh Rust
                    // core (empty listConversationItems) can never overwrite
                    // the HTTP-fetched history on first refresh. Uses
                    // hydrateChatConversation instead of bare fetchConversation
                    // so the _hydratedChat base is set before the live
                    // refreshConversation loop runs.
                    viewModelScope.launch {
                        try {
                            hydrateChatConversation(id)
                        } catch (t: Throwable) {
                            Telemetry.breadcrumb("session", "reconcile_chat_seed_failed",
                                mapOf("session" to id, "err" to (t.message ?: "unknown")))
                        }
                    }
                } catch (t: Throwable) {
                    // A rotated token / UnknownSession on one entry must not
                    // abort the rest of the loop.
                    if (_sessionLifecycle.value[id] is SessionLifecycle.Creating) {
                        updateLifecycle { it - id }
                    }
                    Telemetry.breadcrumb("session", "reconcile_join_failed",
                        mapOf("session" to id, "err" to (t.message ?: "unknown")))
                }
            }
            Telemetry.breadcrumb("session", "reconcile_live_joined",
                mapOf("server" to serverID, "joined" to joined.toString()))

            // -- 3. Decide fate of saved-LIVE rows the broker is NOT running --
            //
            // Three-way decision (mirrors the iOS parity contract):
            //   a. In aliveIDs             -> already handled above; skip.
            //   b. In recoverableIDs       -> broker can respawn on /ws open
            //      (e.g. a broker restart that killed the process but kept
            //      the session on-disk, per PR #700). Auto-rejoin: set
            //      Creating (transient, not Exited), join + hydrate chat.
            //      On success the session stays Active. On failure -> demote.
            //   c. In neither set          -> genuinely gone; demote to History.
            //
            // SCOPE GUARD: only auto-rejoin sessions already in the app's
            // LOCAL active (LIVE) store. Never mass-join every recoverable
            // session the broker returns (the box can have dozens).
            //
            // ANTI-THRASH: autoRejoinedIDs prevents a second rejoin attempt
            // for the same session inside this reconcile cycle.
            val savedLive = _savedSessions.value.filter {
                it.serverId == serverID && it.status == SavedSessionStatus.LIVE
            }
            var demoted = 0
            var autoRejoined = 0
            val autoRejoinedIDs = mutableSetOf<String>()
            for (saved in savedLive) {
                if (saved.id in aliveIDs) continue // already running; skip

                if (saved.id in recoverableIDs && saved.id !in autoRejoinedIDs
                        && saved.id !in deleted) {
                    // -- (b) Recoverable: auto-rejoin so session stays Active --
                    autoRejoinedIDs += saved.id
                    val assistant = run {
                        // Prefer the assistant from the recoverable array; fall
                        // back to what the saved session recorded.
                        var found = "claude"
                        for (ri in 0 until recoverableArr.length()) {
                            val robj = recoverableArr.getJSONObject(ri)
                            if (robj.optString("id", "") == saved.id) {
                                found = robj.optString("assistant", "claude")
                                break
                            }
                        }
                        found
                    }
                    Telemetry.breadcrumb("session", "reconcile_auto_rejoin_start",
                        mapOf("session" to saved.id, "server" to serverID))
                    // Stamp box and set transient Creating state so the home
                    // row stays visible (not demoted) during the rejoin.
                    _sessionBox.value = _sessionBox.value + (saved.id to serverID)
                    updateLifecycle { it + (saved.id to SessionLifecycle.Creating) }
                    hydrateTerminalBuffer(saved.id)
                    try {
                        withContext(Dispatchers.IO) { c.joinSession(saved.id, assistant) }
                        autoRejoined++
                        Telemetry.breadcrumb("session", "reconcile_auto_rejoin_success",
                            mapOf("session" to saved.id))
                        viewModelScope.launch {
                            try {
                                hydrateChatConversation(saved.id)
                            } catch (t: Throwable) {
                                Telemetry.breadcrumb("session", "reconcile_auto_rejoin_chat_failed",
                                    mapOf("session" to saved.id, "err" to (t.message ?: "unknown")))
                            }
                        }
                    } catch (t: Throwable) {
                        // Rejoin failed (rotated token, broker race, etc.) ->
                        // fall through to demote so the session lands in History
                        // rather than being stuck in a phantom Creating state.
                        Telemetry.capture(
                            error = t,
                            message = "reconcile_auto_rejoin_failed",
                            extras = mapOf("session" to saved.id))
                        if (_sessionLifecycle.value[saved.id] is SessionLifecycle.Creating) {
                            updateLifecycle { it - saved.id }
                        }
                        markExited(saved.id)
                        if (_sessionLifecycle.value[saved.id] == null) {
                            updateLifecycle { it + (saved.id to SessionLifecycle.Exited(0)) }
                        }
                        demoted++
                    }
                } else {
                    // -- (c) Genuinely gone -- but require 2 consecutive misses before
                    // demoting. A broker startup window can leave a session briefly
                    // absent from both sets; the second miss confirms it is truly gone
                    // and not just not yet in RecoverableSessions. Mirror of iOS.
                    val misses = (reconcileMisses[saved.id] ?: 0) + 1
                    if (misses < 2) {
                        reconcileMisses[saved.id] = misses
                        Telemetry.breadcrumb("session", "reconcile_demotion_deferred",
                            mapOf("session" to saved.id, "miss" to misses.toString()))
                    } else {
                        reconcileMisses.remove(saved.id)
                        // Confirmed gone on second consecutive miss: demote to History.
                        markExited(saved.id)
                        if (_sessionLifecycle.value[saved.id] == null) {
                            updateLifecycle { it + (saved.id to SessionLifecycle.Exited(0)) }
                        }
                        demoted++
                    }
                }
            }
            if (autoRejoined > 0) {
                Telemetry.breadcrumb("session", "reconcile_auto_rejoined",
                    mapOf("server" to serverID, "count" to autoRejoined.toString()))
            }
            if (demoted > 0) {
                Telemetry.breadcrumb("session", "reconcile_live_demoted",
                    mapOf("server" to serverID, "count" to demoted.toString()))
            }

            // Evict EXITED sessions the broker has GC'd (no longer on disk).
            // Only runs when fetchLiveSessions() succeeded, so the broker's view
            // is current. Safe to remove: the server-side file is gone.
            val brokerKnownIDs = aliveIDs + recoverableIDs
            val gcEvicted = _savedSessions.value.filter {
                it.serverId == serverID &&
                it.status == SavedSessionStatus.EXITED &&
                it.id !in brokerKnownIDs
            }
            if (gcEvicted.isNotEmpty()) {
                for (s in gcEvicted) removeSavedSession(s.id)
                Telemetry.breadcrumb("session", "reconcile_gc_evicted",
                    mapOf("server" to serverID, "count" to gcEvicted.size.toString()))
            }

            // -- 4. CHANGE 4: Auto-resume sessions snapshotted at broker-update
            //    confirm time. Only resume the ids we snapshotted — never
            //    mass-resume arbitrary old recoverable sessions.
            val resumeSet = pendingResume.remove(serverID)
            if (!resumeSet.isNullOrEmpty()) {
                Telemetry.breadcrumb("broker_update", "auto_resume fired",
                    mapOf("box" to serverID, "count" to resumeSet.size.toString()))
                for (sessionID in resumeSet) {
                    if (sessionID in recoverableIDs) {
                        // Look up the assistant from the saved sessions list.
                        val assistant = _savedSessions.value
                            .firstOrNull { it.id == sessionID }?.agent ?: "claude"
                        Telemetry.breadcrumb("broker_update", "auto_resume fire",
                            mapOf("session" to sessionID, "assistant" to assistant))
                        resumeRecoverableSession(sessionID, assistant)
                    }
                }
            }

            // -- 5. Sync the live-session list --
            refreshSessions()
        } catch (t: Throwable) {
            // Older broker without /api/sessions, transient network failure,
            // or auth error. Leave saved LIVE rows untouched — user can resume
            // them on tap. Never propagates to connect().
            Telemetry.breadcrumb("session", "reconcile_live_unavailable",
                mapOf("server" to serverID, "err" to (t.message ?: "unknown")))
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
        updateVisibleHarness()
    }

    // -------------------------------------------------------------------------
    // Foreground refresh helpers (Changes 1-3)
    // -------------------------------------------------------------------------

    /**
     * Proactive HTTP re-fetch for [sessionID]'s conversation on foreground.
     * Non-idempotent: always refreshes the sticky [_hydratedChat] base so a
     * suspended-then-resumed app sees fresh transcript before the WS replay
     * lands. Merges against live FFI state via [refreshConversation] (same
     * rules as [hydrateChatConversation]). Safe to call in parallel with the
     * WS redial -- the broker reads conversation.jsonl from disk.
     * Mirror of iOS [foregroundRefreshConversation].
     */
    private suspend fun foregroundRefreshConversation(sessionID: String) {
        Telemetry.breadcrumb("session", "fg_refresh_conversation_start",
            mapOf("session" to sessionID))
        val items = try {
            fetchConversation(sessionID)
        } catch (t: Throwable) {
            Telemetry.breadcrumb("session", "fg_refresh_conversation_failed",
                mapOf("session" to sessionID, "err" to (t.message ?: t.javaClass.simpleName)))
            return
        }
        if (items.isEmpty()) {
            Telemetry.breadcrumb("session", "fg_refresh_conversation_empty",
                mapOf("session" to sessionID))
            return
        }
        // Refresh the sticky base (non-idempotent -- overwrites with fresh HTTP content).
        _hydratedChat[sessionID] = items
        refreshConversation(sessionID)
        Telemetry.breadcrumb("session", "fg_refresh_conversation_merged",
            mapOf("session" to sessionID, "count" to items.size.toString()))
    }

    /**
     * Reconcile live sessions from the foreground path, guarded against overlap
     * with an in-flight reconcile from [connect]. [reconcileLiveSessions] checks
     * [waitUntilCommandReady] internally which returns false when not ready,
     * so calling it again while in-flight is safe (it returns early).
     * Mirror of iOS reconcile-on-foreground guard (Change 2).
     */
    private suspend fun foregroundReconcileLiveSessions() {
        Telemetry.breadcrumb("session", "fg_reconcile_start")
        reconcileLiveSessions()
    }

    /**
     * Mark sessions that have hydrated content at foreground time.
     * [onConnectionHealth] Connected drains the set and fires a forced post-replay
     * re-read (explicit bypass of PR #871 empty-log gate -- calls
     * [refreshConversation] directly, not through [refreshSessions]).
     * Mirror of iOS [markSessionsForPostConnectRefresh] (Change 3).
     */
    private fun markSessionsForPostConnectRefresh() {
        val hydrated = _sessions.value.filter { _hydratedChat[it.id] != null }.map { it.id }
        synchronized(sessionsNeedingPostConnectRefresh) {
            sessionsNeedingPostConnectRefresh.clear()
            sessionsNeedingPostConnectRefresh.addAll(hydrated)
        }
        Telemetry.breadcrumb("session", "fg_marked_post_connect_refresh",
            mapOf("count" to hydrated.size.toString()))
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

    /**
     * Session-safe broker auto-update gate.
     *
     * Compares the broker's reported version (from `/api/capabilities`) against
     * the app's own release tag. When stale:
     *   - Zero live sessions on the box: silent update (safe; nothing to lose).
     *   - Live sessions present: defer — set [_pendingBrokerUpdate] so the UI
     *     shows a warning banner and the user can confirm.
     *
     * Gated: single-flight ([brokerUpdateInFlight]) + at-most-once per
     * (boxId, broker_version) per launch ([attemptedBrokerUpdate]). Token-paired
     * boxes are skipped (no SSH ref => nothing to re-bootstrap).
     */
    private suspend fun updateBrokerIfStale() {
        val ep = _endpoint.value
        val server = _savedServers.value.firstOrNull { it.endpoint == ep }
        // SSH boxes only — token-paired boxes have no bootstrap to re-run.
        if (server?.ssh == null) return
        val boxId = server.id

        val raw = getJsonOrNull(ep, "/api/capabilities")
        if (raw == null) {
            Telemetry.breadcrumb("broker_update", "capabilities fetch failed (stale check)",
                mapOf("box" to boxId, "host" to ep.displayHost))
            return
        }
        val readiness = runCatching { parseReadiness(raw) }.getOrNull()
        val brokerVersion = readiness?.brokerVersion.orEmpty()
        // Use RELEASE_TAG (the actual release version) as the threshold.
        // VERSION_NAME is pinned to "0.0.1" and cannot be used for comparisons.
        val appVersion = BuildConfig.RELEASE_TAG

        // Unknown / dev brokers report "dev" or empty — never re-bootstrap those.
        // Also skip if the app itself is a dev build.
        if (brokerVersion.isEmpty() || brokerVersion == "dev"
            || appVersion.isEmpty() || appVersion == "dev") {
            Telemetry.breadcrumb("broker_update", "skip — unknown broker or app version",
                mapOf("box" to boxId, "broker_version" to brokerVersion, "app_version" to appVersion))
            return
        }

        val isStale = brokerVersionStatus(brokerVersion, appVersion) is BrokerVersionStatus.UpdateAvailable

        if (!isStale) {
            Telemetry.breadcrumb("broker_update", "broker current",
                mapOf("box" to boxId, "version" to brokerVersion))
            return
        }

        val key = "$boxId@$brokerVersion"
        synchronized(attemptedBrokerUpdate) {
            if (!attemptedBrokerUpdate.add(key)) {
                Telemetry.breadcrumb("broker_update", "skip — already attempted this launch",
                    mapOf("key" to key))
                return
            }
        }
        if (brokerUpdateInFlight || isReconnecting) {
            Telemetry.breadcrumb("broker_update", "skip — update/reconnect in flight",
                mapOf("key" to key))
            return
        }

        val liveCount = liveSessionCount(boxId)
        val decision = brokerUpdateDecision(isStale = true, liveCount = liveCount, isSshPaired = true)

        when (decision) {
            is BrokerUpdateDecision.SilentUpdate -> {
                Telemetry.breadcrumb("broker_update", "stale broker — silent update (no live sessions)",
                    mapOf("box" to boxId, "broker_version" to brokerVersion, "app_version" to appVersion))
                brokerUpdateInFlight = true
                try {
                    attemptSshSelfHeal()
                } finally {
                    brokerUpdateInFlight = false
                }
            }
            is BrokerUpdateDecision.DeferAndWarn -> {
                Telemetry.breadcrumb("broker_update", "deferred (live sessions)",
                    mapOf("box" to boxId, "broker_version" to brokerVersion,
                          "app_version" to appVersion, "live_count" to liveCount.toString()))
                _pendingBrokerUpdate.value = PendingBrokerUpdate(
                    boxId = boxId,
                    brokerVersion = brokerVersion,
                    liveCount = liveCount,
                )
            }
            else -> { /* None / ShowCopyBanner: SSH guard above ensures we never reach these */ }
        }
    }

    /**
     * Called by the UI after the user confirms the "end N sessions to update"
     * dialog. Snapshots live session IDs for auto-resume, then triggers the
     * SSH self-heal that restarts the broker. Mirror of iOS
     * `SessionStore.confirmAndUpdateBroker()`.
     */
    fun confirmAndUpdateBroker() {
        val pending = _pendingBrokerUpdate.value ?: return
        val boxId = pending.boxId

        // Snapshot live session IDs for this box so we can auto-resume them
        // after the broker restarts and the app reconnects.
        val liveIDs = _sessions.value
            .filter { s ->
                _sessionBox.value[s.id] == boxId && isConfirmedLive(s.id)
            }
            .map { it.id }
            .toSet()

        if (liveIDs.isNotEmpty()) {
            pendingResume[boxId] = liveIDs
            Telemetry.breadcrumb("broker_update", "auto_resume scheduled",
                mapOf("box" to boxId, "count" to liveIDs.size.toString()))
        }

        Telemetry.breadcrumb("broker_update", "update confirmed by user",
            mapOf("box" to boxId, "installed" to pending.brokerVersion))
        _pendingBrokerUpdate.value = null
        brokerUpdateInFlight = true
        try {
            attemptSshSelfHeal()
        } finally {
            brokerUpdateInFlight = false
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
            updateVisibleHarness()
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
                updateVisibleHarness()
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
                upsertSavedServer(name = name, endpoint = endpoint, makeDefault = true, sshRef = sshRef, status = SavedServerStatus.Ready)
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
                // Part B: persist a failed SavedServer so Settings shows a Retry row.
                val failedName = serverName?.takeIf { it.isNotBlank() } ?: "$user@$host"
                val failedSshRef = SshEndpointRef(host = host, port = port, username = user)
                persistFailedSshBox(failedName, failedSshRef, detail)
                Telemetry.breadcrumb(
                    "ssh_addbox",
                    "failed box persisted",
                    mapOf("host" to host, "user" to user),
                )
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
                // Part B: persist a failed SavedServer so Settings shows a Retry row.
                val failedName = serverName?.takeIf { it.isNotBlank() } ?: "$user@$host"
                val failedSshRef = SshEndpointRef(host = host, port = port, username = user)
                persistFailedSshBox(failedName, failedSshRef, detail)
                Telemetry.breadcrumb(
                    "ssh_addbox",
                    "failed box persisted",
                    mapOf("host" to host, "user" to user),
                )
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

    /**
     * Upsert a [SavedServer] with [SavedServerStatus.Failed] so it appears in
     * Settings as a retryable entry. Keyed by SSH host+port to avoid duplicates
     * on repeated retries. Uses a synthetic placeholder endpoint so it doesn't
     * clash with any live pairing (no valid broker URL/token yet).
     */
    private fun persistFailedSshBox(name: String, sshRef: SshEndpointRef, reason: String) {
        val placeholderEndpoint = Endpoint(
            url = "ssh-pending://" + sshRef.host + ":" + sshRef.port.toInt().toString(),
            token = "",
        )
        val current = _savedServers.value.toMutableList()
        // De-dup by SSH host+port: if we already have an entry for this host, update it.
        val existingIdx = current.indexOfFirst { it.ssh?.host == sshRef.host && it.ssh?.port == sshRef.port }
        if (existingIdx >= 0) {
            current[existingIdx] = current[existingIdx].copy(
                name = name,
                status = SavedServerStatus.Failed(reason),
            )
        } else {
            current += SavedServer(
                id = UUID.randomUUID().toString(),
                name = name,
                endpoint = placeholderEndpoint,
                isDefault = false,
                ssh = sshRef,
                status = SavedServerStatus.Failed(reason),
            )
        }
        _savedServers.value = current
        persistSavedServers(current)
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
                updateVisibleHarness()
                return@launch
            }
            createSession(assistant = assistant, startupCwd = cwd)
        }
    }

    fun clearSessionCreationError() {
        _sessionCreationError.value = null
    }

    /** Clears the one-shot archive error after the UI has displayed it. */
    fun clearArchiveError() {
        _archiveError.value = null
    }

    fun select(sessionId: String?) { setSelectedId(sessionId) }

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
        setSelectedId(sessionID)
    }

    /**
     * Central setter for [_selectedId] -- mirrors iOS `selectedSessionID`'s
     * `didSet`. Every select/switch/clear path funnels through here so the
     * lazy half of the stale-conversation gate (see [refreshSessions]) has
     * one choke point: opening a session the fan-out skipped as invisible
     * fires exactly the refresh it deferred.
     */
    private fun setSelectedId(sessionId: String?) {
        val previous = _selectedId.value
        _selectedId.value = sessionId
        if (sessionId != null && sessionId != previous && staleConversations.remove(sessionId)) {
            Telemetry.breadcrumb("perf", "refresh_stale_on_open", mapOf("session" to sessionId))
            refreshConversation(sessionId)
        }
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
    /**
     * Count of live sessions attributed to [boxId] (a SavedServer.id).
     *
     * Fix: the Home BOXES row count previously used the whole mixed session
     * list ([sessions].size) for EVERY box, so a non-active box showed the
     * active box's count. This restricts to sessions whose stable per-session
     * box stamp ([sessionBox]) equals [boxId] AND that are confirmed-live, so
     * each row shows its own real count (including non-active boxes).
     */
    fun liveSessionCount(boxId: String): Int =
        _sessions.value.count { s ->
            _sessionBox.value[s.id] == boxId && isConfirmedLive(s.id)
        }

    /**
     * Stamp [sessionId] as belonging to [serverId] in the per-session box
     * routing map. Must be called before [attachLiveSession] for sessions
     * that are not yet in [sessions] (e.g. freshly adopted found-sessions)
     * so liveSessionCount and per-box filtering attribute them correctly.
     */
    fun stampSessionBox(sessionId: String, serverId: String) {
        _sessionBox.value = _sessionBox.value + (sessionId to serverId)
    }

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
                if (!waitUntilCommandReady()) {
                    Telemetry.capture(
                        error = IllegalStateException("harness never ready"),
                        message = "attach live session: harness never ready",
                        tags = mapOf("surface" to "android", "phase" to "attach_session"),
                        extras = mapOf("endpoint" to _endpoint.value.displayHost, "session_id" to sessionID),
                    )
                    return@launch
                }
                val c = client ?: return@launch
                // Mark creating so the home list shows the row attaching
                // rather than vanishing during the round-trip.
                if (_sessionLifecycle.value[sessionID] == null) {
                    updateLifecycle { it + (sessionID to SessionLifecycle.Creating) }
                }
                withContext(Dispatchers.IO) { c.joinSession(sessionID, assistant) }
                // Hydrate chat from HTTP transcript so the Rust core's
                // empty listConversationItems on cold restart can never
                // wipe history. Fire-and-forget; idempotent if reconcile
                // already seeded this session.
                viewModelScope.launch {
                    try {
                        hydrateChatConversation(sessionID)
                    } catch (t: Throwable) {
                        Telemetry.breadcrumb(
                            "chat_hydration", "attach_hydrate_failed",
                            mapOf("session" to sessionID, "err" to (t.message ?: "unknown")),
                        )
                    }
                }
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
                    setSelectedId(sessionID)
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
                val id = withContext(Dispatchers.IO) {
                    val devId = appContext?.let { PushStore.getOrCreateDeviceId(it) }
                    c.createSession(assistant, branch, pickedEffort, pickedModel, startup, pickedMode, fastMode, devId)
                }
                Telemetry.breadcrumb("session", "created", mapOf("assistant" to assistant, "id" to id))
                // Belt-and-suspenders parity with iOS: also propagate stored
                // agent credentials to this box on session create, so a box
                // that became ready without flowing through connect()'s push
                // still gets them. Fire-and-forget; never fails session create.
                viewModelScope.launch { propagateStoredAgentCredentials(_endpoint.value) }
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
                updateVisibleHarness()
                refreshSessions()
                setSelectedId(id)
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
                        updateVisibleHarness()
                        attemptSshSelfHeal()
                    } else {
                        _harness.value = HarnessState.Failed("Pairing expired. Scan a new QR code from the server.")
                        updateVisibleHarness()
                    }
                } else if (isConnectionRefused(t) &&
                           _savedServers.value.firstOrNull { it.endpoint == _endpoint.value }?.ssh != null) {
                    // Dead SSH tunnel: box shows connected but broker is unreachable.
                    // Drive the same SSH self-heal path so harness ends up Reconnecting.
                    Telemetry.breadcrumb("session", "connection refused on SSH box — triggering self-heal",
                        mapOf("phase" to "create_session", "endpoint" to _endpoint.value.displayHost))
                    _harness.value = HarnessState.Reconnecting(1u, 3u)
                    updateVisibleHarness()
                    attemptSshSelfHeal()
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
                        updateVisibleHarness()
                        attemptSshSelfHeal()
                    } else {
                        _harness.value = HarnessState.Failed("Pairing expired. Scan a new QR code from the server.")
                        updateVisibleHarness()
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
        // Unconditionally stamp the persisted row as EXITED so History shows
        // "ENDED" (not "RUNNING"). recordSavedSession() guards on the session
        // being present in _sessions and early-returns when the row was already
        // removed from the live list; markExited() patches the index directly
        // and is idempotent when the row was correctly stamped by the call above.
        markExited(sessionId)
        // Remember the row in case we need to re-insert it on failure.
        val optimisticRow = _sessions.value.firstOrNull { it.id == sessionId }
        val optimisticLifecycle = _sessionLifecycle.value[sessionId]
        // Optimistic removal so the row disappears immediately.
        _sessions.value = _sessions.value.filterNot { it.id == sessionId }
        updateLifecycle { it - sessionId }
        if (_selectedId.value == sessionId) setSelectedId(null)
        // Free all in-memory chat/state data. Transcript is safe on broker disk;
        // History re-fetches via HTTP on first open.
        val convCount = _conversationLog.value[sessionId]?.size ?: 0
        val chatCount = _chatLog.value[sessionId]?.size ?: 0
        clearSessionState(sessionId)
        Telemetry.breadcrumb("memory", "session_state_freed",
            mapOf("session" to sessionId, "conv" to convCount.toString(),
                  "chat" to chatCount.toString(), "reason" to "archive"))
        // Suppress this id in refreshSessions for a short window so the broker's
        // lingering tmux (#199) doesn't make the row flicker back immediately.
        _recentlyArchivedAt[sessionId] = System.currentTimeMillis()
        Telemetry.breadcrumb("session", "archive initiated",
            mapOf("session_id" to sessionId, "endpoint" to _endpoint.value.displayHost))
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
                // Re-insert the optimistically-removed row so the user isn't
                // silently left with a missing session on failure.
                if (optimisticRow != null) {
                    _sessions.value = (_sessions.value + optimisticRow).sortedByDescending {
                        it.lastActivityAt ?: it.startedAt
                    }
                    if (optimisticLifecycle != null) {
                        updateLifecycle { it + (sessionId to optimisticLifecycle) }
                    }
                }
                // Clear the suppression so the row can be re-fetched normally.
                _recentlyArchivedAt.remove(sessionId)
                // Surface the failure to the UI as a one-shot snackbar error.
                _archiveError.value = "Could not archive session. Please try again."
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
        if (_selectedId.value == sessionId) setSelectedId(null)
        // Free all in-memory chat/state data for this session.
        val convCount = _conversationLog.value[sessionId]?.size ?: 0
        val chatCount = _chatLog.value[sessionId]?.size ?: 0
        clearSessionState(sessionId)
        Telemetry.breadcrumb("memory", "session_state_freed",
            mapOf("session" to sessionId, "conv" to convCount.toString(),
                  "chat" to chatCount.toString(), "reason" to "delete"))
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
     * Free all per-session in-memory state after archive or permanent delete.
     * The broker preserves the transcript on disk; History re-fetches via HTTP
     * on first open. Call immediately after the Rust core forgets the session.
     */
    private fun clearSessionState(sessionId: String) {
        _chatLog.value = _chatLog.value - sessionId
        _conversationLog.value = _conversationLog.value - sessionId
        _hydratedChat.remove(sessionId)
        _statusBySession.value = _statusBySession.value - sessionId
        _terminalBuffer.value = _terminalBuffer.value - sessionId
        _quickReplies.value = _quickReplies.value - sessionId
        _credentialSource.value = _credentialSource.value - sessionId
        _agentAuthFailure.value = _agentAuthFailure.value - sessionId
        _previews.value = _previews.value - sessionId
        _connectionHealth.value = _connectionHealth.value - sessionId
        _modelBySession.value = _modelBySession.value - sessionId
        _pinnedContexts.value = _pinnedContexts.value - sessionId
        _subagentRoster.value = _subagentRoster.value - sessionId
        _sessionBox.value = _sessionBox.value - sessionId
        staleConversations.remove(sessionId)
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
        // Box label must come from the session's STABLE box stamp, not the
        // active endpoint at write time. Otherwise a session created on box A
        // gets re-stamped to box B when a status frame lands while box B is
        // active -> the same session shows up as duplicate history rows under
        // two boxes. Fall back to the active endpoint only when unstamped.
        val stableBoxId = _sessionBox.value[sessionId] ?: savedHistoryServerId()
        val next = SavedSessionsReducer.upsert(
            current = _savedSessions.value,
            session = session,
            serverId = stableBoxId,
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
     * Stamp the persisted History row for [sessionId] as [SavedSessionStatus.EXITED],
     * regardless of its current status. Called by [archive] unconditionally so the
     * row always shows ENDED in History -- even when the session was already removed
     * from [_sessions] and [recordSavedSession] would have early-returned without
     * touching the index. `internal` for the same testability reason as [tombstone].
     */
    internal fun markExited(sessionId: String) {
        val next = SavedSessionsReducer.markExited(_savedSessions.value, sessionId)
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
     * Test seam: seed [_conversationLog] for [sessionId] directly so unit
     * tests can exercise transcript logic ([resolvePendingInput] ts-backfill,
     * ordering) without a live broker/WS. Mirrors iOS, where `conversationLog`
     * is a settable property the tests assign directly.
     */
    internal fun seedConversationLogForTest(sessionId: String, items: List<ConversationItem>) {
        _conversationLog.value = _conversationLog.value + (sessionId to items)
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
     * the session. The broker interrupts the running turn (claude stream-json
     * interrupt / codex turn-interrupt / codex-exec kill) and the turn winding
     * down arrives on the normal chat/status stream, which clears the typing
     * indicator. A no-op broker-side when nothing is running.
     *
     * Reliability: if the WS write fails (transient reconnect window), retries
     * once after ~1 s using the live client at that time. Turn state is NOT
     * optimistically cleared -- we wait for the broker's idle status frame.
     */
    fun stopTurn(sessionId: String) {
        val c = client ?: return
        Telemetry.breadcrumb("chat", "stop-turn attempt", mapOf("session" to sessionId))
        viewModelScope.launch {
            val result = runCatching { withContext(Dispatchers.IO) { c.stopTurn(sessionId) } }
            if (result.isSuccess) {
                Telemetry.breadcrumb("chat", "stop-turn ok", mapOf("session" to sessionId))
                return@launch
            }
            Telemetry.breadcrumb("chat", "stop-turn failed — retrying in 1s",
                mapOf("session" to sessionId,
                      "error" to (result.exceptionOrNull()?.message ?: "")))
            // Retry once: transient WS write errors during a reconnect window are
            // the most common cause. Re-resolve the client so a reconnect that
            // swapped the instance is picked up.
            delay(1_000L)
            val retryClient = client ?: return@launch
            val retryResult = runCatching { withContext(Dispatchers.IO) { retryClient.stopTurn(sessionId) } }
            if (retryResult.isSuccess) {
                Telemetry.breadcrumb("chat", "stop-turn retry ok", mapOf("session" to sessionId))
            } else {
                val err = retryResult.exceptionOrNull()
                Telemetry.breadcrumb("chat", "stop-turn retry failed — stop lost",
                    mapOf("session" to sessionId, "error" to (err?.message ?: "")))
                Telemetry.capture(
                    error = err ?: Exception("stop-turn retry failed"),
                    message = "Android stop-turn failed after retry",
                    extras = mapOf("session" to sessionId)
                )
            }
        }
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
     * True when the session is blocked on a pending AskUserQuestion. Finds
     * the LAST non-user `pending_input` item, ignoring trailing assistant/
     * tool/system items that stream in after the question, and returns true
     * only if that item is unresolved. Used to bypass the turn-queue gate so
     * the answer reaches the broker immediately instead of deadlocking.
     */
    fun hasPendingAsk(sessionId: String): Boolean {
        val items = _conversationLog.value[sessionId] ?: return false
        // Find the last non-user pending_input item, skipping trailing
        // assistant/tool/system items that stream in after the question.
        val idx = items.indexOfLast {
            it.role.lowercase() != "user" && it.kind.lowercase() == "pending_input"
        }
        if (idx < 0) return false
        val last = items[idx]
        // A user message AFTER the prompt means the answer was already sent (the
        // broker consumes the pending ask on the first user turn), so the next
        // message is a normal turn, not an answer.
        if (items.drop(idx + 1).any { it.role.lowercase() == "user" }) return false
        // Optimistic client-side resolution flag.
        if (last.id in _resolvedPendingInputIDs.value) return false
        // Belt-and-suspenders: a resolved pending_input from the transcript carries
        // the [[conduit:resolved]] marker in content even after close+reopen.
        if (sh.nikhil.conduit.ui.PendingQuestions.parsePendingResolution(last.content)?.answered == true) return false
        return true
    }

    fun sendChat(sessionId: String, msg: String, bypassTurnGate: Boolean = false) {
        // Funnel: first ever turn sent — first session, no prior server-side conversation items.
        val priorItems = _conversationLog.value[sessionId].orEmpty().filter { !it.id.startsWith("local-") }
        if (_sessions.value.size <= 1 && priorItems.isEmpty()) {
            Telemetry.breadcrumb("onboarding", sh.nikhil.conduit.ui.OnboardingStep.FIRST_TURN_SENT,
                mapOf("session" to sessionId, "chars" to msg.length.toString()))
        }
        // §D: a fresh user turn is the retry — drop any standing agent-auth
        // failure flag so the "Sign in on this box" banner clears. If the
        // retry 401s again, the next assistant/result event re-sets it.
        if (_agentAuthFailure.value.containsKey(sessionId)) {
            _agentAuthFailure.value = _agentAuthFailure.value - sessionId
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
        // Diagnostic: capture the routing-decision inputs for EVERY delivered
        // send so a message that silently gets queued behind a stuck turn, or
        // consumed as an answer to a stale pending-ask, is reconstructable from
        // Sentry without a repro (the "no replies after /clear" device report,
        // #844 verification — the reply path is proven healthy, so a failure is
        // a mis-route here). Cheap ring-buffered breadcrumb. Mirror of iOS.
        Telemetry.breadcrumb("chat", "send routing", mapOf(
            "session" to sessionId,
            "turn_active" to (_statusBySession.value[sessionId]?.turnActive == true).toString(),
            "pending_ask" to hasPendingAsk(sessionId).toString(),
            "is_slash" to msg.startsWith("/").toString(),
        ))
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
        val ts = epochMillisToTs(anchorEpochMillis(sessionId))
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
        // bypassTurnGate=true is used by flushOnReply to deliver a queued
        // message even when turn_active has not yet flipped false (the
        // assistant reply is itself proof the turn ended).
        val turnActive = !bypassTurnGate && _statusBySession.value[sessionId]?.turnActive == true
        if (!pendingAsk) {
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
        }
        // Elicitation bypass: skip the turnActive queue gate and deliver
        // directly. The broker already routes a message-during-pending-ask
        // to the control channel (takePendingAsk / encodeAskAnswer).
        if (pendingAsk) {
            resolvePendingInput(sessionId)
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
            // Pass the echo's stable localId as client_msg_id so the broker can
            // dedup resends and ack THIS message (task K).
            val result = runCatching { withContext(Dispatchers.IO) { c.sendChat(sessionId, msg, localId) } }

            if (result.isSuccess) {
                // WS write returned — NOT yet durably delivered. Keep the entry
                // queued and faded; only the broker's chat_ack (onChatDelivered)
                // marks it done. Fixes "send then background -> lost but shown
                // as sent".
                updatePendingChats { it.markSent(sessionId, localId) }
                setEchoStatus(sessionId, localId, "sent")
                Telemetry.breadcrumb("chat", "ws-write ok — awaiting broker ack",
                    mapOf("session" to sessionId, "local_id" to localId))
                if (manualRetry) {
                    Telemetry.breadcrumb("chat", "retry_result",
                        mapOf("session" to sessionId, "local_id" to localId, "ok" to "true"))
                }
            } else {
                // Broker forgot the session (restart/redeploy/GC): retrying
                // can't recover it. Stop now + route to Resume; don't burn the
                // retry budget or capture a Sentry ERROR on every broker restart.
                if (isUnknownSession(result.exceptionOrNull())) {
                    handleExpiredSession(sessionId, localId)
                    return@launch
                }
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
            // Carry the localId as client_msg_id for broker dedup/ack parity
            // (task K). The steer panel card clears on WS-write as before; the
            // later chat_ack just no-ops (entry already gone).
            val result = runCatching { withContext(Dispatchers.IO) { c.sendChat(sessionId, msg, localId) } }
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
     * Belt-and-suspenders flush called when a LIVE (not replayed) assistant
     * reply arrives. A settled assistant reply is proof the turn ended, so we
     * deliver the oldest queued-turn entry here even if the status frame
     * reporting turnActive=false has not arrived yet (missed/delayed frame).
     * Idempotent with [flushOnTurnComplete]: markDelivered removes the entry
     * before re-delivery, so whichever trigger fires second finds null and
     * is a no-op. The broker also dedups by client_msg_id.
     * Mirror of iOS SessionStore.flushQueuedOnReply.
     */
    internal fun flushOnReply(sessionId: String) {
        val entry = _pendingChats.value.flushOnTurnComplete(sessionId) ?: return
        Telemetry.breadcrumb(
            "chat",
            "flush_on_reply",
            mapOf("session" to sessionId, "local_id" to entry.localId, "chars" to entry.message.length.toString()),
        )
        // Remove BEFORE re-delivery so the queue never holds a duplicate.
        // (The echo was created when sendChat first ran -- do NOT call sendChat
        // again or the transcript gets a duplicate user bubble.)
        updatePendingChats { it.markDelivered(sessionId, entry.localId) }
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
     * True when a send/deliver error means the broker no longer knows this
     * session (restarted/redeployed/GC'd) -- [ConduitException.UnknownSession].
     * Such an error will NEVER recover by retrying the same dead session, so
     * the deliver path stops retrying and routes the user to Resume instead of
     * burning the retry budget + capturing a Sentry ERROR on every broker
     * restart. Matched on the exact UniFFI case (case 6, not a string) so it
     * stays correct if the message wording changes. Mirror of iOS
     * `isUnknownSession`.
     *
     * `internal` (not `private`) so the unit suite can exercise the exact-case
     * match + the expired-echo flip without a live WS.
     */
    internal fun isUnknownSession(error: Throwable?): Boolean =
        error is ConduitException.UnknownSession

    /**
     * Handle a send/deliver that failed because the broker GC'd/forgot the
     * session ([ConduitException.UnknownSession]). Stops retrying immediately
     * (drops only THIS entry from the queue so later flushes don't re-hit the
     * dead session, and other pending sends are untouched), marks the echo
     * `expired` so the bubble offers a Resume affordance, and downgrades the
     * telemetry to an info breadcrumb (NOT a captured ERROR). Mirror of iOS
     * `handleExpiredSession`.
     */
    internal fun handleExpiredSession(sessionId: String, localId: String) {
        // Drop only this entry so flushPendingChats / turn-complete flushes
        // don't keep re-delivering into a session the broker no longer has;
        // other queued sends stay pending.
        updatePendingChats { it.markDelivered(sessionId, localId) }
        setEchoStatus(sessionId, localId, "expired")
        // Downgrade: info breadcrumb, not Telemetry.capture. This fires on
        // every broker restart and is not an actionable error.
        Telemetry.breadcrumb("chat", "send hit UnknownSession -- session expired, offering Resume",
            mapOf("session" to sessionId, "local_id" to localId))
    }

    /**
     * Resume a session the broker forgot ([ConduitException.UnknownSession]):
     * re-attach the live WebSocket so the broker respawns/rejoins the agent,
     * driving the recovered status frame to promote the row to live. Thin
     * wrapper over [attachLiveSession] for parity with iOS
     * `resumeRecoverableSession`; tapped from the `expired` bubble's Resume
     * footer.
     */
    fun resumeRecoverableSession(sessionID: String, assistant: String) {
        Telemetry.breadcrumb("session", "resume_recoverable",
            mapOf("session" to sessionID, "assistant" to assistant))
        attachLiveSession(sessionID, assistant)
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
        val liveDescriptor = _agentDescriptors.value
            .takeIf { it.isNotEmpty() }
            ?.let { descriptorFor(agent, it) }
        val supportsCompact = liveDescriptor?.supportsCompact
        val supportsClear = liveDescriptor?.supportsClear
        val match = SlashCommandRegistry.classify(msg, agent, supportsCompact, supportsClear) ?: return false
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
        //
        // Proactive fast-fail: if the SSH tunnel is definitively dead, kick off
        // self-heal on the Main thread before hitting the refused loopback port.
        val tunnel = sshTunnel
        if (tunnel != null && !tunnel.isAlive() &&
            _savedServers.value.firstOrNull { it.endpoint == _endpoint.value }?.ssh != null) {
            Telemetry.breadcrumb("fs", "listDirectories — SSH tunnel dead, triggering self-heal",
                mapOf("path" to (path ?: "/")))
            withContext(Dispatchers.Main) { reconnect() }
            error("Lost connection to this box. Reconnecting…")
        }
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
         * Older brokers that omit the key parse as null -- no regression.
         */
        val ntfyUrl: String? = null,
        /** Broker can enumerate sessions started outside Conduit. */
        val sessionDiscovery: Boolean = false,
        /** Broker supports fork-onto-worktree for running sessions. */
        val sessionFork: Boolean = false,
        /** Broker supports read-only live-tail of a running session. */
        val sessionWatch: Boolean = false,
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
     * Whether the broker supports the pipeline gate preview + handoff-edit
     * flow (`GET /api/capabilities` -> `"pipeline_gate_preview": true`).
     * False on old brokers that omit the key. Mirror of iOS
     * `SessionStore.pipelineGatePreview`.
     */
    private val _pipelineGatePreview = MutableStateFlow(false)
    val pipelineGatePreview: StateFlow<Boolean> = _pipelineGatePreview.asStateFlow()

    /**
     * Whether the broker supports pipeline resume-from-failed
     * (`GET /api/capabilities` -> `"pipeline_resume": true`).
     * False on old brokers. Mirror of iOS `SessionStore.pipelineResume`.
     */
    private val _pipelineResume = MutableStateFlow(false)
    val pipelineResume: StateFlow<Boolean> = _pipelineResume.asStateFlow()

    /**
     * Whether the broker supports pipeline templates
     * (`GET /api/capabilities` -> `"pipeline_templates": true`).
     * False on old brokers. Mirror of iOS `SessionStore.pipelineTemplates`.
     */
    private val _pipelineTemplates = MutableStateFlow(false)
    val pipelineTemplates: StateFlow<Boolean> = _pipelineTemplates.asStateFlow()

    /**
     * Whether the broker supports fanout-as-a-step
     * (`GET /api/capabilities` -> `"pipeline_fanout": true`).
     * False on old brokers; the fan-out toggle in the builder and the
     * pick panel in the monitor hide when false.
     */
    private val _pipelineFanout = MutableStateFlow(false)
    val pipelineFanout: StateFlow<Boolean> = _pipelineFanout.asStateFlow()

    /**
     * Whether the broker supports per-block model/effort/permission-mode/
     * instructions overrides (`GET /api/capabilities` ->
     * `"pipeline_block_config": true`, PLAN-HARNESS-BUILDER Phase 1).
     * False on old brokers; the per-step config controls in the builder
     * hide when false so the request stays byte-identical to today.
     */
    private val _pipelineBlockConfig = MutableStateFlow(false)
    val pipelineBlockConfig: StateFlow<Boolean> = _pipelineBlockConfig.asStateFlow()

    /**
     * Whether the broker supports pipelines at all
     * (`GET /api/capabilities` -> `"pipeline": true`, broker PR #891).
     * False on old brokers; gates the "Pipelines" command-palette action,
     * the Home active-pipeline affordance, and `PipelineListScreen`. Mirror
     * of iOS `SessionStore.pipelinesEnabled`.
     */
    private val _pipelinesEnabled = MutableStateFlow(false)
    val pipelinesEnabled: StateFlow<Boolean> = _pipelinesEnabled.asStateFlow()

    /**
     * Whether the broker supports If/Else branch blocks
     * (`GET /api/capabilities` -> `"pipeline_branch": true`,
     * PLAN-HARNESS-BUILDER Phase 3). False on old brokers; the If/Else
     * builder control hides when false. Mirror of iOS
     * `SessionStore.pipelineBranch`.
     */
    private val _pipelineBranch = MutableStateFlow(false)
    val pipelineBranch: StateFlow<Boolean> = _pipelineBranch.asStateFlow()

    /**
     * Whether the broker supports bounded Loop-until blocks
     * (`GET /api/capabilities` -> `"pipeline_loop": true`,
     * PLAN-HARNESS-BUILDER Phase 3). False on old brokers; the Loop
     * builder control hides when false. Mirror of iOS
     * `SessionStore.pipelineLoop`.
     */
    private val _pipelineLoop = MutableStateFlow(false)
    val pipelineLoop: StateFlow<Boolean> = _pipelineLoop.asStateFlow()

    /**
     * Whether the broker populates a `result` field on
     * `GET /api/pipeline/{id}` once a pipeline completes
     * (`GET /api/capabilities` -> `"pipeline_result": true`, #906/#907).
     * False on old brokers; the Monitor's Result card hides when false
     * even if the pipeline is complete. Mirror of iOS
     * `SessionStore.pipelineResult`.
     */
    private val _pipelineResult = MutableStateFlow(false)
    val pipelineResult: StateFlow<Boolean> = _pipelineResult.asStateFlow()

    /**
     * Whether the broker supports archiving terminal flows
     * (`GET /api/capabilities` -> `"pipeline_archive": true`, broker #932).
     * False on old brokers; the Archive/Unarchive affordances hide when
     * false. Mirror of iOS `SessionStore.pipelineArchive`.
     */
    private val _pipelineArchive = MutableStateFlow(false)
    val pipelineArchive: StateFlow<Boolean> = _pipelineArchive.asStateFlow()

    /** Broker advertises transactional mid-session agent switching. */
    private val _switchAgentSupported = MutableStateFlow(false)
    val switchAgentSupported: StateFlow<Boolean> = _switchAgentSupported.asStateFlow()

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
        _switchAgentSupported.value = runCatching {
            JSONObject(raw).optJSONObject("features")?.optBoolean("switch_agent", false) ?: false
        }.getOrDefault(false)
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
        // pipeline_gate_preview: top-level boolean; default false on old brokers.
        val gatePreview = runCatching {
            JSONObject(raw).optBoolean("pipeline_gate_preview", false)
        }.getOrDefault(false)
        _pipelineGatePreview.value = gatePreview
        // pipeline_resume: resume-from-failed; default false on old brokers.
        val pipelineResume = runCatching {
            JSONObject(raw).optBoolean("pipeline_resume", false)
        }.getOrDefault(false)
        _pipelineResume.value = pipelineResume
        // pipeline_templates: save/load templates; default false on old brokers.
        val pipelineTemplates = runCatching {
            JSONObject(raw).optBoolean("pipeline_templates", false)
        }.getOrDefault(false)
        _pipelineTemplates.value = pipelineTemplates
        // pipeline_fanout: fanout-as-a-step; default false on old brokers.
        val pipelineFanout = runCatching {
            JSONObject(raw).optBoolean("pipeline_fanout", false)
        }.getOrDefault(false)
        _pipelineFanout.value = pipelineFanout
        // pipeline_block_config: per-block model/effort/mode/instructions
        // overrides (PLAN-HARNESS-BUILDER Phase 1); default false on old brokers.
        val pipelineBlockConfig = runCatching {
            JSONObject(raw).optBoolean("pipeline_block_config", false)
        }.getOrDefault(false)
        _pipelineBlockConfig.value = pipelineBlockConfig
        // pipeline: pipelines exist at all (broker PR #891); default false on old brokers.
        val pipelinesEnabled = runCatching {
            JSONObject(raw).optBoolean("pipeline", false)
        }.getOrDefault(false)
        _pipelinesEnabled.value = pipelinesEnabled
        // pipeline_branch / pipeline_loop: If/Else + Loop blocks
        // (PLAN-HARNESS-BUILDER Phase 3); default false on old brokers.
        _pipelineBranch.value = runCatching {
            JSONObject(raw).optBoolean("pipeline_branch", false)
        }.getOrDefault(false)
        _pipelineLoop.value = runCatching {
            JSONObject(raw).optBoolean("pipeline_loop", false)
        }.getOrDefault(false)
        // pipeline_result: Monitor Result card on completion; default false on old brokers.
        _pipelineResult.value = runCatching {
            JSONObject(raw).optBoolean("pipeline_result", false)
        }.getOrDefault(false)
        // pipeline_archive: archive/unarchive terminal flows (broker #932); default false on old brokers.
        _pipelineArchive.value = runCatching {
            JSONObject(raw).optBoolean("pipeline_archive", false)
        }.getOrDefault(false)
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
                sessionDiscovery = features?.optBoolean("session_discovery", false) ?: false,
                sessionFork = features?.optBoolean("session_fork", false) ?: false,
                sessionWatch = features?.optBoolean("session_watch", false) ?: false,
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

    // -----------------------------------------------------------------------
    // Found Sessions (session_discovery capability)
    // -----------------------------------------------------------------------

    /**
     * Persisted set of hidden found-session external ids, keyed by box id.
     * A hidden session stays suppressed even if rediscovered, until the user
     * unhides it from the "All" filter. Per-box, not global.
     */
    private val _hiddenFound = MutableStateFlow<Map<String, Set<String>>>(emptyMap())

    /** Persisted hidden ids for a specific box. */
    fun hiddenFoundIds(boxId: String): Set<String> = _hiddenFound.value[boxId] ?: emptySet()

    /** Hide a found session by externalId for the given boxId (persisted in memory; no network). */
    fun hideFound(boxId: String, externalId: String) {
        val current = _hiddenFound.value.toMutableMap()
        val box = (current[boxId] ?: emptySet()).toMutableSet()
        box.add(externalId)
        current[boxId] = box
        _hiddenFound.value = current
        Telemetry.breadcrumb("found_sessions", "hide", mapOf("box" to boxId, "external_id" to externalId))
    }

    /** Undo a hide for a found session (used by Snackbar undo). */
    fun unhideFound(boxId: String, externalId: String) {
        val current = _hiddenFound.value.toMutableMap()
        val box = (current[boxId] ?: emptySet()).toMutableSet()
        box.remove(externalId)
        current[boxId] = box
        _hiddenFound.value = current
        Telemetry.breadcrumb("found_sessions", "unhide", mapOf("box" to boxId, "external_id" to externalId))
    }

    /**
     * Wire model for a discovered external session (GET /api/sessions/discovered).
     * Mirrors the JSON shape from FOUND-SESSIONS-CONTRACT.md.
     */
    data class DiscoveredSession(
        val agent: String,
        val externalId: String,
        val title: String,
        val cwd: String,
        val gitBranch: String,
        val turnCount: Int,
        val lastActivityAtMs: Long,
        val isRunning: Boolean,
    )

    /**
     * Wire result of GET /api/sessions/discovered.
     */
    data class DiscoveredSessionsPage(
        val sessions: List<DiscoveredSession>,
        val nextCursor: String,
        val totalOnDisk: Int,
    )

    /**
     * Fetch a paged list of sessions started outside Conduit on this box.
     * Uses GET /api/sessions/discovered per FOUND-SESSIONS-CONTRACT.md.
     * Returns null on any failure (broker unreachable, 403, etc.).
     */
    suspend fun fetchDiscoveredSessions(
        endpoint: Endpoint,
        q: String = "",
        agent: String = "",
        cursor: String = "",
    ): DiscoveredSessionsPage? = withContext(Dispatchers.IO) {
        val base = endpoint.httpBaseUrl ?: return@withContext null
        Telemetry.breadcrumb("found_sessions", "fetch start", mapOf("host" to endpoint.displayHost, "q" to q))
        val sb = StringBuilder("$base/api/sessions/discovered?limit=50")
        if (q.isNotBlank()) sb.append("&q=${java.net.URLEncoder.encode(q, "UTF-8")}")
        if (agent.isNotBlank()) sb.append("&agent=${java.net.URLEncoder.encode(agent, "UTF-8")}")
        if (cursor.isNotBlank()) sb.append("&cursor=${java.net.URLEncoder.encode(cursor, "UTF-8")}")
        return@withContext runCatching {
            val conn = (URL(sb.toString()).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                setRequestProperty("Authorization", "Bearer ${endpoint.token}")
                connectTimeout = 7_000
                readTimeout = 15_000
            }
            try {
                if (conn.responseCode !in 200..299) {
                    Telemetry.breadcrumb("found_sessions", "fetch error", mapOf("code" to conn.responseCode.toString()))
                    return@runCatching null
                }
                val raw = conn.inputStream.bufferedReader().use { it.readText() }
                val obj = JSONObject(raw)
                val arr = obj.optJSONArray("sessions") ?: org.json.JSONArray()
                val sessions = (0 until arr.length()).map { i ->
                    val s = arr.getJSONObject(i)
                    DiscoveredSession(
                        agent = s.optString("agent", "claude"),
                        externalId = s.optString("external_id", ""),
                        title = s.optString("title", ""),
                        cwd = s.optString("cwd", ""),
                        gitBranch = s.optString("git_branch", ""),
                        turnCount = s.optInt("turn_count", 0),
                        lastActivityAtMs = s.optLong("last_activity_at", 0L),
                        isRunning = s.optBoolean("is_running", false),
                    )
                }
                Telemetry.breadcrumb(
                    "found_sessions", "fetch ok",
                    mapOf("count" to sessions.size.toString(), "total" to obj.optInt("total_on_disk", 0).toString()),
                )
                DiscoveredSessionsPage(
                    sessions = sessions,
                    nextCursor = obj.optString("next_cursor", ""),
                    totalOnDisk = obj.optInt("total_on_disk", 0),
                )
            } finally {
                conn.disconnect()
            }
        }.getOrElse { e ->
            Telemetry.breadcrumb("found_sessions", "fetch exception", mapOf("error" to (e.message ?: "unknown")))
            null
        }
    }

    /**
     * Wire model for a transcript item from GET /api/sessions/discovered/transcript.
     */
    data class FoundTranscriptItem(
        val role: String,
        val content: String,
        val ts: String,
    )

    /**
     * Fetch the read-only transcript for a discovered session (pre-adopt).
     * Returns the item list; partial result on corrupt/partial files per contract.
     */
    suspend fun fetchDiscoveredTranscript(
        endpoint: Endpoint,
        agent: String,
        externalId: String,
    ): List<FoundTranscriptItem>? = withContext(Dispatchers.IO) {
        val base = endpoint.httpBaseUrl ?: return@withContext null
        Telemetry.breadcrumb("found_sessions", "transcript fetch", mapOf("agent" to agent, "id" to externalId))
        val url = URL(
            "$base/api/sessions/discovered/transcript" +
                "?agent=${java.net.URLEncoder.encode(agent, "UTF-8")}" +
                "&external_id=${java.net.URLEncoder.encode(externalId, "UTF-8")}",
        )
        return@withContext runCatching {
            val conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                setRequestProperty("Authorization", "Bearer ${endpoint.token}")
                connectTimeout = 7_000
                readTimeout = 15_000
            }
            try {
                if (conn.responseCode !in 200..299) {
                    Telemetry.breadcrumb("found_sessions", "transcript error", mapOf("code" to conn.responseCode.toString()))
                    return@runCatching null
                }
                val raw = conn.inputStream.bufferedReader().use { it.readText() }
                val obj = JSONObject(raw)
                val arr = obj.optJSONArray("items") ?: org.json.JSONArray()
                (0 until arr.length()).map { i ->
                    val item = arr.getJSONObject(i)
                    FoundTranscriptItem(
                        role = item.optString("role", "user"),
                        content = item.optString("content", ""),
                        ts = item.optString("ts", ""),
                    )
                }.also { items ->
                    Telemetry.breadcrumb("found_sessions", "transcript ok", mapOf("items" to items.size.toString()))
                }
            } finally {
                conn.disconnect()
            }
        }.getOrElse { e ->
            Telemetry.breadcrumb("found_sessions", "transcript exception", mapOf("error" to (e.message ?: "unknown")))
            null
        }
    }

    /**
     * Fetch NEW transcript items for a running session since [sinceMs] (unix millis).
     * Used by the Watch live poll loop: GET /api/sessions/discovered/transcript
     * with the since_ts query parameter.
     * Returns a Pair of (new items, latest_ts) on success; null on any failure.
     * Callers should keep retrying on null (paused state) and stop on session end.
     */
    suspend fun fetchDiscoveredTranscriptSince(
        endpoint: Endpoint,
        agent: String,
        externalId: String,
        sinceMs: Long,
    ): Pair<List<FoundTranscriptItem>, Long>? = withContext(Dispatchers.IO) {
        val base = endpoint.httpBaseUrl ?: return@withContext null
        Telemetry.breadcrumb(
            "found_sessions",
            "watch poll",
            mapOf("agent" to agent, "id" to externalId, "since_ms" to sinceMs.toString()),
        )
        val url = URL(
            "$base/api/sessions/discovered/transcript" +
                "?agent=${java.net.URLEncoder.encode(agent, "UTF-8")}" +
                "&external_id=${java.net.URLEncoder.encode(externalId, "UTF-8")}" +
                "&since_ts=$sinceMs",
        )
        return@withContext runCatching {
            val conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                setRequestProperty("Authorization", "Bearer ${endpoint.token}")
                connectTimeout = 7_000
                readTimeout = 15_000
            }
            try {
                if (conn.responseCode !in 200..299) {
                    Telemetry.breadcrumb(
                        "found_sessions",
                        "watch poll error",
                        mapOf("code" to conn.responseCode.toString()),
                    )
                    return@runCatching null
                }
                val raw = conn.inputStream.bufferedReader().use { it.readText() }
                val obj = org.json.JSONObject(raw)
                val arr = obj.optJSONArray("items") ?: org.json.JSONArray()
                val items = (0 until arr.length()).map { i ->
                    val item = arr.getJSONObject(i)
                    FoundTranscriptItem(
                        role = item.optString("role", "user"),
                        content = item.optString("content", ""),
                        ts = item.optString("ts", ""),
                    )
                }
                val latestTs = obj.optLong("latest_ts", sinceMs)
                Telemetry.breadcrumb(
                    "found_sessions",
                    "watch poll ok",
                    mapOf("new_items" to items.size.toString(), "latest_ts" to latestTs.toString()),
                )
                Pair(items, latestTs)
            } finally {
                conn.disconnect()
            }
        }.getOrElse { e ->
            Telemetry.breadcrumb(
                "found_sessions",
                "watch poll exception",
                mapOf("error" to (e.message ?: "unknown")),
            )
            null
        }
    }

    /**
     * Adopt a discovered session (resume or fork) via POST /api/sessions/adopt.
     * Returns the new Conduit session_id on success, or null on failure.
     *
     * After success the caller should open the session via the normal WS flow
     * (select the box + connect, then open the returned session_id in ProjectScreen).
     *
     * mode: "resume" (idle sessions only) | "fork" (running, requires session_fork capability)
     */
    suspend fun adoptFound(
        endpoint: Endpoint,
        agent: String,
        externalId: String,
        cwd: String,
        mode: String,
    ): String? = withContext(Dispatchers.IO) {
        val base = endpoint.httpBaseUrl ?: return@withContext null
        Telemetry.breadcrumb(
            "found_sessions", "adopt start",
            mapOf("agent" to agent, "external_id" to externalId, "mode" to mode),
        )
        return@withContext runCatching {
            val body = JSONObject().apply {
                put("agent", agent)
                put("external_id", externalId)
                put("cwd", cwd)
                put("mode", mode)
            }.toString().toByteArray(Charsets.UTF_8)
            val conn = (URL("$base/api/sessions/adopt").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                setRequestProperty("Authorization", "Bearer ${endpoint.token}")
                setRequestProperty("Content-Type", "application/json")
                doOutput = true
                connectTimeout = 7_000
                readTimeout = 30_000
            }
            try {
                conn.outputStream.use { it.write(body) }
                val code = conn.responseCode
                if (code !in 200..299) {
                    val errBody = runCatching {
                        conn.errorStream?.bufferedReader()?.use { it.readText() }
                    }.getOrNull()
                    Telemetry.breadcrumb(
                        "found_sessions", "adopt error",
                        mapOf("code" to code.toString(), "body" to (errBody ?: "")),
                    )
                    return@runCatching null
                }
                val raw = conn.inputStream.bufferedReader().use { it.readText() }
                val sessionId = JSONObject(raw).optString("session_id", null)
                Telemetry.breadcrumb(
                    "found_sessions", "adopt ok",
                    mapOf("session_id" to (sessionId ?: "null"), "mode" to mode),
                )
                sessionId
            } finally {
                conn.disconnect()
            }
        }.getOrElse { e ->
            Telemetry.breadcrumb("found_sessions", "adopt exception", mapOf("error" to (e.message ?: "unknown")))
            null
        }
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
     * Fetch the broker's live pipeline list (`GET /api/pipelines`, broker
     * `serveListPipelines`). Best-effort: returns an empty list on any
     * network/decode failure (mirrors [getJsonOrNull]'s convention) rather
     * than throwing, so callers -- Home's active-pipeline affordance and
     * `PipelineListScreen` -- can call this directly. This is the ONLY
     * app-side consumer of `GET /api/pipelines`; before it, a pipeline
     * became unreachable the moment its creation sheet was dismissed even
     * though the broker kept it running.
     */
    suspend fun refreshPipelines(includeArchived: Boolean = false): List<sh.nikhil.conduit.ui.PipelineSummary> = withContext(Dispatchers.IO) {
        if (_isDemoMode.value) {
            return@withContext DemoData.pipelines
        }
        val ep = _endpoint.value
        val path = if (includeArchived) "/api/pipelines?include_archived=1" else "/api/pipelines"
        val raw = getJsonOrNull(ep, path)
        if (raw == null) {
            Telemetry.breadcrumb("pipeline", "list fetch failed", mapOf("host" to ep.displayHost, "includeArchived" to includeArchived.toString()))
            return@withContext emptyList()
        }
        val parsed = runCatching<List<sh.nikhil.conduit.ui.PipelineSummary>> {
            val arr = JSONObject(raw).optJSONArray("pipelines") ?: return@runCatching emptyList()
            (0 until arr.length()).map { i ->
                val o = arr.getJSONObject(i)
                // Additive (#922) -- absent on an older broker. Tolerated
                // via optJSONArray/optJSONObject returning null, which the
                // app-side model defaults to (PipelineSummary.steps/result).
                val steps = o.optJSONArray("steps")?.let { stepsArr ->
                    (0 until stepsArr.length()).map { j ->
                        val so = stepsArr.getJSONObject(j)
                        sh.nikhil.conduit.ui.PipelineSummaryStep(
                            agent = so.optString("agent", ""),
                            role = so.optString("role", ""),
                            status = so.optString("status", ""),
                            gateAfter = so.optBoolean("gate_after", false),
                        )
                    }
                }
                val result = o.optJSONObject("result")?.let { ro ->
                    sh.nikhil.conduit.ui.PipelineSummaryResult(
                        filesChanged = ro.optInt("files_changed", 0),
                        insertions = ro.optInt("insertions", 0),
                        deletions = ro.optInt("deletions", 0),
                        finished = ro.optString("finished", "").takeIf { it.isNotEmpty() },
                    )
                }
                sh.nikhil.conduit.ui.PipelineSummary(
                    id = o.optString("id", ""),
                    title = o.optString("title", ""),
                    state = o.optString("state", ""),
                    currentStep = o.optInt("current_step", 0),
                    stepCount = o.optInt("step_count", 0),
                    created = o.optString("created", "").takeIf { it.isNotEmpty() },
                    steps = steps,
                    result = result,
                    archived = o.optBoolean("archived", false),
                )
            }
        }.getOrNull()
        if (parsed == null) {
            Telemetry.breadcrumb("pipeline", "list decode failed", mapOf("host" to ep.displayHost))
            return@withContext emptyList()
        }
        parsed
    }

    /**
     * Archive (or unarchive) a terminal flow (`POST
     * /api/pipeline/{id}/archive|unarchive`, broker #932 -- gated on
     * [pipelineArchive]). Returns true on success; best-effort, mirrors the
     * `continueFlow`-style POST pattern.
     */
    suspend fun setPipelineArchived(id: String, archived: Boolean): Boolean = withContext(Dispatchers.IO) {
        val ep = _endpoint.value
        val base = ep.httpBaseUrl ?: return@withContext false
        val action = if (archived) "archive" else "unarchive"
        Telemetry.breadcrumb("pipeline", if (archived) "archive_tapped" else "unarchive_tapped", mapOf("id" to id))
        runCatching {
            val conn = (URL("$base/api/pipeline/$id/$action").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                setRequestProperty("Authorization", "Bearer ${ep.token}")
                setRequestProperty("Content-Type", "application/json")
                doOutput = true
                connectTimeout = 7_000
                readTimeout = 10_000
            }
            try {
                conn.outputStream.use { it.write("{}".toByteArray()) }
                val ok = conn.responseCode in 200..299
                if (ok) {
                    Telemetry.breadcrumb("pipeline", if (archived) "archive_ok" else "unarchive_ok", mapOf("id" to id))
                } else {
                    Telemetry.capture(
                        RuntimeException("flow archive toggle failed"),
                        message = "flow archive toggle failed",
                        tags = mapOf("surface" to "android", "phase" to "pipeline"),
                        extras = mapOf("id" to id, "archived" to archived.toString(), "status" to conn.responseCode.toString()),
                    )
                }
                ok
            } finally {
                conn.disconnect()
            }
        }.getOrElse { e ->
            Telemetry.capture(
                e,
                message = "flow archive toggle network error",
                tags = mapOf("surface" to "android", "phase" to "pipeline"),
                extras = mapOf("id" to id, "archived" to archived.toString()),
            )
            false
        }
    }

    /**
     * Parse a broker conversation-page JSON array into [ConversationItem] list.
     * Shared between [fetchConversation] (initial tail load) and
     * [fetchOlderConversation] (older-page loads). Items are assigned the
     * given [idPrefix] + index so IDs are stable and distinct between pages.
     */
    private fun parseConversationItems(
        arr: org.json.JSONArray,
        sessionID: String,
        idPrefix: String,
    ): List<ConversationItem> = buildList {
        for (i in 0 until arr.length()) {
            val e = arr.getJSONObject(i)
            val role = e.optString("role", "")
            val rawContent = e.optString("content", "")
            // Detect pending_input BEFORE stripping the sentinel — once stripped
            // the sentinel is gone and we can't classify the item. Mirror of iOS
            // `mapRemoteItem` which checks `isPending` before stripping.
            val isPending = rawContent.contains(sh.nikhil.conduit.ui.PendingQuestions.PENDING_INPUT_SENTINEL)
            val kind = when {
                isPending -> "pending_input"
                role.lowercase() == "tool" -> "tool"
                else -> "message"
            }
            // Strip the sentinel BUT keep the resolution marker so the
            // PendingInputCard can rehydrate its answered/selected state from
            // the transcript (iOS PR #721 parity). Core strips both on the
            // live path; the HTTP-fetch path keeps the resolved marker here.
            val itemContent = stripPendingSentinel(rawContent)
            // If the item carries a resolution marker, parse it and add this
            // item to resolvedPendingInputIDs so the inline card flips to
            // answered immediately on load. Mirror of iOS `mapRemoteItem`.
            if (isPending) {
                val res = sh.nikhil.conduit.ui.PendingQuestions.parsePendingResolution(itemContent)
                if (res?.answered == true) {
                    val id = "$idPrefix-$sessionID-$i"
                    _resolvedPendingInputIDs.value = _resolvedPendingInputIDs.value + id
                    Telemetry.breadcrumb(
                        "approvals",
                        "pending_input rehydrated answered from transcript",
                        mapOf(
                            "session" to sessionID,
                            "has_answer" to (res.answer != null).toString(),
                        ),
                    )
                }
            }
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
            // Options are extracted by PendingInputCard from content when empty;
            // the core classifier populates them on the live path.
            val pendingOptions = emptyList<String>()
            add(
                ConversationItem(
                    id = "$idPrefix-$sessionID-$i",
                    role = role,
                    kind = kind,
                    status = "done",
                    content = itemContent,
                    ts = e.optString("ts", ""),
                    files = files,
                    toolName = null,
                    command = null,
                    exitCode = null,
                    durationMs = null,
                    diffSummary = null,
                    pendingOptions = pendingOptions,
                    sourceAgent = null,
                    targetAgent = null,
                    taskText = null,
                    resultSummary = null,
                    planSteps = emptyList(),
                )
            )
        }
    }

    suspend fun fetchConversation(sessionID: String): List<ConversationItem> = withContext(Dispatchers.IO) {
        // Dispatchers.IO for the same reason as [listDirectories]: the
        // blocking HttpURLConnection calls below must never run on the Main
        // dispatcher (NetworkOnMainThreadException).
        //
        // Uses tail=80 so the broker returns only the most-recent 80 items.
        // The response envelope also carries has_more_before + oldest_ts so
        // we can offer backward pagination via [fetchOlderConversation].
        // Old broker omits has_more_before -> decoded as false (backward-compat).
        val base = _endpoint.value.httpBaseUrl ?: error("Invalid endpoint URL")
        val encodedId = java.net.URLEncoder.encode(sessionID, "UTF-8")
        val url = URL("$base/api/session/conversation/$encodedId?tail=80")
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
            val items = parseConversationItems(arr, sessionID, "saved")
            // Decode pagination envelope (has_more_before absent on old broker -> false).
            val hasMore = obj.optBoolean("has_more_before", false)
            val oldestTs = obj.optLong("oldest_ts", 0L)
            _paginationState.value = _paginationState.value + (sessionID to ConversationPaginationState(
                hasMoreHistory = hasMore,
                oldestLoadedTs = oldestTs,
            ))
            // Populate the conversationLog so ChatPage can observe it and
            // trigger paginated loads. Does NOT pollute live session state
            // because archived sessions carry distinct IDs from active ones.
            _conversationLog.value = _conversationLog.value + (sessionID to items)
            Telemetry.breadcrumb(
                "pagination", "fetch_conversation",
                mapOf("session" to sessionID, "count" to items.size.toString(), "has_more" to hasMore.toString()),
            )
            items
        }
    }

    /**
     * Fetch a page of messages OLDER than [beforeTs] (unix ms) for an
     * archived transcript. Prepends the new items into [_conversationLog] and
     * updates [_paginationState]. Returns the new items + updated hasMore, or
     * null on network failure.
     *
     * Callers must guard against concurrent calls (isLoadingOlder flag in the
     * composable) because this mutates shared state.
     */
    suspend fun fetchOlderConversation(
        sessionID: String,
        beforeTs: Long,
    ): Pair<List<ConversationItem>, Boolean>? = withContext(Dispatchers.IO) {
        val base = _endpoint.value.httpBaseUrl ?: return@withContext null
        val encodedId = java.net.URLEncoder.encode(sessionID, "UTF-8")
        val url = URL("$base/api/session/conversation/$encodedId?before_ts=$beforeTs&limit=80")
        val conn = (url.openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            setRequestProperty("Authorization", "Bearer ${_endpoint.value.token}")
            connectTimeout = 7_000
            readTimeout = 10_000
        }
        runCatching {
            val responseCode = conn.responseCode
            if (responseCode !in 200..299) {
                Telemetry.breadcrumb(
                    "pagination", "fetch_older_error",
                    mapOf("session" to sessionID, "code" to responseCode.toString()),
                )
                return@runCatching null
            }
            conn.inputStream.bufferedReader().use { reader ->
                val raw = reader.readText()
                val obj = JSONObject(raw)
                val arr = obj.optJSONArray("items") ?: JSONArray()
                val hasMore = obj.optBoolean("has_more_before", false)
                val oldestTs = obj.optLong("oldest_ts", 0L)
                val newItems = parseConversationItems(arr, sessionID, "paged-$beforeTs")
                // Prepend older items in front of the existing log and re-sort
                // chronologically so any out-of-order ts values are corrected.
                val existing = _conversationLog.value[sessionID] ?: emptyList()
                val merged = (newItems + existing).sortedByConversationTs { it.ts }
                _conversationLog.value = _conversationLog.value + (sessionID to merged)
                _paginationState.value = _paginationState.value + (sessionID to ConversationPaginationState(
                    hasMoreHistory = hasMore,
                    oldestLoadedTs = oldestTs,
                ))
                Telemetry.breadcrumb(
                    "pagination", "fetch_older_ok",
                    mapOf(
                        "session" to sessionID,
                        "new_count" to newItems.size.toString(),
                        "total" to merged.size.toString(),
                        "has_more" to hasMore.toString(),
                    ),
                )
                Pair(newItems, hasMore)
            }
        }.getOrElse { e ->
            Telemetry.breadcrumb("pagination", "fetch_older_exception", mapOf("session" to sessionID, "error" to (e.message ?: "unknown")))
            null
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
        // Also suppress recently-archived ids for a short window so the broker's
        // lingering tmux (#199) doesn't make the row flicker back immediately.
        val now = System.currentTimeMillis()
        _recentlyArchivedAt.entries.removeAll { (_, ts) -> now - ts > ARCHIVE_SUPPRESS_MS }
        val recentlyArchived = _recentlyArchivedAt.keys.toSet()
        val list = c.listSessions().filterNot { it.id in deleted || it.id in recentlyArchived }
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
        _sessions.value = mergeRefreshedSessions(
            existing = _sessions.value,
            listed = list,
            sessionBox = _sessionBox.value,
            currentBoxId = currentBoxId,
            deleted = deleted,
            recentlyArchived = recentlyArchived,
            idOf = { it.id },
        )
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
        }
        refreshStaleAwareConversations(_sessions.value)
    }

    /**
     * FIX 2 (mirrors iOS App Hang 17-17.8s, v0.0.214, interim -- see
     * docs/PLAN-PER-SESSION-OBSERVABILITY.md for the real per-session-node
     * refactor): gate the fan-out so a status delta pays the merge cost for
     * only the sessions someone can currently SEE, not every session in the
     * list.
     *
     * - Cold-join (`conversationLog[id] == null`, never pulled once) still
     *   refreshes eagerly -- cheap (first pull) and needed so search /
     *   previews have SOMETHING for a brand-new row.
     * - The selected session refreshes eagerly too (debounced -- see
     *   [scheduleEagerSelectedRefresh]).
     * - Everything else is recorded in [staleConversations] and picked up
     *   lazily the moment it's opened (see [setSelectedId]).
     */
    private fun refreshStaleAwareConversations(sessionList: List<ProjectSession>) {
        var skipped = 0
        for (s in sessionList) {
            if (_conversationLog.value[s.id] == null) {
                refreshConversation(s.id)
                continue
            }
            if (s.id == _selectedId.value) {
                scheduleEagerSelectedRefresh(s.id)
            } else {
                staleConversations.add(s.id)
                skipped++
            }
        }
        if (skipped > 0) {
            Telemetry.breadcrumb("perf", "refresh_skipped_stale", mapOf("count" to skipped.toString()))
        }
    }

    /**
     * Trailing-edge debounce (same idiom as [scheduleTerminalPersist]):
     * coalesce repeated fan-out triggers for the selected session to at
     * most one merge per ~300ms so a burst of status deltas doesn't stack
     * up redundant pulls for the one session that's already getting live
     * updates via `onChatEvent`.
     */
    private fun scheduleEagerSelectedRefresh(sessionId: String) {
        if (!eagerSelectedRefreshScheduled.compareAndSet(false, true)) return
        viewModelScope.launch(Dispatchers.IO) {
            delay(300)
            eagerSelectedRefreshScheduled.set(false)
            // Refresh whatever is selected NOW -- it may have changed during
            // the debounce window.
            _selectedId.value?.let { refreshConversation(it) }
        }
    }

    private fun refreshConversation(sessionId: String) {
        val c = client ?: return
        Telemetry.breadcrumb("perf", "refresh_conversation", mapOf("session" to sessionId))
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
                // prompt -- confusing. Splice by timestamp so the order stays
                // chronological. Mirror of iOS `SessionStore.refreshConversation`.
                val existing = _conversationLog.value[sessionId] ?: emptyList()
                val serverFingerprints = items.map { "${it.role}|${it.content}" }.toSet()
                val stillPending = existing.filter {
                    it.id.startsWith("local-") && "${it.role}|${it.content}" !in serverFingerprints
                }
                // Merge under the sticky HTTP-fetched base (iOS parity).
                // On cold restart listConversationItems returns EMPTY until
                // status frames arrive; without this guard the empty live list
                // would overwrite the HTTP-fetched history and wipe the chat.
                // Items already present in the live set (same role|content
                // fingerprint) are deduplicated so history never double-shows.
                val past = _hydratedChat[sessionId] ?: emptyList()
                // Use the stripped key (drops [[conduit:needs-input]] and
                // [[conduit:resolved]] lines) so resolved and unanswered versions
                // of the same AskUserQuestion card are treated as one logical item.
                fun fp(item: ConversationItem) =
                    "${item.role}|${sh.nikhil.conduit.ui.PendingQuestions.strippedKey(item.content)}"
                val liveByKey = items.associateBy { fp(it) }
                // Keys where the past (HTTP transcript) has the resolved marker
                // but the matching live item doesn't — transcript version must win
                // so the card shows as a chip on fresh app restart (resolvedPendingInputIDs
                // is ephemeral).
                val resolvedPastKeys = past
                    .filter { item ->
                        val key = fp(item)
                        item.content.contains(sh.nikhil.conduit.ui.PendingQuestions.PENDING_RESOLVED_MARKER) &&
                            liveByKey[key]?.content?.contains(sh.nikhil.conduit.ui.PendingQuestions.PENDING_RESOLVED_MARKER) != true
                    }
                    .map { fp(it) }
                    .toSet()
                val liveFp = items.map { fp(it) }.toSet()
                val pastNotInLive = past.filter { item ->
                    val key = fp(item)
                    key !in liveFp || key in resolvedPastKeys
                }
                val liveFiltered = items.filter { fp(it) !in resolvedPastKeys }
                // Splice the local user echo and sticky past items into the
                // server log in true chronological order. See [sortedByConversationTs].
                val merged = (pastNotInLive + liveFiltered + stillPending).sortedByConversationTs { it.ts }
                Telemetry.breadcrumb("perf", "refresh_conversation_merge_done",
                    mapOf("session" to sessionId, "count" to merged.size.toString()))
                _conversationLog.value = _conversationLog.value + (sessionId to merged)
            }
        // Fix 9: if this session has the per-session auto-approve grant and the
        // refreshed transcript now ends on a pending approval, auto-resolve it.
        maybeAutoApprove(sessionId)
    }

    /**
     * Seed the sticky HTTP-fetched history base for [sessionID] (idempotent).
     * Fetches the tail-80 conversation from the broker over HTTP, stores it in
     * [_hydratedChat], then calls [refreshConversation] so the live log is
     * immediately merged against the base. Subsequent calls are no-ops (the
     * idempotency guard returns early once the base is set).
     *
     * On cold restart the Rust core's listConversationItems is empty until
     * status frames arrive; hydrating from HTTP first and merging live items
     * ON TOP prevents refreshConversation from clobbering the fetched history
     * with an empty list. Mirror of iOS [SessionStore.hydrateChatConversation].
     *
     * Caller must be on the main dispatcher (or viewModelScope). The inner
     * [fetchConversation] call does its own withContext(Dispatchers.IO).
     */
    private suspend fun hydrateChatConversation(sessionID: String) {
        // Idempotency guard -- only hydrate once per session per process lifetime.
        if (_hydratedChat[sessionID] != null) return
        Telemetry.breadcrumb("chat_hydration", "hydrate start", mapOf("session" to sessionID))
        val items = try {
            fetchConversation(sessionID)
        } catch (t: Throwable) {
            Telemetry.breadcrumb(
                "chat_hydration", "hydrate fetch failed",
                mapOf("session" to sessionID, "err" to (t.message ?: t.javaClass.simpleName)),
            )
            return
        }
        if (items.isEmpty()) {
            Telemetry.breadcrumb("chat_hydration", "hydrate empty -- skipping base", mapOf("session" to sessionID))
            return
        }
        _hydratedChat[sessionID] = items
        Telemetry.breadcrumb(
            "chat_hydration", "hydrate seeded",
            mapOf("session" to sessionID, "count" to items.size.toString()),
        )
        // Merge the live state on top of the newly-seeded base.
        refreshConversation(sessionID)
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
            // Reconcile: a reply proves the broker received the sent message(s).
            // Drain `sent=true` pending entries so their bubbles go solid now
            // without waiting for the explicit chat_ack (which may race or lag).
            val (drained, localIds) = _pendingChats.value.drainSentNormal(sessionId)
            if (localIds.isNotEmpty()) {
                _pendingChats.value = drained
                prefs?.edit()?.putString(KEY_PENDING_CHATS, PendingChatQueue.encode(drained))?.apply()
                for (localId in localIds) setEchoStatus(sessionId, localId, "done")
                Telemetry.breadcrumb("chat", "reconciled sent on reply",
                    mapOf("session" to sessionId, "count" to localIds.size.toString()))
            }
            // Final assistant message arrived — clear the in-memory streaming
            // overlay. Guard: only clear when this event belongs to the
            // current-or-newer turn, not an older broker-replayed transcript
            // message. On WS reconnect the broker replays the last 200 settled
            // messages; each replayed assistant event must NOT evict the live
            // streaming state for an in-flight turn still producing tokens.
            val activeTurnTs = _streamingTurnTs.value[sessionId]
            val shouldClearStreaming: Boolean = if (activeTurnTs == null) {
                // No active streaming turn recorded: safe to clear.
                true
            } else {
                val activeTurnMs = tsEpochMillis(activeTurnTs)
                val eventMs = tsEpochMillis(event.ts)
                if (activeTurnMs <= 0L || eventMs <= 0L) {
                    // Timestamps not comparable (unparseable); fall back to
                    // checking whether the broker says the turn is still active.
                    _statusBySession.value[sessionId]?.turnActive != true
                } else {
                    // Clear only when this event is the current turn or newer.
                    eventMs >= activeTurnMs
                }
            }
            if (shouldClearStreaming) {
                _streamingMessage.update { it - sessionId }
                _turnPhaseBySession.update { it - sessionId }
                _streamingTurnTs.update { it - sessionId }
                _thinkingBySession.update { it - sessionId }
                // Belt-and-suspenders: flush the oldest queued-turn entry now
                // that we know the turn settled (the reply IS the proof). This
                // handles the case where the status frame reporting
                // turnActive=false was missed or delayed across a reconnect.
                // Idempotent with flushOnTurnComplete (second call gets null).
                flushOnReply(sessionId)
            } else {
                Telemetry.breadcrumb(
                    "streaming", "replay skipped clear",
                    mapOf("session" to sessionId, "event_ts" to event.ts,
                        "turn_ts" to (activeTurnTs ?: "")),
                )
            }
        }
        _chatLog.value = _chatLog.value.toMutableMap().also { m ->
            m[sessionId] = (m[sessionId] ?: emptyList()) + event
        }
        // Memory telemetry: breadcrumb at milestones so Sentry has context
        // before a crash/hang caused by a large in-memory conversation store.
        val chatCount = _chatLog.value[sessionId]?.size ?: 0
        if (chatCount == 100 || chatCount == 500 || chatCount == 1000 || (chatCount > 1000 && chatCount % 2500 == 0)) {
            val convCount = _conversationLog.value[sessionId]?.size ?: 0
            Telemetry.breadcrumb("memory", "chat_log_milestone",
                mapOf("session" to sessionId, "chat" to chatCount.toString(), "conv" to convCount.toString()))
        }
        // Section D: best-effort recover from an agent auth 401 surfaced as
        // assistant text (string-match fallback; typed view_event deferred).
        // Also covers "result" role (mirror of iOS which checks both).
        if (event.role == "assistant" || event.role == "result") {
            detectAndHandleAgentAuth401(sessionId, event.content)
        }
        // A fresh turn invalidates the previous turn's AI chips (task
        // #233); the broker emits a new set after this turn completes.
        clearQuickReplies(sessionId)
        refreshConversation(sessionId)
    }

    /**
     * Section D: bidirectional agent-auth 401 handler called on every
     * assistant/result chat event.
     *
     * SET path: if the event looks like an agent auth 401 ("API Error: 401" +
     * "authenticat" / "Invalid authentication credentials" / "Failed to
     * authenticate"), set [_agentAuthFailure] for this session so the chat
     * banner appears, and best-effort auto-propagate the stored credential.
     * De-duped per session (agentAuthRecoveredSessions) so a burst does not
     * re-POST on every frame.
     *
     * CLEAR path (bidirectional fix, mirror of iOS PR #722): if the event is
     * NOT a 401, clear any standing failure flag for this session. This covers
     * the case where the user signs in out-of-band on the box and the agent
     * resumes — the next successful assistant reply clears the banner without
     * requiring the user to send a new turn. Mirror of iOS
     * `SessionStore.detectAgentAuthFailure`.
     */
    private fun detectAndHandleAgentAuth401(sessionId: String, content: String) {
        val lower = content.lowercase()
        val looksLike401 =
            (lower.contains("api error: 401") && lower.contains("authenticat")) ||
            lower.contains("invalid authentication credentials") ||
            lower.contains("failed to authenticate")
        if (!looksLike401) {
            // CLEAR path: a successful (non-401) assistant reply means the
            // agent recovered — dismiss the "Sign in on this box" banner.
            if (_agentAuthFailure.value.containsKey(sessionId)) {
                _agentAuthFailure.value = _agentAuthFailure.value - sessionId
                Telemetry.breadcrumb(
                    "agent-credentials",
                    "401 banner cleared — agent replied OK",
                    mapOf("session" to sessionId),
                )
            }
            return
        }
        // SET path: attribute the provider from the session assistant.
        val assistant = _sessions.value.firstOrNull { it.id == sessionId }?.assistant
        val provider = when (assistant?.lowercase()) {
            "claude" -> OAuthProvider.ANTHROPIC
            "codex" -> OAuthProvider.OPENAI
            else -> OAuthProvider.ANTHROPIC
        }
        // Update the banner flag (idempotent if provider unchanged).
        if (_agentAuthFailure.value[sessionId] != provider) {
            _agentAuthFailure.value = _agentAuthFailure.value + (sessionId to provider)
        }
        // De-dupe auto-recover per session so a burst doesn't re-POST.
        if (!agentAuthRecoveredSessions.add(sessionId)) return
        Telemetry.breadcrumb(
            "agent-credentials",
            "401 detected in chat",
            mapOf("session" to sessionId, "assistant" to (assistant ?: "unknown")),
        )
        val ctx = appContext
        val endpoint = _endpoint.value
        // Only re-push if we actually hold a stored credential for the
        // provider; otherwise the banner routes the user to sign in.
        val haveStored = ctx != null &&
            runCatching { OAuthStore.load(ctx, provider) }.getOrNull() != null
        if (!haveStored) {
            Telemetry.breadcrumb(
                "agent-credentials",
                "401 no stored credential to replay",
                mapOf("session" to sessionId, "provider" to provider.raw),
            )
            return
        }
        Telemetry.breadcrumb(
            "agent-credentials",
            "401 auto-recover propagating",
            mapOf("session" to sessionId, "provider" to provider.raw),
        )
        viewModelScope.launch { propagateStoredAgentCredentials(endpoint) }
    }

    override fun onViewEvent(sessionId: String, kind: String, payload: Map<String, String>) {
        when (kind) {
            "quick_replies" -> ingestQuickReplies(sessionId, payload)
            "session_title" -> ingestSessionTitle(sessionId, payload)
            "agents" -> ingestSubagents(sessionId, payload)
            "credential_source" -> ingestCredentialSource(sessionId, payload)
            "chat_streaming" -> ingestChatStreaming(sessionId, payload)
            "turn_phase" -> ingestTurnPhase(sessionId, payload)
            "thinking_streaming" -> ingestThinkingStreaming(sessionId, payload)
            else -> routeAgentLoginViewEvent(kind, payload)
        }
    }

    /**
     * Handle a chat_streaming view_event: store partial assistant content
     * as the in-memory streaming overlay. No-op if the payload is missing
     * required fields (old broker path).
     * Mirror of iOS SessionStore.ingestChatStreaming.
     */
    fun ingestChatStreaming(sessionId: String, payload: Map<String, String>) {
        val content = payload["content"] ?: return
        val turnTs = payload["turn_ts"] ?: return
        _streamingMessage.update { it + (sessionId to content) }
        // Record the turn timestamp so onChatEvent can skip clearing streaming
        // state for replayed older transcript messages during an active turn.
        _streamingTurnTs.update { it + (sessionId to turnTs) }
        Telemetry.breadcrumb(
            "streaming", "partial arrived",
            mapOf("turn_ts" to turnTs, "len" to content.length.toString(), "session" to sessionId),
        )
    }

    /**
     * Handle a turn_phase view_event: record the broker-reported turn phase
     * ("writing", "working", or "") for the given session. Used by the typing
     * indicator to show distinct states.
     * Mirror of iOS SessionStore.ingestTurnPhase.
     */
    fun ingestTurnPhase(sessionId: String, payload: Map<String, String>) {
        val phase = payload["turn_phase"] ?: ""
        _turnPhaseBySession.update { it + (sessionId to phase) }
        Telemetry.breadcrumb("turn_phase", phase.ifEmpty { "cleared" },
            mapOf("session" to sessionId))
    }

    /**
     * Handle a thinking_streaming view_event: store the accumulated reasoning
     * text for the current Claude turn. Ephemeral -- not persisted into the
     * transcript or conversationLog. Cleared alongside [_streamingMessage]
     * when the turn ends.
     * Mirror of iOS SessionStore.ingestThinkingStreaming.
     */
    fun ingestThinkingStreaming(sessionId: String, payload: Map<String, String>) {
        val content = payload["content"] ?: return
        _thinkingBySession.update { it + (sessionId to content) }
        Telemetry.breadcrumb(
            "thinking", "partial arrived",
            mapOf("len" to content.length.toString(), "session" to sessionId),
        )
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

    /**
     * Ingest a `credential_source` view_event from the broker. Stores the
     * source ("box" or "app_forwarded") so the chat view can show a subtle
     * banner when the app credential is being forwarded as a fallback because
     * the box is not logged in locally. Mirror of iOS
     * `SessionStore.ingestCredentialSource`.
     */
    fun ingestCredentialSource(sessionId: String, payload: Map<String, String>) {
        val source = payload["source"]?.takeIf { it.isNotEmpty() } ?: return
        _credentialSource.value = _credentialSource.value.toMutableMap().also { it[sessionId] = source }
        Telemetry.breadcrumb(
            "credential",
            "credential_source_received",
            mapOf("source" to source, "session" to sessionId),
        )
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
        // Mirror turn_phase from the status frame so reconnecting clients show
        // the correct indicator immediately without waiting for a view_event
        // replay (view_events are not buffered/replayed on reconnect).
        status.turnPhase?.let { phase ->
            _turnPhaseBySession.update { it + (status.session to phase) }
        }
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
        updateVisibleHarness()
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
                // Safety net: when turnActive transitions false, clear any
                // lingering streaming state. Covers cancelled turns and
                // clock-skew where no final onChatEvent arrives with a
                // matching ts to trigger the normal clear path. Mirror of
                // iOS ingestStatus safety net.
                _streamingMessage.update { it - status.session }
                _turnPhaseBySession.update { it - status.session }
                _streamingTurnTs.update { it - status.session }
                _thinkingBySession.update { it - status.session }
                Telemetry.breadcrumb(
                    "streaming", "cleared on turn-complete status",
                    mapOf("session" to status.session),
                )
            } else if (!nowActive &&
                _pendingChats.value.flushOnTurnComplete(status.session) != null &&
                _pendingChats.value.flushable(status.session).isEmpty()
            ) {
                // Level-triggered flush (deadlock fix): the app reconnected/
                // opened to a session that is ALREADY idle yet still holds a
                // queued-turn entry. Happens when the broker restarts mid-turn
                // — the app still believed turn_active=true (so the user's next
                // message was parked in "Queued Next"), but the recovered
                // session comes back idle, so the true→false edge above never
                // fires and neither the edge- nor reply-triggered flush runs.
                // Without this the queued message is stuck forever ("message
                // sent but the agent never picks it up" after every broker
                // restart). The empty flushable() guard keeps delivery
                // one-at-a-time. Mirror of iOS ingestStatus flush-on-idle.
                Telemetry.breadcrumb(
                    "chat", "flush-on-idle-status",
                    mapOf("session" to status.session),
                )
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
        // Mark any queued-turn entries as "failed" so the user sees the visual
        // indicator that these messages were not sent. The session is terminal;
        // queuedTurn entries cannot be retried. Clear the full queue after marking
        // so flushPendingChats never attempts delivery into a dead session.
        val queuedForExit = _pendingChats.value.queuedTurnEntries(sessionId)
        for (entry in queuedForExit) {
            setEchoStatus(sessionId, entry.localId, "failed")
        }
        if (queuedForExit.isNotEmpty()) {
            Telemetry.breadcrumb("chat", "exit cleared queued-turn entries",
                mapOf("session" to sessionId, "count" to queuedForExit.size.toString()))
            updatePendingChats { it.clear(sessionId) }
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
        // Box-switch flicker: a superseded old client's onDisconnected is now
        // dropped upstream by GenerationGuardedDelegate, so callbacks that reach
        // here belong to the CURRENT client and are genuine — handle them.
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
                updateVisibleHarness()
                attemptSshSelfHeal()
                return
            }
        }
        _harness.value = if (isAuthReason) {
            HarnessState.Failed("Pairing expired. Scan a new QR code from the server.")
        } else {
            HarnessState.Failed("Disconnected: $reason")
        }
        updateVisibleHarness()
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

    /**
     * Clear the transient "agent is working" state for a session when the
     * connection drops. A turn's in-flight status cannot be trusted across a
     * connection drop: the broker may have restarted and the turn is gone.
     * The authoritative reconnect status frame re-asserts turn_active=true if
     * a turn genuinely survived. This prevents the composer from being stuck
     * on the Stop button and the send gate from blocking all subsequent
     * messages until a force-quit (bug: stuck on Stop after broker restart).
     * Mirror of iOS [SessionStore.clearStaleTurnState].
     */
    private fun clearStaleTurnState(sessionId: String) {
        _statusBySession.value[sessionId]?.let { prev ->
            if (prev.turnActive == true) {
                _statusBySession.value = _statusBySession.value + (sessionId to prev.copy(turnActive = false))
            }
        }
        // Reset the edge-trigger so the next authoritative status frame is
        // not ignored (the detector compares against this stored value).
        _lastTurnActive[sessionId] = false
        _streamingMessage.update { it - sessionId }
        _turnPhaseBySession.update { it - sessionId }
        _streamingTurnTs.update { it - sessionId }
        _thinkingBySession.update { it - sessionId }
        Telemetry.breadcrumb("chat", "cleared stale turn state on disconnect",
            mapOf("session" to sessionId))
    }

    override fun onConnectionHealth(sessionId: String, health: ConnectionHealth) {
        _connectionHealth.value = _connectionHealth.value + (sessionId to health)
        when (health) {
            is ConnectionHealth.Connected -> {
                val newHarness = if (_sessionLifecycle.value.isNotEmpty()) {
                    HarnessState.Live
                } else {
                    HarnessState.Linked
                }
                _harness.value = newHarness
                // Change 4: record last-good harness; clear grace window suppression
                // so the banner returns to the real (connected) state immediately.
                lastReachableHarness = newHarness
                if (_suppressGraceReconnecting.value) {
                    _suppressGraceReconnecting.value = false
                    graceWindowJob?.cancel()
                    graceWindowJob = null
                    Telemetry.breadcrumb("session", "fg_grace_window_connected_cleared",
                        mapOf("session" to sessionId))
                }
                updateVisibleHarness()
                // Change 3: forced post-replay re-read for sessions marked at foreground.
                // Explicit bypass of PR #871 empty-log gate -- calls refreshConversation
                // directly (not through refreshSessions) so it always runs.
                val needsRefresh = synchronized(sessionsNeedingPostConnectRefresh) {
                    sessionsNeedingPostConnectRefresh.remove(sessionId)
                }
                if (needsRefresh) {
                    refreshConversation(sessionId)
                    Telemetry.breadcrumb("session", "fg_post_connect_refresh_fired",
                        mapOf("session" to sessionId))
                }
                // Promote any queuedTurn entries to normal so they are picked
                // up by flushPendingChats below. After a broker restart the
                // turn they were waiting on is gone; they should be re-delivered
                // now that the turn gate is clear (clearStaleTurnState zeroed it
                // on disconnect).
                updatePendingChats { it.promoteQueuedTurnToNormal(sessionId) }
                // Flush any `sent`-but-unacked messages for this session. The
                // Rust core's per-session reconnect worker fires this callback
                // when it re-establishes the WS (distinct from the app-level
                // connectInternal which also flushes all sessions). Without
                // this flush, messages whose WS write succeeded but whose
                // `chat_ack` arrived after the connection dropped stay stuck
                // in the `sent`/faded state forever -- the app-level flush
                // only runs on a full app-level reconnect, not Rust-layer
                // auto-reconnects. Calling flushPendingChats is idempotent:
                // if there is nothing to flush (normal initial connect) it is
                // a no-op.
                Telemetry.breadcrumb("chat", "flush on session reconnect",
                    mapOf("session" to sessionId))
                flushPendingChats(sessionId)
            }
            is ConnectionHealth.Connecting -> {
                _harness.value = HarnessState.Reconnecting(health.attempt, health.maxAttempts)
                // Stale-turn clearing must run immediately -- do NOT gate on grace window
                // (SAFETY: clearStaleTurnState must always run on connecting per #865).
                clearStaleTurnState(sessionId)
                // Change 4: start the "assume connected" grace window when the reconnect
                // cycle begins within ~5s of a foreground event. The banner stays at the
                // last-known-good state for ~4s; if Connected arrives first the job is
                // cancelled and no flicker is ever shown.
                val fg = foregroundedAt
                if (fg != null && System.currentTimeMillis() - fg < 5_000L
                    && !_suppressGraceReconnecting.value) {
                    _suppressGraceReconnecting.value = true
                    graceWindowJob?.cancel()
                    graceWindowJob = viewModelScope.launch {
                        delay(4_000L)
                        _suppressGraceReconnecting.value = false
                        updateVisibleHarness()
                        Telemetry.breadcrumb("session", "fg_grace_window_expired",
                            mapOf("session" to sessionId))
                    }
                    Telemetry.breadcrumb("session", "fg_grace_window_started",
                        mapOf("session" to sessionId))
                }
                updateVisibleHarness()
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
                    clearStaleTurnState(sessionId)
                    onDisconnected(health.reason)
                }
            }
        }
    }

    /**
     * The broker acked durable receipt of a chat we sent (task K). The
     * [clientMsgId] is the optimistic echo's `localId`. Drop the entry from the
     * persisted outbox (so it is NOT re-sent) and flip the transcript echo to
     * `done` (solid bubble). Idempotent: a duplicate ack (e.g. a resend whose
     * first ack we missed) just no-ops once the entry is gone.
     */
    override fun onChatDelivered(sessionId: String, clientMsgId: String) {
        Telemetry.breadcrumb("chat", "broker ack — delivered",
            mapOf("session" to sessionId, "local_id" to clientMsgId))
        updatePendingChats { it.markDelivered(sessionId, clientMsgId) }
        setEchoStatus(sessionId, clientMsgId, "done")
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

    /** True when the error is a TCP connection-refused — the SSH tunnel or
     *  broker is dead but harness still reports Live. Callers trigger
     *  SSH self-heal instead of surfacing a cryptic error. */
    fun isConnectionRefused(t: Throwable): Boolean {
        val text = (t.message ?: t.toString()).lowercase()
        return text.contains("connection refused") || text.contains("os error 61") || text.contains("econnrefused")
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
            when (val st = s.status) {
                is SavedServerStatus.Ready -> o.put("status", "ready")
                is SavedServerStatus.Failed -> {
                    val so = JSONObject()
                    so.put("state", "failed")
                    so.put("reason", st.reason)
                    o.put("status", so)
                }
                null -> { /* omit key -- backward-compat default */ }
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
                    val decodedStatus: SavedServerStatus? = run {
                        val st = o.opt("status")
                        when {
                            st == null -> null
                            st is String && st == "ready" -> SavedServerStatus.Ready
                            st is JSONObject -> {
                                val state = st.optString("state", "")
                                if (state == "failed") SavedServerStatus.Failed(st.optString("reason", ""))
                                else null
                            }
                            else -> null
                        }
                    }
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
                            status = decodedStatus,
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
