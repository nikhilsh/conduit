package sh.nikhil.conduit.auth

import android.content.Context
import org.json.JSONObject
import java.util.Base64

/**
 * Signed-in state + plan badge for the per-agent account rows in Settings →
 * Accounts (Round-2 fix 3, Conduit_Fixes_Handoff images 05→06). Derived
 * entirely from the locally stored OAuth credential ([OAuthStore]) — no
 * network, no new data flow. Claude's credential JSON carries
 * `subscriptionType` ("max" / "pro" / "team"); Codex encodes
 * `chatgpt_plan_type` inside the id_token's `https://api.openai.com/auth`
 * claim. Where the provider omitted the plan we show no badge rather than
 * fabricating one. Mirror of iOS `AgentAccountStatus`.
 */
data class AgentAccountStatus(
    /** UI agent key — drives tint + avatar ("claude" / "codex"). */
    val agent: String,
    val provider: OAuthProvider,
    /** Friendly row title ("Claude" / "Codex"). */
    val displayName: String,
    val signedIn: Boolean,
    /** Uppercase plan badge ("MAX" / "PRO" / "PLUS" …) — null hides it. */
    val planLabel: String?,
) {
    companion object {
        /** Current status for both agent accounts, Claude first. */
        fun current(context: Context): List<AgentAccountStatus> = listOf(
            load(context, agent = "claude", displayName = "Claude", provider = OAuthProvider.ANTHROPIC),
            load(context, agent = "codex", displayName = "Codex", provider = OAuthProvider.OPENAI),
        )

        private fun load(
            context: Context,
            agent: String,
            displayName: String,
            provider: OAuthProvider,
        ): AgentAccountStatus {
            val credential = runCatching { OAuthStore.load(context, provider) }.getOrNull()
            return AgentAccountStatus(
                agent = agent,
                provider = provider,
                displayName = displayName,
                signedIn = credential != null,
                planLabel = credential?.let(::planLabel),
            )
        }

        /** Plan badge text from a stored credential, uppercased. */
        fun planLabel(credential: OAuthCredential): String? = when (credential) {
            is OAuthCredential.Anthropic ->
                credential.blob.claudeAiOauth.subscriptionType
                    ?.trim()?.takeIf { it.isNotEmpty() }?.uppercase()
            is OAuthCredential.OpenAi ->
                credential.blob.tokens?.idToken?.let(::chatgptPlanType)?.uppercase()
        }

        /**
         * Reads `chatgpt_plan_type` out of the id_token's
         * `https://api.openai.com/auth` claim. UNVERIFIED decode (no
         * signature check) — display-only metadata, never used for auth
         * decisions.
         */
        fun chatgptPlanType(jwt: String): String? {
            val parts = jwt.split(".")
            if (parts.size < 2) return null
            return runCatching {
                // java.util (minSdk 26) rather than android.util so the
                // decode stays pure-JVM unit-testable.
                val payload = Base64.getUrlDecoder().decode(parts[1].trimEnd('='))
                val auth = JSONObject(String(payload, Charsets.UTF_8))
                    .optJSONObject("https://api.openai.com/auth") ?: return null
                auth.optString("chatgpt_plan_type", "").takeIf { it.isNotEmpty() }
            }.getOrNull()
        }
    }
}
