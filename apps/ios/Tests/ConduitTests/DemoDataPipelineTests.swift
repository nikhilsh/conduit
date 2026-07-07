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

/// Pins `SessionStore.demoStartFlow` -- the Flow wizard's demo-mode "Start
/// flow" fake-flow builder (no network, extends the demo home's FLOWS
/// list). Mirror of Android `DemoDataPipelineTest`'s fake-flow coverage.
@Suite("Demo fake flow (SessionStore.demoStartFlow)")
@MainActor
struct DemoFakeFlowTests {

    private func makeSteps() -> [ConduitUI.PipelineStep] {
        [
            ConduitUI.PipelineStep(agentType: "claude", role: "researcher", promptTemplate: "p1", inputFromPrev: "none", gateAfter: false),
            ConduitUI.PipelineStep(agentType: "codex", role: "engineer", promptTemplate: "p2", inputFromPrev: "output", gateAfter: false),
        ]
    }

    @Test func firstFakeFlowGetsIndexOneId() {
        let store = SessionStore()
        let (id, status) = store.demoStartFlow(title: "Test flow", task: "do the thing", cwd: "", steps: makeSteps())
        #expect(id == "demo-fake-1")
        #expect(status.id == "demo-fake-1")
    }

    @Test func fakeFlowIsRunningWithFirstStepRunning() {
        let store = SessionStore()
        let (_, status) = store.demoStartFlow(title: "Test flow", task: "do the thing", cwd: "", steps: makeSteps())
        #expect(status.state == "running")
        #expect(status.steps.count == 2)
        #expect(status.steps[0].phase == "running")
        #expect(status.steps[0].session_id != nil)
        #expect(status.steps[1].phase == nil)
        #expect(status.steps[1].session_id == nil)
    }

    @Test func fakeFlowIsPrependedToDemoPipelinesList() {
        let store = SessionStore()
        store.demoStartFlow(title: "Test flow", task: "do the thing", cwd: "", steps: makeSteps())
        #expect(store.demoPipelinesList.first?.id == "demo-fake-1")
        #expect(store.demoPipelinesList.count == DemoData.pipelines.count + 1)
    }

    @Test func demoPipelineStatusFallsBackToStaticFixtures() {
        let store = SessionStore()
        // No fake flow started yet -- static fixtures still resolve.
        #expect(store.demoPipelineStatus(id: "demo-flow-1")?.title == "Add rate limiter to broker")
        #expect(store.demoPipelineStatus(id: "not-a-real-flow") == nil)
    }

    @Test func demoPipelineStatusResolvesTheFakeFlow() {
        let store = SessionStore()
        let (id, _) = store.demoStartFlow(title: "Test flow", task: "do the thing", cwd: "", steps: makeSteps())
        #expect(store.demoPipelineStatus(id: id)?.task == "do the thing")
    }

    @Test func branchStepsAreExcludedFromTheFakeFlow() {
        let store = SessionStore()
        var branch = ConduitUI.PipelineStep()
        branch.kind = "branch"
        let (_, status) = store.demoStartFlow(title: "Test flow", task: "t", cwd: "", steps: makeSteps() + [branch])
        #expect(status.steps.count == 2)
    }

    @Test func deactivateDemoClearsFakeFlows() {
        let store = SessionStore()
        store.demoStartFlow(title: "Test flow", task: "do the thing", cwd: "", steps: makeSteps())
        #expect(!store.demoPipelinesList.isEmpty)
        store.deactivateDemo()
        #expect(store.demoPipelinesList.count == DemoData.pipelines.count)
    }
}
