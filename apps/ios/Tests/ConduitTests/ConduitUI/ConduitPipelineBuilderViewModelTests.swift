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

    // MARK: - PLAN-HARNESS-BUILDER Phase 3: sub-stack add/remove/move

    @Test func addControlFlowStepSeedsDefaultSubStack() {
        let vm = ConduitUI.PipelineBuilderViewModel()
        vm.addControlFlowStep(kind: "branch")
        #expect(vm.steps.count == 2)
        let branchStep = vm.steps[1]
        #expect(branchStep.kind == "branch")
        #expect(branchStep.branchThen.count == 1)
        #expect(vm.selectedStepID == branchStep.id)

        vm.addControlFlowStep(kind: "loop")
        let loopStep = vm.steps[2]
        #expect(loopStep.kind == "loop")
        #expect(loopStep.loopBody.count == 1)
    }

    @Test func addSubStepAppendsToTheChosenArm() {
        let vm = ConduitUI.PipelineBuilderViewModel()
        vm.addControlFlowStep(kind: "branch")
        let stepID = vm.steps[1].id

        vm.addSubStep(stepID: stepID, arm: .then)
        #expect(vm.steps[1].branchThen.count == 2)
        #expect(vm.steps[1].branchElse.count == 0)

        vm.addSubStep(stepID: stepID, arm: .elseArm)
        #expect(vm.steps[1].branchElse.count == 1)
    }

    @Test func removeSubStepRemovesFromTheChosenArmOnly() {
        let vm = ConduitUI.PipelineBuilderViewModel()
        vm.addControlFlowStep(kind: "branch")
        let stepID = vm.steps[1].id
        vm.addSubStep(stepID: stepID, arm: .then)
        let subID = vm.steps[1].branchThen[0].id

        vm.removeSubStep(stepID: stepID, arm: .then, subStepID: subID)
        #expect(vm.steps[1].branchThen.count == 1)
    }

    @Test func removeSubStepNeverEmptiesALoopBody() {
        let vm = ConduitUI.PipelineBuilderViewModel()
        vm.addControlFlowStep(kind: "loop")
        let stepID = vm.steps[1].id
        let onlyBodyID = vm.steps[1].loopBody[0].id

        // A loop body must keep >= 1 step (broker rejects an empty body).
        vm.removeSubStep(stepID: stepID, arm: .body, subStepID: onlyBodyID)
        #expect(vm.steps[1].loopBody.count == 1)
    }

    @Test func moveSubStepSwapsAdjacentEntries() {
        let vm = ConduitUI.PipelineBuilderViewModel()
        vm.addControlFlowStep(kind: "loop")
        let stepID = vm.steps[1].id
        vm.addSubStep(stepID: stepID, arm: .body)
        var second = vm.steps[1].loopBody[1]
        second.agentType = "codex"
        vm.updateSubStep(stepID: stepID, arm: .body, subStep: second)
        let firstID = vm.steps[1].loopBody[0].id
        let secondID = vm.steps[1].loopBody[1].id

        vm.moveSubStep(stepID: stepID, arm: .body, subStepID: secondID, direction: -1)
        #expect(vm.steps[1].loopBody[0].id == secondID)
        #expect(vm.steps[1].loopBody[1].id == firstID)

        // Past either end is a no-op.
        vm.moveSubStep(stepID: stepID, arm: .body, subStepID: secondID, direction: -1)
        #expect(vm.steps[1].loopBody[0].id == secondID)
    }

    // MARK: - Config-sheet redesign: task 2a input_from_prev defaults

    @Test func addStepDefaultsInputFromPrevToOutputAfterTheFirst() {
        let vm = ConduitUI.PipelineBuilderViewModel()
        // Step 0 (seeded by init) keeps "none" -- there is no previous step.
        #expect(vm.steps[0].inputFromPrev == "none")

        vm.addStep()
        #expect(vm.steps[1].inputFromPrev == "output", "a step after the first must default to output, not silently drop the handoff")

        vm.addStep()
        #expect(vm.steps[2].inputFromPrev == "output")
    }

    @Test func addControlFlowStepDefaultsInputFromPrevToOutputAfterTheFirst() {
        let vm = ConduitUI.PipelineBuilderViewModel()
        vm.addControlFlowStep(kind: "branch")
        #expect(vm.steps[1].inputFromPrev == "output")
    }

    @Test func addSubStepDefaultsInputFromPrevToOutputAfterTheFirstInItsArm() {
        let vm = ConduitUI.PipelineBuilderViewModel()
        vm.addControlFlowStep(kind: "branch")
        let stepID = vm.steps[1].id

        // The control-flow step's starter Then sub-step (index 0 of its own
        // arm) keeps "none".
        #expect(vm.steps[1].branchThen[0].inputFromPrev == "none")

        vm.addSubStep(stepID: stepID, arm: .then)
        #expect(vm.steps[1].branchThen[1].inputFromPrev == "output")

        // Else starts a FRESH arm -- its own first sub-step is index 0 of
        // Else, so it keeps "none" even though the parent step is not first.
        vm.addSubStep(stepID: stepID, arm: .elseArm)
        #expect(vm.steps[1].branchElse[0].inputFromPrev == "none")
        vm.addSubStep(stepID: stepID, arm: .elseArm)
        #expect(vm.steps[1].branchElse[1].inputFromPrev == "output")
    }

    // MARK: - Config-sheet redesign: task 1 model dedupe regression
    //
    // The pipeline Builder's block-config model row used to hand-roll its
    // own "Default" + `ForEach(catalog)` menu, which double-listed the
    // catalog's own "" (recommended) entry alongside the hardcoded "Default"
    // row (owner screenshot). The redesign deletes that hand-rolled list and
    // reuses `ForkOptions.models(forAssistant:catalog:)` -- assert it never
    // yields two rows for the same "" wire value.
    @Test func pipelineModelOptionsNeverDoubleListDefault() {
        let catalog: [ConduitUI.AgentModel] = [
            .init(id: "", displayName: "Default (recommended)",
                  description: "Opus 4.8 with 1M context",
                  isDefault: true, efforts: ["low", "medium", "high", "xhigh", "max"]),
            .init(id: "opus", displayName: "Opus 4.8", isDefault: false, efforts: ["low", "medium", "high"]),
            .init(id: "sonnet", displayName: "Sonnet 4.6", isDefault: false, efforts: ["low", "medium", "high"]),
        ]
        let options = ConduitUI.ForkOptions.models(forAssistant: "claude", catalog: catalog)
        #expect(options.filter { $0.isEmpty }.count == 1, "exactly one Default row, not a hardcoded row PLUS the catalog's own empty-string entry")
        #expect(options == ["", "opus", "sonnet"])
        // design_handoff_review_fixes R2: the flow step editor's Advanced
        // rows now reuse this same list -- pin no id ever appears twice.
        #expect(Set(options).count == options.count)
    }

    @Test func createRequestRoundTripsBranchAndLoopBlocks() throws {
        var branchStep = ConduitUI.PipelineStep()
        branchStep.kind = "branch"
        branchStep.branchConditionValue = "APPROVED"
        var loopStep = ConduitUI.PipelineStep()
        loopStep.kind = "loop"
        loopStep.loopMaxIterations = 2

        let vm = ConduitUI.PipelineBuilderViewModel(steps: [branchStep, loopStep])
        let req = vm.createRequest(title: "T", task: "task", cwd: "", base: "main")

        #expect(req.steps[0].kind == "branch")
        #expect(req.steps[0].branch?.condition.value == "APPROVED")
        #expect(req.steps[1].kind == "loop")
        #expect(req.steps[1].loop?.max_iterations == 2)
    }

    // MARK: - Chain guardrail (Start-button last-line-of-defense)

    @Test func unchainedStepIndicesEmptyWhenAllChained() {
        var a = ConduitUI.PipelineStep(); a.inputFromPrev = "none"
        var b = ConduitUI.PipelineStep(); b.inputFromPrev = "output"
        var c = ConduitUI.PipelineStep(); c.inputFromPrev = "memory+output"
        let vm = ConduitUI.PipelineBuilderViewModel(steps: [a, b, c])

        #expect(vm.unchainedStepIndices().isEmpty)
    }

    @Test func unchainedStepIndicesCatchesNoneStepsAfterTheFirst() {
        var a = ConduitUI.PipelineStep(); a.inputFromPrev = "none"
        var b = ConduitUI.PipelineStep(); b.inputFromPrev = "none"
        var c = ConduitUI.PipelineStep(); c.inputFromPrev = "output"
        var d = ConduitUI.PipelineStep(); d.inputFromPrev = "none"
        let vm = ConduitUI.PipelineBuilderViewModel(steps: [a, b, c, d])

        #expect(vm.unchainedStepIndices() == [1, 3])
    }

    @Test func unchainedStepIndicesIgnoresStepZero() {
        // Step 0's "none" is expected (there is no previous step) and must
        // never trigger the guardrail.
        var a = ConduitUI.PipelineStep(); a.inputFromPrev = "none"
        let vm = ConduitUI.PipelineBuilderViewModel(steps: [a])

        #expect(vm.unchainedStepIndices().isEmpty)
    }

    @Test func unchainedStepIndicesIgnoresSubSteps() {
        // A branch/loop sub-step's own "none" first-of-arm is legitimate
        // (task-2a precedent) and out of scope for this top-level-only check
        // regardless of the parent step's own index or chaining state.
        let vm = ConduitUI.PipelineBuilderViewModel()
        vm.addControlFlowStep(kind: "loop")
        let stepID = vm.steps[1].id
        vm.addSubStep(stepID: stepID, arm: .body)
        var secondBody = vm.steps[1].loopBody[1]
        secondBody.inputFromPrev = "none"
        vm.updateSubStep(stepID: stepID, arm: .body, subStep: secondBody)

        // The parent loop step itself (index 1) defaults to "output" via
        // addControlFlowStep, so only its sub-steps carry "none" here.
        #expect(vm.unchainedStepIndices().isEmpty)
    }

    @Test func chainUnchainedStepsFlipsOnlyUnchainedTopLevelSteps() {
        var a = ConduitUI.PipelineStep(); a.inputFromPrev = "none"
        var b = ConduitUI.PipelineStep(); b.inputFromPrev = "none"
        var c = ConduitUI.PipelineStep(); c.inputFromPrev = "memory"
        let vm = ConduitUI.PipelineBuilderViewModel(steps: [a, b, c])

        vm.chainUnchainedSteps()

        #expect(vm.steps[0].inputFromPrev == "none", "step 0 must never be rewritten")
        #expect(vm.steps[1].inputFromPrev == "output")
        #expect(vm.steps[2].inputFromPrev == "memory", "an already-set non-none value must not be clobbered")
        #expect(vm.unchainedStepIndices().isEmpty)
    }
}
