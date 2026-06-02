import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

// MARK: - Phone-side OAuth (litter-faithful) — the LIVE login path
//
// This file drives the in-app OAuth flow that lets a phone-side user
// log in to ChatGPT (Codex/OpenAI) and Claude (Anthropic) on their own
// account: PKCE on the phone → native browser → token exchange on the
// phone → ship the provider-native credential blob to the broker via
// `set_agent_credentials`. The broker stores it encrypted and
// materializes a per-session `~/.codex/auth.json` /
// `~/.claude/.credentials.json` (see `broker/internal/credentials/`).
//
// History: the earlier attempt used a `conduit://` custom-scheme
// redirect, which BOTH providers reject at `/oauth/authorize`. The fix
// (this revision) follows litter (`dnakov/litter`): use the providers'
// real, whitelisted redirects —
//   - OpenAI/Codex: a loopback `http://localhost:1455/auth/callback`
//     captured by an in-app `AgentLoginLoopbackServer` (RFC 8252),
//   - Anthropic/Claude: the `https://platform.claude.com/oauth/code/callback`
//     code-display page; the user copies the shown code and pastes it
//     back into the app (the `claude` CLI's own flow).
// — never a custom scheme at the authorize step. `captureMode` on
// `OAuthConfig` is the seam between the two.

/// iOS OAuth driver for the two agent providers we ship: ChatGPT
/// (OpenAI / Codex) and Claude (Anthropic).
///
/// Drives PKCE S256 → native browser → token exchange against the
/// provider's token endpoint. Returns an `OAuthCredential` case whose
/// payload matches what the CLI persists on disk (`~/.codex/auth.json`
/// for OpenAI, `~/.claude/.credentials.json` for Anthropic — see PLAN
/// §B.1 / §C.1 for verbatim schemas). The broker writes either blob to
/// disk unmodified.
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
                // Loopback redirect — the exact one the codex CLI's own
                // login server uses (`codex-rs/login/src/server.rs`:
                // DEFAULT_PORT 1455, path /auth/callback). This client_id
                // whitelists it; an in-app `AgentLoginLoopbackServer`
                // catches the browser redirect on the device.
                redirectURI: URL(string: "http://localhost:1455/auth/callback")!,
                callbackURLScheme: "conduit",
                captureMode: .loopback(port: 1455, path: "/auth/callback"),
                authorizePath: "oauth/authorize",
                tokenURL: URL(string: "https://auth.openai.com/oauth/token")!
            )
        case .anthropic:
            // Claude Code CLI's OAuth params. The client_id + endpoints
            // here were reverse-engineered from the `claude` CLI binary
            // and confirmed against `claude auth login --claudeai`'s
            // actual stdout (authorize host claude.ai, redirect
            // platform.claude.com/oauth/code/callback, the `code=true`
            // flag that selects the code-display page). Anthropic
            // doesn't publish these. Risks:
            //
            //   1. Anthropic may rotate the client_id without notice; we
            //      ship an app update if it happens (same risk litter
            //      accepts for Codex).
            //   2. Claude uses a CODE-PASTE flow, not a loopback: the
            //      browser lands on platform.claude.com which *displays*
            //      a `code#state` string; the user copies it and pastes
            //      it back into the app (captureMode `.codePaste`). The
            //      token exchange still happens on the phone.
            //
            // NEEDS ON-DEVICE VERIFICATION: token endpoint shape + whether
            // the exchange requires `state` are reverse-engineered.
            return OAuthConfig(
                issuer: URL(string: "https://claude.ai")!,
                clientID: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
                // EXACT scope set the real `claude auth login --claudeai`
                // sends (captured from the CLI's authorize URL). Missing
                // `org:create_api_key` made claude.ai reject the request
                // with "Authorization failed: Invalid request format".
                scopes: [
                    "org:create_api_key",
                    "user:profile",
                    "user:inference",
                    "user:sessions:claude_code",
                    "user:mcp_servers",
                    "user:file_upload",
                ],
                // The real, whitelisted redirect the CLI uses — a remote
                // page that displays the code (no loopback to intercept).
                redirectURI: URL(string: "https://platform.claude.com/oauth/code/callback")!,
                callbackURLScheme: "conduit",
                captureMode: .codePaste,
                // Anthropic splits authorize (claude.ai) from token
                // exchange (platform.claude.com) — `issuer` alone
                // can't derive both, hence the explicit `tokenURL`.
                authorizePath: "oauth/authorize",
                tokenURL: URL(string: "https://platform.claude.com/v1/oauth/token")!,
                // `code=true` selects the copy-paste code-display page
                // instead of an auto-redirect; observed in the CLI's URL.
                extraAuthorizeParams: ["code": "true"]
            )
        }
    }

    /// Keychain account used to persist the resulting credential blob.
    /// Service is `"sh.nikhil.conduit.oauth"` (see `OAuthCredentialStore`).
    var keychainAccount: String { rawValue }
}

/// How the phone captures the authorization `code` after the user
/// finishes the browser consent step — the one thing that genuinely
/// differs between the two providers.
enum OAuthCaptureMode: Sendable, Equatable {
    /// RFC 8252 loopback: the provider redirects the browser to
    /// `http://localhost:<port><path>?code=...`; an in-app
    /// `AgentLoginLoopbackServer` catches it. Used by OpenAI/Codex.
    case loopback(port: UInt16, path: String)
    /// Code-display: the provider shows a `code#state` string the user
    /// copies and pastes back into the app. Used by Anthropic/Claude.
    case codePaste
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
    /// How the `code` comes back — loopback (codex) vs paste (claude).
    var captureMode: OAuthCaptureMode
    /// Path appended to `issuer` for the authorize endpoint. OpenAI
    /// uses `oauth/authorize` on `auth.openai.com`; Anthropic uses
    /// `oauth/authorize` on `claude.ai`.
    var authorizePath: String
    /// Full token-exchange URL. We don't derive this from `issuer`
    /// because Anthropic splits authorize (`claude.ai`) and token
    /// (`platform.claude.com`) across two hosts — see
    /// `OAuthProvider.anthropic`.
    var tokenURL: URL
    /// Extra query items appended to the authorize URL (e.g. Claude's
    /// `code=true` code-display selector). Empty for OpenAI.
    var extraAuthorizeParams: [String: String] = [:]

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
    var authMode: String?        // "chatgpt" for the OAuth path (lowercase, matches codex on disk)
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

    // Transient per-attempt state. `pending*` bridge the gap between
    // opening the browser and the user pasting the code (code-paste
    // flow). The continuation + handles drive the loopback flow and are
    // cleared by `resumeLogin` exactly once.
    private var pendingVerifier: String?
    private var pendingState: String?
    private var loginContinuation: CheckedContinuation<String, Error>?
    private var loopbackServer: AgentLoginLoopbackServer?
    private var webSession: ASWebAuthenticationSession?

    init(provider: OAuthProvider, urlSession: URLSession = .shared) {
        self.provider = provider
        self.urlSession = urlSession
    }

    // MARK: - Public entry points

    /// Loopback flow (OpenAI/Codex). Opens the browser, captures the
    /// redirect on an in-app loopback listener, exchanges the code, and
    /// returns the credential. Throws for code-paste providers — use
    /// `beginCodePasteAuthorize()` / `finishCodePaste(_:)` for those.
    func startLogin() async throws -> OAuthCredential {
        let cfg = provider.config
        guard case .loopback(let port, let path) = cfg.captureMode else {
            throw OAuthClientError.underlying("startLogin() is for loopback providers; use the code-paste API")
        }
        let verifier = deterministicVerifier ?? Self.generateCodeVerifier()
        let challenge = Self.codeChallenge(from: verifier)
        let state = Self.generateRandomURLSafe(byteCount: 16)
        let authorizeURL = try buildAuthorizeURL(config: cfg, codeChallenge: challenge, state: state)

        let code = try await captureLoopbackCode(authorizeURL: authorizeURL, cfg: cfg, port: port, path: path)
        return try await exchangeCodeForCredential(code: code, verifier: verifier, state: state, config: cfg)
    }

    /// Code-paste flow step 1 (Anthropic/Claude). Generates PKCE, stashes
    /// the verifier/state for step 2, and returns the authorize URL the
    /// caller should open in the system browser. The provider displays a
    /// `code#state` string the user copies.
    func beginCodePasteAuthorize() throws -> URL {
        let cfg = provider.config
        let verifier = deterministicVerifier ?? Self.generateCodeVerifier()
        let challenge = Self.codeChallenge(from: verifier)
        let state = Self.generateRandomURLSafe(byteCount: 16)
        pendingVerifier = verifier
        pendingState = state
        return try buildAuthorizeURL(config: cfg, codeChallenge: challenge, state: state)
    }

    /// Code-paste flow step 2. Takes what the user pasted (the provider
    /// shows `code#state`; we split on `#`), exchanges it, and returns
    /// the credential.
    func finishCodePaste(pasted: String) async throws -> OAuthCredential {
        let cfg = provider.config
        guard let verifier = pendingVerifier else {
            throw OAuthClientError.underlying("no pending code-paste flow — call beginCodePasteAuthorize() first")
        }
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        // Claude's code-display page shows "<code>#<state>". Split off the
        // code; prefer the pasted state for the exchange, else the one we
        // generated.
        let segs = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let code = segs.first.map(String.init) ?? trimmed
        let state = segs.count > 1 ? String(segs[1]) : (pendingState ?? "")
        guard !code.isEmpty else { throw OAuthClientError.missingCode }
        defer { pendingVerifier = nil; pendingState = nil }
        return try await exchangeCodeForCredential(code: code, verifier: verifier, state: state, config: cfg)
    }

    // MARK: - Loopback capture

    private func captureLoopbackCode(authorizeURL: URL, cfg: OAuthConfig, port: UInt16, path: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.loginContinuation = cont
            let server = AgentLoginLoopbackServer(port: port, path: path)
            self.loopbackServer = server
            do {
                try server.start(timeout: 600) { [weak self] result in
                    Task { @MainActor in
                        guard let self else { return }
                        switch result {
                        case .success(let cb):
                            if !cb.errorReason.isEmpty {
                                self.resumeLogin(.failure(OAuthClientError.underlying("provider error: \(cb.errorReason)")))
                            } else if cb.code.isEmpty {
                                self.resumeLogin(.failure(OAuthClientError.missingCode))
                            } else {
                                self.resumeLogin(.success(cb.code))
                            }
                        case .failure(let err):
                            self.resumeLogin(.failure(err))
                        }
                    }
                }
            } catch {
                self.resumeLogin(.failure(error))
                return
            }
            // Open the browser. The loopback redirect is http://localhost,
            // which ASWebAuthenticationSession won't treat as its callback
            // scheme — so its success closure never fires; the loopback
            // listener above delivers the code. This completion only fires
            // on user-cancel / error.
            let session = ASWebAuthenticationSession(url: authorizeURL, callbackURLScheme: cfg.callbackURLScheme) { [weak self] _, error in
                Task { @MainActor in
                    guard let self, let error else { return }
                    if let asErr = error as? ASWebAuthenticationSessionError, asErr.code == .canceledLogin {
                        self.resumeLogin(.failure(OAuthClientError.userCancelled))
                    } else {
                        self.resumeLogin(.failure(OAuthClientError.underlying("\(error)")))
                    }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.webSession = session
            session.start()
        }
    }

    /// Resolves the loopback continuation exactly once and tears down the
    /// listener + browser. Safe to call from either the loopback callback
    /// or the web-session completion (whichever wins the race).
    private func resumeLogin(_ result: Result<String, Error>) {
        guard let cont = loginContinuation else { return }
        loginContinuation = nil
        loopbackServer?.stop()
        loopbackServer = nil
        webSession?.cancel()
        webSession = nil
        switch result {
        case .success(let code): cont.resume(returning: code)
        case .failure(let err): cont.resume(throwing: err)
        }
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
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: config.scopeString),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        // Provider-specific extras (e.g. Claude's `code=true`). Sorted so
        // the generated URL is deterministic for the test layer.
        for key in config.extraAuthorizeParams.keys.sorted() {
            items.append(URLQueryItem(name: key, value: config.extraAuthorizeParams[key]))
        }
        comps?.queryItems = items
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

    // MARK: - ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Pick the first active foreground window. iOS 26's scene model
        // makes this the canonical lookup. If nothing's foreground,
        // fall through to ANY connected scene's first window, and
        // finally construct a detached anchor against any connected
        // UIWindowScene (`UIWindow.init()` was deprecated in iOS 26 —
        // `init(windowScene:)` is the replacement).
        let foregroundScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        if let window = foregroundScenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return window
        }
        if let window = foregroundScenes.flatMap(\.windows).first {
            return window
        }
        guard let anyScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        else {
            // Truly unreachable in a running iOS app — by the time OAuth
            // launches, UIApplication has at least one connected scene.
            // The deprecated `UIWindow()` would otherwise be the only
            // way to satisfy the return type without a scene.
            preconditionFailure("OAuth presentation requested before any UIWindowScene attached")
        }
        if let window = anyScene.windows.first {
            return window
        }
        return UIWindow(windowScene: anyScene)
    }

    // MARK: - Token exchange

    private func exchangeCodeForCredential(
        code: String,
        verifier: String,
        state: String,
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
        var items = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI.absoluteString),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        // Anthropic's code-paste token exchange echoes the `state` from
        // the displayed `code#state` string; OpenAI's loopback exchange
        // does not need it (and we don't send it).
        if provider == .anthropic, !state.isEmpty {
            items.append(URLQueryItem(name: "state", value: state))
        }
        form.queryItems = items
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
            // Lowercase "chatgpt" — matches what a real `codex login` writes
            // to ~/.codex/auth.json. codex deserializes auth_mode
            // case-sensitively; "ChatGPT" fails to match → codex ignores the
            // OAuth tokens and falls back to API-key mode.
            authMode: "chatgpt",
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
/// its own Keychain service (`"sh.nikhil.conduit.oauth"`) keyed by
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
    static let service = "sh.nikhil.conduit.oauth"

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
