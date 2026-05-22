import Testing
import Foundation
@testable import SweKitty

/// Pins the JSON wire shape iOS sends to the broker for
/// `set_agent_credentials` (docs/PLAN-AGENT-OAUTH.md §D.1, Stage 2).
///
/// The broker's parser at `broker/internal/ws/server.go` reads the
/// envelope as:
///
/// ```go
/// var env struct {
///     Type       string          `json:"type"`
///     Provider   string          `json:"provider"`
///     Kind       string          `json:"kind"`
///     Credential json.RawMessage `json:"credential"`
/// }
/// ```
///
/// and `handleSetAgentCredentials` rejects anything outside
/// `{anthropic, openai}` × `kind="oauth"` × non-empty credential. These
/// tests pin the *inner* `credential` blob to be the provider-native
/// disk shape — what the broker writes byte-for-byte to
/// `~/.codex/auth.json` / `~/.claude/.credentials.json` — so a future
/// refactor that accidentally double-wraps the blob (or stringifies it)
/// trips a unit test before it ships.
@Suite("set_agent_credentials envelope")
struct AgentCredentialEnvelopeTests {

    // MARK: - OpenAI / Codex (`auth.json` shape)

    /// The full `auth.json` blob — `auth_mode`, `OPENAI_API_KEY` (null
    /// on the ChatGPT path, but emitted explicitly), `tokens`,
    /// `last_refresh`, `agent_identity` — survives the
    /// `encodeCredentialAsJSONString` round-trip with the exact keys
    /// the codex CLI expects. Mirrors `AuthDotJson.encode(to:)` in
    /// `OAuthClient.swift` (PR #102 fixed the null-emission bug).
    @Test func openAIEnvelopeMatchesAuthDotJsonShape() throws {
        let credential: OAuthCredential = .openai(
            AuthDotJson(
                authMode: "ChatGPT",
                openaiAPIKey: nil,
                tokens: .init(
                    idToken: "ID_TOKEN_VALUE",
                    accessToken: "ACCESS_TOKEN_VALUE",
                    refreshToken: "REFRESH_TOKEN_VALUE",
                    accountID: "acct-123"
                ),
                lastRefresh: nil,
                agentIdentity: nil
            )
        )
        let json = try SessionStore.encodeCredentialAsJSONString(credential)
        let parsed = try parseObject(json)

        // Wire keys = codex-rs/login/src/auth/storage.rs verbatim.
        #expect(parsed["auth_mode"] as? String == "ChatGPT")
        // Critical: OPENAI_API_KEY must be present-and-explicit-null,
        // not missing, so codex parses the file as an OAuth credential
        // and doesn't fall back to the api-key path. The custom
        // encoder in `AuthDotJson.encode(to:)` exists precisely to
        // emit this null instead of stripping the key.
        #expect(parsed.keys.contains("OPENAI_API_KEY"))
        #expect(parsed["OPENAI_API_KEY"] is NSNull)

        let tokens = parsed["tokens"] as? [String: Any]
        #expect(tokens?["id_token"] as? String == "ID_TOKEN_VALUE")
        #expect(tokens?["access_token"] as? String == "ACCESS_TOKEN_VALUE")
        #expect(tokens?["refresh_token"] as? String == "REFRESH_TOKEN_VALUE")
        #expect(tokens?["account_id"] as? String == "acct-123")
    }

    /// The broker's `handleSetAgentCredentials` keys off the
    /// **provider** field on the outer envelope. The iOS wrapper
    /// doesn't build that envelope (the Rust core does) — but we
    /// double-check that `OAuthProvider.rawValue` matches the literal
    /// strings the broker expects (`"openai"` and `"anthropic"`,
    /// PLAN-AGENT-OAUTH §D.1). A refactor that renames the cases
    /// would silently break the wire match without this pin.
    @Test func providerRawValuesMatchBrokerExpectations() {
        #expect(OAuthProvider.openai.rawValue == "openai")
        #expect(OAuthProvider.anthropic.rawValue == "anthropic")
    }

    // MARK: - Anthropic / Claude (`.credentials.json` shape)

    /// Claude's `.credentials.json` nests under `claudeAiOauth`. The
    /// broker writes the blob verbatim, so the nesting must survive
    /// the wire send.
    @Test func anthropicEnvelopeMatchesClaudeCredentialsJsonShape() throws {
        let credential: OAuthCredential = .anthropic(
            ClaudeCredentialsJson(
                claudeAiOauth: .init(
                    accessToken: "sk-ant-oat01-ACCESS",
                    refreshToken: "sk-ant-ort01-REFRESH",
                    expiresAt: 1_700_000_000_000,
                    scopes: ["user:inference", "user:profile"],
                    subscriptionType: "max"
                )
            )
        )
        let json = try SessionStore.encodeCredentialAsJSONString(credential)
        let parsed = try parseObject(json)

        let oauth = parsed["claudeAiOauth"] as? [String: Any]
        #expect(oauth?["accessToken"] as? String == "sk-ant-oat01-ACCESS")
        #expect(oauth?["refreshToken"] as? String == "sk-ant-ort01-REFRESH")
        // expiresAt is ms-since-epoch (claude CLI stores ms, not
        // seconds) — preserve that so the broker can compare against
        // `Date.now * 1000` directly. (PLAN §B.1.)
        #expect(oauth?["expiresAt"] as? Int64 == 1_700_000_000_000)
        #expect(oauth?["scopes"] as? [String] == ["user:inference", "user:profile"])
        #expect(oauth?["subscriptionType"] as? String == "max")
    }

    /// The Anthropic blob round-trips back through `JSONDecoder` into
    /// the same `ClaudeCredentialsJson` (modulo Equatable). Catches a
    /// refactor that drops a field on encode or renames a coding key
    /// on decode.
    @Test func anthropicBlobRoundTrips() throws {
        let original = ClaudeCredentialsJson(
            claudeAiOauth: .init(
                accessToken: "A",
                refreshToken: "R",
                expiresAt: 42,
                scopes: ["x", "y"],
                subscriptionType: nil
            )
        )
        let json = try SessionStore.encodeCredentialAsJSONString(.anthropic(original))
        let decoded = try JSONDecoder().decode(
            ClaudeCredentialsJson.self,
            from: Data(json.utf8)
        )
        #expect(decoded == original)
    }

    /// Same round-trip for OpenAI: decoded blob equals the original.
    /// `last_refresh` is intentionally nil here — codex tolerates
    /// missing `last_refresh` on first-write per its decode path. We
    /// don't test the date-encoding format because UniFFI / the
    /// broker don't currently care.
    @Test func openAIBlobRoundTrips() throws {
        let original = AuthDotJson(
            authMode: "ChatGPT",
            openaiAPIKey: nil,
            tokens: .init(
                idToken: "ID",
                accessToken: "AT",
                refreshToken: "RT",
                accountID: nil
            ),
            lastRefresh: nil,
            agentIdentity: nil
        )
        let json = try SessionStore.encodeCredentialAsJSONString(.openai(original))
        let decoded = try JSONDecoder().decode(AuthDotJson.self, from: Data(json.utf8))
        #expect(decoded == original)
    }

    // MARK: - Helpers

    /// Decode `json` (UTF-8) into `[String: Any]` for shape inspection.
    /// Throws if the top-level isn't a JSON object — every credential
    /// blob is, so any other shape is a test-level bug we want to fail
    /// on loudly.
    private func parseObject(_ json: String) throws -> [String: Any] {
        let data = Data(json.utf8)
        let any = try JSONSerialization.jsonObject(with: data, options: [])
        guard let obj = any as? [String: Any] else {
            throw NSError(
                domain: "AgentCredentialEnvelopeTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "expected object, got \(type(of: any))"]
            )
        }
        return obj
    }
}
