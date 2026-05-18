package sh.nikhil.swekitty

import android.content.Context
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
import java.util.UUID
import uniffi.swe_kitty_core.ChatEvent
import uniffi.swe_kitty_core.PreviewInfo
import uniffi.swe_kitty_core.ProjectSession
import uniffi.swe_kitty_core.SessionStatus
import uniffi.swe_kitty_core.SweKittyClient
import uniffi.swe_kitty_core.SweKittyDelegate

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
    data class Failed(val reason: String) : HarnessState()

    val isReachable: Boolean get() = this is Linked || this is Live
    val canIssueCommands: Boolean get() = isReachable
    val badgeLabel: String get() = when (this) {
        is Disconnected -> "Disconnected"
        is Connecting   -> "Connecting…"
        is Linked       -> "Ready"
        is Live         -> "Live"
        is Failed       -> "Offline"
    }
    val failureReason: String? get() = (this as? Failed)?.reason
}

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

    private val _previews = MutableStateFlow<Map<String, PreviewInfo>>(emptyMap())
    val previews: StateFlow<Map<String, PreviewInfo>> = _previews.asStateFlow()

    private var client: SweKittyClient? = null
    private var prefs: android.content.SharedPreferences? = null

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
        }
    }

    fun setEndpoint(url: String, token: String) {
        val e = Endpoint(url.trim(), token.trim())
        _endpoint.value = e
        prefs?.edit()
            ?.putString(KEY_URL, e.url)
            ?.putString(KEY_TOKEN, e.token)
            ?.apply()
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
                _harness.value = HarnessState.Failed(t.message ?: t.toString())
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

    fun clearSessionCreationError() {
        _sessionCreationError.value = null
    }

    fun select(sessionId: String?) { _selectedId.value = sessionId }

    fun createSession(assistant: String, branch: String? = null) {
        val c = client ?: return
        _sessionCreationError.value = null
        val pendingId = "pending-${UUID.randomUUID()}"
        updateLifecycle { it + (pendingId to SessionLifecycle.Creating) }
        viewModelScope.launch {
            try {
                val id = withContext(Dispatchers.IO) { c.createSession(assistant, branch) }
                updateLifecycle { (it - pendingId) + (id to SessionLifecycle.Live) }
                _harness.value = HarnessState.Live
                refreshSessions()
                _selectedId.value = id
            } catch (t: Throwable) {
                val reason = t.message ?: t.toString()
                updateLifecycle { it + (pendingId to SessionLifecycle.FailedToStart(reason)) }
                _sessionCreationError.value = reason
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
                _sessionCreationError.value = "switch_agent: ${t.message}"
            }
        }
    }

    fun exit(sessionId: String) {
        val c = client ?: return
        viewModelScope.launch {
            runCatching { withContext(Dispatchers.IO) { c.exitSession(sessionId) } }
            updateLifecycle { it - sessionId }
            refreshSessions()
            if (_selectedId.value == sessionId) _selectedId.value = null
        }
    }

    fun sendInput(sessionId: String, data: ByteArray) {
        val c = client ?: return
        viewModelScope.launch { runCatching { withContext(Dispatchers.IO) { c.sendInput(sessionId, data) } } }
    }

    fun sendChat(sessionId: String, msg: String) {
        val c = client ?: return
        viewModelScope.launch { runCatching { withContext(Dispatchers.IO) { c.sendChat(sessionId, msg) } } }
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
            if (_sessionLifecycle.value[s.id] == null) {
                updateLifecycle { it + (s.id to SessionLifecycle.Live) }
            }
        }
    }

    private fun updateLifecycle(transform: (Map<String, SessionLifecycle>) -> Map<String, SessionLifecycle>) {
        _sessionLifecycle.value = transform(_sessionLifecycle.value)
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
    }

    override fun onPreviewReady(sessionId: String, preview: PreviewInfo) {
        _previews.value = _previews.value + (sessionId to preview)
    }

    override fun onStatus(status: SessionStatus) {
        _statusBySession.value = _statusBySession.value + (status.session to status)
        status.preview?.let { _previews.value = _previews.value + (status.session to it) }
        if (_sessionLifecycle.value[status.session] == null ||
            _sessionLifecycle.value[status.session] is SessionLifecycle.Creating) {
            updateLifecycle { it + (status.session to SessionLifecycle.Live) }
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
        _harness.value = HarnessState.Failed("Disconnected: $reason")
    }

    companion object {
        private const val KEY_URL = "swekitty.endpoint.url"
        private const val KEY_TOKEN = "swekitty.endpoint.token"
    }
}
