import XCTest
@testable import Conduit

/// Plan-badge derivation for the Settings → Accounts rows (Round-2 fix 3).
/// Pure decode logic — no Keychain, no network.
final class AgentAccountStatusTests: XCTestCase {

    private func jwt(payloadJSON: String) -> String {
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64url("{\"alg\":\"none\"}")).\(b64url(payloadJSON)).sig"
    }

    func testChatgptPlanTypeReadsAuthClaim() {
        let token = jwt(payloadJSON: #"{"https://api.openai.com/auth":{"chatgpt_plan_type":"pro","user_id":"u"}}"#)
        XCTAssertEqual(AgentAccountStatus.chatgptPlanType(fromIDToken: token), "pro")
    }

    func testChatgptPlanTypeNilWhenClaimMissing() {
        XCTAssertNil(AgentAccountStatus.chatgptPlanType(fromIDToken: jwt(payloadJSON: #"{"sub":"u"}"#)))
        XCTAssertNil(AgentAccountStatus.chatgptPlanType(fromIDToken: "not-a-jwt"))
        XCTAssertNil(AgentAccountStatus.chatgptPlanType(fromIDToken: ""))
    }

    func testPlanLabelUppercasesClaudeSubscription() {
        let credential = OAuthCredential.anthropic(
            ClaudeCredentialsJson(
                claudeAiOauth: .init(
                    accessToken: "a",
                    refreshToken: "r",
                    expiresAt: 0,
                    scopes: [],
                    subscriptionType: "max"
                )
            )
        )
        XCTAssertEqual(AgentAccountStatus.planLabel(for: credential), "MAX")
    }

    func testPlanLabelNilWhenClaudeSubscriptionAbsent() {
        let credential = OAuthCredential.anthropic(
            ClaudeCredentialsJson(
                claudeAiOauth: .init(
                    accessToken: "a",
                    refreshToken: "r",
                    expiresAt: 0,
                    scopes: [],
                    subscriptionType: nil
                )
            )
        )
        XCTAssertNil(AgentAccountStatus.planLabel(for: credential))
    }

    // MARK: isExpired (round-4 — Settings must not say "signed in" for a
    // credential the broker already refuses as expired)

    private func anthropicCredential(expiresAt: Int64) -> OAuthCredential {
        .anthropic(
            ClaudeCredentialsJson(
                claudeAiOauth: .init(
                    accessToken: "a",
                    refreshToken: "r",
                    expiresAt: expiresAt,
                    scopes: [],
                    subscriptionType: nil
                )
            )
        )
    }

    func testAnthropicExpiredWhenPastExpiresAt() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        // expiresAt is ms-since-epoch; one second in the past.
        let cred = anthropicCredential(expiresAt: Int64((2_000_000 - 1) * 1000))
        XCTAssertTrue(AgentAccountStatus.isExpired(cred, now: now))
    }

    func testAnthropicFreshWhenBeforeExpiresAt() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let cred = anthropicCredential(expiresAt: Int64((2_000_000 + 3600) * 1000))
        XCTAssertFalse(AgentAccountStatus.isExpired(cred, now: now))
    }
}
