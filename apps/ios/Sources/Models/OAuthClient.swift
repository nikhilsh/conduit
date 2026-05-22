import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

// MARK: - DEPRECATED (v1 — superseded by v2 server-side login flow)
//
// This file implements the v1 PKCE-on-the-phone approach documented
// in `docs/PLAN-AGENT-OAUTH.md` "v1 archive". It is **deprecated**:
// both Anthropic and OpenAI reject the `swekitty://` custom-scheme
// redirect URI at the authorize endpoint, so this code path doesn't
// reach token exchange in practice. PRs #100/#104/#110/#112 shipped
// it; the dead-code state was confirmed end-to-end against both
// providers in May 2026.
//
// The replacement is `AgentLoginCoordinator` + `AgentLoginLoopbackServer`,
// which mirrors litter's pattern: the broker spawns `codex login` /
// `claude auth login` on the broker host, the phone hosts a tiny
// HTTP listener on `127.0.0.1:<port>` to catch the provider's
// redirect, and ships the captured query string back over WS. See
// `docs/PLAN-AGENT-OAUTH.md` "Approach v2".
//
// This file is retained (rather than deleted) so existing Settings
// surfaces and the `OAuthCredentialStore` Keychain reads continue to
// compile during the v2 transition. Stage 4 of the v2 plan removes
// it (and `set_agent_credentials` / `AgentCredentialEnvelope` /
// `replayStoredAgentCredentials`). Do not extend the code below;
// any new work should target `AgentLoginCoordinator`.

/// Stages 0–1 of `docs/PLAN-AGENT-OAUTH.md` v1 (deprecated) — iOS
/// OAuth driver for the two agent providers we ship: ChatGPT
/// (OpenAI / Codex) and Claude (Anthropic).
///
/// Drives PKCE S256 → `ASWebAuthenticationSession` → token exchange
/// against the provider's token endpoint. Returns an `OAuthCredential`
/// case whose payload matches what the CLI persists on disk
/// (`~/.codex/auth.json` for OpenAI, `~/.claude/.credentials.json` for
/// Anthropic — see PLAN §B.1 / §C.1 for verbatim schemas). Stage 2's
/// broker can write either blob to disk unmodified.
///
/// Out of scope for this PR: refresh, broker wiring.
///
/// Why `swekitty://` custom scheme instead of loopback `http://127.0.0.1:1455/auth/callback`
/// (which is what the codex CLI uses): `ASWebAuthenticationSession`
/// requires a `callbackURLScheme:` that is a non-http custom scheme —
/// it won't intercept http loopback URLs (litter works around this by
/// running its own loopback HTTP server on the phone, which we
/// deliberately don't replicate, see §A.4 "Borrow vs diverge"). The
/// risk this exposes — either provider may reject the custom-scheme
/// redirect at `/oauth/authorize` — is documented in the PR; if so
/// we'll fall back to litter's loopback server in a follow-up.
enum OAuthProvider: String, Sendable {
    case openai
    case anthropic

    var config: OAuthConfig {
        switch self {
        case .openai:
            return OAuthConfig(
                issuer: URL(string: "https://auth.openai.com")!,
                // Codex CLI public client ID — see PLAN §C.2.
                clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
                scopes: ["openid", "profile", "email", "offline_access"],
                redirectURI: URL(string: "swekitty://oauth/openai/callback")!,
                callbackURLScheme: "swekitty",
                authorizePath: "oauth/authorize",
                tokenURL: URL(string: "https://auth.openai.com/oauth/token")!
            )
        case .anthropic:
            // Claude Code CLI's OAuth params. The client_id + endpoints
            // here were reverse-engineered from the `claude` CLI binary
            // (see PR body for source link) — Anthropic doesn't publish
            // these in their docs. Risks:
            //
            //   1. Anthropic may rotate the client_id without notice; we
            //      ship an app update if it happens.
            //   2. The real CLI's flow uses redirect_uri =
            //      `https://platform.claude.com/oauth/code/callback`
            //      (a server-side bounce that displays the code for
            //      copy-paste). We instead use a custom-scheme URI so
            //      ASWebAuthenticationSession can intercept it. If
            //      Anthropic's authorize endpoint refuses arbitrary
            //      redirect_uris (likely whitelisted), this fails at
            //      `/oauth/authorize` and we fall back in a follow-up
            //      (loopback HTTP server, or a relay on the swe-kitty
            //      website that 302s into `swekitty://...`).
            //
            // TODO(stage-1): Verify the flow end-to-end on-device.
            return OAuthConfig(
                issuer: URL(string: "https://claude.ai")!,
                clientID: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
                scopes: [
                    "user:profile",
                    "user:inference",
                    "user:file_upload",
                    "user:mcp_servers",
                    "user:sessions:claude_code",
                ],
                redirectURI: URL(string: "swekitty://oauth/anthropic/callback")!,
                callbackURLScheme: "swekitty",
                // Anthropic splits authorize (claude.ai) from token
                // exchange (platform.claude.com) — `issuer` alone
                // can't derive both, hence the explicit `tokenURL`.
                authorizePath: "oauth/authorize",
                tokenURL: URL(string: "https://platform.claude.com/v1/oauth/token")!
            )
        }
    }

    /// Keychain account used to persist the resulting credential blob.
    /// Service is `"sh.nikhil.swekitty.oauth"` (see `OAuthCredentialStore`).
    var keychainAccount: String { rawValue }
}

struct OAuthConfig: Sendable {
    var issuer: URL
    var clientID: String
    var scopes: [String]
    var redirectURI: URL
    /// The scheme `ASWebAuthenticationSession` watches for the callback
    /// — must match `redirectURI.scheme`. Hoisted out so the test layer
    /// can assert it without rebuilding URLComponents.
    var callbackURLScheme: String
    /// Path appended to `issuer` for the authorize endpoint. OpenAI
    /// uses `oauth/authorize` on `auth.openai.com`; Anthropic uses
    /// `oauth/authorize` on `claude.ai`.
    var authorizePath: String
    /// Full token-exchange URL. We don't derive this from `issuer`
    /// because Anthropic splits authorize (`claude.ai`) and token
    /// (`platform.claude.com`) across two hosts — see
    /// `OAuthProvider.anthropic`.
    var tokenURL: URL

    var authorizeURL: URL { issuer.appendingPathComponent(authorizePath) }
    var scopeString: String { scopes.joined(separator: " ") }
}

/// Provider-discriminated in-memory credential the broker eventually
/// receives. Each case wraps the provider's **native on-disk shape**
/// verbatim — when Stage 1's broker materializes the blob into a
/// per-session agent home, it writes the inner struct to disk
/// byte-for-byte without normalization. That's why the two cases don't
/// share fields: codex's `auth.json` and Claude's `.credentials.json`
/// genuinely look nothing alike and squashing them together would
/// force translation on both write and read.
enum OAuthCredential: Sendable, Equatable {
    case openai(AuthDotJson)
    case anthropic(ClaudeCredentialsJson)

    /// Provider this credential belongs to. Used by the Keychain shim
    /// to pick its account key.
    var provider: OAuthProvider {
        switch self {
        case .openai: return .openai
        case .anthropic: return .anthropic
        }
    }
}

/// Shape of `~/.codex/auth.json` (PLAN §C.1, mirrors
/// `codex-rs/login/src/auth/storage.rs`'s `AuthDotJson`). The broker
/// writes this JSON to `<agent-home>/.codex/auth.json` byte-for-byte.
struct AuthDotJson: Codable, Sendable, Equatable {
    var authMode: String?        // "ChatGPT" for the OAuth path
    var openaiAPIKey: String?    // null on the ChatGPT path
    var tokens: TokenData?
    var lastRefresh: Date?
    var agentIdentity: String?

    struct TokenData: Codable, Sendable, Equatable {
        var idToken: String
        var accessToken: String
        var refreshToken: String
        var accountID: String?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case accountID = "account_id"
        }
    }

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case openaiAPIKey = "OPENAI_API_KEY"
        case tokens
        case lastRefresh = "last_refresh"
        case agentIdentity = "agent_identity"
    }

    // Custom encode: codex CLI's auth.json always emits OPENAI_API_KEY
    // (even on the ChatGPT path where it's null). Default JSONEncoder
    // omits nil optionals — emit explicit null for that one key so the
    // byte-for-byte parity with codex-rs/login/src/auth/storage.rs holds.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(authMode, forKey: .authMode)
        if let openaiAPIKey {
            try c.encode(openaiAPIKey, forKey: .openaiAPIKey)
        } else {
            try c.encodeNil(forKey: .openaiAPIKey)
        }
        try c.encodeIfPresent(tokens, forKey: .tokens)
        try c.encodeIfPresent(lastRefresh, forKey: .lastRefresh)
        try c.encodeIfPresent(agentIdentity, forKey: .agentIdentity)
    }
}

/// Shape of `~/.claude/.credentials.json` (PLAN §B.1). The broker
/// writes this JSON to `<agent-home>/.claude/.credentials.json`
/// byte-for-byte.
///
/// Why a nested `claudeAiOauth` instead of flat fields: the claude
/// CLI's on-disk file already wraps the OAuth blob under that key —
/// presumably so the same file can later host non-OAuth credentials
/// (API keys, helper-script paths) under sibling keys. We mirror it
/// exactly so the broker can `cp` the JSON without massaging.
struct ClaudeCredentialsJson: Codable, Sendable, Equatable {
    var claudeAiOauth: ClaudeAiOauth

    struct ClaudeAiOauth: Codable, Sendable, Equatable {
        var accessToken: String
        var refreshToken: String
        /// Milliseconds since Unix epoch. The claude CLI stores ms,
        /// not seconds — we preserve that so the broker can compare
        /// against `Date.now * 1000` directly.
        var expiresAt: Int64
        var scopes: [String]
        /// "max" / "pro" / "team" / etc. — surfaces to the UI so the
        /// user knows which plan is authorizing each request. The
        /// token endpoint may omit this on first issue; we leave it
        /// nil-able rather than defaulting to a string we'd have to
        /// later disambiguate from "actually missing".
        var subscriptionType: String?
    }
}

/// Errors surfaced from `OAuthClient.startLogin()`. The UI maps them to
/// human strings; the test layer pins the case identities.
enum OAuthClientError: Error, Equatable {
    case userCancelled
    case missingCallback
    case missingCode
    case tokenExchangeFailed(status: Int, body: String)
    case malformedTokenResponse
    case underlying(String)
}

/// PKCE + OAuth-code-exchange driver. Stateless across calls — each
/// `startLogin()` generates a fresh verifier + state.
@MainActor
final class OAuthClient: NSObject, ASWebAuthenticationPresentationContextProviding {
    let provider: OAuthProvider
    let urlSession: URLSession

    /// Optional injection seam — `nil` outside of tests; tests pass a
    /// fixed verifier to make `state` + `code_challenge` deterministic.
    var deterministicVerifier: String?

    init(provider: OAuthProvider, urlSession: URLSession = .shared) {
        self.provider = provider
        self.urlSession = urlSession
    }

    // MARK: - Public entry point

    func startLogin() async throws -> OAuthCredential {
        let cfg = provider.config
        let verifier = deterministicVerifier ?? Self.generateCodeVerifier()
        let challenge = Self.codeChallenge(from: verifier)
        let state = Self.generateRandomURLSafe(byteCount: 16)

        let authorizeURL = try buildAuthorizeURL(
            config: cfg,
            codeChallenge: challenge,
            state: state
        )

        let callbackURL = try await runWebAuthSession(
            authorizeURL: authorizeURL,
            callbackScheme: cfg.callbackURLScheme
        )

        let code = try Self.extractAuthorizationCode(from: callbackURL)
        return try await exchangeCodeForCredential(
            code: code,
            verifier: verifier,
            config: cfg
        )
    }

    // MARK: - PKCE math (unit-tested)

    /// Generates a high-entropy PKCE code_verifier per RFC 7636 §4.1.
    /// 64 random bytes → base64url(no-padding) ≈ 86 chars, well inside
    /// the [43, 128] character bound the spec allows.
    nonisolated static func generateCodeVerifier() -> String {
        generateRandomURLSafe(byteCount: 64)
    }

    /// RFC 7636 §4.2 — code_challenge = BASE64URL-ENCODE(SHA256(ASCII(verifier))).
    /// `verifier` is required to be ASCII; we deliberately don't
    /// validate that here (the generator only emits ASCII) so the
    /// function stays pure for testing.
    nonisolated static func codeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let digest = SHA256.hash(data: data)
        return base64URLEncode(Data(digest))
    }

    /// RFC 4648 §5 base64url, no padding. Hoisted for the test layer +
    /// reuse in `extractAuthorizationCode`.
    nonisolated static func base64URLEncode(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        s = s.replacingOccurrences(of: "=", with: "")
        return s
    }

    /// Random URL-safe string of `ceil(byteCount * 4 / 3)` chars (after
    /// stripping padding). Backed by `SecRandomCopyBytes` — no
    /// `arc4random` fallback because we'd rather crash than emit weak
    /// entropy for a PKCE verifier.
    nonisolated static func generateRandomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed (\(status))")
        return base64URLEncode(Data(bytes))
    }

    // MARK: - URL construction

    private func buildAuthorizeURL(
        config: OAuthConfig,
        codeChallenge: String,
        state: String
    ) throws -> URL {
        var comps = URLComponents(url: config.authorizeURL, resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: config.scopeString),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = comps?.url else {
            throw OAuthClientError.underlying("authorize URL build failed")
        }
        return url
    }

    nonisolated static func extractAuthorizationCode(from callback: URL) throws -> String {
        let comps = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        if let err = comps?.queryItems?.first(where: { $0.name == "error" })?.value {
            throw OAuthClientError.underlying("authorize-redirect error: \(err)")
        }
        guard let code = comps?.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            throw OAuthClientError.missingCode
        }
        return code
    }

    // MARK: - ASWebAuthenticationSession driver

    private func runWebAuthSession(
        authorizeURL: URL,
        callbackScheme: String
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: authorizeURL,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error {
                    if let asErr = error as? ASWebAuthenticationSessionError,
                       asErr.code == .canceledLogin {
                        cont.resume(throwing: OAuthClientError.userCancelled)
                    } else {
                        cont.resume(throwing: OAuthClientError.underlying("\(error)"))
                    }
                    return
                }
                guard let callbackURL else {
                    cont.resume(throwing: OAuthClientError.missingCallback)
                    return
                }
                cont.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            // Share cookies with Safari so a user already signed in to
            // ChatGPT in Safari skips the password prompt.
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Pick the first active foreground window. iOS 26's scene model
        // makes this the canonical lookup; the only fallback path is a
        // detached anchor, which iOS treats as "host me yourself".
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return window
        }
        if let window = scenes.flatMap(\.windows).first {
            return window
        }
        return ASPresentationAnchor()
    }

    // MARK: - Token exchange

    private func exchangeCodeForCredential(
        code: String,
        verifier: String,
        config: OAuthConfig
    ) async throws -> OAuthCredential {
        var req = URLRequest(url: config.tokenURL)
        req.httpMethod = "POST"
        req.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI.absoluteString),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        req.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch {
            throw OAuthClientError.underlying("token POST failed: \(error)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw OAuthClientError.underlying("non-HTTP token response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthClientError.tokenExchangeFailed(status: http.statusCode, body: body)
        }

        switch provider {
        case .openai:   return .openai(try Self.decodeOpenAITokenResponse(data))
        case .anthropic: return .anthropic(try Self.decodeAnthropicTokenResponse(data))
        }
    }

    /// The OpenAI `/oauth/token` JSON response is the standard OAuth
    /// shape (`{ access_token, refresh_token, id_token, ... }`). We map
    /// it onto the codex CLI's `AuthDotJson` so downstream stages
    /// (broker materialization) get the file shape they expect.
    nonisolated static func decodeOpenAITokenResponse(_ data: Data) throws -> AuthDotJson {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthClientError.malformedTokenResponse
        }
        guard let access = obj["access_token"] as? String,
              let id = obj["id_token"] as? String else {
            throw OAuthClientError.malformedTokenResponse
        }
        // `refresh_token` is technically optional on OAuth — but the
        // `offline_access` scope means OpenAI always returns one. Treat
        // a missing one as malformed so we fail loudly in Stage 0
        // rather than persist a half-credential.
        guard let refresh = obj["refresh_token"] as? String else {
            throw OAuthClientError.malformedTokenResponse
        }
        let accountID = obj["account_id"] as? String

        return AuthDotJson(
            authMode: "ChatGPT",
            openaiAPIKey: nil,
            tokens: .init(
                idToken: id,
                accessToken: access,
                refreshToken: refresh,
                accountID: accountID
            ),
            lastRefresh: Date(),
            agentIdentity: nil
        )
    }

    /// Decode Anthropic's `/v1/oauth/token` response into the
    /// `.credentials.json` shape (PLAN §B.1). The endpoint returns a
    /// standard OAuth-ish blob — `access_token`, `refresh_token`,
    /// `expires_in` (seconds), `scope` (space-separated) — and may
    /// include vendor-specific `subscription_type` / `account.subscription`
    /// fields. We map it onto `ClaudeCredentialsJson` so the broker can
    /// write it directly to `~/.claude/.credentials.json`.
    ///
    /// `expiresAt` is computed as `(now + expires_in_seconds) * 1000`
    /// because the on-disk file stores ms-since-epoch (not seconds-until,
    /// not seconds-since). Doing the conversion here keeps the broker
    /// dumb: it just JSON-encodes and writes.
    nonisolated static func decodeAnthropicTokenResponse(_ data: Data) throws -> ClaudeCredentialsJson {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthClientError.malformedTokenResponse
        }
        guard let access = obj["access_token"] as? String,
              let refresh = obj["refresh_token"] as? String else {
            throw OAuthClientError.malformedTokenResponse
        }

        // `expires_in` is seconds-from-now per RFC 6749 §5.1. If
        // Anthropic ever switches to absolute `expires_at`, this branch
        // will keep working as long as the field name doesn't change —
        // we fall back to a 1-hour default otherwise (matches the
        // claude CLI's empirical refresh cadence).
        let expiresInSec: Double
        if let s = obj["expires_in"] as? Double { expiresInSec = s }
        else if let s = obj["expires_in"] as? Int { expiresInSec = Double(s) }
        else { expiresInSec = 3600 }
        let expiresAtMs = Int64((Date().timeIntervalSince1970 + expiresInSec) * 1000)

        // Scopes come back as a single space-delimited string per
        // RFC 6749 §3.3. Splitting here lets the broker write the
        // claudeAiOauth.scopes array verbatim.
        let scopes: [String]
        if let s = obj["scope"] as? String {
            scopes = s.split(separator: " ").map(String.init)
        } else if let arr = obj["scope"] as? [String] {
            scopes = arr
        } else {
            scopes = []
        }

        // Anthropic's docs don't pin where `subscription_type` lives.
        // Accept either the flat `subscription_type` field or a nested
        // `account.subscription` object — whichever appears.
        let subscription: String?
        if let s = obj["subscription_type"] as? String {
            subscription = s
        } else if let account = obj["account"] as? [String: Any],
                  let s = account["subscription"] as? String {
            subscription = s
        } else {
            subscription = nil
        }

        return ClaudeCredentialsJson(
            claudeAiOauth: .init(
                accessToken: access,
                refreshToken: refresh,
                expiresAt: expiresAtMs,
                scopes: scopes,
                subscriptionType: subscription
            )
        )
    }
}

/// Persistence shim used by `AgentLoginSheet`. Keeps the OAuth blob in
/// its own Keychain service (`"sh.nikhil.swekitty.oauth"`) keyed by
/// provider, so the legacy pairing keys never collide with credential
/// blobs and a "wipe-OAuth" affordance can blow them away without
/// touching pairing state.
///
/// Each provider's blob is stored in its **native disk shape** — for
/// `.openai` that's `AuthDotJson`, for `.anthropic` that's
/// `ClaudeCredentialsJson`. We don't wrap them in a tagged-enum
/// envelope on disk because the Keychain account already names the
/// provider, and Stage 2's broker will eventually want to lift the
/// bytes straight onto disk without unwrapping anything.
enum OAuthCredentialStore {
    static let service = "sh.nikhil.swekitty.oauth"

    static func save(_ credential: OAuthCredential) throws {
        let data: Data
        switch credential {
        case .openai(let blob):   data = try JSONEncoder().encode(blob)
        case .anthropic(let blob): data = try JSONEncoder().encode(blob)
        }
        Keychain.set(data, service: service, account: credential.provider.keychainAccount)
    }

    static func load(provider: OAuthProvider) -> OAuthCredential? {
        guard let data = Keychain.get(service: service, account: provider.keychainAccount) else {
            return nil
        }
        switch provider {
        case .openai:
            return (try? JSONDecoder().decode(AuthDotJson.self, from: data)).map { .openai($0) }
        case .anthropic:
            return (try? JSONDecoder().decode(ClaudeCredentialsJson.self, from: data)).map { .anthropic($0) }
        }
    }

    static func clear(provider: OAuthProvider) {
        Keychain.delete(service: service, account: provider.keychainAccount)
    }
}
