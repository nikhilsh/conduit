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
    /// Uppercase plan badge ("MAX" / "PRO" / "PLUS" …) — nil hides the badge.
    let planLabel: String?

    var id: String { agent }

    /// Current status for both agent accounts, Claude first (stable order,
    /// matches the usage surfaces).
    static func current() -> [AgentAccountStatus] {
        [
            load(agent: "claude", displayName: "Claude", provider: .anthropic),
            load(agent: "codex", displayName: "Codex", provider: .openai),
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
            planLabel: credential.flatMap(planLabel(for:))
        )
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
