import Foundation
import Observation

// MARK: - PipelineBuilderViewModel
//
// PLAN-HARNESS-BUILDER Phase 2 (docs/PLAN-HARNESS-BUILDER.md 3). Pure-data
// state holder for the visual pipeline Builder -- extracted so BOTH the
// phone (stacked list + config sheet) and tablet (two-pane rail + inspector)
// layouts read the SAME steps array rather than each keeping its own copy.
//
// Deliberately holds ONLY the ordered steps + selection -- title/task/cwd/
// base and networking (template load/save/delete, submit) stay in the view
// (they need SessionStore/Telemetry environment access that a pure model
// shouldn't own). The wire encoders (PipelineRequestStep /
// PipelineCreateRequest / PipelineTemplateSaveRequest) are UNCHANGED from
// Phase 1 -- this view model only reshapes how steps are edited, never how
// they're encoded, so create-request JSON stays byte-identical to the
// Phase-1 form for an equivalent config.
extension ConduitUI {

    @Observable
    final class PipelineBuilderViewModel {
        var steps: [PipelineStep]
        /// The step currently open in the config sheet (phone) or shown in
        /// the inspector pane (tablet). Nil on tablet means "no selection
        /// yet" (inspector shows an empty state).
        var selectedStepID: PipelineStep.ID?

        init(steps: [PipelineStep] = [PipelineStep()]) {
            self.steps = steps
            self.selectedStepID = steps.first?.id
        }

        var canDeleteStep: Bool { steps.count > 1 }

        func addStep() {
            var s = PipelineStep()
            // Task-2a fix: a step after the first defaults to "output" so
            // the previous step's reply actually reaches it -- the plain
            // "none" default was a silent no-handoff bug the owner hit
            // directly. Step 0 keeps "none" (there is no previous step).
            if !steps.isEmpty { s.inputFromPrev = "output" }
            steps.append(s)
            selectedStepID = s.id
        }

        /// Adds a control-flow block (PLAN-HARNESS-BUILDER Phase 3). `kind`
        /// is `"branch"` or `"loop"` -- both PipelineStep default their
        /// sub-stacks with one starter PipelineSubStep, so a fresh block is
        /// immediately submittable (a loop body must have >= 1 step; a
        /// branch's arms are optional but starting with one is a friendlier
        /// default than an empty Then).
        func addControlFlowStep(kind: String) {
            var s = PipelineStep()
            s.kind = kind
            if !steps.isEmpty { s.inputFromPrev = "output" }
            steps.append(s)
            selectedStepID = s.id
        }

        func removeStep(id: PipelineStep.ID) {
            guard steps.count > 1 else { return }
            let wasSelected = selectedStepID == id
            steps.removeAll { $0.id == id }
            if wasSelected {
                selectedStepID = steps.first?.id
            }
        }

        // MARK: Sub-stack editing (Then / Else / Loop body)

        private func subStepArray(_ arm: PipelineSubStepArm, in step: PipelineStep) -> [PipelineSubStep] {
            switch arm {
            case .then: return step.branchThen
            case .elseArm: return step.branchElse
            case .body: return step.loopBody
            }
        }

        private func setSubStepArray(_ arm: PipelineSubStepArm, _ value: [PipelineSubStep], in index: Int) {
            switch arm {
            case .then: steps[index].branchThen = value
            case .elseArm: steps[index].branchElse = value
            case .body: steps[index].loopBody = value
            }
        }

        func addSubStep(stepID: PipelineStep.ID, arm: PipelineSubStepArm) {
            guard let idx = index(for: stepID) else { return }
            var arr = subStepArray(arm, in: steps[idx])
            var sub = PipelineSubStep()
            // Task-2a fix: same "output after the first" default within a
            // Then/Else/body sub-stack -- the arm's own first step keeps
            // "none".
            if !arr.isEmpty { sub.inputFromPrev = "output" }
            arr.append(sub)
            setSubStepArray(arm, arr, in: idx)
        }

        /// Removes a sub-step. A loop body must keep at least one step
        /// (broker validation: `len(s.Loop.Body) == 0` is rejected); Then/
        /// Else may go to zero (both are optional arrays on the wire).
        func removeSubStep(stepID: PipelineStep.ID, arm: PipelineSubStepArm, subStepID: PipelineSubStep.ID) {
            guard let idx = index(for: stepID) else { return }
            var arr = subStepArray(arm, in: steps[idx])
            if arm == .body && arr.count <= 1 { return }
            arr.removeAll { $0.id == subStepID }
            setSubStepArray(arm, arr, in: idx)
        }

        /// Swaps `subStepID` with its neighbor `direction` positions away
        /// (-1 = up, +1 = down). A no-op past either end -- deliberately a
        /// simple adjacent swap (not `move(fromOffsets:toOffset:)`'s
        /// pre-removal-index convention) since the UI drives this from plain
        /// up/down buttons on a nested (non-`List`) row, not `.onMove`.
        func moveSubStep(stepID: PipelineStep.ID, arm: PipelineSubStepArm, subStepID: PipelineSubStep.ID, direction: Int) {
            guard let idx = index(for: stepID) else { return }
            var arr = subStepArray(arm, in: steps[idx])
            guard let i = arr.firstIndex(where: { $0.id == subStepID }) else { return }
            let j = i + direction
            guard arr.indices.contains(j) else { return }
            arr.swapAt(i, j)
            setSubStepArray(arm, arr, in: idx)
        }

        func subStepBinding(stepID: PipelineStep.ID, arm: PipelineSubStepArm, subStepID: PipelineSubStep.ID) -> PipelineSubStep {
            guard let idx = index(for: stepID) else { return PipelineSubStep() }
            return subStepArray(arm, in: steps[idx]).first(where: { $0.id == subStepID }) ?? PipelineSubStep()
        }

        func updateSubStep(stepID: PipelineStep.ID, arm: PipelineSubStepArm, subStep: PipelineSubStep) {
            guard let idx = index(for: stepID) else { return }
            var arr = subStepArray(arm, in: steps[idx])
            if let i = arr.firstIndex(where: { $0.id == subStep.id }) {
                arr[i] = subStep
                setSubStepArray(arm, arr, in: idx)
            }
        }

        /// Drag-reorder (List .onMove offsets/destination semantics). A
        /// step carries no client-side index field -- the broker assigns
        /// Index: i from ARRAY POSITION at create time
        /// (ws/pipeline.go:serveCreatePipeline), so reordering the array is
        /// the entire reindex; there is nothing else to renumber.
        func moveSteps(from offsets: IndexSet, to destination: Int) {
            steps.move(fromOffsets: offsets, toOffset: destination)
        }

        func index(for id: PipelineStep.ID) -> Int? {
            steps.firstIndex(where: { $0.id == id })
        }

        // MARK: Chain guardrail
        //
        // Start-button last-line-of-defense (owner hit this twice: a saved
        // template/draft carries "none" forever even though #911 defaults
        // brand-NEW steps to "output"). Top-level steps only -- sub-steps
        // (branch/loop Then/Else/body) inherit context differently and are
        // excluded from this check entirely.

        /// Indices (0-based, into `steps`) of top-level steps after the
        /// first whose `inputFromPrev` is still `"none"` -- these silently
        /// drop the previous step's reply from their prompt. Step 0 is
        /// always excluded (there is no previous step to chain from).
        func unchainedStepIndices() -> [Int] {
            steps.indices.filter { $0 > 0 && steps[$0].inputFromPrev == "none" }
        }

        /// "Chain steps" resolution offered by the guardrail alert: flips
        /// every currently-unchained top-level step to `"output"`. Never
        /// touches step 0 or sub-steps.
        func chainUnchainedSteps() {
            for i in unchainedStepIndices() {
                steps[i].inputFromPrev = "output"
            }
        }

        func applyTemplate(_ tmpl: PipelineTemplate) {
            steps = tmpl.steps.map { s in
                var step = PipelineStep(
                    agentType: s.agent_type,
                    role: s.role,
                    promptTemplate: s.prompt_template,
                    inputFromPrev: s.input_from_prev,
                    gateAfter: s.gate_after,
                    model: s.model ?? "",
                    reasoningEffort: s.reasoning_effort ?? "",
                    permissionMode: s.permission_mode ?? "",
                    instructions: s.instructions ?? ""
                )
                switch s.kind {
                case "branch":
                    guard let b = s.branch else { break }
                    step.kind = "branch"
                    step.branchConditionSource = b.condition.source
                    step.branchConditionPredicate = b.condition.predicate
                    step.branchConditionValue = b.condition.value ?? ""
                    step.branchThen = (b.then ?? []).map(Self.subStep(from:))
                    step.branchElse = (b.elseArm ?? []).map(Self.subStep(from:))
                case "loop":
                    guard let l = s.loop else { break }
                    step.kind = "loop"
                    step.loopBody = l.body.map(Self.subStep(from:))
                    step.loopUntilSource = l.until.source
                    step.loopUntilPredicate = l.until.predicate
                    step.loopUntilValue = l.until.value ?? ""
                    step.loopMaxIterations = l.max_iterations
                default:
                    break
                }
                return step
            }
            if steps.isEmpty { steps = [PipelineStep()] }
            selectedStepID = steps.first?.id
        }

        private static func subStep(from t: PipelineTemplateSubStep) -> PipelineSubStep {
            PipelineSubStep(
                agentType: t.agent_type,
                role: t.role,
                promptTemplate: t.prompt_template,
                inputFromPrev: t.input_from_prev,
                gateAfter: t.gate_after,
                model: t.model ?? "",
                reasoningEffort: t.reasoning_effort ?? "",
                permissionMode: t.permission_mode ?? "",
                instructions: t.instructions ?? ""
            )
        }

        /// /api/pipeline create-request body -- same shape/encoder as
        /// Phase 1 (PipelineRequestStep(_:)), just sourced from this
        /// model's steps instead of an inline @State array.
        func createRequest(title: String, task: String, cwd: String, base: String) -> PipelineCreateRequest {
            PipelineCreateRequest(
                title: title,
                task: task,
                cwd: cwd,
                base: base,
                steps: steps.map { PipelineRequestStep($0) }
            )
        }

        /// /api/pipeline-templates save-request body -- same shape as
        /// Phase 1.
        func templateSaveRequest(title: String, task: String) -> PipelineTemplateSaveRequest {
            PipelineTemplateSaveRequest(
                title: title,
                task: task,
                steps: steps.map { PipelineRequestStep($0) }
            )
        }

        /// Topology-preview items (agent/role/gate/fanout only -- no config
        /// detail) for PipelineTopologyRail.
        var topologyItems: [PipelineTopologyItem] {
            steps.map { s in
                PipelineTopologyItem(
                    id: s.id,
                    agentType: s.agentType,
                    role: s.role,
                    gateAfter: s.gateAfter,
                    fanoutCount: s.fanoutEnabled ? s.fanoutCount : 0,
                    kind: s.kind,
                    thenCount: s.branchThen.count,
                    elseCount: s.branchElse.count,
                    bodyCount: s.loopBody.count,
                    maxIterations: s.loopMaxIterations
                )
            }
        }
    }
}
