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
        let encoded = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(TurnActivityAttributes.ContentState.self, from: encoded)
        #expect(decoded == content)
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
