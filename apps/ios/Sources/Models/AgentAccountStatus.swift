import Foundation

// MARK: - AgentAccountStatus
//
// Signed-in state + plan badge for the per-agent account rows in Settings →
// Accounts (Round-2 fix 3, Conduit_Fixes_Handoff images 05→06). Derived
// entirely from the locally stored OAuth credential (Keychain) — no network,
// no new data flow. Claude's credential JSON carries `subscriptionType`
// ("max" / "pro" / "team"); Codex encodes `chatgpt_plan_type` inside the
// id_token's `https://api.openai.com/auth` claim. Where the provider omitted
// the plan we show no badge rather than fabricating one.

struct AgentAccountStatus: Identifiable, Equatable {
    /// UI agent key — drives tint + avatar ("claude" / "codex").
    let agent: String
    let provider: OAuthProvider
    /// Friendly row title ("Claude" / "Codex").
    let displayName: String
    let signedIn: Bool
    /// True when a stored credential exists but its access token is past
    /// `expiresAt` (round-4 device feedback: the broker had logged
    /// "stored anthropic OAuth blob expired … using host credentials"
    /// while Settings still said "signed in" — `credential != nil` alone
    /// is not the truth). Expired ⇒ the broker won't use this credential
    /// for new sessions; the row asks for a re-sign-in.
    let expired: Bool
    /// Uppercase plan badge ("MAX" / "PRO" / "PLUS" …) — nil hides the badge.
    let planLabel: String?

    var id: String { agent }

    /// Signed in AND usable — what the green dot should actually mean.
    var usable: Bool { signedIn && !expired }

    /// Current status for agent accounts that have an OAuth login provider.
    ///
    /// When `descriptors` is non-empty (broker PR #440+), the list is built
    /// from the agents that advertise a `login_provider` in their descriptor,
    /// using each descriptor's `display_name`. Claude appears first for
    /// display stability; unknown providers are skipped (no credential type).
    ///
    /// When `descriptors` is nil/empty the static two-agent hardcoding is
    /// used so behaviour is unchanged on old brokers (WS-3.1 fallback rule).
    static func current(descriptors: [String: AgentDescriptor]? = nil) -> [AgentAccountStatus] {
        // Descriptor-driven path (new broker).
        if let descriptors, !descriptors.isEmpty {
            let pairs: [(agent: String, displayName: String, loginProvider: String)] = descriptors
                .compactMap { (key, desc) in
                    guard !desc.loginProvider.isEmpty else { return nil }
                    let name = desc.displayName.isEmpty ? key.capitalized : desc.displayName
                    return (agent: key, displayName: name, loginProvider: desc.loginProvider)
                }
                // Claude first, then alphabetical for stable ordering.
                .sorted { a, b in
                    if a.agent == "claude" { return true }
                    if b.agent == "claude" { return false }
                    return a.agent < b.agent
                }
            return pairs.compactMap { pair in
                guard let provider = OAuthProvider(loginProvider: pair.loginProvider) else { return nil }
                return load(agent: pair.agent, displayName: pair.displayName, provider: provider)
            }
        }
        // Static fallback (old broker or no descriptors yet).
        return [
            load(agent: "claude", displayName: "Claude", provider: .anthropic),
            load(agent: "codex",  displayName: "Codex",  provider: .openai),
        ]
    }

    private static func load(
        agent: String,
        displayName: String,
        provider: OAuthProvider
    ) -> AgentAccountStatus {
        let credential = OAuthCredentialStore.load(provider: provider)
        return AgentAccountStatus(
            agent: agent,
            provider: provider,
            displayName: displayName,
            signedIn: credential != nil,
            expired: credential.map { isExpired($0) } ?? false,
            planLabel: credential.flatMap(planLabel(for:))
        )
    }

    /// Whether a stored credential's access token is past its expiry.
    /// Mirrors the broker's own check (`expiry < host now` → it falls
    /// back to host credentials), so Settings tells the same story the
    /// broker acts on.
    ///   - anthropic: `claudeAiOauth.expiresAt` is ms-since-epoch.
    ///   - openai: no client-side expiry check — the codex CLI refreshes
    ///     its own token server-side from auth.json, so a stale id_token
    ///     here does NOT mean logged out.
    static func isExpired(_ credential: OAuthCredential, now: Date = Date()) -> Bool {
        switch credential {
        case .anthropic(let blob):
            return Double(blob.claudeAiOauth.expiresAt) < now.timeIntervalSince1970 * 1000
        case .openai:
            return false
        }
    }

    /// Plan badge text from a stored credential, uppercased for the mono
    /// badge capsule. nil when the provider didn't report a plan.
    static func planLabel(for credential: OAuthCredential) -> String? {
        switch credential {
        case .anthropic(let blob):
            let plan = blob.claudeAiOauth.subscriptionType?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (plan?.isEmpty == false) ? plan?.uppercased() : nil
        case .openai(let blob):
            guard let idToken = blob.tokens?.idToken else { return nil }
            return chatgptPlanType(fromIDToken: idToken)?.uppercased()
        }
    }

    /// Reads `chatgpt_plan_type` out of the id_token's
    /// `https://api.openai.com/auth` claim. UNVERIFIED decode (no signature
    /// check) — display-only metadata, never used for auth decisions.
    static func chatgptPlanType(fromIDToken jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let auth = obj["https://api.openai.com/auth"] as? [String: Any],
              let plan = auth["chatgpt_plan_type"] as? String,
              !plan.isEmpty
        else { return nil }
        return plan
    }
}

// MARK: - AgentBoxStatus
//
// Stage-2 per-box readiness line (the SECOND line of each agent-account row):
// whether the CONNECTED box already holds this agent's credential, derived from
// `brokerReadiness.agents[<agent>].signedIn`. View-agnostic (no SwiftUI Color)
// so both ConduitAgentLoginSheet and ConduitSettingsView render it identically;
// each view maps `tone` to its own theme color.
struct AgentBoxStatus: Equatable {
    enum Tone { case ready, absent }
    let text: String
    let tone: Tone

    /// Build line 2 for the given agent against a connected box.
    /// Returns nil when there is no connected box OR readiness is unknown
    /// (old broker / not yet fetched) -- in those cases line 2 is HIDDEN so we
    /// never assert a false per-box state.
    ///   - boxName: the connected box's display name (nil = no box connected).
    ///   - signedIn: `brokerReadiness.agents[agent].signedIn` (nil = unknown).
    static func make(agent: String, boxName: String?, signedIn: Bool?) -> AgentBoxStatus? {
        guard let boxName, let signedIn else { return nil }
        if signedIn {
            return AgentBoxStatus(text: "Ready on \(boxName)", tone: .ready)
        }
        return AgentBoxStatus(text: "Not on \(boxName) - auto-pushes on connect", tone: .absent)
    }
}
