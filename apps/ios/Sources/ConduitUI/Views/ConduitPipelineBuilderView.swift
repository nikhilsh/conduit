import SwiftUI

// MARK: - Pipeline (Flow) model + request types
//
// Shared pipeline step/template/request model types. The legacy
// `PipelineBuilderView` that used to live in this file was retired in
// favor of `ConduitUI.FlowStartSheet` + `ConduitUI.FlowWizardView`
// (phone and tablet both) -- these types remain because
// `ConduitPipelineBuilderViewModel` and the Flow step/branch editors
// (`ConduitFlowStepEditorSheet`, etc.) still build on them.

extension ConduitUI {

    // MARK: - Pipeline models

    struct PipelineStep: Identifiable {
        let id = UUID()
        var agentType: String = "claude"
        var role: String = "engineer"
        var promptTemplate: String = ""
        var inputFromPrev: String = "none"
        var gateAfter: Bool = false
        // Per-block config (PLAN-HARNESS-BUILDER Phase 1, gated on
        // store.pipelineBlockConfig). "" = adapter default / inherit.
        var model: String = ""
        var reasoningEffort: String = ""
        var permissionMode: String = ""
        var instructions: String = ""
        // Fanout config (present only when fanoutEnabled == true)
        var fanoutEnabled: Bool = false
        var fanoutCount: Int = 2
        // Per-run agent types (index-aligned); empty = use step agent for all runs
        var fanoutAgentTypes: [String] = []
        // Per-run config overrides (index-aligned; "" = inherit from the step).
        var fanoutModels: [String] = []
        var fanoutReasoningEfforts: [String] = []
        var fanoutPermissionModes: [String] = []

        // MARK: Control flow (PLAN-HARNESS-BUILDER Phase 3, gated on
        // store.pipelineBranch / store.pipelineLoop). "" = plain agent step
        // (everything above), back-compatible with Phase 1/2.
        var kind: String = "" // "" | "branch" | "loop"
        // Branch condition (used when kind == "branch")
        var branchConditionSource: String = "prev_output" // "prev_output" | "exit_status"
        var branchConditionPredicate: String = "contains" // prev_output: contains|not_contains|matches; exit_status: succeeded|failed
        var branchConditionValue: String = ""
        // Then/Else sub-stacks -- PipelineSubStep (agent-only: no kind, no
        // fanout, no nested branch/loop). This is the depth-2 + no-fanout-
        // inside guard ENFORCED BY THE TYPE SYSTEM, not a runtime check --
        // there is no control to hide because the option doesn't exist on
        // this type (docs/PLAN-HARNESS-BUILDER.md §4.1/§4.5).
        var branchThen: [PipelineSubStep] = [PipelineSubStep()]
        var branchElse: [PipelineSubStep] = []

        // Loop config (used when kind == "loop")
        var loopBody: [PipelineSubStep] = [PipelineSubStep()]
        var loopUntilSource: String = "prev_output"
        var loopUntilPredicate: String = "contains"
        var loopUntilValue: String = ""
        var loopMaxIterations: Int = 3 // 1-5, default 3 (owner decision §8.5)

        var isControlFlow: Bool { kind == "branch" || kind == "loop" }

        // MARK: Role prompt templates (shared by `PipelineBuilderViewModel`'s
        // step creation and `ConduitFlowStepEditorSheet`'s role picker/
        // on-appear prefill -- one copy so they can't drift). Pipeline
        // vocabulary is Research/Design/Build/Custom (design_handoff_flow
        // README "Interactions & state"); "custom" (and any role without a
        // canned template) leaves the prompt blank for the user to fill in.

        /// Role -> canned prompt template.
        static func defaultPromptTemplate(forRole role: String) -> String {
            switch role {
            case "researcher": return "Investigate the codebase and summarize findings."
            case "architect":  return "Design the implementation. Prior work: {{prev}}"
            case "engineer":   return "Implement the approved design. Prior work: {{prev}}"
            default:           return ""
            }
        }

        /// A single starter step for a brand-new flow/pipeline -- role
        /// "researcher" with its prompt prefilled, never a blank "engineer"
        /// step (device feedback: a fresh Flow opened to "Engineer" with an
        /// empty prompt).
        static var starter: PipelineStep {
            var step = PipelineStep()
            step.role = "researcher"
            step.promptTemplate = defaultPromptTemplate(forRole: "researcher")
            return step
        }
    }

    /// A step nested inside a branch's Then/Else arm or a loop's body.
    /// Deliberately a SEPARATE, smaller type from `PipelineStep` -- it has no
    /// `kind`/`branch`/`loop`/`fanout` fields, which is the depth-2 +
    /// no-fanout-inside bound from PLAN-HARNESS-BUILDER §4.1/§4.5 enforced
    /// by construction: there is no control to hide because a sub-step
    /// cannot represent another branch/loop/fanout in the first place.
    struct PipelineSubStep: Identifiable {
        let id = UUID()
        var agentType: String = "claude"
        var role: String = "engineer"
        var promptTemplate: String = ""
        var inputFromPrev: String = "none"
        var gateAfter: Bool = false
        var model: String = ""
        var reasoningEffort: String = ""
        var permissionMode: String = ""
        var instructions: String = ""
    }

    /// Which sub-stack a `PipelineSubStep` belongs to -- used to address
    /// add/remove/move operations without three near-identical call sites.
    /// Equatable: `removeSubStep`'s loop-body-never-empty guard compares
    /// `arm == .body`.
    enum PipelineSubStepArm: Equatable {
        case then, elseArm, body
    }

    /// PLAN-HARNESS-BUILDER Phase 3 (§4.3/§4.5) pure decision, extracted so
    /// it is directly unit-testable (the View's `modelRowHidden` wraps this
    /// with live `store` state): the model row shows whenever the agent's
    /// descriptor reports `supports.model_override == true` AND its model
    /// catalog is non-empty -- replacing the Phase-1 hardcoded gemini
    /// exclusion (owner decision §8.3) now that broker PR #900 wires
    /// `SpawnOverride.Model` through ACP `session/set_model` for gemini too.
    static func pipelineModelRowHidden(modelOverride: Bool, catalogEmpty: Bool) -> Bool {
        if catalogEmpty { return true }
        return !modelOverride
    }

    /// Identifies one sub-step's full-config editor sheet: which parent
    /// block, which arm, which sub-step.
    struct SubStepEditTarget: Identifiable {
        let stepID: PipelineStep.ID
        let arm: PipelineSubStepArm
        let subStepID: PipelineSubStep.ID
        var id: String { "\(stepID)-\(arm)-\(subStepID)" }
    }

    struct CreatedPipeline: Identifiable {
        let id: String
        let state: String
        let currentStep: Int
    }

    // MARK: - Template models

    struct PipelineTemplate: Identifiable, Decodable {
        let id: String
        let title: String
        let task: String
        let steps: [PipelineTemplateStep]
    }

    struct PipelineTemplateStep: Decodable {
        let agent_type: String
        let role: String
        let prompt_template: String
        let input_from_prev: String
        let gate_after: Bool
        // Per-block config (PLAN-HARNESS-BUILDER Phase 1). Optional so a
        // template saved before this shipped (or an old broker's response)
        // decodes fine with these absent.
        let model: String?
        let reasoning_effort: String?
        let permission_mode: String?
        let instructions: String?
        // Control flow (PLAN-HARNESS-BUILDER Phase 3). Optional so a
        // template saved before this shipped decodes fine with these absent.
        // Defaulted to nil (not just optional) so the synthesized memberwise
        // init stays source-compatible with every pre-Phase-3 call site
        // (Decodable's synthesized init(from:) is unaffected either way --
        // this default only matters for the memberwise init Swift also
        // generates for a struct with no custom init).
        let kind: String?
        let branch: PipelineTemplateBranch?
        let loop: PipelineTemplateLoop?

        init(
            agent_type: String,
            role: String,
            prompt_template: String,
            input_from_prev: String,
            gate_after: Bool,
            model: String? = nil,
            reasoning_effort: String? = nil,
            permission_mode: String? = nil,
            instructions: String? = nil,
            kind: String? = nil,
            branch: PipelineTemplateBranch? = nil,
            loop: PipelineTemplateLoop? = nil
        ) {
            self.agent_type = agent_type
            self.role = role
            self.prompt_template = prompt_template
            self.input_from_prev = input_from_prev
            self.gate_after = gate_after
            self.model = model
            self.reasoning_effort = reasoning_effort
            self.permission_mode = permission_mode
            self.instructions = instructions
            self.kind = kind
            self.branch = branch
            self.loop = loop
        }
    }

    struct PipelineTemplateCondition: Decodable {
        let source: String
        let predicate: String
        let value: String?
    }

    /// A decoded Then/Else/body step -- agent-only fields, mirrors
    /// `PipelineSubStep` (no kind/branch/loop/fanout: depth-2 bound).
    struct PipelineTemplateSubStep: Decodable {
        let agent_type: String
        let role: String
        let prompt_template: String
        let input_from_prev: String
        let gate_after: Bool
        let model: String?
        let reasoning_effort: String?
        let permission_mode: String?
        let instructions: String?
    }

    struct PipelineTemplateBranch: Decodable {
        let condition: PipelineTemplateCondition
        let then: [PipelineTemplateSubStep]?
        let elseArm: [PipelineTemplateSubStep]?

        enum CodingKeys: String, CodingKey {
            case condition, then
            case elseArm = "else"
        }
    }

    struct PipelineTemplateLoop: Decodable {
        let body: [PipelineTemplateSubStep]
        let until: PipelineTemplateCondition
        let max_iterations: Int
    }

    // MARK: - Request wire types (PLAN-HARNESS-BUILDER Phase 1)
    //
    // Type-level (not function-local) so ConduitTests can round-trip them
    // directly. Shape mirrors the broker's embedded `StepConfig`
    // (broker/internal/pipeline/stepconfig.go) -- flat on the step, omitted
    // when empty. Identical shape for both `/api/pipeline` (create) and
    // `/api/pipeline-templates` (save) -- one step encoder, no lockstep risk.

    struct PipelineRequestFanout: Encodable, Equatable {
        var count: Int
        var agent_types: [String]?
        // Per-run config overrides; "" = inherit from the step. No per-run
        // instructions -- runs share the block's instructions (owner
        // decision §8.1).
        var models: [String]?
        var reasoning_efforts: [String]?
        var permission_modes: [String]?
    }

    /// A recursively-encoded Then/Else/body step -- agent-only fields (no
    /// kind/branch/loop/fanout), mirroring `PipelineSubStep`.
    struct PipelineRequestSubStep: Encodable, Equatable {
        var agent_type: String
        var role: String
        var prompt_template: String
        var input_from_prev: String
        var gate_after: Bool
        var model: String?
        var reasoning_effort: String?
        var permission_mode: String?
        var instructions: String?

        init(_ s: PipelineSubStep) {
            agent_type = s.agentType
            role = s.role
            prompt_template = s.promptTemplate
            input_from_prev = s.inputFromPrev
            gate_after = s.gateAfter
            model = s.model.isEmpty ? nil : s.model
            reasoning_effort = s.reasoningEffort.isEmpty ? nil : s.reasoningEffort
            permission_mode = s.permissionMode.isEmpty ? nil : s.permissionMode
            instructions = s.instructions.isEmpty ? nil : s.instructions
        }
    }

    struct PipelineConditionRequest: Encodable, Equatable {
        var source: String
        var predicate: String
        // Unused for exit_status (broker: `Value string \`json:"value,omitempty"\``).
        var value: String?
    }

    struct PipelineBranchRequest: Encodable, Equatable {
        var condition: PipelineConditionRequest
        var then: [PipelineRequestSubStep]?
        var elseArm: [PipelineRequestSubStep]?

        enum CodingKeys: String, CodingKey {
            case condition, then
            case elseArm = "else"
        }
    }

    struct PipelineLoopRequest: Encodable, Equatable {
        var body: [PipelineRequestSubStep]
        var until: PipelineConditionRequest
        var max_iterations: Int
    }

    struct PipelineRequestStep: Encodable, Equatable {
        var agent_type: String
        var role: String
        var prompt_template: String
        var input_from_prev: String
        var gate_after: Bool
        var fanout: PipelineRequestFanout?
        // Per-block config (PLAN-HARNESS-BUILDER Phase 1); omitted when
        // empty so an old broker's decode is unaffected.
        var model: String?
        var reasoning_effort: String?
        var permission_mode: String?
        var instructions: String?
        // Control flow (PLAN-HARNESS-BUILDER Phase 3); omitted when the step
        // is a plain agent step so the request stays byte-identical to
        // Phase 1/2 for every non-control-flow block.
        var kind: String?
        var branch: PipelineBranchRequest?
        var loop: PipelineLoopRequest?

        init(_ s: PipelineStep) {
            agent_type = s.agentType
            role = s.role
            prompt_template = s.promptTemplate
            input_from_prev = s.inputFromPrev
            gate_after = s.gateAfter
            fanout = s.fanoutEnabled ? PipelineRequestFanout(
                count: s.fanoutCount,
                agent_types: s.fanoutAgentTypes.isEmpty ? nil : s.fanoutAgentTypes,
                models: s.fanoutModels.isEmpty ? nil : s.fanoutModels,
                reasoning_efforts: s.fanoutReasoningEfforts.isEmpty ? nil : s.fanoutReasoningEfforts,
                permission_modes: s.fanoutPermissionModes.isEmpty ? nil : s.fanoutPermissionModes
            ) : nil
            model = s.model.isEmpty ? nil : s.model
            reasoning_effort = s.reasoningEffort.isEmpty ? nil : s.reasoningEffort
            permission_mode = s.permissionMode.isEmpty ? nil : s.permissionMode
            instructions = s.instructions.isEmpty ? nil : s.instructions

            switch s.kind {
            case "branch":
                kind = "branch"
                branch = PipelineBranchRequest(
                    condition: PipelineConditionRequest(
                        source: s.branchConditionSource,
                        predicate: s.branchConditionPredicate,
                        value: s.branchConditionSource == "prev_output"
                            ? (s.branchConditionValue.isEmpty ? nil : s.branchConditionValue)
                            : nil
                    ),
                    then: s.branchThen.isEmpty ? nil : s.branchThen.map { PipelineRequestSubStep($0) },
                    elseArm: s.branchElse.isEmpty ? nil : s.branchElse.map { PipelineRequestSubStep($0) }
                )
                loop = nil
            case "loop":
                kind = "loop"
                loop = PipelineLoopRequest(
                    body: s.loopBody.map { PipelineRequestSubStep($0) },
                    until: PipelineConditionRequest(
                        source: s.loopUntilSource,
                        predicate: s.loopUntilPredicate,
                        value: s.loopUntilSource == "prev_output"
                            ? (s.loopUntilValue.isEmpty ? nil : s.loopUntilValue)
                            : nil
                    ),
                    max_iterations: s.loopMaxIterations
                )
                branch = nil
            default:
                kind = nil
                branch = nil
                loop = nil
            }
        }
    }

    struct PipelineCreateRequest: Encodable {
        var title: String
        var task: String
        var cwd: String
        var base: String
        var steps: [PipelineRequestStep]
    }

    struct PipelineTemplateSaveRequest: Encodable {
        var title: String
        var task: String
        var steps: [PipelineRequestStep]
    }

}
