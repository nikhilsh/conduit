package sh.nikhil.swekitty.auth

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the wire shape of the `set_agent_credentials` envelope (PLAN
 * §D.1). Mirror of the iOS envelope assertions (forthcoming in iOS
 * Stage 2). The broker reads these keys verbatim — drift here is a
 * silent on-disk-file-format break, so each invariant is a separate
 * assertion to make the failure mode obvious.
 */
class AgentCredentialEnvelopeTest {

    private fun openAiSample() = OAuthCredential.OpenAi(
        AuthDotJson(
            authMode = "ChatGPT",
            openaiApiKey = null,
            tokens = AuthDotJson.TokenData(
                idToken = "i",
                accessToken = "a",
                refreshToken = "r",
                accountId = "acct-1",
            ),
            lastRefreshIso = "2026-05-22T08:00:00Z",
            agentIdentity = null,
        )
    )

    private fun anthropicSample() = OAuthCredential.Anthropic(
        ClaudeCredentialsJson(
            claudeAiOauth = ClaudeCredentialsJson.ClaudeAiOauth(
                accessToken = "sk-ant-oat01-aaa",
                refreshToken = "sk-ant-ort01-bbb",
                expiresAt = 1_700_000_000_000L,
                scopes = listOf("user:inference", "user:profile"),
                subscriptionType = "max",
            )
        )
    )

    @Test fun envelopeHasRequiredTopLevelKeys() {
        val json = AgentCredentialEnvelope.build(openAiSample(), timestampIso = "2026-05-22T08:00:00Z")
        assertTrue(json, json.contains("\"type\":\"set_agent_credentials\""))
        assertTrue(json, json.contains("\"ts\":\"2026-05-22T08:00:00Z\""))
        assertTrue(json, json.contains("\"provider\":\"openai\""))
        assertTrue(json, json.contains("\"kind\":\"oauth\""))
        assertTrue(json, json.contains("\"credential\":"))
    }

    @Test fun envelopeAnthropicCarriesProviderTag() {
        val json = AgentCredentialEnvelope.build(anthropicSample(), timestampIso = "2026-05-22T08:00:00Z")
        assertTrue(json, json.contains("\"provider\":\"anthropic\""))
        // The inner blob is the claude-cli on-disk shape verbatim — the
        // broker `cp`'s these bytes onto `.credentials.json` without
        // massaging, so the nested keys must match PLAN §B.1.
        assertTrue(json, json.contains("\"claudeAiOauth\""))
        assertTrue(json, json.contains("\"accessToken\":\"sk-ant-oat01-aaa\""))
        assertTrue(json, json.contains("\"refreshToken\":\"sk-ant-ort01-bbb\""))
        assertTrue(json, json.contains("\"expiresAt\":1700000000000"))
        assertTrue(json, json.contains("\"subscriptionType\":\"max\""))
    }

    @Test fun envelopeOpenAiPreservesNullOpenaiApiKey() {
        // PLAN §C.5: `OPENAI_API_KEY` is always emitted, null on the
        // ChatGPT path. The Stage 1 broker writes the inner blob to
        // disk byte-for-byte, so the explicit null has to survive the
        // envelope.
        val json = AgentCredentialEnvelope.build(openAiSample(), timestampIso = "2026-05-22T08:00:00Z")
        assertTrue(json, json.contains("\"OPENAI_API_KEY\":null"))
    }

    @Test fun envelopeAutogeneratesTimestampWhenAbsent() {
        // When the production caller omits `timestampIso`, the
        // envelope reads the wall clock and emits an ISO-8601 UTC
        // string. We can't pin the value but we can pin the shape.
        val json = AgentCredentialEnvelope.build(openAiSample(), timestampIso = null)
        val tsRegex = Regex("\"ts\":\"\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?Z\"")
        assertNotNull(
            "ts field missing or wrong shape: $json",
            tsRegex.find(json),
        )
    }

    @Test fun envelopeKindIsOAuthForBothProviders() {
        // `kind` is fixed to "oauth" today; reserved so a later
        // "api-key" path can add a sibling kind without breaking the
        // protocol.
        val a = AgentCredentialEnvelope.build(openAiSample())
        val b = AgentCredentialEnvelope.build(anthropicSample())
        assertTrue(a.contains("\"kind\":\"oauth\""))
        assertTrue(b.contains("\"kind\":\"oauth\""))
    }

    @Test fun providerRawTagsMatchPlanDocCases() {
        // PLAN §D.1 enumerates only "anthropic" and "openai" as
        // provider tags. Locking those here means flipping
        // OAuthProvider.raw would flip a contract test, not silently
        // mismatch the broker.
        assertEquals("openai", OAuthProvider.OPENAI.raw)
        assertEquals("anthropic", OAuthProvider.ANTHROPIC.raw)
    }
}
