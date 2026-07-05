import Foundation
import Testing
@testable import Conduit

/// PLAN-HARNESS-BUILDER Phase 2 (docs/PLAN-HARNESS-BUILDER.md 3.4): the
/// visual Builder's `PipelineBuilderViewModel` must be a pure reshape of the
/// Phase-1 form -- same steps in, same `/api/pipeline` create-request JSON
/// out -- and drag-reorder must reindex the array (steps carry no
/// client-side index; the broker assigns `Index: i` from array position, so
/// "reindexing" IS reordering the array). Mirror of Android
/// `PipelineBuilderViewModelTest`.
@Suite("ConduitUI pipeline builder view model")
struct ConduitPipelineBuilderViewModelTests {

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj ?? [:]
    }

    @Test func createRequestMatchesPhase1FormEncoding() throws {
        var stepA = ConduitUI.PipelineStep()
        stepA.agentType = "claude"
        stepA.role = "engineer"
        stepA.model = "opus"
        stepA.reasoningEffort = "high"
        var stepB = ConduitUI.PipelineStep()
        stepB.agentType = "codex"
        stepB.role = "researcher"
        stepB.gateAfter = true

        // The "Phase-1 form" shape: an inline array + the shared encoders,
        // exactly as ConduitPipelineBuilderView did before Phase 2.
        let legacySteps = [stepA, stepB]
        let legacyRequest = ConduitUI.PipelineCreateRequest(
            title: "Title", task: "Task", cwd: "/tmp", base: "main",
            steps: legacySteps.map { ConduitUI.PipelineRequestStep($0) }
        )

        // The Phase-2 view model, seeded with the SAME steps.
        let vm = ConduitUI.PipelineBuilderViewModel(steps: legacySteps)
        let vmRequest = vm.createRequest(title: "Title", task: "Task", cwd: "/tmp", base: "main")

        // Compare structurally (decoded JSON), not raw `Data` -- JSONEncoder
        // does not guarantee stable key ordering across separate encode()
        // calls, so a raw byte comparison here is flaky even when the wire
        // content is identical.
        let legacyObj = try jsonObject(legacyRequest) as NSDictionary
        let vmObj = try jsonObject(vmRequest) as NSDictionary
        #expect(legacyObj == vmObj)
    }

    @Test func templateSaveRequestMatchesPhase1FormEncoding() throws {
        var step = ConduitUI.PipelineStep()
        step.agentType = "gemini"
        step.instructions = "Be terse."

        let legacyRequest = ConduitUI.PipelineTemplateSaveRequest(
            title: "T", task: "Do it",
            steps: [step].map { ConduitUI.PipelineRequestStep($0) }
        )
        let vm = ConduitUI.PipelineBuilderViewModel(steps: [step])
        let vmRequest = vm.templateSaveRequest(title: "T", task: "Do it")

        // Same rationale as above -- structural comparison, not raw Data.
        let legacyObj = try jsonObject(legacyRequest) as NSDictionary
        let vmObj = try jsonObject(vmRequest) as NSDictionary
        #expect(legacyObj == vmObj)
    }

    @Test func moveStepsReordersArray() {
        var a = ConduitUI.PipelineStep(); a.agentType = "claude"
        var b = ConduitUI.PipelineStep(); b.agentType = "codex"
        var c = ConduitUI.PipelineStep(); c.agentType = "gemini"
        let vm = ConduitUI.PipelineBuilderViewModel(steps: [a, b, c])

        // Move the first step ("claude") to the end -- List .onMove
        // semantics: source offsets + a destination index PAST the moved
        // range's original position.
        vm.moveSteps(from: IndexSet(integer: 0), to: 3)

        #expect(vm.steps.map(\.agentType) == ["codex", "gemini", "claude"])
    }

    @Test func moveStepsReindexesCreateRequestOrder() throws {
        var a = ConduitUI.PipelineStep(); a.agentType = "claude"
        var b = ConduitUI.PipelineStep(); b.agentType = "codex"
        var c = ConduitUI.PipelineStep(); c.agentType = "gemini"
        let vm = ConduitUI.PipelineBuilderViewModel(steps: [a, b, c])

        vm.moveSteps(from: IndexSet(integer: 2), to: 0)

        let req = vm.createRequest(title: "T", task: "task", cwd: "", base: "main")
        // The broker assigns Index: i from array position at create time
        // (ws/pipeline.go serveCreatePipeline) -- so the reordered array
        // order IS the reindexed 0..n-1 order sent over the wire.
        #expect(req.steps.map(\.agent_type) == ["gemini", "claude", "codex"])
    }

    @Test func addAndRemoveStepKeepsAtLeastOne() {
        let vm = ConduitUI.PipelineBuilderViewModel()
        #expect(vm.steps.count == 1)
        vm.removeStep(id: vm.steps[0].id)
        #expect(vm.steps.count == 1, "must never remove the last step")

        vm.addStep()
        #expect(vm.steps.count == 2)
        let firstID = vm.steps[0].id
        vm.removeStep(id: firstID)
        #expect(vm.steps.count == 1)
        #expect(vm.steps.first?.id != firstID)
    }

    @Test func applyTemplateReplacesSteps() {
        let vm = ConduitUI.PipelineBuilderViewModel()
        let tmpl = ConduitUI.PipelineTemplate(
            id: "t1", title: "Refactor", task: "Refactor auth",
            steps: [
                ConduitUI.PipelineTemplateStep(
                    agent_type: "codex", role: "architect", prompt_template: "design it",
                    input_from_prev: "none", gate_after: true,
                    model: "gpt-5-codex", reasoning_effort: "high",
                    permission_mode: "plan", instructions: "focus on the API"
                ),
            ]
        )
        vm.applyTemplate(tmpl)
        #expect(vm.steps.count == 1)
        #expect(vm.steps[0].agentType == "codex")
        #expect(vm.steps[0].model == "gpt-5-codex")
        #expect(vm.steps[0].instructions == "focus on the API")
        #expect(vm.selectedStepID == vm.steps[0].id)
    }
}
