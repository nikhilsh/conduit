package sh.nikhil.conduit.auth

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URI

/**
 * Android mirror of the iOS Swift Testing suite for
 * `AgentLoginCoordinator`. Locks down the state-machine transitions
 * + the inbound view_event dispatch contract so the two platforms
 * can't drift.
 *
 * The flow under test:
 *   1. `start(.openai)`           → state = WaitingForBrokerURL
 *   2. handleAgentLoginURL(...)   → state = AwaitingBrowserRedirect
 *   3. loopback delivers code     → state = ForwardingCallback
 *   4. handleAgentLoginComplete() → state = Succeeded
 *
 * Failure transitions: `handleAgentLoginFailed("reason")` →
 * `Failed("reason")`. `cancel()` from any non-terminal state →
 * `Cancelled` (plus a `cancel_agent_login` to the broker if a
 * session_token has been issued).
 *
 * Tests deliberately avoid `kotlinx-coroutines-test` so the gradle
 * dep surface doesn't have to grow. `runBlocking` on the dispatcher
 * the coordinator owns is enough to flush queued work for our
 * assertions; the in-memory fake transport never suspends.
 */
class AgentLoginCoordinatorTest {

    private class FakeTransport : AgentLoginTransport {
        val sentStarts = mutableListOf<String>()
        val sentCallbacks = mutableListOf<Pair<String, String>>()
        val sentCancels = mutableListOf<String>()

        override suspend fun sendStartAgentLogin(provider: String) {
            sentStarts += provider
        }

        override suspend fun sendAgentLoginCallback(sessionToken: String, queryString: String) {
            sentCallbacks += sessionToken to queryString
        }

        override suspend fun sendCancelAgentLogin(sessionToken: String) {
            sentCancels += sessionToken
        }
    }

    /**
     * Loopback double whose `start()` is a no-op — tests that only
     * need the state-machine transitions can use this without binding
     * a real socket.
     */
    private class NoopLoopback(port: Int) : AgentLoginLoopbackServer(port = port) {
        var stopped = false
        override fun start(
            timeoutMillis: Long,
            onCallback: (Result<CallbackResult>) -> Unit,
        ) { /* no-op */ }
        override fun stop() { stopped = true }
    }

    private fun newCoordinator(
        transport: AgentLoginTransport = FakeTransport(),
        loopbackFactory: (Int) -> AgentLoginLoopbackServer = { NoopLoopback(it) },
    ): AgentLoginCoordinator = AgentLoginCoordinator(
        transport = transport,
        loopbackFactory = loopbackFactory,
        // Unconfined: the launches inside `start()` / `cancel()`
        // resolve synchronously so `runBlocking { }` round-trips the
        // suspending transport call before we assert.
        scope = CoroutineScope(Dispatchers.Unconfined),
    )

    @Test
    fun start_sendsStartAgentLoginAndSetsWaitingState() = runBlocking {
        val transport = FakeTransport()
        val coord = newCoordinator(transport = transport)
        coord.start(AgentLoginProvider.OPENAI)
        assertEquals(listOf("openai"), transport.sentStarts)
        assertEquals(AgentLoginCoordinator.State.WaitingForBrokerURL, coord.state.value)
        assertEquals(AgentLoginProvider.OPENAI, coord.provider)
    }

    @Test
    fun handleAgentLoginURL_movesToAwaitingBrowserRedirect() {
        val coord = newCoordinator()
        coord.start(AgentLoginProvider.OPENAI)
        coord.handleAgentLoginURL(
            loopbackPort = 1455,
            sessionToken = "tok-1",
            authorizeUrl = URI.create("https://auth.openai.com/oauth/authorize?x=1"),
        )
        val s = coord.state.value
        assertTrue("expected AwaitingBrowserRedirect, got $s", s is AgentLoginCoordinator.State.AwaitingBrowserRedirect)
        s as AgentLoginCoordinator.State.AwaitingBrowserRedirect
        assertEquals(1455, s.loopbackPort)
        assertEquals("tok-1", s.sessionToken)
    }

    @Test
    fun handleAgentLoginComplete_resolvesToSucceeded() {
        val coord = newCoordinator()
        coord.handleAgentLoginURL(1455, "tok-1", URI.create("https://x/y?x=1"))
        coord.handleAgentLoginComplete()
        assertEquals(AgentLoginCoordinator.State.Succeeded, coord.state.value)
    }

    @Test
    fun handleAgentLoginFailed_resolvesToFailedWithReason() {
        val coord = newCoordinator()
        coord.handleAgentLoginFailed("token exchange failed")
        val s = coord.state.value
        assertTrue(s is AgentLoginCoordinator.State.Failed)
        s as AgentLoginCoordinator.State.Failed
        assertEquals("token exchange failed", s.reason)
    }

    @Test
    fun cancel_fromAwaitingBrowserRedirect_sendsCancelToBroker() = runBlocking {
        val transport = FakeTransport()
        val coord = newCoordinator(transport = transport)
        coord.handleAgentLoginURL(1455, "tok-2", URI.create("https://x/y?x=1"))
        coord.cancel()
        assertEquals(AgentLoginCoordinator.State.Cancelled, coord.state.value)
        assertEquals(listOf("tok-2"), transport.sentCancels)
    }

    @Test
    fun cancel_fromIdle_doesNotNotifyBroker() = runBlocking {
        val transport = FakeTransport()
        val coord = newCoordinator(transport = transport)
        coord.cancel()
        assertEquals(AgentLoginCoordinator.State.Cancelled, coord.state.value)
        assertTrue("idle cancel should not send to broker", transport.sentCancels.isEmpty())
    }
}
