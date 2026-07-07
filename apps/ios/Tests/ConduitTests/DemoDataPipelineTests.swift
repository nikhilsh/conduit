import Foundation
import Testing
@testable import Conduit

/// Pins the demo-mode Flow fixtures (`DemoData.pipelines` /
/// `DemoData.pipelineStatus(id:)`) added alongside the demo home FLOWS
/// section + Monitor static-fixture seam. Catches drift in the literal
/// titles/states the Appetize tour taps by text, and the shape the real
/// `ConduitUI.FlowCard` / `ConduitUI.PipelineMonitorView` expect. Mirror of
/// Android `DemoDataPipelineTest`.
@Suite("Demo pipeline fixtures")
struct DemoDataPipelineTests {

    @Test func seedsTwoDemoFlows() {
        #expect(DemoData.pipelines.count == 2)
    }

    @Test func gatedFlowFixtureMatchesTourTapTarget() {
        // The Appetize tour taps this exact title text -- a drift here
        // silently breaks the tour, not CI, so pin it directly.
        let flow = DemoData.pipelines.first { $0.id == "demo-flow-1" }
        #expect(flow?.title == "Add rate limiter to broker")
        #expect(flow?.state == "awaiting_gate")
    }

    @Test func gatedFlowFixtureHasAGateAfterStep() {
        let flow = DemoData.pipelines.first { $0.id == "demo-flow-1" }
        let steps = flow?.steps ?? []
        #expect(steps.contains { $0.gate_after })
    }

    @Test func runningFlowFixtureMatchesExpectedShape() {
        let flow = DemoData.pipelines.first { $0.id == "demo-flow-2" }
        #expect(flow?.title == "Migrate settings to KV store")
        #expect(flow?.state == "running")
        #expect(flow?.steps?.map(\.status) == ["done", "running", "queued"])
    }

    @Test func monitorFixtureExistsForEverySummary() {
        for summary in DemoData.pipelines {
            let status = DemoData.pipelineStatus(id: summary.id)
            #expect(status != nil)
            #expect(status?.id == summary.id)
            #expect(status?.title == summary.title)
            #expect(status?.state == summary.state)
        }
    }

    @Test func gatedMonitorFixtureCarriesAGatePayload() {
        let status = DemoData.pipelineStatus(id: "demo-flow-1")
        #expect(status?.gate != nil)
        #expect(status?.gate?.prev.contains("Proposed design") == true)
    }

    @Test func unknownIdReturnsNil() {
        #expect(DemoData.pipelineStatus(id: "not-a-real-flow") == nil)
    }
}
