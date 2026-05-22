import Testing
import Foundation
@testable import SweKitty

/// PKCE S256 math + token-response decode for the agent OAuth Stage 0
/// spike (`docs/PLAN-AGENT-OAUTH.md` §E.1, §C.1). No browser, no
/// network — these pin the pure functions that
/// `OAuthClient.startLogin()` composes.
@Suite("OAuthClient — PKCE math + token-response decode")
struct PKCETests {

    // MARK: - PKCE S256 (RFC 7636)

    /// RFC 7636 Appendix B reference pair:
    ///
    /// > code_verifier  = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    /// > code_challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    ///
    /// If this assertion ever fails the implementation has drifted —
    /// either SHA256 broke or the base64url variant accidentally
    /// switched back to standard padding.
    @Test func rfc7636AppendixBVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        #expect(OAuthClient.codeChallenge(from: verifier) == expected)
    }

    /// Empty-input control: SHA256("") = base64url-encoded(
    /// 47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU). Asserts we don't
    /// silently emit padding `=` characters.
    @Test func emptyVerifierMatchesKnownSHA256() {
        let challenge = OAuthClient.codeChallenge(from: "")
        #expect(challenge == "47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU")
        // base64url has no '+', no '/', and crucially no padding '=' —
        // the OAuth authorize URL must not need urlencoding the
        // challenge.
        #expect(!challenge.contains("="))
        #expect(!challenge.contains("+"))
        #expect(!challenge.contains("/"))
    }

    /// PKCE is deterministic: same verifier → same challenge, always.
    /// The generator uses `SecRandomCopyBytes` but the *transform* is
    /// pure SHA256 + base64url.
    @Test func codeChallengeIsDeterministic() {
        let verifier = "abc123"
        let first = OAuthClient.codeChallenge(from: verifier)
        let second = OAuthClient.codeChallenge(from: verifier)
        #expect(first == second)
    }

    // MARK: - Verifier generation

    /// `generateCodeVerifier` defaults to 64 bytes of entropy. After
    /// base64url-no-padding that lands at exactly 86 chars — well
    /// inside RFC 7636's `[43, 128]` bound on the encoded verifier.
    @Test func generatedVerifierLengthInsideRFCBounds() {
        let verifier = OAuthClient.generateCodeVerifier()
        #expect(verifier.count >= 43)
        #expect(verifier.count <= 128)
        // No padding leaked.
        #expect(!verifier.contains("="))
    }

    @Test func generatedVerifiersAreUnique() {
        // Two consecutive calls collide with probability ~2^-256.
        // If this ever fails, the entropy source is broken.
        let a = OAuthClient.generateCodeVerifier()
        let b = OAuthClient.generateCodeVerifier()
        #expect(a != b)
    }

    // MARK: - base64URLEncode helper

    /// All three replacements happen: `+` → `-`, `/` → `_`, `=` dropped.
    /// We pick an input whose standard base64 contains all three signs.
    @Test func base64URLEncodeHandlesAllReplacements() {
        // Bytes that force `+` and `/` in standard base64:
        //   0xFB 0xFF 0xBF → "+/+/" in std base64; we wrap with extra
        //   bytes to also force a padding `=`.
        let data = Data([0xFB, 0xFF, 0xBF, 0xFB, 0xFF])
        let std = data.base64EncodedString()
        // Sanity: std encoding contains characters we expect to rewrite.
        #expect(std.contains("+") || std.contains("/") || std.contains("="))

        let url = OAuthClient.base64URLEncode(data)
        #expect(!url.contains("+"))
        #expect(!url.contains("/"))
        #expect(!url.contains("="))
    }

    // MARK: - Authorize-redirect parsing

    @Test func extractAuthorizationCodeReturnsCode() throws {
        let url = URL(string: "swekitty://oauth/openai/callback?code=abc-123&state=xyz")!
        let code = try OAuthClient.extractAuthorizationCode(from: url)
        #expect(code == "abc-123")
    }

    @Test func extractAuthorizationCodeThrowsOnMissingCode() {
        let url = URL(string: "swekitty://oauth/openai/callback?state=xyz")!
        do {
            _ = try OAuthClient.extractAuthorizationCode(from: url)
            Issue.record("expected missingCode but got a value")
        } catch let err as OAuthClientError {
            #expect(err == .missingCode)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func extractAuthorizationCodeThrowsOnProviderError() {
        // OpenAI redirects `?error=access_denied` when the user
        // dismisses the consent screen in-page (vs cancelling the
        // ASWebAuth sheet itself — that path returns no callback URL
        // and triggers `.userCancelled` upstream).
        let url = URL(string: "swekitty://oauth/openai/callback?error=access_denied")!
        do {
            _ = try OAuthClient.extractAuthorizationCode(from: url)
            Issue.record("expected an error but got a value")
        } catch {
            // any error is fine — we just want this not to succeed
        }
    }

    // MARK: - OAuthProvider config

    /// Pins the hardcoded constants from PLAN §C.2 — these are the same
    /// public client ID + issuer the `codex` CLI uses for its own
    /// `login` subcommand. If OpenAI ever rotates them, this test
    /// flips red and the fix is a single-line edit.
    @Test func openaiProviderConfigIsHardcodedCodexCLI() {
        let cfg = OAuthProvider.openai.config
        #expect(cfg.clientID == "app_EMoamEEZ73f0CkXaXp7hrann")
        #expect(cfg.issuer == URL(string: "https://auth.openai.com")!)
        #expect(cfg.scopeString == "openid profile email offline_access")
        #expect(cfg.redirectURI == URL(string: "swekitty://oauth/openai/callback")!)
        #expect(cfg.callbackURLScheme == "swekitty")
        #expect(cfg.authorizeURL == URL(string: "https://auth.openai.com/oauth/authorize")!)
        #expect(cfg.tokenURL == URL(string: "https://auth.openai.com/oauth/token")!)
    }

    /// Pins the Claude Code CLI public OAuth constants reverse-engineered
    /// from the `claude` CLI binary (see PR
    /// `oauth-stage1-claude-button` for the source link). If Anthropic
    /// rotates the public client_id or moves an endpoint, this test
    /// flips red and the fix is again a single-line edit.
    ///
    /// Note Anthropic uses **two hosts**: authorize on `claude.ai`,
    /// token on `platform.claude.com`. We pin both URLs verbatim so a
    /// silent typo here doesn't leak past CI.
    @Test func anthropicProviderConfigMatchesClaudeCLI() {
        let cfg = OAuthProvider.anthropic.config
        #expect(cfg.clientID == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        #expect(cfg.issuer == URL(string: "https://claude.ai")!)
        #expect(cfg.scopeString == "user:profile user:inference user:file_upload user:mcp_servers user:sessions:claude_code")
        #expect(cfg.redirectURI == URL(string: "swekitty://oauth/anthropic/callback")!)
        #expect(cfg.callbackURLScheme == "swekitty")
        #expect(cfg.authorizeURL == URL(string: "https://claude.ai/oauth/authorize")!)
        #expect(cfg.tokenURL == URL(string: "https://platform.claude.com/v1/oauth/token")!)
    }

    // MARK: - OpenAI token-response decode

    /// The codex CLI persists the token blob under specific JSON keys
    /// — `id_token`, `access_token`, `refresh_token`, `account_id`
    /// (PLAN §C.1). `decodeOpenAITokenResponse` builds the in-memory
    /// shape that Stage 2 will serialize back out under the *same*
    /// keys.
    @Test func decodeOpenAITokenResponseMapsOAuthFieldsOntoAuthDotJsonShape() throws {
        let json = """
        {
          "access_token": "atk-aaa",
          "refresh_token": "rtk-bbb",
          "id_token": "idt-ccc",
          "account_id": "acct-ddd",
          "token_type": "Bearer",
          "expires_in": 3600
        }
        """.data(using: .utf8)!
        let cred = try OAuthClient.decodeOpenAITokenResponse(json)
        #expect(cred.authMode == "ChatGPT")
        #expect(cred.openaiAPIKey == nil)
        #expect(cred.agentIdentity == nil)
        let t = try #require(cred.tokens)
        #expect(t.accessToken == "atk-aaa")
        #expect(t.refreshToken == "rtk-bbb")
        #expect(t.idToken == "idt-ccc")
        #expect(t.accountID == "acct-ddd")
    }

    /// `account_id` is allowed to be absent — the codex CLI extracts
    /// it from the id_token JWT downstream when this field is missing.
    @Test func decodeOpenAITokenResponseAllowsMissingAccountID() throws {
        let json = """
        {
          "access_token": "a",
          "refresh_token": "r",
          "id_token": "i"
        }
        """.data(using: .utf8)!
        let cred = try OAuthClient.decodeOpenAITokenResponse(json)
        #expect(cred.tokens?.accountID == nil)
    }

    @Test func decodeOpenAITokenResponseFailsOnMissingRefreshToken() {
        // The `offline_access` scope means OpenAI always returns a
        // refresh_token. If it's missing, we fail loudly rather than
        // persist a half-credential that'll break on next inference.
        let json = """
        {
          "access_token": "a",
          "id_token": "i"
        }
        """.data(using: .utf8)!
        do {
            _ = try OAuthClient.decodeOpenAITokenResponse(json)
            Issue.record("expected malformedTokenResponse")
        } catch let err as OAuthClientError {
            #expect(err == .malformedTokenResponse)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func decodeOpenAITokenResponseFailsOnGarbageBody() {
        let garbage = Data("not json".utf8)
        do {
            _ = try OAuthClient.decodeOpenAITokenResponse(garbage)
            Issue.record("expected malformedTokenResponse")
        } catch let err as OAuthClientError {
            #expect(err == .malformedTokenResponse)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - Anthropic token-response decode

    /// Anthropic's `/v1/oauth/token` returns the standard OAuth-ish
    /// blob: `access_token`, `refresh_token`, `expires_in` (seconds),
    /// `scope` (space-separated). We map it onto the
    /// `.credentials.json` shape (PLAN §B.1) — nested
    /// `claudeAiOauth.accessToken` / `refreshToken` / `expiresAt`
    /// (ms-since-epoch) / `scopes` (array).
    @Test func decodeAnthropicTokenResponseMapsOntoClaudeCredentialsJson() throws {
        let json = """
        {
          "access_token": "sk-ant-oat01-aaa",
          "refresh_token": "sk-ant-ort01-bbb",
          "expires_in": 3600,
          "scope": "user:profile user:inference user:file_upload user:mcp_servers user:sessions:claude_code",
          "subscription_type": "max",
          "token_type": "Bearer"
        }
        """.data(using: .utf8)!

        // Pin a known "now" by sampling immediately before + after; the
        // implementation reads `Date()` once internally so the produced
        // `expiresAt` must land in `[before + 3600s, after + 3600s]`.
        let before = Int64(Date().timeIntervalSince1970 * 1000) + Int64(3600 * 1000)
        let cred = try OAuthClient.decodeAnthropicTokenResponse(json)
        let after = Int64(Date().timeIntervalSince1970 * 1000) + Int64(3600 * 1000)

        #expect(cred.claudeAiOauth.accessToken == "sk-ant-oat01-aaa")
        #expect(cred.claudeAiOauth.refreshToken == "sk-ant-ort01-bbb")
        #expect(cred.claudeAiOauth.subscriptionType == "max")
        #expect(cred.claudeAiOauth.scopes == [
            "user:profile", "user:inference", "user:file_upload",
            "user:mcp_servers", "user:sessions:claude_code",
        ])
        #expect(cred.claudeAiOauth.expiresAt >= before)
        #expect(cred.claudeAiOauth.expiresAt <= after)
    }

    /// `subscription_type` is allowed to be absent — Anthropic's docs
    /// don't pin whether the OAuth response carries it, and the
    /// claude CLI writes `null` to disk in that case. We mirror that
    /// rather than synthesizing a fake plan name.
    @Test func decodeAnthropicTokenResponseAllowsMissingSubscriptionType() throws {
        let json = """
        {
          "access_token": "a",
          "refresh_token": "r",
          "expires_in": 3600,
          "scope": ""
        }
        """.data(using: .utf8)!
        let cred = try OAuthClient.decodeAnthropicTokenResponse(json)
        #expect(cred.claudeAiOauth.subscriptionType == nil)
        // Empty scope string → empty array, not [""].
        #expect(cred.claudeAiOauth.scopes == [])
    }

    @Test func decodeAnthropicTokenResponseFailsOnMissingRefreshToken() {
        let json = """
        {
          "access_token": "a",
          "expires_in": 3600
        }
        """.data(using: .utf8)!
        do {
            _ = try OAuthClient.decodeAnthropicTokenResponse(json)
            Issue.record("expected malformedTokenResponse")
        } catch let err as OAuthClientError {
            #expect(err == .malformedTokenResponse)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func decodeAnthropicTokenResponseFailsOnGarbageBody() {
        let garbage = Data("not json".utf8)
        do {
            _ = try OAuthClient.decodeAnthropicTokenResponse(garbage)
            Issue.record("expected malformedTokenResponse")
        } catch let err as OAuthClientError {
            #expect(err == .malformedTokenResponse)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - OAuthCredential JSON shape

    /// Round-trips an `AuthDotJson` through JSON and asserts the keys
    /// match what the codex CLI writes to `auth.json` (PLAN §C.1):
    /// snake_case `auth_mode`, screaming `OPENAI_API_KEY`, nested
    /// `tokens.id_token` / `access_token` / `refresh_token` /
    /// `account_id`. Stage 1's broker reads these keys verbatim.
    @Test func authDotJsonKeysMatchCodexSchema() throws {
        let cred = AuthDotJson(
            authMode: "ChatGPT",
            openaiAPIKey: nil,
            tokens: .init(
                idToken: "i",
                accessToken: "a",
                refreshToken: "r",
                accountID: "acct"
            ),
            lastRefresh: nil,
            agentIdentity: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(cred)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"auth_mode\":\"ChatGPT\""))
        #expect(json.contains("\"OPENAI_API_KEY\":null"))
        #expect(json.contains("\"id_token\":\"i\""))
        #expect(json.contains("\"access_token\":\"a\""))
        #expect(json.contains("\"refresh_token\":\"r\""))
        #expect(json.contains("\"account_id\":\"acct\""))
    }

    /// Round-trips a `ClaudeCredentialsJson` through JSON and asserts
    /// the keys match what the `claude` CLI writes to
    /// `~/.claude/.credentials.json` (PLAN §B.1): camelCase
    /// `claudeAiOauth`, `accessToken`, `refreshToken`, `expiresAt`
    /// (number, ms), `scopes`, `subscriptionType`. The broker reads
    /// these keys verbatim.
    @Test func claudeCredentialsJSONKeysMatchClaudeSchema() throws {
        let cred = ClaudeCredentialsJson(
            claudeAiOauth: .init(
                accessToken: "sk-ant-oat01-aaa",
                refreshToken: "sk-ant-ort01-bbb",
                expiresAt: 1_700_000_000_000,
                scopes: ["user:inference", "user:profile"],
                subscriptionType: "max"
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(cred)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"claudeAiOauth\""))
        #expect(json.contains("\"accessToken\":\"sk-ant-oat01-aaa\""))
        #expect(json.contains("\"refreshToken\":\"sk-ant-ort01-bbb\""))
        #expect(json.contains("\"expiresAt\":1700000000000"))
        #expect(json.contains("\"scopes\":[\"user:inference\",\"user:profile\"]"))
        #expect(json.contains("\"subscriptionType\":\"max\""))
    }

    /// Decodes a fixture in the exact shape Anthropic writes to disk
    /// (PLAN §B.1) — pins that our Codable layer reads back-out the
    /// same shape the broker will see when it lifts the JSON off
    /// `.credentials.json`.
    @Test func claudeCredentialsJSONDecodesDiskFixture() throws {
        let fixture = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-oat01-aaa",
            "refreshToken": "sk-ant-ort01-bbb",
            "expiresAt": 1700000000000,
            "scopes": ["user:inference", "user:profile"],
            "subscriptionType": "max"
          }
        }
        """.data(using: .utf8)!
        let cred = try JSONDecoder().decode(ClaudeCredentialsJson.self, from: fixture)
        #expect(cred.claudeAiOauth.accessToken == "sk-ant-oat01-aaa")
        #expect(cred.claudeAiOauth.refreshToken == "sk-ant-ort01-bbb")
        #expect(cred.claudeAiOauth.expiresAt == 1_700_000_000_000)
        #expect(cred.claudeAiOauth.scopes == ["user:inference", "user:profile"])
        #expect(cred.claudeAiOauth.subscriptionType == "max")
    }
}
