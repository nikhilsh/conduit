import Testing
import Foundation
@testable import Conduit

#if canImport(ActivityKit)
import ActivityKit
#endif

/// Sanity guards for the shared `ActivityAttributes` shape that ships
/// between the host app and the `ConduitWidgets` extension.
///
/// The widget extension target compiles the *same* `TurnActivityAttributes`
/// declaration we test here (see `apps/ios/project.yml`'s
/// `ConduitWidgets.sources` list). If the two ever drift — different
/// Codable shape, different generic conformance — the system rejects the
/// `Activity.request(...)` silently at runtime. These tests are a
/// compile-time + smoke check that the contract hasn't slipped.
@Suite("TurnLiveActivity widget contract")
struct TurnLiveActivityWidgetSanityTests {

    #if canImport(ActivityKit)
    @Test func attributesConformToActivityAttributes() {
        // Compile-time guarantee: if `TurnActivityAttributes` ever stops
        // conforming to `ActivityAttributes` this won't compile.
        let _: any ActivityAttributes.Type = TurnActivityAttributes.self
    }

    @Test func attributesRoundTripFromPureData() {
        let data = TurnActivityAttributesData(
            agentName: "claude", sessionID: "s-42", sessionName: "Code Review"
        )
        let attrs = TurnActivityAttributes(from: data)
        #expect(attrs.agentName == "claude")
        #expect(attrs.sessionID == "s-42")
        #expect(attrs.sessionName == "Code Review")
    }

    @Test func contentStateRoundTripFromPureData() throws {
        let state = TurnActivityContentState(
            currentTool: "Bash",
            currentCommand: "ls",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            tokensIn: 12,
            tokensOut: 34,
            status: "running",
            syncedAt: Date(timeIntervalSince1970: 1_700_000_100),
            summary: "exit 0"
        )
        let content = TurnActivityAttributes.ContentState(from: state)
        #expect(content.currentTool == "Bash")
        #expect(content.currentCommand == "ls")
        #expect(content.tokensIn == 12)
        #expect(content.tokensOut == 34)
        #expect(content.status == "running")
        #expect(content.syncedAt == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(content.summary == "exit 0")

        // Encode + decode so we catch a Codable-shape break the
        // moment a field rename slips past code review.
        // With the push-decodable custom Codable the encoded form uses
        // "startedAtMs"/"syncedAtMs" Int keys -- verify round-trip.
        let encoded = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(TurnActivityAttributes.ContentState.self, from: encoded)
        #expect(decoded == content)

        // Verify the epoch-millis keys are present in the encoded JSON
        // (push contract: broker sends these exact keys).
        // Use JSONSerialization to inspect raw values without type constraints.
        let rawJSON = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect((rawJSON?["startedAtMs"] as? Int) == 1_700_000_000_000)
        #expect((rawJSON?["syncedAtMs"]  as? Int) == 1_700_000_100_000)
    }

    /// Decode a push content-state JSON that matches the broker contract
    /// (spec SS2: epoch-millis timestamps, string interruptKind, etc.).
    /// This is the canonical test that the push path works end-to-end.
    @Test func contentStateDecodesFromBrokerPushJSON() throws {
        // Sample push content-state from the spec SS2 contract.
        let json = """
        {
          "currentTool": "Read",
          "currentCommand": "ls -la",
          "startedAtMs": 1749600000000,
          "syncedAtMs":  1749600005000,
          "tokensIn": 1234,
          "tokensOut": 56,
          "status": "running",
          "summary": null,
          "interruptKind": "choice",
          "prompt": "Which migration strategy?",
          "optionCount": 3
        }
        """
        let data = Data(json.utf8)
        let cs = try JSONDecoder().decode(TurnActivityAttributes.ContentState.self, from: data)

        #expect(cs.currentTool == "Read")
        #expect(cs.currentCommand == "ls -la")
        // 1749600000000 ms = 1749600000.0 s since epoch
        #expect(cs.startedAt == Date(timeIntervalSince1970: 1_749_600_000.0))
        #expect(cs.syncedAt  == Date(timeIntervalSince1970: 1_749_600_005.0))
        #expect(cs.tokensIn  == 1234)
        #expect(cs.tokensOut == 56)
        #expect(cs.status    == "running")
        #expect(cs.summary   == nil)
        #expect(cs.interruptKind == .choice)
        #expect(cs.prompt == "Which migration strategy?")
        #expect(cs.optionCount == 3)
    }

    /// Decode a push content-state with "end" / exited status shape
    /// (broker emits this on turn end).
    @Test func contentStateDecodesExitedPushJSON() throws {
        let json = """
        {
          "startedAtMs": 1749600000000,
          "syncedAtMs":  1749600060000,
          "tokensIn": 5000,
          "tokensOut": 800,
          "status": "exited",
          "summary": "exit 0"
        }
        """
        let data = Data(json.utf8)
        let cs = try JSONDecoder().decode(TurnActivityAttributes.ContentState.self, from: data)

        #expect(cs.currentTool == nil)
        #expect(cs.currentCommand == nil)
        #expect(cs.status  == "exited")
        #expect(cs.summary == "exit 0")
        #expect(cs.tokensIn == 5000)
        #expect(cs.tokensOut == 800)
        #expect(cs.interruptKind == nil)
    }
    #endif

    /// Always-on smoke: even without ActivityKit (e.g. in a future
    /// cross-platform compile), the pure-data layer the widget reads
    /// from must keep these fields. If someone renames them, this
    /// fails before the contract test even gets a chance to.
    @Test func pureDataContractStable() {
        let state = TurnActivityContentState(startedAt: Date(timeIntervalSince1970: 0))
        #expect(state.tokensIn == 0)
        #expect(state.tokensOut == 0)
        #expect(state.status == "running")
        #expect(state.currentTool == nil)
        #expect(state.currentCommand == nil)
    }
}
