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
            let s = PipelineStep()
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

        func applyTemplate(_ tmpl: PipelineTemplate) {
            steps = tmpl.steps.map { s in
                PipelineStep(
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
            }
            if steps.isEmpty { steps = [PipelineStep()] }
            selectedStepID = steps.first?.id
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
                    fanoutCount: s.fanoutEnabled ? s.fanoutCount : 0
                )
            }
        }
    }
}
