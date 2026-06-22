package sh.nikhil.conduit

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.nikhil.conduit.auth.OAuthProvider
import uniffi.conduit_core.ChatEvent

/**
 * Pins the bidirectional agent-auth 401 banner (iOS PR #722 parity).
 *
 * The banner is SET when an incoming assistant/result event matches the
 * 401/auth-failure string markers, and CLEARED when a subsequent
 * assistant event does NOT match (agent recovered out-of-band). It is
 * also CLEARED when the user sends a new turn (sendChat).
 *
 * Tests run without hydrate() so we stay on the JVM classpath.
 */
class AgentAuth401BannerTest {

    private fun chatEvent(
        role: String = "assistant",
        content: String,
        ts: String = "2026-06-22T12:00:00Z",
    ): ChatEvent = ChatEvent(
        role = role,
        content = content,
        ts = ts,
        files = emptyList(),
    )

    // --- SET path ---

    @Test
    fun `401 apiError marker sets banner`() {
        val store = SessionStore()
        store.onChatEvent("s1", chatEvent(content = "API Error: 401. Please authenticat again."))
        assertNotNull("banner should be set for 401", store.agentAuthFailure.value["s1"])
    }

    @Test
    fun `invalid authentication credentials sets banner`() {
        val store = SessionStore()
        store.onChatEvent("s1", chatEvent(content = "Invalid authentication credentials provided."))
        assertNotNull(store.agentAuthFailure.value["s1"])
    }

    @Test
    fun `failed to authenticate sets banner`() {
        val store = SessionStore()
        store.onChatEvent("s1", chatEvent(content = "Failed to authenticate with the provider."))
        assertNotNull(store.agentAuthFailure.value["s1"])
    }

    @Test
    fun `api error 401 without authenticat does NOT set banner`() {
        // Require both "api error: 401" AND "authenticat" (iOS parity).
        val store = SessionStore()
        store.onChatEvent("s1", chatEvent(content = "The request returned HTTP 401."))
        assertNull(
            "bare '401' without auth framing must not set banner",
            store.agentAuthFailure.value["s1"],
        )
    }

    @Test
    fun `result role also sets banner`() {
        val store = SessionStore()
        store.onChatEvent("s1", chatEvent(role = "result", content = "Failed to authenticate."))
        assertNotNull(store.agentAuthFailure.value["s1"])
    }

    // --- CLEAR path (bidirectional) ---

    @Test
    fun `non-401 assistant event clears a previously set banner`() {
        val store = SessionStore()
        // Set the banner first.
        store.onChatEvent("s1", chatEvent(content = "Failed to authenticate."))
        assertNotNull("banner should be set", store.agentAuthFailure.value["s1"])
        // A normal (non-401) assistant reply clears it — agent recovered out-of-band.
        store.onChatEvent("s1", chatEvent(content = "Here is the result of your task."))
        assertNull("banner should be cleared after OK reply", store.agentAuthFailure.value["s1"])
    }

    @Test
    fun `non-401 event on session with no banner is a no-op`() {
        val store = SessionStore()
        store.onChatEvent("s1", chatEvent(content = "Everything is fine."))
        assertNull("no banner should appear for normal event", store.agentAuthFailure.value["s1"])
    }

    @Test
    fun `sendChat clears the banner`() {
        val store = SessionStore()
        store.onChatEvent("s1", chatEvent(content = "Failed to authenticate."))
        assertNotNull("banner should be set", store.agentAuthFailure.value["s1"])
        // User sends a new turn — banner must drop even before the reply arrives.
        store.sendChat("s1", "please retry")
        assertNull("banner must clear on user send", store.agentAuthFailure.value["s1"])
    }

    @Test
    fun `banner is scoped per session`() {
        val store = SessionStore()
        store.onChatEvent("s1", chatEvent(content = "Failed to authenticate."))
        store.onChatEvent("s2", chatEvent(content = "All good here."))
        assertNotNull("s1 should have a banner", store.agentAuthFailure.value["s1"])
        assertNull("s2 should not have a banner", store.agentAuthFailure.value["s2"])
    }

    @Test
    fun `clearing s2 does not touch s1 banner`() {
        val store = SessionStore()
        store.onChatEvent("s1", chatEvent(content = "Failed to authenticate."))
        store.onChatEvent("s2", chatEvent(content = "Failed to authenticate."))
        // s2 gets a good reply — only s2 banner clears.
        store.onChatEvent("s2", chatEvent(content = "Task completed successfully."))
        assertNotNull("s1 banner should still be set", store.agentAuthFailure.value["s1"])
        assertNull("s2 banner should be cleared", store.agentAuthFailure.value["s2"])
    }

    @Test
    fun `claude assistant maps to ANTHROPIC provider`() {
        val store = SessionStore()
        store.onChatEvent("s1", chatEvent(content = "Failed to authenticate."))
        // No sessions seeded -> falls back to ANTHROPIC (default).
        val provider = store.agentAuthFailure.value["s1"]
        assertTrue("default provider should be ANTHROPIC", provider == OAuthProvider.ANTHROPIC)
    }

    @Test
    fun `banner does not set for user role event`() {
        val store = SessionStore()
        // user role events are not processed by detectAndHandleAgentAuth401.
        store.onChatEvent("s1", chatEvent(role = "user", content = "Failed to authenticate."))
        assertNull("user role must not set banner", store.agentAuthFailure.value["s1"])
    }
}
