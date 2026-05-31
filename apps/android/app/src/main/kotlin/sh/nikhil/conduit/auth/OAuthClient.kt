package sh.nikhil.conduit.auth

import android.content.Context
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import okhttp3.FormBody
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.TimeUnit

/**
 * Android port of `apps/ios/Sources/Models/OAuthClient.swift` (Stages
 * 0–1 of `docs/PLAN-AGENT-OAUTH.md`). Drives PKCE S256 →
 * Chrome Custom Tabs → token exchange against the provider's
 * `/oauth/token` endpoint. Returns an `OAuthCredential` whose payload
 * matches what the CLI persists on disk (`~/.codex/auth.json` for
 * OpenAI / Codex, `~/.claude/.credentials.json` for Anthropic — see
 * PLAN §B.1 / §C.1 for verbatim schemas). The Stage 2 broker can write
 * either blob to disk unmodified.
 *
 * Out of scope for this PR: refresh, broker wiring, agent_credentials_refreshed
 * round-trip.
 *
 * Custom Tabs is fundamentally async: it launches a tab in a separate
 * task, the user authenticates in the browser, and the provider
 * redirects to `conduit://oauth/<provider>/callback?code=...`. The
 * existing `MainActivity` intent filter on the `conduit` scheme then
 * fires `onNewIntent`, which routes the URI here via
 * [completeWithCallbackUri]. This is the same async-handoff shape iOS
 * gets implicitly from `ASWebAuthenticationSession`'s callback closure.
 */
enum class OAuthProvider(val raw: String) {
    OPENAI("openai"),
    ANTHROPIC("anthropic");

    val config: OAuthConfig
        get() = when (this) {
            OPENAI -> OAuthConfig(
                issuer = "https://auth.openai.com",
                // Codex CLI public client ID — see PLAN §C.2.
                clientId = "app_EMoamEEZ73f0CkXaXp7hrann",
                scopes = listOf("openid", "profile", "email", "offline_access"),
                redirectUri = "conduit://oauth/openai/callback",
                callbackScheme = "conduit",
                authorizePath = "oauth/authorize",
                tokenUrl = "https://auth.openai.com/oauth/token",
            )
            ANTHROPIC -> OAuthConfig(
                // Claude Code CLI OAuth params reverse-engineered from
                // the `claude` CLI binary — same constants iOS pins.
                // Anthropic splits authorize (claude.ai) from token
                // exchange (platform.claude.com).
                issuer = "https://claude.ai",
                clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
                scopes = listOf(
                    "user:profile",
                    "user:inference",
                    "user:file_upload",
                    "user:mcp_servers",
                    "user:sessions:claude_code",
                ),
                redirectUri = "conduit://oauth/anthropic/callback",
                callbackScheme = "conduit",
                authorizePath = "oauth/authorize",
                tokenUrl = "https://platform.claude.com/v1/oauth/token",
            )
        }

    /** Keychain / EncryptedSharedPreferences account key. */
    val storageKey: String get() = raw

    companion object {
        fun fromRaw(raw: String): OAuthProvider? =
            values().firstOrNull { it.raw == raw }
    }
}

data class OAuthConfig(
    val issuer: String,
    val clientId: String,
    val scopes: List<String>,
    val redirectUri: String,
    /** Must match `redirectUri`'s scheme — matches the intent filter. */
    val callbackScheme: String,
    val authorizePath: String,
    val tokenUrl: String,
) {
    val authorizeUrl: String get() = "$issuer/$authorizePath"
    val scopeString: String get() = scopes.joinToString(" ")
}

/**
 * Provider-discriminated in-memory credential. Mirror of iOS
 * `OAuthCredential` enum. Each variant wraps the provider's native
 * on-disk shape verbatim — Stage 2's broker will write the inner blob
 * byte-for-byte without normalization.
 */
sealed class OAuthCredential {
    abstract val provider: OAuthProvider
    abstract fun toJson(): String

    data class OpenAi(val blob: AuthDotJson) : OAuthCredential() {
        override val provider get() = OAuthProvider.OPENAI
        override fun toJson(): String = blob.toJsonString()
    }
    data class Anthropic(val blob: ClaudeCredentialsJson) : OAuthCredential() {
        override val provider get() = OAuthProvider.ANTHROPIC
        override fun toJson(): String = blob.toJsonString()
    }
}

/**
 * Shape of `~/.codex/auth.json` (PLAN §C.1, mirrors
 * `codex-rs/login/src/auth/storage.rs`'s `AuthDotJson`). Stage 2's
 * broker writes this to `<agent-home>/.codex/auth.json` byte-for-byte.
 *
 * Why we hand-roll JSON (vs `kotlinx.serialization`):
 * - `OPENAI_API_KEY` must be emitted as explicit `null` on the
 *   ChatGPT path (the codex CLI's writer does this; if we omit the
 *   key the file diffs against a real `claude login` install).
 * - The Android module doesn't currently pull in `kotlinx.serialization`.
 *   `org.json.JSONObject` is already on the classpath.
 */
data class AuthDotJson(
    val authMode: String?,        // "ChatGPT" for the OAuth path
    val openaiApiKey: String?,    // null on the ChatGPT path
    val tokens: TokenData?,
    val lastRefreshIso: String?,  // ISO-8601 UTC string; null when missing
    val agentIdentity: String?,
) {
    data class TokenData(
        val idToken: String,
        val accessToken: String,
        val refreshToken: String,
        val accountId: String?,
    )

    /**
     * Hand-rolled JSON to defend two byte-for-byte invariants the
     * codex CLI's writer expects: `OPENAI_API_KEY` is always present
     * (null on the ChatGPT path, not omitted) and `tokens.*` keys are
     * snake_case (`id_token`, `access_token`, `refresh_token`,
     * `account_id`).
     */
    fun toJsonString(): String {
        val sb = StringBuilder("{")
        var first = true
        fun comma() { if (!first) sb.append(','); first = false }
        if (authMode != null) {
            comma(); sb.append("\"auth_mode\":").append(quote(authMode))
        }
        comma()
        sb.append("\"OPENAI_API_KEY\":")
        if (openaiApiKey == null) sb.append("null") else sb.append(quote(openaiApiKey))
        if (tokens != null) {
            comma()
            sb.append("\"tokens\":{")
            sb.append("\"id_token\":").append(quote(tokens.idToken))
            sb.append(",\"access_token\":").append(quote(tokens.accessToken))
            sb.append(",\"refresh_token\":").append(quote(tokens.refreshToken))
            if (tokens.accountId != null) {
                sb.append(",\"account_id\":").append(quote(tokens.accountId))
            }
            sb.append('}')
        }
        if (lastRefreshIso != null) {
            comma(); sb.append("\"last_refresh\":").append(quote(lastRefreshIso))
        }
        if (agentIdentity != null) {
            comma(); sb.append("\"agent_identity\":").append(quote(agentIdentity))
        }
        sb.append('}')
        return sb.toString()
    }

    private fun quote(s: String): String = JSONObject.quote(s)
}

/**
 * Shape of `~/.claude/.credentials.json` (PLAN §B.1). The Stage 2
 * broker writes this to `<agent-home>/.claude/.credentials.json`
 * byte-for-byte.
 *
 * Note the nested `claudeAiOauth` wrapper — the `claude` CLI's
 * on-disk file already wraps the OAuth blob under that key
 * (presumably to leave room for sibling keys like API-key auth). We
 * mirror exactly so the broker can `cp` without massaging.
 */
data class ClaudeCredentialsJson(
    val claudeAiOauth: ClaudeAiOauth,
) {
    data class ClaudeAiOauth(
        val accessToken: String,
        val refreshToken: String,
        /** ms-since-epoch — the claude CLI stores milliseconds, not
         *  seconds. We preserve that so the broker can compare
         *  against a wall-clock ms reading directly. */
        val expiresAt: Long,
        val scopes: List<String>,
        /** "max" / "pro" / "team" / etc. May be absent on first issue. */
        val subscriptionType: String?,
    )

    fun toJsonString(): String {
        val sb = StringBuilder("{\"claudeAiOauth\":{")
        sb.append("\"accessToken\":").append(JSONObject.quote(claudeAiOauth.accessToken))
        sb.append(",\"refreshToken\":").append(JSONObject.quote(claudeAiOauth.refreshToken))
        sb.append(",\"expiresAt\":").append(claudeAiOauth.expiresAt)
        sb.append(",\"scopes\":[")
        claudeAiOauth.scopes.forEachIndexed { i, s ->
            if (i > 0) sb.append(',')
            sb.append(JSONObject.quote(s))
        }
        sb.append(']')
        if (claudeAiOauth.subscriptionType != null) {
            sb.append(",\"subscriptionType\":").append(JSONObject.quote(claudeAiOauth.subscriptionType))
        }
        sb.append("}}")
        return sb.toString()
    }
}

/** Errors surfaced from [OAuthClient]. UI maps these to strings. */
sealed class OAuthClientError : Throwable() {
    data object UserCancelled : OAuthClientError()
    data object MissingCallback : OAuthClientError()
    data object MissingCode : OAuthClientError()
    data class TokenExchangeFailed(val status: Int, val body: String) : OAuthClientError()
    data object MalformedTokenResponse : OAuthClientError()
    data class Underlying(override val message: String) : OAuthClientError()
}

/**
 * One in-flight authorization request. Holds the PKCE verifier +
 * state across the async Custom Tabs → intent-filter handoff. The
 * verifier is regenerated on every call to [OAuthClient.startLogin].
 *
 * Stays in-memory only — a process kill while the browser tab is open
 * forces the user to retry. We don't persist the verifier because
 * leaking it to disk would defeat the purpose of PKCE.
 */
data class OAuthRequest(
    val provider: OAuthProvider,
    val verifier: String,
    val state: String,
)

/**
 * PKCE driver. Stateless across calls — each [startLogin] generates a
 * fresh verifier + state. The Custom Tabs launch is fire-and-forget;
 * the caller (`AgentLoginSheet`) holds the returned [OAuthRequest] and
 * later calls [completeWithCallbackUri] when the intent filter
 * delivers the redirect.
 *
 * Test hook: pass [deterministicVerifier] to pin the PKCE math under
 * unit tests (RFC 7636 Appendix B vector).
 */
class OAuthClient(
    val provider: OAuthProvider,
    private val httpClient: OkHttpClient = defaultHttpClient(),
    private val deterministicVerifier: String? = null,
) {

    /**
     * Build the authorize URL with PKCE S256 and launch Chrome Custom
     * Tabs. Returns the [OAuthRequest] holding the verifier so the
     * caller can finish the exchange when the redirect lands.
     */
    fun startLogin(context: Context): OAuthRequest {
        val cfg = provider.config
        val verifier = deterministicVerifier ?: generateCodeVerifier()
        val challenge = codeChallenge(verifier)
        val state = generateRandomUrlSafe(16)

        val authorizeUri = Uri.parse(cfg.authorizeUrl).buildUpon().apply {
            appendQueryParameter("response_type", "code")
            appendQueryParameter("client_id", cfg.clientId)
            appendQueryParameter("redirect_uri", cfg.redirectUri)
            appendQueryParameter("scope", cfg.scopeString)
            appendQueryParameter("code_challenge", challenge)
            appendQueryParameter("code_challenge_method", "S256")
            appendQueryParameter("state", state)
        }.build()

        val tabsIntent = CustomTabsIntent.Builder()
            .setShowTitle(true)
            .build()
        tabsIntent.launchUrl(context, authorizeUri)

        return OAuthRequest(provider = provider, verifier = verifier, state = state)
    }

    /**
     * Exchange `code` for tokens. Called from
     * [completeWithCallbackUri]; pulled out into its own suspend fn so
     * the test layer can drive it directly.
     */
    suspend fun exchangeCode(code: String, verifier: String): OAuthCredential {
        val cfg = provider.config
        val body = FormBody.Builder()
            .add("grant_type", "authorization_code")
            .add("client_id", cfg.clientId)
            .add("code", code)
            .add("redirect_uri", cfg.redirectUri)
            .add("code_verifier", verifier)
            .build()
        val req = Request.Builder()
            .url(cfg.tokenUrl)
            .post(body)
            .header("Accept", "application/json")
            .build()

        val (status, payload) = runCatching {
            httpClient.newCall(req).execute().use { resp ->
                resp.code to (resp.body?.string() ?: "")
            }
        }.getOrElse { t ->
            throw OAuthClientError.Underlying("token POST failed: ${t.message ?: t}")
        }
        if (status !in 200..299) {
            throw OAuthClientError.TokenExchangeFailed(status = status, body = payload)
        }
        val bytes = payload.toByteArray()
        return when (provider) {
            OAuthProvider.OPENAI -> OAuthCredential.OpenAi(decodeOpenAITokenResponse(bytes))
            OAuthProvider.ANTHROPIC -> OAuthCredential.Anthropic(decodeAnthropicTokenResponse(bytes))
        }
    }

    /**
     * Drives the end-to-end "callback URI → credential" handoff from
     * the intent filter. The activity's `onNewIntent` parses the URI,
     * verifies the state matches the original [OAuthRequest], then
     * calls this to exchange the code.
     */
    suspend fun completeWithCallbackUri(uri: Uri, req: OAuthRequest): OAuthCredential {
        val returnedState = uri.getQueryParameter("state")
        if (returnedState != null && returnedState != req.state) {
            throw OAuthClientError.Underlying("state mismatch: cross-site / replay")
        }
        val code = extractAuthorizationCode(uri)
        return exchangeCode(code, req.verifier)
    }

    companion object {
        // MARK: PKCE math (unit-tested)

        /**
         * RFC 7636 §4.1 — 64 random bytes → base64url(no-padding) lands
         * at 86 chars, well inside the [43, 128] bound.
         */
        @JvmStatic
        fun generateCodeVerifier(): String = generateRandomUrlSafe(64)

        /** RFC 7636 §4.2 — code_challenge = BASE64URL(SHA256(verifier)). */
        @JvmStatic
        fun codeChallenge(verifier: String): String {
            val digest = MessageDigest.getInstance("SHA-256")
                .digest(verifier.toByteArray(Charsets.US_ASCII))
            return base64UrlEncode(digest)
        }

        /** RFC 4648 §5 base64url, no padding. */
        @JvmStatic
        fun base64UrlEncode(bytes: ByteArray): String {
            val flags = android.util.Base64.NO_PADDING or
                android.util.Base64.NO_WRAP or
                android.util.Base64.URL_SAFE
            // Test on JVM (no android.util.Base64) falls through to the
            // pure-JVM path via java.util.Base64.
            return runCatching { android.util.Base64.encodeToString(bytes, flags) }
                .getOrElse { java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(bytes) }
        }

        /** Random URL-safe string backed by [SecureRandom]. */
        @JvmStatic
        fun generateRandomUrlSafe(byteCount: Int): String {
            val bytes = ByteArray(byteCount)
            SecureRandom().nextBytes(bytes)
            return base64UrlEncode(bytes)
        }

        /** Extracts `?code=...`, throws on `?error=...` or missing code. */
        @JvmStatic
        fun extractAuthorizationCode(uri: Uri): String =
            extractAuthorizationCodeFromString(uri.toString())

        /**
         * Pure-string variant — exposed so unit tests can exercise the
         * parser without instantiating `android.net.Uri` (which on the
         * JVM unit-test classpath either throws "not mocked" or
         * requires pulling in Robolectric).
         */
        @JvmStatic
        fun extractAuthorizationCodeFromString(uriString: String): String {
            val params = parseQueryParams(uriString)
            val err = params["error"]
            if (!err.isNullOrEmpty()) {
                throw OAuthClientError.Underlying("authorize-redirect error: $err")
            }
            val code = params["code"]
            if (code.isNullOrEmpty()) throw OAuthClientError.MissingCode
            return code
        }

        private fun parseQueryParams(uriString: String): Map<String, String> {
            val q = uriString.substringAfter('?', missingDelimiterValue = "")
                .substringBefore('#')
            if (q.isEmpty()) return emptyMap()
            val out = mutableMapOf<String, String>()
            for (pair in q.split('&')) {
                if (pair.isEmpty()) continue
                val eq = pair.indexOf('=')
                if (eq < 0) {
                    out[urlDecode(pair)] = ""
                } else {
                    out[urlDecode(pair.substring(0, eq))] = urlDecode(pair.substring(eq + 1))
                }
            }
            return out
        }

        private fun urlDecode(s: String): String =
            java.net.URLDecoder.decode(s, "UTF-8")

        // MARK: Token-response decode (unit-tested)

        /**
         * Map an OpenAI `/oauth/token` JSON body onto the codex CLI's
         * `auth.json` shape (PLAN §C.1). `account_id` is allowed to be
         * absent — the codex CLI extracts it from the id_token JWT
         * downstream when missing. `refresh_token` is required because
         * the `offline_access` scope guarantees it.
         */
        @JvmStatic
        fun decodeOpenAITokenResponse(data: ByteArray): AuthDotJson {
            val obj = parseJsonObject(data) ?: throw OAuthClientError.MalformedTokenResponse
            val access = obj.optString("access_token", "").takeIf { it.isNotEmpty() }
                ?: throw OAuthClientError.MalformedTokenResponse
            val id = obj.optString("id_token", "").takeIf { it.isNotEmpty() }
                ?: throw OAuthClientError.MalformedTokenResponse
            val refresh = obj.optString("refresh_token", "").takeIf { it.isNotEmpty() }
                ?: throw OAuthClientError.MalformedTokenResponse
            val accountId = obj.optString("account_id", "").takeIf { it.isNotEmpty() }

            val nowIso = java.time.OffsetDateTime.now(java.time.ZoneOffset.UTC)
                .format(java.time.format.DateTimeFormatter.ISO_INSTANT)

            return AuthDotJson(
                authMode = "ChatGPT",
                openaiApiKey = null,
                tokens = AuthDotJson.TokenData(
                    idToken = id,
                    accessToken = access,
                    refreshToken = refresh,
                    accountId = accountId,
                ),
                lastRefreshIso = nowIso,
                agentIdentity = null,
            )
        }

        /**
         * Map an Anthropic `/v1/oauth/token` body onto the claude
         * CLI's `.credentials.json` shape (PLAN §B.1).
         *
         * `expiresAt` is `(now + expires_in_seconds) * 1000` because
         * the on-disk file stores ms-since-epoch. Doing the conversion
         * here keeps the broker dumb.
         */
        @JvmStatic
        fun decodeAnthropicTokenResponse(data: ByteArray): ClaudeCredentialsJson {
            val obj = parseJsonObject(data) ?: throw OAuthClientError.MalformedTokenResponse
            val access = obj.optString("access_token", "").takeIf { it.isNotEmpty() }
                ?: throw OAuthClientError.MalformedTokenResponse
            val refresh = obj.optString("refresh_token", "").takeIf { it.isNotEmpty() }
                ?: throw OAuthClientError.MalformedTokenResponse

            // `expires_in` per RFC 6749 §5.1 is seconds-from-now.
            val expiresInSec: Double = when {
                obj.has("expires_in") -> obj.optDouble("expires_in", 3600.0)
                else -> 3600.0
            }
            val expiresAtMs = ((System.currentTimeMillis() / 1000.0 + expiresInSec) * 1000).toLong()

            // Scope per RFC 6749 §3.3 — space-delimited string.
            val scopes: List<String> = when (val raw = obj.opt("scope")) {
                is String -> if (raw.isBlank()) emptyList() else raw.split(' ').filter { it.isNotEmpty() }
                is org.json.JSONArray -> List(raw.length()) { raw.optString(it, "") }.filter { it.isNotEmpty() }
                else -> emptyList()
            }

            val subscription: String? = obj.optString("subscription_type", "")
                .takeIf { it.isNotEmpty() }
                ?: obj.optJSONObject("account")?.optString("subscription", "")?.takeIf { it.isNotEmpty() }

            return ClaudeCredentialsJson(
                claudeAiOauth = ClaudeCredentialsJson.ClaudeAiOauth(
                    accessToken = access,
                    refreshToken = refresh,
                    expiresAt = expiresAtMs,
                    scopes = scopes,
                    subscriptionType = subscription,
                )
            )
        }

        private fun parseJsonObject(data: ByteArray): JSONObject? =
            runCatching { JSONObject(String(data, Charsets.UTF_8)) }.getOrNull()

        private fun defaultHttpClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            .build()
    }
}
