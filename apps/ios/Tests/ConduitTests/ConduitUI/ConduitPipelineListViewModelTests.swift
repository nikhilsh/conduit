import Foundation
import Testing
@testable import Conduit

/// Pins `ConduitUI.PipelineSummary` decode (incl. unknown-state tolerance)
/// and `ConduitUI.PipelineListViewModel`'s pure sort/group helpers -- the
/// only app-side consumer of `GET /api/pipelines`. Mirror of Android
/// `PipelineListViewModelTest`.
@Suite("ConduitUI pipeline list")
struct ConduitPipelineListViewModelTests {

    private func summary(
        id: String, title: String = "t", state: String,
        currentStep: Int = 0, stepCount: Int = 1, created: String? = nil
    ) -> ConduitUI.PipelineSummary {
        ConduitUI.PipelineSummary(
            id: id, title: title, state: state,
            current_step: currentStep, step_count: stepCount, created: created
        )
    }

    // MARK: - Decode

    @Test func decodesListResponseShape() throws {
        let json = """
        {"pipelines":[
            {"id":"p_1","title":"Fix bug","state":"running","current_step":1,"step_count":3,"created":"2026-07-01T00:00:00Z"}
        ]}
        """.data(using: .utf8)!
        struct Envelope: Decodable { let pipelines: [ConduitUI.PipelineSummary] }
        let decoded = try JSONDecoder().decode(Envelope.self, from: json)
        #expect(decoded.pipelines.count == 1)
        #expect(decoded.pipelines[0].id == "p_1")
        #expect(decoded.pipelines[0].title == "Fix bug")
        #expect(decoded.pipelines[0].state == "running")
        #expect(decoded.pipelines[0].current_step == 1)
        #expect(decoded.pipelines[0].step_count == 3)
    }

    @Test func toleratesUnknownState() throws {
        // A newer broker might introduce a state this build doesn't know
        // about yet. `state` decodes as a raw String, so this must not
        // throw -- and the unknown state must fall into the "active"
        // sort bucket, not vanish or crash.
        let json = """
        {"pipelines":[
            {"id":"p_2","title":"t","state":"some_future_state","current_step":0,"step_count":1}
        ]}
        """.data(using: .utf8)!
        struct Envelope: Decodable { let pipelines: [ConduitUI.PipelineSummary] }
        let decoded = try JSONDecoder().decode(Envelope.self, from: json)
        #expect(decoded.pipelines.count == 1)
        #expect(ConduitUI.PipelineListViewModel.group(for: decoded.pipelines[0].state) == .active)
    }

    @Test func toleratesMissingCreated() throws {
        let json = """
        {"pipelines":[
            {"id":"p_3","title":"t","state":"complete","current_step":0,"step_count":1}
        ]}
        """.data(using: .utf8)!
        struct Envelope: Decodable { let pipelines: [ConduitUI.PipelineSummary] }
        let decoded = try JSONDecoder().decode(Envelope.self, from: json)
        #expect(decoded.pipelines[0].created == nil)
    }

    // MARK: - Grouping

    @Test func groupsNeedsYouStates() {
        #expect(ConduitUI.PipelineListViewModel.group(for: "awaiting_gate") == .needsYou)
        #expect(ConduitUI.PipelineListViewModel.group(for: "awaiting_pick") == .needsYou)
    }

    @Test func groupsTerminalStates() {
        #expect(ConduitUI.PipelineListViewModel.group(for: "complete") == .terminal)
        #expect(ConduitUI.PipelineListViewModel.group(for: "failed") == .terminal)
        #expect(ConduitUI.PipelineListViewModel.group(for: "cancelled") == .terminal)
    }

    @Test func groupsRunningAndPendingAsActive() {
        #expect(ConduitUI.PipelineListViewModel.group(for: "running") == .active)
        #expect(ConduitUI.PipelineListViewModel.group(for: "pending") == .active)
        #expect(ConduitUI.PipelineListViewModel.group(for: "step_done") == .active)
    }

    // MARK: - Sort order

    @Test func sortsNeedsYouBeforeActiveBeforeTerminal() {
        let items = [
            summary(id: "a", state: "complete", created: "2026-07-01T00:00:00Z"),
            summary(id: "b", state: "running"),
            summary(id: "c", state: "awaiting_gate"),
        ]
        let sorted = ConduitUI.PipelineListViewModel.sorted(items)
        #expect(sorted.map(\.id) == ["c", "b", "a"])
    }

    @Test func sortsTerminalPipelinesByRecencyDescending() {
        let items = [
            summary(id: "old", state: "complete", created: "2026-01-01T00:00:00Z"),
            summary(id: "new", state: "complete", created: "2026-06-01T00:00:00Z"),
        ]
        let sorted = ConduitUI.PipelineListViewModel.sorted(items)
        #expect(sorted.map(\.id) == ["new", "old"])
    }

    @Test func preservesInputOrderWithinNonTerminalGroups() {
        let items = [
            summary(id: "first", state: "running"),
            summary(id: "second", state: "running"),
        ]
        let sorted = ConduitUI.PipelineListViewModel.sorted(items)
        #expect(sorted.map(\.id) == ["first", "second"])
    }

    // MARK: - Home affordance gate

    @Test func homeAffordanceGatesOnExactlyThreeActiveStates() {
        #expect(ConduitUI.PipelineListViewModel.isActiveForHomeAffordance("running"))
        #expect(ConduitUI.PipelineListViewModel.isActiveForHomeAffordance("awaiting_gate"))
        #expect(ConduitUI.PipelineListViewModel.isActiveForHomeAffordance("awaiting_pick"))
        #expect(!ConduitUI.PipelineListViewModel.isActiveForHomeAffordance("pending"))
        #expect(!ConduitUI.PipelineListViewModel.isActiveForHomeAffordance("complete"))
        #expect(!ConduitUI.PipelineListViewModel.isActiveForHomeAffordance("failed"))
        #expect(!ConduitUI.PipelineListViewModel.isActiveForHomeAffordance("cancelled"))
    }
}
