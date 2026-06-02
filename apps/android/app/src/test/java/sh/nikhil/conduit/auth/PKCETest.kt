package sh.nikhil.conduit.auth

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Android mirror of `apps/ios/Tests/ConduitTests/PKCETests.swift`.
 * Pins the pure functions that `OAuthClient.startLogin()` composes —
 * PKCE S256 math, RFC 7636 reference vectors, base64url variants,
 * authorize-redirect parsing, and the token-response → on-disk-shape
 * decode for both providers.
 *
 * Stays under plain JUnit (no Robolectric) so the math runs without
 * spinning up the Android framework. The implementation uses
 * `android.util.Base64` when available and falls back to
 * `java.util.Base64` on the JVM — the fallback is what these tests
 * exercise.
 */
class PKCETest {

    // MARK: - PKCE S256 (RFC 7636)

    /**
     * RFC 7636 Appendix B reference pair:
     *   code_verifier  = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
     *   code_challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
     * If this assertion ever fails the implementation has drifted —
     * either SHA256 broke or the base64url variant accidentally
     * switched back to standard padding.
     */
    @Test fun rfc7636AppendixBVector() {
        val verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        val expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        assertEquals(expected, OAuthClient.codeChallenge(verifier))
    }

    /**
     * Empty-input control: SHA256("") = base64url-encoded(
     * 47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU). Asserts we don't
     * silently emit padding `=` characters.
     */
    @Test fun emptyVerifierMatchesKnownSHA256() {
        val challenge = OAuthClient.codeChallenge("")
        assertEquals("47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU", challenge)
        // base64url has no '+', no '/', and crucially no padding '='.
        assertFalse(challenge.contains("="))
        assertFalse(challenge.contains("+"))
        assertFalse(challenge.contains("/"))
    }

    /** PKCE is deterministic: same verifier → same challenge, always. */
    @Test fun codeChallengeIsDeterministic() {
        val verifier = "abc123"
        assertEquals(
            OAuthClient.codeChallenge(verifier),
            OAuthClient.codeChallenge(verifier),
        )
    }

    // MARK: - Verifier generation

    /**
     * `generateCodeVerifier` defaults to 64 bytes of entropy. After
     * base64url-no-padding that lands at 86 chars — well inside
     * RFC 7636's `[43, 128]` bound on the encoded verifier.
     */
    @Test fun generatedVerifierLengthInsideRFCBounds() {
        val verifier = OAuthClient.generateCodeVerifier()
        assertTrue("verifier too short: ${verifier.length}", verifier.length >= 43)
        assertTrue("verifier too long: ${verifier.length}", verifier.length <= 128)
        assertFalse(verifier.contains("="))
    }

    @Test fun generatedVerifiersAreUnique() {
        // Two consecutive calls collide with probability ~2^-256.
        val a = OAuthClient.generateCodeVerifier()
        val b = OAuthClient.generateCodeVerifier()
        assertNotEquals(a, b)
    }

    // MARK: - base64UrlEncode

    /** All three replacements happen: `+` → `-`, `/` → `_`, `=` dropped. */
    @Test fun base64UrlEncodeHandlesAllReplacements() {
        // Bytes that force `+` and `/` in standard base64.
        val data = byteArrayOf(0xFB.toByte(), 0xFF.toByte(), 0xBF.toByte(), 0xFB.toByte(), 0xFF.toByte())
        val url = OAuthClient.base64UrlEncode(data)
        assertFalse(url.contains("+"))
        assertFalse(url.contains("/"))
        assertFalse(url.contains("="))
    }

    // MARK: - Authorize-redirect parsing

    @Test fun extractAuthorizationCodeReturnsCode() {
        val s = "conduit://oauth/openai/callback?code=abc-123&state=xyz"
        assertEquals("abc-123", OAuthClient.extractAuthorizationCodeFromString(s))
    }

    @Test fun extractAuthorizationCodeThrowsOnMissingCode() {
        val s = "conduit://oauth/openai/callback?state=xyz"
        try {
            OAuthClient.extractAuthorizationCodeFromString(s)
            fail("expected MissingCode")
        } catch (e: OAuthClientError.MissingCode) {
            // ok
        }
    }

    @Test fun extractAuthorizationCodeThrowsOnProviderError() {
        val s = "conduit://oauth/openai/callback?error=access_denied"
        try {
            OAuthClient.extractAuthorizationCodeFromString(s)
            fail("expected an error")
        } catch (e: Throwable) {
            // any error is fine
        }
    }

    // MARK: - OAuthProvider config

    /**
     * Pins the hardcoded constants from PLAN §C.2 — same public client
     * ID + issuer the `codex` CLI uses for its own `login` subcommand.
     * If OpenAI rotates them, this test flips red and the fix is a
     * single-line edit. Cross-checked against iOS PKCETests.
     */
    @Test fun openaiProviderConfigIsHardcodedCodexCLI() {
        val cfg = OAuthProvider.OPENAI.config
        assertEquals("app_EMoamEEZ73f0CkXaXp7hrann", cfg.clientId)
        assertEquals("https://auth.openai.com", cfg.issuer)
        assertEquals("openid profile email offline_access", cfg.scopeString)
        // Loopback redirect — the codex CLI's own (RFC 8252), caught
        // in-app by AgentLoginLoopbackServer.
        assertEquals("http://localhost:1455/auth/callback", cfg.redirectUri)
        assertEquals("conduit", cfg.callbackScheme)
        assertEquals(OAuthCaptureMode.Loopback(1455, "/auth/callback"), cfg.captureMode)
        assertEquals("https://auth.openai.com/oauth/authorize", cfg.authorizeUrl)
        assertEquals("https://auth.openai.com/oauth/token", cfg.tokenUrl)
        assertEquals(emptyMap<String, String>(), cfg.extraAuthorizeParams)
    }

    /**
     * Pins the Claude Code CLI public OAuth constants reverse-engineered
     * from the `claude` CLI binary. Anthropic uses two hosts: authorize
     * on `claude.ai`, token on `platform.claude.com`. We pin both
     * URLs verbatim so a silent typo here doesn't leak past CI.
     */
    @Test fun anthropicProviderConfigMatchesClaudeCLI() {
        val cfg = OAuthProvider.ANTHROPIC.config
        assertEquals("9d1c250a-e61b-44d9-88ed-5944d1962f5e", cfg.clientId)
        assertEquals("https://claude.ai", cfg.issuer)
        assertEquals(
            "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload",
            cfg.scopeString,
        )
        // Claude uses the real code-display redirect (no loopback) and a
        // code-paste capture; `code=true` selects the display page.
        assertEquals("https://platform.claude.com/oauth/code/callback", cfg.redirectUri)
        assertEquals("conduit", cfg.callbackScheme)
        assertEquals(OAuthCaptureMode.CodePaste, cfg.captureMode)
        assertEquals("https://claude.ai/oauth/authorize", cfg.authorizeUrl)
        assertEquals("https://platform.claude.com/v1/oauth/token", cfg.tokenUrl)
        assertEquals(mapOf("code" to "true"), cfg.extraAuthorizeParams)
    }

    // MARK: - OpenAI token-response decode

    @Test fun decodeOpenAITokenResponseMapsOAuthFieldsOntoAuthDotJsonShape() {
        val json = """
            {
              "access_token": "atk-aaa",
              "refresh_token": "rtk-bbb",
              "id_token": "idt-ccc",
              "account_id": "acct-ddd",
              "token_type": "Bearer",
              "expires_in": 3600
            }
        """.trimIndent().toByteArray()
        val cred = OAuthClient.decodeOpenAITokenResponse(json)
        assertEquals("chatgpt", cred.authMode)
        assertNull(cred.openaiApiKey)
        assertNull(cred.agentIdentity)
        val t = cred.tokens!!
        assertEquals("atk-aaa", t.accessToken)
        assertEquals("rtk-bbb", t.refreshToken)
        assertEquals("idt-ccc", t.idToken)
        assertEquals("acct-ddd", t.accountId)
    }

    /** `account_id` is allowed to be absent (codex extracts from id_token JWT). */
    @Test fun decodeOpenAITokenResponseAllowsMissingAccountID() {
        val json = """{"access_token":"a","refresh_token":"r","id_token":"i"}""".toByteArray()
        val cred = OAuthClient.decodeOpenAITokenResponse(json)
        assertNull(cred.tokens!!.accountId)
    }

    @Test fun decodeOpenAITokenResponseFailsOnMissingRefreshToken() {
        // `offline_access` scope means OpenAI always returns one.
        val json = """{"access_token":"a","id_token":"i"}""".toByteArray()
        try {
            OAuthClient.decodeOpenAITokenResponse(json)
            fail("expected MalformedTokenResponse")
        } catch (e: OAuthClientError.MalformedTokenResponse) {
            // ok
        }
    }

    @Test fun decodeOpenAITokenResponseFailsOnGarbageBody() {
        try {
            OAuthClient.decodeOpenAITokenResponse("not json".toByteArray())
            fail("expected MalformedTokenResponse")
        } catch (e: OAuthClientError.MalformedTokenResponse) {
            // ok
        }
    }

    // MARK: - Anthropic token-response decode

    @Test fun decodeAnthropicTokenResponseMapsOntoClaudeCredentialsJson() {
        val json = """
            {
              "access_token": "sk-ant-oat01-aaa",
              "refresh_token": "sk-ant-ort01-bbb",
              "expires_in": 3600,
              "scope": "user:profile user:inference user:file_upload user:mcp_servers user:sessions:claude_code",
              "subscription_type": "max",
              "token_type": "Bearer"
            }
        """.trimIndent().toByteArray()

        val before = System.currentTimeMillis() + 3600L * 1000L
        val cred = OAuthClient.decodeAnthropicTokenResponse(json)
        val after = System.currentTimeMillis() + 3600L * 1000L

        assertEquals("sk-ant-oat01-aaa", cred.claudeAiOauth.accessToken)
        assertEquals("sk-ant-ort01-bbb", cred.claudeAiOauth.refreshToken)
        assertEquals("max", cred.claudeAiOauth.subscriptionType)
        assertEquals(
            listOf(
                "user:profile", "user:inference", "user:file_upload",
                "user:mcp_servers", "user:sessions:claude_code",
            ),
            cred.claudeAiOauth.scopes,
        )
        assertTrue("expiresAt below window", cred.claudeAiOauth.expiresAt >= before - 10)
        assertTrue("expiresAt above window", cred.claudeAiOauth.expiresAt <= after + 10)
    }

    @Test fun decodeAnthropicTokenResponseAllowsMissingSubscriptionType() {
        val json = """{"access_token":"a","refresh_token":"r","expires_in":3600,"scope":""}""".toByteArray()
        val cred = OAuthClient.decodeAnthropicTokenResponse(json)
        assertNull(cred.claudeAiOauth.subscriptionType)
        // Empty scope string → empty list, not [""].
        assertEquals(emptyList<String>(), cred.claudeAiOauth.scopes)
    }

    @Test fun decodeAnthropicTokenResponseFailsOnMissingRefreshToken() {
        val json = """{"access_token":"a","expires_in":3600}""".toByteArray()
        try {
            OAuthClient.decodeAnthropicTokenResponse(json)
            fail("expected MalformedTokenResponse")
        } catch (e: OAuthClientError.MalformedTokenResponse) {
            // ok
        }
    }

    @Test fun decodeAnthropicTokenResponseFailsOnGarbageBody() {
        try {
            OAuthClient.decodeAnthropicTokenResponse("not json".toByteArray())
            fail("expected MalformedTokenResponse")
        } catch (e: OAuthClientError.MalformedTokenResponse) {
            // ok
        }
    }

    // MARK: - AuthDotJson / ClaudeCredentialsJson on-disk JSON shape

    /**
     * Round-trips an `AuthDotJson` through JSON and asserts the keys
     * match what the codex CLI writes to `auth.json` (PLAN §C.1):
     * snake_case `auth_mode`, screaming `OPENAI_API_KEY` (always
     * emitted, null on ChatGPT path), nested `tokens.id_token` /
     * `access_token` / `refresh_token` / `account_id`. Stage 1's
     * broker reads these keys verbatim.
     */
    @Test fun authDotJsonKeysMatchCodexSchema() {
        val cred = AuthDotJson(
            authMode = "chatgpt",
            openaiApiKey = null,
            tokens = AuthDotJson.TokenData(
                idToken = "i",
                accessToken = "a",
                refreshToken = "r",
                accountId = "acct",
            ),
            lastRefreshIso = null,
            agentIdentity = null,
        )
        val json = cred.toJsonString()
        assertTrue(json, json.contains("\"auth_mode\":\"chatgpt\""))
        assertTrue(json, json.contains("\"OPENAI_API_KEY\":null"))
        assertTrue(json, json.contains("\"id_token\":\"i\""))
        assertTrue(json, json.contains("\"access_token\":\"a\""))
        assertTrue(json, json.contains("\"refresh_token\":\"r\""))
        assertTrue(json, json.contains("\"account_id\":\"acct\""))
    }

    /**
     * Round-trips a `ClaudeCredentialsJson` through JSON and asserts
     * the keys match what the `claude` CLI writes to
     * `~/.claude/.credentials.json` (PLAN §B.1).
     */
    @Test fun claudeCredentialsJSONKeysMatchClaudeSchema() {
        val cred = ClaudeCredentialsJson(
            claudeAiOauth = ClaudeCredentialsJson.ClaudeAiOauth(
                accessToken = "sk-ant-oat01-aaa",
                refreshToken = "sk-ant-ort01-bbb",
                expiresAt = 1_700_000_000_000L,
                scopes = listOf("user:inference", "user:profile"),
                subscriptionType = "max",
            )
        )
        val json = cred.toJsonString()
        assertTrue(json, json.contains("\"claudeAiOauth\""))
        assertTrue(json, json.contains("\"accessToken\":\"sk-ant-oat01-aaa\""))
        assertTrue(json, json.contains("\"refreshToken\":\"sk-ant-ort01-bbb\""))
        assertTrue(json, json.contains("\"expiresAt\":1700000000000"))
        assertTrue(json, json.contains("\"scopes\":[\"user:inference\",\"user:profile\"]"))
        assertTrue(json, json.contains("\"subscriptionType\":\"max\""))
    }
}
