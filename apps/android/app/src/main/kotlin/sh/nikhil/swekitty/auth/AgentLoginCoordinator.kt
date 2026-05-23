package sh.nikhil.swekitty.auth

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.net.URI

/**
 * Android mirror of iOS `AgentLoginCoordinator.swift`
 * (PLAN-AGENT-OAUTH.md "Approach v2" / Stage 3).
 *
 * Orchestrates the litter-faithful agent-login flow:
 *
 *   1. Send `start_agent_login` over WS.
 *   2. Wait for `agent_login_url` view_event from broker.
 *   3. Bind a local `127.0.0.1` loopback listener on the supplied port.
 *   4. Open the authorize URL in a Chrome Custom Tab
 *      (the View-layer's responsibility — the coordinator just hands
 *      back the URL via its `state`).
 *   5. When the browser redirects back to the loopback, ship the
 *      captured query string over WS via `agent_login_callback`.
 *   6. Wait for `agent_login_complete` and resolve.
 *
 * Concurrency: thread-safe state machine. Public methods can be called
 * from any thread; internal `loopback` / `state` mutations hold the
 * monitor. WS sends are launched on a `Dispatchers.IO` scope owned by
 * the coordinator so a caller doesn't have to thread a scope through.
 *
 * The actual UI wiring (sheet button → `start(...)`) plus a WS
 * dispatcher in `SessionStore` to route inbound `agent_login_*`
 * view_events to the active coordinator is a follow-up — this PR
 * ships the testable state machine + the protocol glue, exactly as
 * iOS Stage 0 (`apps/ios/Sources/Models/AgentLoginCoordinator.swift`)
 * landed.
 */
class AgentLoginCoordinator(
    private val transport: AgentLoginTransport,
    private val loopbackFactory: (port: Int) -> AgentLoginLoopbackServer = { AgentLoginLoopbackServer(it) },
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    /**
     * Internal state — exposed as a [StateFlow] so the Compose sheet
     * can `collectAsState` it. Mirror of iOS's `State` enum but on
     * Kotlin we use a sealed class so each variant can carry its own
     * payload without nullable side-channels.
     */
    sealed class State {
        data object Idle : State()
        data object WaitingForBrokerURL : State()
        data class AwaitingBrowserRedirect(
            val loopbackPort: Int,
            val sessionToken: String,
            val authorizeUrl: URI,
        ) : State()
        data class ForwardingCallback(val sessionToken: String) : State()
        data object Succeeded : State()
        data class Failed(val reason: String) : State()
        data object Cancelled : State()
    }

    private val lock = Any()

    /** Provider this coordinator is driving — set by [start]. */
    @Volatile var provider: AgentLoginProvider? = null
        private set

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()

    /**
     * Loopback listener handle — non-null only while we're in
     * `AwaitingBrowserRedirect`. Held on the coordinator so the
     * listener isn't GC'd if the sheet composable rebuilds.
     */
    private var loopback: AgentLoginLoopbackServer? = null

    /**
     * Kick off the v2 flow for [provider]. Returns immediately; the
     * flow advances asynchronously as the broker's view_events arrive
     * and the user completes the browser dance.
     */
    fun start(provider: AgentLoginProvider) {
        synchronized(lock) {
            this.provider = provider
            _state.value = State.WaitingForBrokerURL
        }
        scope.launch { transport.sendStartAgentLogin(provider.wireName) }
    }

    /**
     * Inbound `agent_login_url` view_event handler. Wired by the
     * SessionStore WS dispatcher. Binds the loopback BEFORE the View
     * layer is told to open the browser, so a very-fast OAuth
     * completion (cached browser session) doesn't redirect into a
     * void. Idempotent: a second event with a fresh token aborts the
     * previous attempt.
     */
    fun handleAgentLoginURL(
        loopbackPort: Int,
        sessionToken: String,
        authorizeUrl: URI,
    ) {
        val server = loopbackFactory(loopbackPort)
        try {
            server.start { result -> handleLoopbackResult(result, sessionToken) }
        } catch (t: Throwable) {
            synchronized(lock) { loopback = null }
            _state.value = State.Failed("Could not bind loopback :$loopbackPort: ${t.message ?: t::class.simpleName}")
            return
        }
        synchronized(lock) {
            loopback?.stop()
            loopback = server
            _state.value = State.AwaitingBrowserRedirect(loopbackPort, sessionToken, authorizeUrl)
        }
    }

    /** Inbound `agent_login_complete` view_event. */
    fun handleAgentLoginComplete() {
        synchronized(lock) {
            loopback?.stop()
            loopback = null
            _state.value = State.Succeeded
        }
    }

    /** Inbound `agent_login_failed` view_event. */
    fun handleAgentLoginFailed(reason: String) {
        fail(reason)
    }

    /**
     * User-driven cancel (sheet dismissed). Tears down local state
     * and notifies the broker so the CLI subprocess dies.
     */
    fun cancel() {
        val sessionTokenToCancel: String? = synchronized(lock) {
            loopback?.stop()
            loopback = null
            val token = when (val s = _state.value) {
                is State.AwaitingBrowserRedirect -> s.sessionToken
                is State.ForwardingCallback -> s.sessionToken
                else -> null
            }
            _state.value = State.Cancelled
            token
        }
        if (sessionTokenToCancel != null) {
            scope.launch {
                runCatching { transport.sendCancelAgentLogin(sessionTokenToCancel) }
            }
        }
    }

    private fun fail(reason: String) {
        synchronized(lock) {
            loopback?.stop()
            loopback = null
            _state.value = State.Failed(reason)
        }
    }

    private fun handleLoopbackResult(
        result: Result<AgentLoginLoopbackServer.CallbackResult>,
        sessionToken: String,
    ) {
        result.fold(
            onFailure = { fail(it.message ?: it::class.simpleName.orEmpty()) },
            onSuccess = { cb ->
                if (cb.errorReason.isNotEmpty()) {
                    fail("provider error: ${cb.errorReason}")
                    return
                }
                if (cb.code.isEmpty()) {
                    fail("loopback delivered no authorization code")
                    return
                }
                synchronized(lock) {
                    _state.value = State.ForwardingCallback(sessionToken)
                }
                scope.launch {
                    runCatching {
                        transport.sendAgentLoginCallback(sessionToken, cb.rawQueryString)
                    }.onFailure { fail("forward to broker failed: ${it.message}") }
                }
            },
        )
    }
}

/**
 * Provider identity for the v2 flow. Distinct from the v1
 * [OAuthClient]'s [OAuthProvider] enum so the deprecated v1 code path
 * keeps compiling during the migration. Stage 4 collapses the two.
 */
enum class AgentLoginProvider(val wireName: String) {
    /** OpenAI / `codex login`. */
    OPENAI("openai"),
    /** Anthropic / `claude auth login`. */
    ANTHROPIC("anthropic"),
}

/**
 * Wire-transport contract for the coordinator. Stage 1's SessionStore
 * implements this against the live WS; tests inject a fake that
 * records outbound payloads and exposes setters to synthesise inbound
 * view_events.
 */
interface AgentLoginTransport {
    suspend fun sendStartAgentLogin(provider: String)
    suspend fun sendAgentLoginCallback(sessionToken: String, queryString: String)
    suspend fun sendCancelAgentLogin(sessionToken: String)
}
