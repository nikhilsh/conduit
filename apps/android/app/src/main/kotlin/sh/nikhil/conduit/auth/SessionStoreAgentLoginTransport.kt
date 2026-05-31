package sh.nikhil.conduit.auth

import sh.nikhil.conduit.SessionStore

/**
 * Concrete [AgentLoginTransport] backed by [SessionStore]'s Rust client.
 * Android mirror of iOS `SessionStoreAgentLoginTransport`. The store
 * methods forward to `ConduitClient.startAgentLogin` /
 * `agentLoginCallback` / `cancelAgentLogin` (bridged over UDL), carried
 * over any live session WS — identity-scoped, like set_agent_credentials.
 */
class SessionStoreAgentLoginTransport(
    private val store: SessionStore,
) : AgentLoginTransport {
    override suspend fun sendStartAgentLogin(provider: String) {
        store.sendAgentLoginStart(provider)
    }

    override suspend fun sendAgentLoginCallback(sessionToken: String, queryString: String) {
        store.sendAgentLoginCallback(sessionToken, queryString)
    }

    override suspend fun sendCancelAgentLogin(sessionToken: String) {
        store.sendAgentLoginCancel(sessionToken)
    }
}
