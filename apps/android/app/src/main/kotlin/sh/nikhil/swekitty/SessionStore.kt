package sh.nikhil.swekitty

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
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import sh.nikhil.swekitty.auth.AgentCredentialEnvelope
import sh.nikhil.swekitty.auth.OAuthCredential
import sh.nikhil.swekitty.auth.OAuthRequest
import sh.nikhil.swekitty.state.NetworkReachabilityObserver
import sh.nikhil.swekitty.state.ReachabilityEvent
import sh.nikhil.swekitty.state.ReachabilityStatus
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import uniffi.swe_kitty_core.ChatEvent
import uniffi.swe_kitty_core.ConnectionHealth
import uniffi.swe_kitty_core.ConversationItem
import uniffi.swe_kitty_core.PreviewInfo
import uniffi.swe_kitty_core.ProjectSession
import uniffi.swe_kitty_core.SessionStatus
import uniffi.swe_kitty_core.SshCredentials
import uniffi.swe_kitty_core.SshException
import uniffi.swe_kitty_core.SshHostKeyDelegate
import uniffi.swe_kitty_core.SweKittyClient
import sh.nikhil.swekitty.auth.AgentLoginCoordinator
import uniffi.swe_kitty_core.SweKittyDelegate
import uniffi.swe_kitty_core.ViewEventFile
import uniffi.swe_kitty_core.sshBootstrap as ffiSshBootstrap
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
 * Pairs the in-flight [OAuthRequest] (PKCE verifier + state, kept in
 * memory only) with the redirect [android.net.Uri] delivered to
 * MainActivity by the `swekitty://oauth/...` intent filter. The
 * [AgentLoginSheet] observes [SessionStore.oauthCallback] and drives
 * the token exchange when both halves are present.
 */
data class PendingOAuthCallback(
    val request: OAuthRequest,
    val uri: android.net.Uri,
)

data class SavedServer(
    val id: String,
    val name: String,
    val endpoint: Endpoint,
    val isDefault: Boolean,
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
 * v1 store: wraps SweKittyClient and bridges Rust delegate callbacks back onto
 * the main dispatcher as StateFlow updates. Replaced by Hilt-style DI in v2.
 */
class SessionStore : ViewModel(), SweKittyDelegate {

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

    /** Banner-style error for the most recent session-creation failure. */
    private val _sessionCreationError = MutableStateFlow<String?>(null)
    val sessionCreationError: StateFlow<String?> = _sessionCreationError.asStateFlow()

    private val _terminalBuffer = MutableStateFlow<Map<String, ByteArray>>(emptyMap())
    val terminalBuffer: StateFlow<Map<String, ByteArray>> = _terminalBuffer.asStateFlow()

    private val _chatLog = MutableStateFlow<Map<String, List<ChatEvent>>>(emptyMap())
    val chatLog: StateFlow<Map<String, List<ChatEvent>>> = _chatLog.asStateFlow()
    private val _conversationLog = MutableStateFlow<Map<String, List<ConversationItem>>>(emptyMap())
    val conversationLog: StateFlow<Map<String, List<ConversationItem>>> = _conversationLog.asStateFlow()

    private val _previews = MutableStateFlow<Map<String, PreviewInfo>>(emptyMap())
    val previews: StateFlow<Map<String, PreviewInfo>> = _previews.asStateFlow()

    /** Per-session connection health from the Rust reconnect worker. */
    private val _connectionHealth = MutableStateFlow<Map<String, ConnectionHealth>>(emptyMap())
    val connectionHealth: StateFlow<Map<String, ConnectionHealth>> = _connectionHealth.asStateFlow()

    /** SSH-bootstrap progress, observed by the SSH login sheet. */
    private val _sshBootstrap = MutableStateFlow<SshBootstrapState>(SshBootstrapState.Idle)
    val sshBootstrap: StateFlow<SshBootstrapState> = _sshBootstrap.asStateFlow()

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
     * Routed in from MainActivity when an `swekitty://oauth/...`
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
     * `SweKittyClient.setAgentCredentials(_:blob:)`.
     *
     * Status note (Stage 0/1 spike): the Rust core hasn't yet
     * exposed an arbitrary-control-message send path
     * (`SweKittyClient.send_input` / `send_chat` are per-session
     * only — there's no `send_json` on the public surface). Until
     * that lands we log the envelope JSON to logcat so on-device
     * QA can eyeball the wire format. The envelope-builder + the
     * call site are both load-bearing for the eventual broker
     * round-trip — they just don't transit a socket yet. Mirrors
     * iOS, which currently `print()`s the credential and defers
     * the WS send to Stage 2.
     */
    fun sendAgentCredentials(credential: OAuthCredential) {
        val envelope = AgentCredentialEnvelope.build(credential)
        android.util.Log.i(
            "SessionStore",
            "set_agent_credentials envelope (${credential.provider.raw}): $envelope",
        )
        // TODO(stage-2): wire to a raw `client?.sendJson(envelope)`
        // once the UDL exposes one. The envelope is already the exact
        // shape PLAN §D.1 specifies; flipping this to a real send is
        // a one-line change.
    }

    // Agent OAuth login v2 (outbound) — forward the three control frames
    // through the Rust client. Identity-scoped, carried over any live
    // session WS. Throw if no client is connected so the coordinator
    // surfaces a `.Failed`. Mirror of iOS SessionStore.sendAgentLogin*.

    suspend fun sendAgentLoginStart(provider: String) {
        val c = client ?: throw IllegalStateException("no active swe-kitty client")
        c.startAgentLogin(provider)
    }

    suspend fun sendAgentLoginCallback(sessionToken: String, queryString: String) {
        val c = client ?: throw IllegalStateException("no active swe-kitty client")
        c.agentLoginCallback(sessionToken, queryString)
    }

    suspend fun sendAgentLoginCancel(sessionToken: String) {
        val c = client ?: throw IllegalStateException("no active swe-kitty client")
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

    fun displayName(session: ProjectSession): String =
        _displayNames.value[session.id] ?: session.name

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
     * docs/PLAN-LITTER-UI.md Stage 3 flagged a Rust `fork_session`
     * UDL method as a future optimization, but client-side is enough.
     */
    fun forkSession(sessionId: String) {
        val c = client ?: return
        val original = _sessions.value.firstOrNull { it.id == sessionId } ?: return
        viewModelScope.launch {
            try {
                val newId = withContext(Dispatchers.IO) {
                    c.createSession(original.assistant, original.branch)
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
     * Parse a `swekitty://...` URL, save the endpoint, connect, and
     * arm `pendingAgentPick` so the picker sheet shows automatically.
     * Called from MainActivity on intent.data arrival.
     */
    fun applyDeepLink(raw: String) {
        val parsed = sh.nikhil.swekitty.PairingURL.parse(raw) ?: return
        val ep = Endpoint(url = parsed.endpoint, token = parsed.token)
        setEndpoint(ep.url, ep.token)
        upsertSavedServer(name = ep.displayHost, endpoint = ep, makeDefault = true)
        disconnect()
        connect()
        _pendingAgentPick.value = PendingAgentPick(hostNote = ep.displayHost)
    }

    /** Wired by the bridge; consumed by the dialog's Accept/Reject buttons. */
    @Volatile private var hostKeyResolver: ((Boolean) -> Unit)? = null

    private var hostKeyTrustStore: SshHostKeyTrustStore? = null

    private var client: SweKittyClient? = null
    private var prefs: android.content.SharedPreferences? = null
    private var reachability: NetworkReachabilityObserver? = null
    private val lifecycleObserver = object : DefaultLifecycleObserver {
        override fun onResume(owner: LifecycleOwner) {
            // App came back from background — local sockets may be
            // silently dead. Nudge every worker into reconnect.
            client?.notifyNetworkChange()
        }
    }

    fun hydrate(ctx: Context) {
        if (prefs == null) {
            val master = MasterKey.Builder(ctx)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            prefs = EncryptedSharedPreferences.create(
                ctx,
                "swekitty-endpoint",
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
            refreshRecentDirectories()
            if (_endpoint.value.isComplete && _savedServers.value.none { it.endpoint == _endpoint.value }) {
                upsertSavedServer(_endpoint.value.displayHost, _endpoint.value, makeDefault = true)
            }
            installNetworkAndLifecycleHooks(ctx.applicationContext)
            hostKeyTrustStore = SshHostKeyTrustStore.forContext(ctx.applicationContext)
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

    fun upsertSavedServer(name: String, endpoint: Endpoint, makeDefault: Boolean) {
        val current = _savedServers.value.toMutableList()
        val existing = current.indexOfFirst { it.endpoint == endpoint }
        if (existing >= 0) {
            val defaultFlag = if (makeDefault) true else current[existing].isDefault
            current[existing] = current[existing].copy(name = name, isDefault = defaultFlag)
        } else {
            current += SavedServer(
                id = UUID.randomUUID().toString(),
                name = if (name.isBlank()) endpoint.displayHost else name,
                endpoint = endpoint,
                isDefault = makeDefault || current.isEmpty(),
            )
        }
        if (makeDefault) {
            val defaultId = current.firstOrNull { it.endpoint == endpoint }?.id
            for (i in current.indices) current[i] = current[i].copy(isDefault = current[i].id == defaultId)
        }
        _savedServers.value = current
        persistSavedServers(current)
    }

    fun selectSavedServer(serverId: String, autoConnect: Boolean) {
        val server = _savedServers.value.firstOrNull { it.id == serverId } ?: return
        val next = _savedServers.value.map { it.copy(isDefault = it.id == serverId) }
        _savedServers.value = next
        persistSavedServers(next)
        setEndpoint(server.endpoint.url, server.endpoint.token)
        if (autoConnect) {
            disconnect()
            connect()
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
        val c = SweKittyClient(e.url, e.token)
        client = c
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { c.connect(this@SessionStore) }
                _harness.value = HarnessState.Linked
                refreshSessions()
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
        client?.disconnect()
        client = null
        _harness.value = HarnessState.Disconnected
    }

    fun reconnect() {
        disconnect()
        connect()
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
        _sshBootstrap.value = SshBootstrapState.Running("Connecting to $user@$host:$port…")
        val bridge = SshHostKeyBridge(this, host, port)
        viewModelScope.launch {
            val preToken = java.util.UUID.randomUUID().toString()
            try {
                _sshBootstrap.value = SshBootstrapState.Running("Starting harness on $host…")
                val result = withContext(Dispatchers.IO) {
                    ffiSshBootstrap(
                        credentials,
                        preToken,
                        anthropicApiKey,
                        openaiApiKey,
                        imageRef,
                        bridge,
                    )
                }
                val url = "ws://127.0.0.1:${result.localPort.toInt()}"
                val token = result.token
                val endpoint = Endpoint(url, token)
                val name = serverName?.takeIf { it.isNotBlank() } ?: "$user@$host"
                setEndpoint(url, token)
                upsertSavedServer(name = name, endpoint = endpoint, makeDefault = true)
                disconnect()
                connect()
                _sshBootstrap.value = SshBootstrapState.Idle
            } catch (e: SshException) {
                val detail = describeSsh(e)
                _sshBootstrap.value = SshBootstrapState.Failed(detail)
                Telemetry.capture(
                    error = e,
                    message = "Android SSH bootstrap failed",
                    tags = mapOf("surface" to "android", "phase" to "ssh_bootstrap", "code" to sshCode(e)),
                    extras = mapOf("host" to host, "user" to user, "detail" to detail),
                )
            } catch (t: Throwable) {
                val detail = t.message ?: t.toString()
                _sshBootstrap.value = SshBootstrapState.Failed(detail)
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

    private fun describeSsh(e: SshException): String = when (e) {
        is SshException.Dial                -> "Couldn't reach the host: ${e.message}"
        is SshException.Handshake           -> "SSH handshake failed: ${e.message}"
        is SshException.HostKeyRejected     -> "Host key rejected: ${e.message}"
        is SshException.AuthFailed          -> "Authentication failed: ${e.message}"
        is SshException.DockerMissing       -> "Docker is not installed on the server: ${e.message}"
        is SshException.DockerPermission    -> "User can't reach Docker: ${e.message}"
        is SshException.PortConflict        -> "Server port is already in use: ${e.message}"
        is SshException.HarnessStartTimeout -> "Harness took too long to come up: ${e.message}"
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
                _harness.value = HarnessState.Failed("Connect/start failed: harness did not become ready in time.")
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
            is SessionLifecycle.FailedToStart,
            null -> false
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
        initialPrompt: String? = null,
    ) {
        val c = client ?: return
        _sessionCreationError.value = null
        val pendingId = "pending-${UUID.randomUUID()}"
        updateLifecycle { it + (pendingId to SessionLifecycle.Creating) }
        viewModelScope.launch {
            try {
                val id = withContext(Dispatchers.IO) { c.createSession(assistant, branch) }
                startupCwd?.trim()?.takeIf { it.isNotEmpty() }?.let { cwd ->
                    val cmd = "cd ${shellQuoted(cwd)} && pwd\n"
                    runCatching { withContext(Dispatchers.IO) { c.sendInput(id, cmd.toByteArray()) } }
                    rememberRecentDirectory(cwd)
                }
                initialPrompt?.trim()?.takeIf { it.isNotEmpty() }?.let { prompt ->
                    runCatching { withContext(Dispatchers.IO) { c.sendChat(id, prompt) } }
                }
                updateLifecycle { (it - pendingId) + (id to SessionLifecycle.Live) }
                _harness.value = HarnessState.Live
                refreshSessions()
                _selectedId.value = id
            } catch (t: Throwable) {
                val reason = describe(t)
                updateLifecycle { it + (pendingId to SessionLifecycle.FailedToStart(reason)) }
                _sessionCreationError.value = reason
                if (isAuth(t)) {
                    _harness.value = HarnessState.Failed("Pairing expired. Scan a new QR code from the harness.")
                }
                Telemetry.capture(
                    error = t,
                    message = "Android create session failed",
                    tags = mapOf("surface" to "android", "phase" to "create_session", "assistant" to assistant),
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
                    _harness.value = HarnessState.Failed("Pairing expired. Scan a new QR code from the harness.")
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

    fun exit(sessionId: String) {
        // Optimistic removal so the row disappears immediately. Previously
        // we cleared state only *after* the async exitSession +
        // refreshSessions round-trip, so the row lingered until the call
        // returned (read as laggy). Prune locally first; refreshSessions
        // re-pulls the live list afterward, so a failed exit self-corrects.
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
            // session on disk and the row reappeared / sessions piled up.
            // No live WS handle required, so it also works for exited rows.
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

    fun sendInput(sessionId: String, data: ByteArray) {
        val c = client ?: return
        viewModelScope.launch { runCatching { withContext(Dispatchers.IO) { c.sendInput(sessionId, data) } } }
    }

    fun sendChat(sessionId: String, msg: String) {
        val c = client ?: return
        // Optimistic local echo — harness doesn't loop user messages back
        // as onChatEvent, so the chat tab would stay empty until the
        // assistant replies. The `local-` id lets refreshConversation
        // preserve this entry until the server's typed log catches up.
        val ts = java.time.OffsetDateTime.now(java.time.ZoneOffset.UTC)
            .format(java.time.format.DateTimeFormatter.ISO_INSTANT)
        val item = ConversationItem(
            id = "local-${java.util.UUID.randomUUID()}",
            role = "user",
            kind = "message",
            status = "done",
            content = msg,
            ts = ts,
            files = emptyList(),
            toolName = null,
            command = null,
            exitCode = null,
            durationMs = null,
            diffSummary = null,
            pendingOptions = emptyList(),
        )
        _conversationLog.value = _conversationLog.value.toMutableMap().also { m ->
            m[sessionId] = (m[sessionId] ?: emptyList()) + item
        }
        _chatLog.value = _chatLog.value.toMutableMap().also { m ->
            m[sessionId] = (m[sessionId] ?: emptyList()) +
                ChatEvent(role = "user", content = msg, ts = ts, files = emptyList())
        }
        viewModelScope.launch { runCatching { withContext(Dispatchers.IO) { c.sendChat(sessionId, msg) } } }
    }

    suspend fun listDirectories(path: String?): RemoteDirectoryListing {
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
            return RemoteDirectoryListing(
                path = obj.optString("path", path ?: "~"),
                parent = obj.optString("parent", path ?: "~"),
                entries = entries,
            )
        }
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
    suspend fun fetchConversation(sessionID: String): List<ConversationItem> {
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
            return buildList {
                for (i in 0 until arr.length()) {
                    val e = arr.getJSONObject(i)
                    val role = e.optString("role", "")
                    val kind = if (role.lowercase() == "tool") "tool" else "message"
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
                            content = e.optString("content", ""),
                            ts = e.optString("ts", ""),
                            files = files,
                            toolName = null,
                            command = null,
                            exitCode = null,
                            durationMs = null,
                            diffSummary = null,
                            pendingOptions = emptyList(),
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
        val list = c.listSessions()
        _sessions.value = list
        for (s in list) {
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
                val merged = (items + stillPending).sortedBy { it.ts }
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

    // SweKittyDelegate — callbacks arrive on UniFFI worker threads; mutate
    // StateFlows directly (they're thread-safe) but no UI assumptions here.

    override fun onPtyData(sessionId: String, data: ByteArray) {
        _terminalBuffer.value = _terminalBuffer.value.toMutableMap().also { m ->
            val prev = m[sessionId] ?: ByteArray(0)
            m[sessionId] = prev + data
        }
    }

    override fun onChatEvent(sessionId: String, event: ChatEvent) {
        _chatLog.value = _chatLog.value.toMutableMap().also { m ->
            m[sessionId] = (m[sessionId] ?: emptyList()) + event
        }
        refreshConversation(sessionId)
    }

    override fun onViewEvent(sessionId: String, kind: String, payload: Map<String, String>) {
        routeAgentLoginViewEvent(kind, payload)
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
        val serverLabel = status.displayName?.trim()?.takeIf { it.isNotEmpty() }
            ?: status.sessionName?.trim()?.takeIf { it.isNotEmpty() }
        if (serverLabel != null && _displayNames.value[status.session] != serverLabel) {
            val next = _displayNames.value.toMutableMap()
            next[status.session] = serverLabel
            _displayNames.value = next
            prefs?.edit()?.putString(KEY_DISPLAY_NAMES, encodeDisplayNames(next))?.apply()
        }
        _harness.value = HarnessState.Live
        refreshSessions()
    }

    override fun onSnapshot(sessionId: String, gunzipped: ByteArray) {
        _terminalBuffer.value = _terminalBuffer.value + (sessionId to gunzipped)
    }

    override fun onExit(sessionId: String, code: Int) {
        updateLifecycle { it + (sessionId to SessionLifecycle.Exited(code)) }
        _statusBySession.value[sessionId]?.let { prev ->
            _statusBySession.value = _statusBySession.value + (sessionId to prev.copy(
                phase = "exited($code)",
                health = "red",
            ))
        }
    }

    override fun onDisconnected(reason: String) {
        // Preserve an existing "Pairing expired" diagnosis — the server tearing
        // down the socket right after an auth rejection is part of the same
        // failure, not a new one.
        val current = _harness.value
        if (current is HarnessState.Failed &&
            current.reason.lowercase().contains("pairing expired")
        ) {
            return
        }
        val lower = reason.lowercase()
        _harness.value = if (
            lower.contains("auth") || lower.contains("401") || lower.contains("unauthorized")
        ) {
            HarnessState.Failed("Pairing expired. Scan a new QR code from the harness.")
        } else {
            HarnessState.Failed("Disconnected: $reason")
        }
        Telemetry.capture(
            error = IllegalStateException(reason),
            message = "Android disconnected from harness",
            tags = mapOf(
                "surface" to "android",
                "phase" to "disconnect",
                "reason_code" to connectionReasonCode(reason),
            ),
            extras = mapOf(
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
                    _harness.value = HarnessState.Failed("Pairing expired. Scan a new QR code from the harness.")
                    Telemetry.capture(
                        error = IllegalStateException(health.reason),
                        message = "Android connection health auth failure",
                        tags = mapOf(
                            "surface" to "android",
                            "phase" to "connection_health",
                            "reason_code" to "auth_expired",
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
            return "Authentication failed. This pairing token has expired; scan a fresh QR code from the harness."
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
        private const val KEY_URL = "swekitty.endpoint.url"
        private const val KEY_TOKEN = "swekitty.endpoint.token"
        private const val KEY_SAVED_SERVERS = "swekitty.saved_servers"
        private const val KEY_RECENT_DIRS = "swekitty.recent_dirs_by_server"
        private const val KEY_DISPLAY_NAMES = "swekitty.session_display_names"

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
                    add(
                        SavedServer(
                            id = o.optString("id", UUID.randomUUID().toString()),
                            name = o.optString("name", ""),
                            endpoint = Endpoint(
                                o.optString("url", ""),
                                o.optString("token", ""),
                            ),
                            isDefault = o.optBoolean("default", false),
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

    private fun shellQuoted(raw: String): String {
        val escaped = raw.replace("'", "'\"'\"'")
        return "'$escaped'"
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
