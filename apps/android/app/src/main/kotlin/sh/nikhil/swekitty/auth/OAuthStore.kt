package sh.nikhil.swekitty.auth

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * EncryptedSharedPreferences wrapper for the per-user agent OAuth
 * credentials. Mirror of iOS `OAuthCredentialStore` (Keychain service
 * `sh.nikhil.swekitty.oauth`).
 *
 * Each provider's blob lives under its own pref key in its native
 * disk shape (`AuthDotJson` JSON for OpenAI, `ClaudeCredentialsJson`
 * JSON for Anthropic) — we don't wrap in a discriminated envelope on
 * disk because the pref key already names the provider, and the
 * Stage 2 broker will eventually want to lift the bytes straight onto
 * disk without unwrapping.
 *
 * Encryption is AES256-GCM via Android Keystore (matches the existing
 * `swekitty-endpoint` EncryptedSharedPreferences in `SessionStore`).
 */
object OAuthStore {
    private const val PREFS_NAME = "swekitty-agent-credentials"

    private fun prefs(context: Context): android.content.SharedPreferences {
        val master = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        return EncryptedSharedPreferences.create(
            context,
            PREFS_NAME,
            master,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    /** Persist the credential JSON for `provider`. */
    fun save(context: Context, credential: OAuthCredential) {
        prefs(context).edit()
            .putString(credential.provider.storageKey, credential.toJson())
            .apply()
    }

    /** Load and decode the credential for `provider`, or null if absent. */
    fun load(context: Context, provider: OAuthProvider): OAuthCredential? {
        val raw = prefs(context).getString(provider.storageKey, null) ?: return null
        return decode(provider, raw)
    }

    /** Wipe the credential for `provider`. */
    fun clear(context: Context, provider: OAuthProvider) {
        prefs(context).edit().remove(provider.storageKey).apply()
    }

    /**
     * Pure decode for tests + the WS-refresh path. Returns null on
     * malformed JSON rather than throwing — the UI surfaces the
     * absence as "please re-login" rather than a parse trace.
     */
    fun decode(provider: OAuthProvider, json: String): OAuthCredential? {
        return runCatching {
            when (provider) {
                OAuthProvider.OPENAI -> OAuthCredential.OpenAi(decodeAuthDotJson(json))
                OAuthProvider.ANTHROPIC -> OAuthCredential.Anthropic(decodeClaudeCredentialsJson(json))
            }
        }.getOrNull()
    }

    private fun decodeAuthDotJson(raw: String): AuthDotJson {
        val obj = org.json.JSONObject(raw)
        val authMode = obj.optString("auth_mode", "").takeIf { it.isNotEmpty() }
        val openaiApiKey = if (obj.has("OPENAI_API_KEY") && !obj.isNull("OPENAI_API_KEY"))
            obj.getString("OPENAI_API_KEY") else null
        val tokens = obj.optJSONObject("tokens")?.let { t ->
            AuthDotJson.TokenData(
                idToken = t.optString("id_token", ""),
                accessToken = t.optString("access_token", ""),
                refreshToken = t.optString("refresh_token", ""),
                accountId = t.optString("account_id", "").takeIf { it.isNotEmpty() },
            )
        }
        val lastRefresh = obj.optString("last_refresh", "").takeIf { it.isNotEmpty() }
        val agentIdentity = obj.optString("agent_identity", "").takeIf { it.isNotEmpty() }
        return AuthDotJson(
            authMode = authMode,
            openaiApiKey = openaiApiKey,
            tokens = tokens,
            lastRefreshIso = lastRefresh,
            agentIdentity = agentIdentity,
        )
    }

    private fun decodeClaudeCredentialsJson(raw: String): ClaudeCredentialsJson {
        val obj = org.json.JSONObject(raw).getJSONObject("claudeAiOauth")
        val scopes = obj.optJSONArray("scopes")?.let { arr ->
            List(arr.length()) { arr.optString(it, "") }.filter { it.isNotEmpty() }
        } ?: emptyList()
        return ClaudeCredentialsJson(
            claudeAiOauth = ClaudeCredentialsJson.ClaudeAiOauth(
                accessToken = obj.optString("accessToken", ""),
                refreshToken = obj.optString("refreshToken", ""),
                expiresAt = obj.optLong("expiresAt", 0L),
                scopes = scopes,
                subscriptionType = obj.optString("subscriptionType", "").takeIf { it.isNotEmpty() },
            )
        )
    }
}
