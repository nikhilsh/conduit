import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

/// Stage 0 of `docs/PLAN-AGENT-OAUTH.md` — iOS-only ChatGPT (OpenAI /
/// Codex) OAuth spike.
///
/// Drives PKCE S256 → `ASWebAuthenticationSession` → token exchange
/// against `https://auth.openai.com/oauth/token`. Returns a `Credential`
/// blob whose shape matches what the `codex` CLI persists at
/// `~/.codex/auth.json` (see PLAN §C.1 for the verbatim schema). That
/// way Stage 1's broker can write the blob to disk unmodified.
///
/// Out of scope for Stage 0: refresh, broker wiring, Claude flow.
///
/// Why `swekitty://` custom scheme instead of loopback `http://127.0.0.1:1455/auth/callback`
/// (which is what the codex CLI uses): `ASWebAuthenticationSession`
/// requires a `callbackURLScheme:` that is a non-http custom scheme —
/// it won't intercept http loopback URLs (litter works around this by
/// running its own loopback HTTP server on the phone, which we
/// deliberately don't replicate, see §A.4 "Borrow vs diverge"). The
/// risk this exposes — OpenAI may reject the custom-scheme redirect at
/// `/oauth/authorize` — is documented in the PR; if so we'll fall back
/// to litter's loopback server in a follow-up.
enum OAuthProvider: String, Sendable {
    case openai

    var config: OAuthConfig {
        switch self {
        case .openai:
            return OAuthConfig(
                issuer: URL(string: "https://auth.openai.com")!,
                // Codex CLI public client ID — see PLAN §C.2.
                clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
                scopes: ["openid", "profile", "email", "offline_access"],
                redirectURI: URL(string: "swekitty://oauth/openai/callback")!,
                callbackURLScheme: "swekitty"
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

    var authorizeURL: URL { issuer.appendingPathComponent("oauth/authorize") }
    var tokenURL: URL { issuer.appendingPathComponent("oauth/token") }
    var scopeString: String { scopes.joined(separator: " ") }
}

/// In-memory shape of the credential blob the broker eventually
/// receives. Schema mirrors `codex-rs/login/src/auth/storage.rs`'s
/// `AuthDotJson` (PLAN §C.1). We keep the field names verbatim — when
/// Stage 1 lands, the broker writes this JSON to
/// `<agent-home>/.codex/auth.json` byte-for-byte.
struct OAuthCredential: Codable, Sendable, Equatable {
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
    static func generateCodeVerifier() -> String {
        generateRandomURLSafe(byteCount: 64)
    }

    /// RFC 7636 §4.2 — code_challenge = BASE64URL-ENCODE(SHA256(ASCII(verifier))).
    /// `verifier` is required to be ASCII; we deliberately don't
    /// validate that here (the generator only emits ASCII) so the
    /// function stays pure for testing.
    static func codeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let digest = SHA256.hash(data: data)
        return base64URLEncode(Data(digest))
    }

    /// RFC 4648 §5 base64url, no padding. Hoisted for the test layer +
    /// reuse in `extractAuthorizationCode`.
    static func base64URLEncode(_ data: Data) -> String {
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
    static func generateRandomURLSafe(byteCount: Int) -> String {
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

    static func extractAuthorizationCode(from callback: URL) throws -> String {
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

        return try Self.decodeTokenResponse(data)
    }

    /// The OpenAI `/oauth/token` JSON response is the standard OAuth
    /// shape (`{ access_token, refresh_token, id_token, ... }`). We map
    /// it onto the codex CLI's `AuthDotJson` so downstream stages
    /// (broker materialization) get the file shape they expect.
    static func decodeTokenResponse(_ data: Data) throws -> OAuthCredential {
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

        return OAuthCredential(
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
}

/// Persistence shim used by `AgentLoginSheet`. Keeps the OAuth blob in
/// its own Keychain service (`"sh.nikhil.swekitty.oauth"`) keyed by
/// provider, so the legacy pairing keys never collide with credential
/// blobs and a "wipe-OAuth" affordance can blow them away without
/// touching pairing state.
enum OAuthCredentialStore {
    static let service = "sh.nikhil.swekitty.oauth"

    static func save(_ credential: OAuthCredential, provider: OAuthProvider) throws {
        let data = try JSONEncoder().encode(credential)
        Keychain.set(data, service: service, account: provider.keychainAccount)
    }

    static func load(provider: OAuthProvider) -> OAuthCredential? {
        guard let data = Keychain.get(service: service, account: provider.keychainAccount) else {
            return nil
        }
        return try? JSONDecoder().decode(OAuthCredential.self, from: data)
    }

    static func clear(provider: OAuthProvider) {
        Keychain.delete(service: service, account: provider.keychainAccount)
    }
}
