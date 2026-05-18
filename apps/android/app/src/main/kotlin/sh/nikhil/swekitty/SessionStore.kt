package sh.nikhil.swekitty

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.swe_kitty_core.ChatEvent
import uniffi.swe_kitty_core.PreviewInfo
import uniffi.swe_kitty_core.ProjectSession
import uniffi.swe_kitty_core.SessionStatus
import uniffi.swe_kitty_core.SweKittyClient
import uniffi.swe_kitty_core.SweKittyDelegate

sealed class ConnectionState {
    data object Disconnected : ConnectionState()
    data object Connecting : ConnectionState()
    data object Connected : ConnectionState()
    data class Failed(val reason: String) : ConnectionState()
}

data class Endpoint(val url: String = "", val token: String = "") {
    val isComplete get() = url.isNotBlank() && token.isNotBlank()
}

/**
 * v1 store: wraps SweKittyClient and bridges Rust delegate callbacks back onto
 * the main dispatcher as StateFlow updates. Replaced by Hilt-style DI in v2.
 */
class SessionStore : ViewModel(), SweKittyDelegate {

    private val _endpoint = MutableStateFlow(Endpoint())
    val endpoint: StateFlow<Endpoint> = _endpoint.asStateFlow()

    private val _connection = MutableStateFlow<ConnectionState>(ConnectionState.Disconnected)
    val connection: StateFlow<ConnectionState> = _connection.asStateFlow()

    private val _sessions = MutableStateFlow<List<ProjectSession>>(emptyList())
    val sessions: StateFlow<List<ProjectSession>> = _sessions.asStateFlow()

    private val _selectedId = MutableStateFlow<String?>(null)
    val selectedId: StateFlow<String?> = _selectedId.asStateFlow()

    private val _statusBySession = MutableStateFlow<Map<String, SessionStatus>>(emptyMap())
    val statusBySession: StateFlow<Map<String, SessionStatus>> = _statusBySession.asStateFlow()

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

    fun connect() {
        val e = _endpoint.value
        if (!e.isComplete) { _connection.value = ConnectionState.Failed("missing endpoint"); return }
        _connection.value = ConnectionState.Connecting
        val c = SweKittyClient(e.url, e.token)
        client = c
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { c.connect(this@SessionStore) }
                _connection.value = ConnectionState.Connected
                refreshSessions()
            } catch (t: Throwable) {
                _connection.value = ConnectionState.Failed(t.message ?: t.toString())
            }
        }
    }

    fun disconnect() {
        client?.disconnect()
        client = null
        _connection.value = ConnectionState.Disconnected
    }

    fun select(sessionId: String?) { _selectedId.value = sessionId }

    fun createSession(assistant: String, branch: String? = null) {
        val c = client ?: return
        viewModelScope.launch {
            try {
                val id = withContext(Dispatchers.IO) { c.createSession(assistant, branch) }
                refreshSessions()
                _selectedId.value = id
            } catch (t: Throwable) {
                _connection.value = ConnectionState.Failed("create_session: ${t.message}")
            }
        }
    }

    fun switchAgent(sessionId: String, assistant: String) {
        val c = client ?: return
        viewModelScope.launch {
            try { withContext(Dispatchers.IO) { c.switchAgent(sessionId, assistant) } }
            catch (t: Throwable) { _connection.value = ConnectionState.Failed("switch_agent: ${t.message}") }
        }
    }

    fun exit(sessionId: String) {
        val c = client ?: return
        viewModelScope.launch {
            runCatching { withContext(Dispatchers.IO) { c.exitSession(sessionId) } }
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

    private fun refreshSessions() {
        val c = client ?: return
        _sessions.value = c.listSessions()
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
        refreshSessions()
    }

    override fun onSnapshot(sessionId: String, gunzipped: ByteArray) {
        _terminalBuffer.value = _terminalBuffer.value + (sessionId to gunzipped)
    }

    override fun onExit(sessionId: String, code: Int) {
        // health → red via a synthetic status update; surfaced by ProjectScreen.
        _statusBySession.value[sessionId]?.let { prev ->
            _statusBySession.value = _statusBySession.value + (sessionId to prev.copy(
                phase = "exited($code)",
                health = "red",
            ))
        }
    }

    override fun onDisconnected(reason: String) {
        _connection.value = ConnectionState.Failed("disconnected: $reason")
    }

    companion object {
        private const val KEY_URL = "swekitty.endpoint.url"
        private const val KEY_TOKEN = "swekitty.endpoint.token"
    }
}
