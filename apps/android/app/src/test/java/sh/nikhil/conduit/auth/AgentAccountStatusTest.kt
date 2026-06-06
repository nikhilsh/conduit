package sh.nikhil.conduit.auth

import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Plan-badge derivation for the Settings → Accounts rows (Round-2 fix 3).
 * Pure decode logic — no Android deps, no network.
 */
class AgentAccountStatusTest {

    private fun jwtWithPayload(payloadJson: String): String {
        val enc = Base64.getUrlEncoder().withoutPadding()
        val header = enc.encodeToString("""{"alg":"none"}""".toByteArray())
        val payload = enc.encodeToString(payloadJson.toByteArray())
        return "$header.$payload.sig"
    }

    @Test
    fun chatgptPlanTypeReadsAuthClaim() {
        val jwt = jwtWithPayload(
            """{"https://api.openai.com/auth":{"chatgpt_plan_type":"pro","user_id":"u"}}""",
        )
        assertEquals("pro", AgentAccountStatus.chatgptPlanType(jwt))
    }

    @Test
    fun chatgptPlanTypeNullWhenClaimMissing() {
        assertNull(AgentAccountStatus.chatgptPlanType(jwtWithPayload("""{"sub":"u"}""")))
        assertNull(AgentAccountStatus.chatgptPlanType("not-a-jwt"))
        assertNull(AgentAccountStatus.chatgptPlanType(""))
    }

    @Test
    fun planLabelUppercasesClaudeSubscription() {
        val credential = OAuthCredential.Anthropic(
            ClaudeCredentialsJson(
                claudeAiOauth = ClaudeCredentialsJson.ClaudeAiOauth(
                    accessToken = "a",
                    refreshToken = "r",
                    expiresAt = 0L,
                    scopes = emptyList(),
                    subscriptionType = "max",
                ),
            ),
        )
        assertEquals("MAX", AgentAccountStatus.planLabel(credential))
    }

    @Test
    fun planLabelNullWhenClaudeSubscriptionAbsent() {
        val credential = OAuthCredential.Anthropic(
            ClaudeCredentialsJson(
                claudeAiOauth = ClaudeCredentialsJson.ClaudeAiOauth(
                    accessToken = "a",
                    refreshToken = "r",
                    expiresAt = 0L,
                    scopes = emptyList(),
                    subscriptionType = null,
                ),
            ),
        )
        assertNull(AgentAccountStatus.planLabel(credential))
    }
}
