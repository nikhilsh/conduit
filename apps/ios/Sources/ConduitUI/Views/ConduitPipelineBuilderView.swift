import SwiftUI

// MARK: - ConduitPipelineBuilderView
//
// Create a new multi-step pipeline. Calls POST /api/pipeline on submit.
// On success navigates to ConduitPipelineMonitorView with the returned
// pipeline ID.
//
// HOW TO PRESENT:
//   .sheet(isPresented: $showPipelineBuilder) {
//       ConduitUI.PipelineBuilderView()
//           .environment(store)
//   }

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

    // MARK: - Builder view

    struct PipelineBuilderView: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass

        @State private var title: String = ""
        @State private var task: String = ""
        @State private var cwd: String = ""
        @State private var baseBranch: String = "main"
        // PLAN-HARNESS-BUILDER Phase 2: steps + selection live in a shared
        // view model so the phone (stacked list + sheet) and tablet
        // (two-pane rail + inspector) layouts read the same state.
        @State private var viewModel = PipelineBuilderViewModel()
        // Phone only: which step's config sheet is presented (nil = none).
        @State private var configSheetStepID: UUID? = nil
        // Sub-step (Then/Else/body) full-config editor -- a stacked sheet on
        // BOTH phone and tablet (unlike the top-level block, which is a
        // sheet on phone / inline inspector on tablet). Nested indefinitely
        // deep two-pane inspectors aren't worth the plumbing for a depth-2-
        // bounded sub-stack, so this one level always modals.
        @State private var subStepEditTarget: SubStepEditTarget? = nil

        @State private var isSubmitting = false
        @State private var errorAlert: String? = nil
        @State private var createdPipeline: CreatedPipeline? = nil
        @State private var navigateToMonitor = false
        // Chain guardrail (Start-button last-line-of-defense) -- non-empty
        // means the confirm alert is showing for these 0-based step indices.
        @State private var chainGuardrailIndices: [Int] = []

        // MARK: Phone reorder-drag state
        //
        // Long-press-then-drag reorder for the phone block stack (replaces
        // List's `.onMove`, which required a permanently-active edit mode
        // that neutered the row's horizontal insets -- see `phoneBody`).
        // Mirrors Android's `ReorderableBlockStack` (PipelineBuilderScreen.kt):
        // each card reports its own measured height; crossing half a
        // neighbor's height while dragging swaps it via `viewModel.moveSteps`.
        @State private var draggingStepID: PipelineStep.ID?
        @State private var dragOffsetY: CGFloat = 0
        @State private var stepHeights: [PipelineStep.ID: CGFloat] = [:]

        // Template state
        @State private var templates: [PipelineTemplate] = []
        @State private var isLoadingTemplates = false
        @State private var showTemplatePicker = false
        @State private var isSavingTemplate = false
        @State private var templateDeleteConfirm: PipelineTemplate? = nil

        private static let staticAgentOptions = ["claude", "codex", "opencode"]
        private let roleOptions = ["researcher", "architect", "engineer", "custom"]
        private let inputFromPrevOptions = ["none", "output", "memory", "memory+output"]

        /// Live assistant list from the broker's capabilities descriptors
        /// (`store.agentDescriptors`, WS-3.1) -- the same store data the
        /// fork / new-session pickers consume, in the same order (claude,
        /// codex first, then extras alphabetically -- mirrors
        /// `ConduitAgentPickerSheet.allAgentKinds`). "shell" is excluded --
        /// it is a raw terminal, not an agent. Falls back to the static
        /// list before the first successful capabilities fetch (old broker,
        /// or fetch still pending) so the picker never renders empty.
        private var agentOptions: [String] {
            let descriptors = store.agentDescriptors
            guard !descriptors.isEmpty else { return Self.staticAgentOptions }
            let known = ["claude", "codex"].filter { descriptors.keys.contains($0) }
            let extras = descriptors.keys
                .filter { !known.contains($0) && $0.lowercased() != "shell" }
                .sorted()
            return known + extras
        }

        /// The model catalog for `agentType`: prefer the descriptor's own
        /// `models[]` (WS-3.1), fall back to the top-level `modelCatalog`
        /// (same broker data, different seam) so either fetch path populates
        /// the picker.
        private func modelCatalog(for agentType: String) -> [ConduitUI.AgentModel] {
            let key = agentType.lowercased()
            if let m = store.agentDescriptors[key]?.models, !m.isEmpty { return m }
            return store.modelCatalog[agentType] ?? []
        }

        /// PLAN-HARNESS-BUILDER Phase 3 (§4.3/§4.5): the model row shows
        /// whenever the agent's descriptor reports `supports.model_override
        /// == true` AND its model catalog is non-empty -- replacing the
        /// Phase-1 hardcoded gemini exclusion (owner decision §8.3) now that
        /// broker PR #900 wires `SpawnOverride.Model` through ACP
        /// `session/set_model` for gemini too. An agent whose descriptor is
        /// missing (old broker, no `agents` map) or reports
        /// `model_override == false` (opencode today) still hides the row --
        /// a visible control must always be honored.
        private func modelRowHidden(agentType: String, catalog: [ConduitUI.AgentModel]) -> Bool {
            ConduitUI.pipelineModelRowHidden(
                modelOverride: store.agentDescriptors[agentType.lowercased()]?.supports.modelOverride ?? false,
                catalogEmpty: catalog.isEmpty
            )
        }

        private func effortOptions(model: String, catalog: [ConduitUI.AgentModel]) -> [String] {
            ConduitUI.ForkOptions.catalogEntry(for: model, in: catalog.isEmpty ? nil : catalog)?.efforts ?? []
        }

        private func supportsPlanMode(agentType: String) -> Bool {
            store.agentDescriptors[agentType.lowercased()]?.supports.planMode ?? false
        }

        private var isTablet: Bool { horizontalSizeClass == .regular }

        // MARK: Themed capsule controls (config-sheet redesign)
        //
        // Replaces the stock gray `.pickerStyle(.segmented)` used throughout
        // the step config sheet/inspector with the same capsule-segment
        // idiom as the new-session Auto/Plan mode picker -- owner ask: "make
        // it look like the rest of the app". A trailing per-option glyph
        // (used for the Agent segment's `AgentGlyph`) is optional.

        @ViewBuilder
        private func capsuleSegments(
            _ options: [String],
            selection: Binding<String>,
            label: @escaping (String) -> String = { $0 },
            glyph: ((String) -> AgentGlyph)? = nil
        ) -> some View {
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { opt in
                    let selected = selection.wrappedValue == opt
                    Button {
                        selection.wrappedValue = opt
                    } label: {
                        segmentLabelContent(opt: opt, selected: selected, label: label, glyph: glyph)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        /// Selected = a SOLID accent-filled capsule (same convention as
        /// `ConduitActionPill`'s `.solid` variant / the chat option-row
        /// selected state: opaque tint fill + `accentText`). The glass-tint
        /// wash this used to route through (`conduitGlassCapsule(tint:
        /// neon.accent)`) only overlays a 6%-opacity fill on top of the
        /// glass, which read as near-black `accentText` on a barely-tinted
        /// dark surface -- illegible (owner: "selected options cannot be
        /// read", #911 follow-up). Unselected keeps the plain glass capsule
        /// unchanged.
        @ViewBuilder
        private func segmentLabelContent(
            opt: String,
            selected: Bool,
            label: (String) -> String,
            glyph: ((String) -> AgentGlyph)?
        ) -> some View {
            let content = HStack(spacing: 5) {
                if let glyph {
                    glyph(opt)
                        .frame(width: 14, height: 14)
                }
                Text(label(opt))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .foregroundStyle(selected ? neon.accentText : neon.textDim)

            if selected {
                content.background(Capsule().fill(neon.accent))
            } else {
                content.conduitGlassCapsule(tint: nil)
            }
        }

        /// Filled-bar reasoning-effort dial matching the new-session
        /// `DirectoryPicker.effortDialSection`, extended with a leading
        /// "Default" stop (pipeline blocks can opt out of an override
        /// entirely, unlike new-session where an effort is always chosen).
        private func effortDialRow(effort: Binding<String>, options: [String], tint: Color) -> some View {
            struct Stop { let label: String; let value: String; let desc: String }
            let stops = [Stop(label: "Default", value: "", desc: "Inherits the flow's default reasoning effort.")]
                + options.map { Stop(label: ConduitUI.ForkOptions.effortLabel($0), value: $0, desc: ConduitUI.ForkOptions.effortDescription($0)) }
            let idx = max(0, stops.firstIndex(where: { $0.value == effort.wrappedValue }) ?? 0)
            let cur = stops[idx]
            return VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    ForEach(Array(stops.enumerated()), id: \.offset) { i, stop in
                        Button {
                            effort.wrappedValue = stop.value
                        } label: {
                            VStack(spacing: 7) {
                                Capsule()
                                    .fill(i <= idx && idx > 0 ? tint : neon.textFaint.opacity(0.25))
                                    .frame(height: 7)
                                Text(stop.label)
                                    .font(neon.sans(11).weight(i == idx ? .bold : .medium))
                                    .foregroundStyle(i == idx ? neon.text : neon.textFaint)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                    }
                }
                Text(cur.desc)
                    .font(neon.sans(11.5))
                    .foregroundStyle(neon.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .animation(.easeInOut(duration: 0.15), value: effort.wrappedValue)
        }

        /// Auto/Plan capsule + helper caption -- identical copy to the
        /// new-session `modeSection`.
        private func modeCapsuleRow(mode: Binding<String>) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                capsuleSegments(
                    ConduitUI.ForkOptions.permissionModes,
                    selection: mode,
                    label: { ConduitUI.ForkOptions.permissionModeLabel($0) }
                )
                Text("Plan = read-only; agent explores and proposes without editing.")
                    .font(neon.mono(10.5))
                    .foregroundStyle(neon.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        /// Caption explaining the "input from prev" segments -- device
        /// feedback: the control's meaning wasn't obvious (owner-hit silent
        /// no-handoff bug, task 2b).
        private var inputFromPrevCaption: some View {
            Text("output = the previous step's reply is included in this step's prompt")
                .font(neon.mono(10.5))
                .foregroundStyle(neon.textFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        /// Glass rounded-rect text field matching the new-session sheet's
        /// fields (`conduitGlassRoundedRect`) -- replaces the ad hoc
        /// `RoundedRectangle().fill(neon.surface2)` box.
        private func glassField(_ placeholder: String, text: Binding<String>, mono: Bool = false) -> some View {
            TextField(placeholder, text: text, axis: .vertical)
                .font(mono ? neon.mono(13) : neon.sans(13))
                .foregroundStyle(neon.text)
                .lineLimit(2...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .conduitGlassRoundedRect(cornerRadius: 13)
                .tint(neon.accent)
        }

        var body: some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    if isTablet {
                        tabletBody
                    } else {
                        phoneBody
                    }
                }
                .navigationTitle("New flow")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .foregroundStyle(neon.textDim)
                    }
                    if store.pipelineTemplates {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                loadTemplates()
                                showTemplatePicker = true
                            } label: {
                                HStack(spacing: 4) {
                                    if isLoadingTemplates {
                                        ProgressView()
                                            .progressViewStyle(.circular)
                                            .scaleEffect(0.7)
                                            .tint(neon.accent)
                                    } else {
                                        Image(systemName: "doc.badge.arrow.up")
                                            .font(.system(size: 14, weight: .semibold))
                                    }
                                    Text("From template")
                                        .font(neon.sans(13).weight(.semibold))
                                }
                                .foregroundStyle(neon.accent)
                            }
                        }
                    }
                }
                .tint(neon.accent)
                .navigationDestination(isPresented: $navigateToMonitor) {
                    if let p = createdPipeline {
                        ConduitUI.PipelineMonitorView(
                            pipelineID: p.id,
                            pipelineTitle: title.isEmpty ? "Flow" : title
                        )
                        .environment(store)
                    }
                }
                .sheet(isPresented: Binding(
                    get: { configSheetStepID != nil },
                    set: { if !$0 { configSheetStepID = nil } }
                )) {
                    if let id = configSheetStepID, let index = viewModel.index(for: id) {
                        configSheet(index: index)
                    }
                }
                .sheet(isPresented: $showTemplatePicker) {
                    templatePickerSheet
                }
                .sheet(item: $subStepEditTarget) { target in
                    subStepEditorSheet(target)
                }
                .alert("Delete template?", isPresented: Binding(
                    get: { templateDeleteConfirm != nil },
                    set: { if !$0 { templateDeleteConfirm = nil } }
                )) {
                    Button("Delete", role: .destructive) {
                        if let t = templateDeleteConfirm {
                            deleteTemplate(t)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    if let t = templateDeleteConfirm {
                        Text("Delete \"\(t.title)\"? This cannot be undone.")
                    }
                }
                .alert("Error", isPresented: Binding(
                    get: { errorAlert != nil },
                    set: { if !$0 { errorAlert = nil } }
                )) {
                    Button("OK") { errorAlert = nil }
                } message: {
                    if let m = errorAlert { Text(m) }
                }
                // Chain guardrail: last-line-of-defense at Start, since a
                // saved template/draft carries "none" forever even though
                // #911 defaults brand-new steps to "output" (owner hit this
                // twice -- "step 2 just did its own thing").
                .alert("Steps aren't chained", isPresented: Binding(
                    get: { !chainGuardrailIndices.isEmpty },
                    set: { if !$0 { chainGuardrailIndices = [] } }
                )) {
                    Button("Chain steps") {
                        Telemetry.breadcrumb("pipeline", "chain guardrail chain",
                            data: ["steps": "\(chainGuardrailIndices.count)"])
                        viewModel.chainUnchainedSteps()
                        chainGuardrailIndices = []
                        submitPipeline()
                    }
                    Button("Start anyway") {
                        Telemetry.breadcrumb("pipeline", "chain guardrail start anyway",
                            data: ["steps": "\(chainGuardrailIndices.count)"])
                        chainGuardrailIndices = []
                        submitPipeline()
                    }
                    Button("Cancel", role: .cancel) {
                        chainGuardrailIndices = []
                    }
                } message: {
                    Text(chainGuardrailMessage)
                }
            }
            .appearanceColorScheme()
            .onAppear {
                // Seed CWD from the current session's working dir if available
                if let activeID = store.selectedSessionID,
                   let status = store.statusBySession[activeID],
                   let sessionCwd = status.cwd, !sessionCwd.isEmpty {
                    cwd = sessionCwd
                }
                Telemetry.breadcrumb("pipeline", "builder opened")
            }
        }

        // MARK: Phone layout -- stacked block-card list + config sheet
        //
        // A plain `ScrollView` + `VStack`, NOT a `List`. A `List` was tried
        // twice (Phase 2, then #909's `.listRowInsets` pass) and neither
        // produced reliable side margins: this screen holds the steps
        // `ForEach` permanently in edit mode (`.environment(\.editMode,
        // .constant(.active))`) so `.onMove` always shows its drag handle,
        // and UIKit's editing-state row layout does NOT reliably honor a
        // custom `.listRowInsets` leading/trailing pair once a row belongs
        // to a movable group -- the reorder accessory is drawn past the
        // row's own inset box, and empirically the whole row's content
        // insets go along with it. `tabletBody` below never had this
        // problem because it was ALREADY a plain `ScrollView` + `VStack`
        // with a single `.padding(16)` -- that's the proven precedent this
        // mirrors, plus Android's `PipelineBuilderScreen.kt`, which never
        // used a `LazyColumn` item's own insets either: one
        // `contentPadding(horizontal = 16.dp)` on the whole column, same
        // number reused here.
        private var phoneBody: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    metadataSection

                    VStack(alignment: .leading, spacing: 10) {
                        stepsHeader

                        if viewModel.steps.count > 1 {
                            topologyPreview
                        }

                        reorderableStepStack

                        addStepRow
                    }

                    if store.pipelineTemplates {
                        saveTemplateButton
                    }

                    startButton
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }

        /// Long-press-then-drag reorder stack (replaces `List.onMove`).
        /// Each card measures its own height via a `GeometryReader` background;
        /// while dragging, crossing half of a neighbor's height swaps places with
        /// it through `viewModel.moveSteps` -- the SAME tested reorder
        /// entrypoint the old `.onMove` closure called, so
        /// `ConduitPipelineBuilderViewModelTests`'s move-semantics coverage
        /// still applies unchanged. Mirrors Android's
        /// `ReorderableBlockStack` measured-height + threshold-swap design.
        private var reorderableStepStack: some View {
            VStack(spacing: 8) {
                ForEach(Array(viewModel.steps.enumerated()), id: \.element.id) { index, step in
                    let isDragging = draggingStepID == step.id
                    blockCard(step: step, index: index, onDelete: viewModel.canDeleteStep ? {
                        viewModel.removeStep(id: step.id)
                    } : nil)
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .onAppear { stepHeights[step.id] = geo.size.height }
                                    .onChange(of: geo.size.height) { _, newHeight in
                                        stepHeights[step.id] = newHeight
                                    }
                            }
                        )
                        .zIndex(isDragging ? 1 : 0)
                        .offset(y: isDragging ? dragOffsetY : 0)
                        .opacity(isDragging ? 0.92 : 1)
                        .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.8), value: dragOffsetY)
                        .onTapGesture { configSheetStepID = step.id }
                        .simultaneousGesture(stepDragGesture(step: step, index: index))
                }
            }
        }

        /// Long-press (so a plain tap still opens the config sheet) then
        /// drag vertically; crossing half the dragged card's own height
        /// past a neighbor swaps the two via `viewModel.moveSteps` (List
        /// `.onMove` offset/destination convention -- see the view model's
        /// doc comment). `current` is re-looked-up by id each callback so a
        /// mid-drag swap (which changes array indices) stays consistent.
        private func stepDragGesture(step: PipelineStep, index: Int) -> some Gesture {
            LongPressGesture(minimumDuration: 0.35)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                .onChanged { value in
                    switch value {
                    case .second(true, let drag):
                        guard let drag else { return }
                        if draggingStepID == nil {
                            draggingStepID = step.id
                            Telemetry.breadcrumb("pipeline", "builder_drag_start", data: ["index": "\(index)"])
                        }
                        dragOffsetY = drag.translation.height
                        guard let current = viewModel.index(for: step.id),
                              let myHeight = stepHeights[step.id], myHeight > 0 else { return }
                        if dragOffsetY > myHeight / 2, current < viewModel.steps.count - 1 {
                            let neighborID = viewModel.steps[current + 1].id
                            let neighborHeight = stepHeights[neighborID] ?? myHeight
                            viewModel.moveSteps(from: IndexSet(integer: current), to: current + 2)
                            dragOffsetY -= neighborHeight + 8
                        } else if dragOffsetY < -(myHeight / 2), current > 0 {
                            let neighborID = viewModel.steps[current - 1].id
                            let neighborHeight = stepHeights[neighborID] ?? myHeight
                            viewModel.moveSteps(from: IndexSet(integer: current), to: current - 1)
                            dragOffsetY += neighborHeight + 8
                        }
                    default:
                        break
                    }
                }
                .onEnded { _ in
                    draggingStepID = nil
                    dragOffsetY = 0
                }
        }

        private func configSheet(index: Int) -> some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            stepConfigEditor(step: stepBinding(index), index: index)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                    }
                }
                .navigationTitle("Step \(index + 1)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { configSheetStepID = nil }
                            .foregroundStyle(neon.accent)
                    }
                    if viewModel.canDeleteStep {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(role: .destructive) {
                                let id = viewModel.steps[index].id
                                configSheetStepID = nil
                                viewModel.removeStep(id: id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .foregroundStyle(neon.red)
                        }
                    }
                }
            }
        }

        // MARK: Tablet layout -- block-list rail + inspector pane

        private var tabletBody: some View {
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        metadataSection
                        VStack(alignment: .leading, spacing: 10) {
                            stepsHeader
                            if viewModel.steps.count > 1 {
                                topologyPreview
                            }
                            ForEach(Array(viewModel.steps.enumerated()), id: \.element.id) { index, step in
                                blockCard(step: step, index: index, isSelected: viewModel.selectedStepID == step.id)
                                    .onTapGesture { viewModel.selectedStepID = step.id }
                                    .contextMenu {
                                        if viewModel.canDeleteStep {
                                            Button(role: .destructive) {
                                                viewModel.removeStep(id: step.id)
                                            } label: {
                                                Label("Delete step", systemImage: "trash")
                                            }
                                        }
                                    }
                            }
                            addStepRow
                        }
                        if store.pipelineTemplates {
                            saveTemplateButton
                        }
                        startButton
                    }
                    .padding(16)
                }
                .frame(width: 360)

                Divider().background(neon.border)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let selID = viewModel.selectedStepID,
                           let index = viewModel.index(for: selID) {
                            Text("Step \(index + 1)")
                                .font(neon.mono(12).weight(.bold))
                                .foregroundStyle(neon.textDim)
                                .textCase(.uppercase)
                            stepConfigEditor(step: stepBinding(index), index: index)
                        } else {
                            Text("Select a step to configure it.")
                                .font(neon.sans(14))
                                .foregroundStyle(neon.textFaint)
                                .padding(.top, 40)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }

        // MARK: Binding helper

        /// Binding into `viewModel.steps[index]` by POSITION (steps carry no
        /// client-side index field; the array position IS the order). The
        /// index is recomputed by the caller (`viewModel.index(for:)`) on
        /// every access, so this stays correct even if a drag-reorder moves
        /// the step while its sheet/inspector is open.
        private func stepBinding(_ index: Int) -> Binding<PipelineStep> {
            Binding(
                get: { viewModel.steps.indices.contains(index) ? viewModel.steps[index] : PipelineStep() },
                set: { newValue in
                    if viewModel.steps.indices.contains(index) { viewModel.steps[index] = newValue }
                }
            )
        }

        // MARK: Template picker sheet

        private var templatePickerSheet: some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    if templates.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 36, weight: .light))
                                .foregroundStyle(neon.textFaint)
                            Text("No templates saved yet")
                                .font(neon.sans(15))
                                .foregroundStyle(neon.textDim)
                            Text("Use \"Save as template\" after filling in a flow.")
                                .font(neon.sans(13))
                                .foregroundStyle(neon.textFaint)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(32)
                    } else {
                        ScrollView {
                            VStack(spacing: 10) {
                                ForEach(templates) { tmpl in
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(tmpl.title)
                                                .font(neon.sans(14).weight(.semibold))
                                                .foregroundStyle(neon.text)
                                            Text("\(tmpl.steps.count) step\(tmpl.steps.count == 1 ? "" : "s")")
                                                .font(neon.mono(11))
                                                .foregroundStyle(neon.textFaint)
                                        }
                                        Spacer(minLength: 8)
                                        // Swipe-or-button delete
                                        Button {
                                            templateDeleteConfirm = tmpl
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(neon.red)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .neonCardSurface(neon, fill: neon.surface, cornerRadius: 12)
                                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .onTapGesture {
                                        applyTemplate(tmpl)
                                        showTemplatePicker = false
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            templateDeleteConfirm = tmpl
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                    }
                }
                .navigationTitle("From template")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showTemplatePicker = false }
                            .foregroundStyle(neon.textDim)
                    }
                }
            }
        }

        // MARK: Save as template button

        private var saveTemplateButton: some View {
            ConduitUI.ActionButton(variant: .secondary, tint: neon.accent) {
                saveAsTemplate()
            } label: {
                HStack(spacing: 6) {
                    if isSavingTemplate {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(neon.accent)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Text(isSavingTemplate ? "Saving..." : "Save as template")
                }
            }
            .disabled(isSavingTemplate || startDisabled)
            .opacity((isSavingTemplate || startDisabled) ? 0.45 : 1)
        }

        // MARK: Metadata section

        private var metadataSection: some View {
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("Flow details")

                labeledField("Title") {
                    TextField("e.g. Refactor auth flow", text: $title)
                        .font(neon.sans(15))
                        .foregroundStyle(neon.text)
                        .textInputAutocapitalization(.sentences)
                        .tint(neon.accent)
                }

                labeledField("Task") {
                    TextField("Describe the task...", text: $task, axis: .vertical)
                        .font(neon.sans(14))
                        .foregroundStyle(neon.text)
                        .lineLimit(3...6)
                        .tint(neon.accent)
                }

                labeledField("Working dir") {
                    TextField("/path/to/project", text: $cwd)
                        .font(neon.mono(13))
                        .foregroundStyle(neon.text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .tint(neon.accent)
                }

                labeledField("Base branch") {
                    TextField("main", text: $baseBranch)
                        .font(neon.mono(13))
                        .foregroundStyle(neon.text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .tint(neon.accent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
        }

        // MARK: Steps header + topology preview + add-step row

        private var stepsHeader: some View {
            HStack {
                sectionLabel("Steps")
                Spacer(minLength: 8)
            }
        }

        /// Compact read-only rail (`ConduitUI.PipelineTopologyRail`) giving
        /// an at-a-glance view of the whole stack -- gate pause-markers +
        /// indented fanout clusters -- above the editable block cards.
        private var topologyPreview: some View {
            ConduitUI.PipelineTopologyRail(items: viewModel.topologyItems) { id in
                if isTablet {
                    viewModel.selectedStepID = id
                } else {
                    configSheetStepID = id
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface2.opacity(0.5), cornerRadius: 12)
        }

        /// Add-block affordance: a plain button when neither control-flow
        /// flag is on (byte-identical UX to Phase 2), a Menu offering
        /// Agent step / If-Else / Loop once the broker advertises either.
        @ViewBuilder
        private var addStepRow: some View {
            if store.pipelineBranch || store.pipelineLoop {
                Menu {
                    Button {
                        viewModel.addStep()
                    } label: {
                        Label("Agent step", systemImage: "person.fill")
                    }
                    if store.pipelineBranch {
                        Button {
                            viewModel.addControlFlowStep(kind: "branch")
                        } label: {
                            Label("If/Else", systemImage: "arrow.triangle.branch")
                        }
                    }
                    if store.pipelineLoop {
                        Button {
                            viewModel.addControlFlowStep(kind: "loop")
                        } label: {
                            Label("Loop", systemImage: "repeat")
                        }
                    }
                } label: {
                    ConduitUI.ActionPill(label: "Add step", systemImage: "plus", variant: .soft)
                }
            } else {
                ConduitUI.ActionPill(label: "Add step", systemImage: "plus", variant: .soft) {
                    viewModel.addStep()
                }
            }
        }

        // MARK: Block card (compact -- tap opens config)

        @ViewBuilder
        private func blockCard(step: PipelineStep, index: Int, isSelected: Bool = false, onDelete: (() -> Void)? = nil) -> some View {
            if step.isControlFlow {
                controlFlowBlockCard(step: step, index: index, isSelected: isSelected, onDelete: onDelete)
            } else {
                agentBlockCard(step: step, index: index, isSelected: isSelected, onDelete: onDelete)
            }
        }

        private func agentBlockCard(step: PipelineStep, index: Int, isSelected: Bool, onDelete: (() -> Void)? = nil) -> some View {
            ConduitUI.Card(
                tint: isSelected ? neon.accent : nil
            ) {
                HStack(alignment: .top, spacing: 12) {
                    AgentGlyph(assistant: step.agentType, size: 26)
                        .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text("\(index + 1). \(step.role.capitalized)")
                                .font(neon.sans(13).weight(.semibold))
                                .foregroundStyle(neon.text)
                                .lineLimit(1)
                            if step.gateAfter {
                                Image(systemName: "hand.raised.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(neon.yellow)
                            }
                            if step.fanoutEnabled {
                                Image(systemName: "arrow.branch")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(neon.accent)
                            }
                        }

                        blockChips(step: step)

                        if !step.instructions.isEmpty {
                            Text(step.instructions)
                                .font(neon.sans(11))
                                .foregroundStyle(neon.textFaint)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }

                    Spacer(minLength: 4)

                    // Phone-only (List's `.swipeActions` is gone along with
                    // the List itself -- see `phoneBody`); tablet keeps its
                    // existing `.contextMenu` delete and passes no closure.
                    if let onDelete {
                        Button(role: .destructive, action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(neon.red)
                        }
                        .buttonStyle(.plain)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(neon.textFaint)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }

        /// Compact summary card for an If/Else or Loop block -- condition +
        /// sub-stack counts only. The full Then/Else/body editor lives in
        /// the config sheet/inspector (`controlFlowConfigEditor`), reached
        /// by tapping this card, same precedent as the fanout toggle today.
        private func controlFlowBlockCard(step: PipelineStep, index: Int, isSelected: Bool, onDelete: (() -> Void)? = nil) -> some View {
            ConduitUI.Card(
                tint: isSelected ? neon.accent : nil
            ) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: step.kind == "loop" ? "repeat" : "arrow.triangle.branch")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(neon.accent)
                        .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text("\(index + 1). \(step.kind == "loop" ? "Loop" : "If/Else")")
                                .font(neon.sans(13).weight(.semibold))
                                .foregroundStyle(neon.text)
                                .lineLimit(1)
                            if step.kind == "loop" {
                                Text("max \(step.loopMaxIterations)x")
                                    .font(neon.mono(9).weight(.bold))
                                    .foregroundStyle(neon.accent)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(neon.accent.opacity(0.15)))
                            }
                        }

                        Text(conditionSummary(step: step))
                            .font(neon.sans(11))
                            .foregroundStyle(neon.textDim)
                            .lineLimit(2)

                        if step.kind == "branch" {
                            Text("\(step.branchThen.count) then / \(step.branchElse.count) else")
                                .font(neon.mono(10))
                                .foregroundStyle(neon.textFaint)
                        } else {
                            Text("\(step.loopBody.count) step\(step.loopBody.count == 1 ? "" : "s") in body")
                                .font(neon.mono(10))
                                .foregroundStyle(neon.textFaint)
                        }
                    }

                    Spacer(minLength: 4)

                    if let onDelete {
                        Button(role: .destructive, action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(neon.red)
                        }
                        .buttonStyle(.plain)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(neon.textFaint)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }

        /// Inline parameter chips: `agent - model - effort - mode`, only
        /// the ones whose value is set/non-default (agent always shows;
        /// model/effort/mode only when the block overrides the adapter
        /// default).
        private func blockChips(step: PipelineStep) -> some View {
            HStack(spacing: 6) {
                ConduitUI.Chip(label: step.agentType, tint: neon.agentTint(forAgent: step.agentType))
                if !step.model.isEmpty {
                    ConduitUI.Chip(label: modelLabel(step.model, in: modelCatalog(for: step.agentType)))
                }
                if !step.reasoningEffort.isEmpty {
                    ConduitUI.Chip(label: ConduitUI.ForkOptions.effortLabel(step.reasoningEffort))
                }
                if !step.permissionMode.isEmpty {
                    ConduitUI.Chip(label: ConduitUI.ForkOptions.permissionModeLabel(step.permissionMode))
                }
            }
        }

        // MARK: Per-step config editor (shared by the phone sheet + tablet inspector)

        @ViewBuilder
        private func stepConfigEditor(step: Binding<PipelineStep>, index: Int) -> some View {
            if step.wrappedValue.isControlFlow {
                controlFlowConfigEditor(step: step)
            } else {
                agentStepConfigEditor(step: step, index: index)
            }
        }

        @ViewBuilder
        private func agentStepConfigEditor(step: Binding<PipelineStep>, index: Int) -> some View {
            VStack(alignment: .leading, spacing: 14) {
                // Agent type picker -- themed capsule segments + AgentGlyph,
                // matching the new-session agent picker's per-agent tinting.
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("Agent")
                    capsuleSegments(agentOptions, selection: step.agentType) { AgentGlyph(assistant: $0, size: 14) }
                }

                // Per-block config (model / effort / permission mode /
                // instructions), gated on pipeline_block_config so an old
                // broker never sees controls it would silently drop.
                if store.pipelineBlockConfig {
                    blockConfigSection(step: step)
                }

                // Role picker
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("Role")
                    capsuleSegments(roleOptions, selection: step.role)
                        .onChange(of: step.wrappedValue.role) { _, newRole in
                            if newRole != "custom" {
                                step.wrappedValue.promptTemplate = rolePromptTemplate(newRole)
                            }
                        }
                }

                // Prompt template
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("Prompt template")
                    glassField("Custom prompt...", text: step.promptTemplate)
                }

                // Input from prev
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("Input from prev")
                    capsuleSegments(inputFromPrevOptions, selection: step.inputFromPrev)
                    inputFromPrevCaption
                }

                // Gate after toggle
                ConduitUI.toggleRow(
                    icon: "checkmark.shield",
                    title: "Gate after this step",
                    isOn: step.gateAfter
                )
                .neonCardSurface(neon, fill: neon.surface2.opacity(0.5), cornerRadius: 12)

                // Fan out toggle (gated on pipeline_fanout capability)
                if store.pipelineFanout {
                    fanoutSection(step: step)
                }
            }
        }

        // MARK: Control-flow config editor (If/Else + Loop, PLAN-HARNESS-BUILDER Phase 3)
        //
        // Mirrors the fanout precedent (§3.1: the indented per-run editor
        // lives inside the config sheet, not inline in the compact block
        // card) -- the Then/Else/body sub-stacks with add/remove/reorder
        // render here, inside the same sheet (phone) / inspector (tablet)
        // used for every other block's config.

        @ViewBuilder
        private func controlFlowConfigEditor(step: Binding<PipelineStep>) -> some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: step.wrappedValue.kind == "loop" ? "repeat" : "arrow.triangle.branch")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(neon.accent)
                    Text(step.wrappedValue.kind == "loop" ? "Loop" : "If/Else")
                        .font(neon.sans(14).weight(.bold))
                        .foregroundStyle(neon.text)
                }

                if step.wrappedValue.kind == "branch" {
                    conditionEditor(
                        title: "Condition",
                        source: step.branchConditionSource,
                        predicate: step.branchConditionPredicate,
                        value: step.branchConditionValue
                    )

                    subStackEditor(
                        title: "Then",
                        stepID: step.wrappedValue.id,
                        arm: .then,
                        subSteps: step.wrappedValue.branchThen
                    )
                    subStackEditor(
                        title: "Else (optional)",
                        stepID: step.wrappedValue.id,
                        arm: .elseArm,
                        subSteps: step.wrappedValue.branchElse
                    )
                } else {
                    conditionEditor(
                        title: "Until",
                        source: step.loopUntilSource,
                        predicate: step.loopUntilPredicate,
                        value: step.loopUntilValue
                    )

                    maxIterationsStepper(step: step)

                    subStackEditor(
                        title: "Body",
                        stepID: step.wrappedValue.id,
                        arm: .body,
                        subSteps: step.wrappedValue.loopBody
                    )
                }
            }
        }

        /// Condition source picker (prev_output / exit_status), then either
        /// a predicate + value editor (prev_output) or a succeeded/failed
        /// toggle (exit_status) -- mirrors `pipeline.Condition`
        /// (broker/internal/pipeline/controlflow.go).
        @ViewBuilder
        private func conditionEditor(
            title: String,
            source: Binding<String>,
            predicate: Binding<String>,
            value: Binding<String>
        ) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased())
                    .font(neon.mono(10).weight(.semibold))
                    .foregroundStyle(neon.textFaint)

                Picker(title, selection: source) {
                    Text("Prev output").tag("prev_output")
                    Text("Exit status").tag("exit_status")
                }
                .pickerStyle(.segmented)
                .tint(neon.accent)
                .onChange(of: source.wrappedValue) { _, newSource in
                    // Snap the predicate to a valid one for the new source
                    // (broker validateCondition rejects a mismatched pair).
                    if newSource == "exit_status" {
                        if predicate.wrappedValue != "succeeded" && predicate.wrappedValue != "failed" {
                            predicate.wrappedValue = "succeeded"
                        }
                    } else if predicate.wrappedValue != "contains"
                        && predicate.wrappedValue != "not_contains"
                        && predicate.wrappedValue != "matches" {
                        predicate.wrappedValue = "contains"
                    }
                }

                if source.wrappedValue == "exit_status" {
                    Picker("Predicate", selection: predicate) {
                        Text("Succeeded").tag("succeeded")
                        Text("Failed").tag("failed")
                    }
                    .pickerStyle(.segmented)
                    .tint(neon.accent)
                } else {
                    Picker("Predicate", selection: predicate) {
                        Text("Contains").tag("contains")
                        Text("Not contains").tag("not_contains")
                        Text("Matches (regex)").tag("matches")
                    }
                    .pickerStyle(.segmented)
                    .tint(neon.accent)

                    TextField("Value to match...", text: value)
                        .font(neon.mono(13))
                        .foregroundStyle(neon.text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(neon.surface2)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(neon.border, lineWidth: 1))
                        )
                        .tint(neon.accent)
                }
            }
        }

        /// max_iterations stepper, 1-5 (broker hard cap, owner decision
        /// §8.5), default 3.
        private func maxIterationsStepper(step: Binding<PipelineStep>) -> some View {
            HStack {
                Text("Max iterations")
                    .font(neon.mono(11).weight(.semibold))
                    .foregroundStyle(neon.textFaint)
                    .textCase(.uppercase)
                Spacer(minLength: 8)
                HStack(spacing: 12) {
                    Button {
                        if step.wrappedValue.loopMaxIterations > 1 {
                            step.wrappedValue.loopMaxIterations -= 1
                        }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(step.wrappedValue.loopMaxIterations > 1 ? neon.accent : neon.textFaint)
                    }
                    .buttonStyle(.plain)
                    Text("\(step.wrappedValue.loopMaxIterations)")
                        .font(neon.mono(15).weight(.bold))
                        .foregroundStyle(neon.text)
                        .frame(minWidth: 20, alignment: .center)
                    Button {
                        if step.wrappedValue.loopMaxIterations < 5 {
                            step.wrappedValue.loopMaxIterations += 1
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(step.wrappedValue.loopMaxIterations < 5 ? neon.accent : neon.textFaint)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        /// A Then/Else/body sub-stack: an indented list of compact sub-step
        /// rows (tap to open the full agent-config editor) + an add-step
        /// affordance. Reorder is up/down (not drag) -- these rows live in a
        /// plain VStack, not a `List`, since they're nested inside a config
        /// sheet/inspector that is itself scrollable content.
        @ViewBuilder
        private func subStackEditor(
            title: String,
            stepID: PipelineStep.ID,
            arm: PipelineSubStepArm,
            subSteps: [PipelineSubStep]
        ) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased())
                    .font(neon.mono(10).weight(.semibold))
                    .foregroundStyle(neon.textFaint)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(subSteps.enumerated()), id: \.element.id) { i, sub in
                        subStepRow(sub: sub, index: i, count: subSteps.count, stepID: stepID, arm: arm)
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(neon.border.opacity(0.5)).frame(width: 1)
                }

                ConduitUI.ActionPill(label: "Add step", systemImage: "plus", variant: .soft) {
                    viewModel.addSubStep(stepID: stepID, arm: arm)
                }
                .padding(.leading, 10)
            }
        }

        private func subStepRow(
            sub: PipelineSubStep,
            index: Int,
            count: Int,
            stepID: PipelineStep.ID,
            arm: PipelineSubStepArm
        ) -> some View {
            HStack(spacing: 8) {
                AgentGlyph(assistant: sub.agentType, size: 20)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(index + 1). \(sub.role.capitalized)")
                        .font(neon.sans(12).weight(.semibold))
                        .foregroundStyle(neon.text)
                        .lineLimit(1)
                    let detail = [
                        sub.model.isEmpty ? nil : modelLabel(sub.model, in: modelCatalog(for: sub.agentType)),
                        sub.instructions.isEmpty ? nil : sub.instructions,
                    ].compactMap { $0 }.joined(separator: " \u{00B7} ")
                    if !detail.isEmpty {
                        Text(detail)
                            .font(neon.sans(10))
                            .foregroundStyle(neon.textFaint)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Button {
                    viewModel.moveSubStep(stepID: stepID, arm: arm, subStepID: sub.id, direction: -1)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .opacity(index == 0 ? 0.3 : 1)
                Button {
                    viewModel.moveSubStep(stepID: stepID, arm: arm, subStepID: sub.id, direction: 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .disabled(index == count - 1)
                .opacity(index == count - 1 ? 0.3 : 1)
                Button {
                    viewModel.removeSubStep(stepID: stepID, arm: arm, subStepID: sub.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(neon.red)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(neon.surface2.opacity(0.6))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture {
                subStepEditTarget = SubStepEditTarget(stepID: stepID, arm: arm, subStepID: sub.id)
            }
        }

        /// Compact one-line human-readable condition summary shown on the
        /// block card (e.g. "if output contains \"APPROVED\"").
        private func conditionSummary(step: PipelineStep) -> String {
            let isLoop = step.kind == "loop"
            let source = isLoop ? step.loopUntilSource : step.branchConditionSource
            let predicate = isLoop ? step.loopUntilPredicate : step.branchConditionPredicate
            let value = isLoop ? step.loopUntilValue : step.branchConditionValue
            let verb = isLoop ? "until" : "if"
            if source == "exit_status" {
                return "\(verb) previous step \(predicate)"
            }
            return "\(verb) output \(predicateLabel(predicate)) \"\(value)\""
        }

        private func predicateLabel(_ p: String) -> String {
            switch p {
            case "contains": return "contains"
            case "not_contains": return "does not contain"
            case "matches": return "matches"
            default: return p
            }
        }

        // MARK: Sub-step editor sheet (Then/Else/body -- always modal, both phone + tablet)

        private func subStepEditorSheet(_ target: SubStepEditTarget) -> some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            subStepConfigEditor(sub: subStepBinding(target))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                    }
                }
                .navigationTitle("Step")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { subStepEditTarget = nil }
                            .foregroundStyle(neon.accent)
                    }
                }
            }
        }

        private func subStepBinding(_ target: SubStepEditTarget) -> Binding<PipelineSubStep> {
            Binding(
                get: {
                    viewModel.subStepBinding(stepID: target.stepID, arm: target.arm, subStepID: target.subStepID)
                },
                set: { newValue in
                    viewModel.updateSubStep(stepID: target.stepID, arm: target.arm, subStep: newValue)
                }
            )
        }

        /// Agent-only config editor for a Then/Else/body sub-step -- no
        /// fanout, no kind, no nested control flow (depth-2 bound by
        /// construction, PipelineSubStep has none of those fields).
        @ViewBuilder
        private func subStepConfigEditor(sub: Binding<PipelineSubStep>) -> some View {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("Agent")
                    capsuleSegments(agentOptions, selection: sub.agentType) { AgentGlyph(assistant: $0, size: 14) }
                }

                if store.pipelineBlockConfig {
                    subStepBlockConfigSection(sub: sub)
                }

                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("Role")
                    capsuleSegments(roleOptions, selection: sub.role)
                        .onChange(of: sub.wrappedValue.role) { _, newRole in
                            if newRole != "custom" {
                                sub.wrappedValue.promptTemplate = rolePromptTemplate(newRole)
                            }
                        }
                }

                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("Prompt template")
                    glassField("Custom prompt...", text: sub.promptTemplate)
                }

                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("Input from prev")
                    capsuleSegments(inputFromPrevOptions, selection: sub.inputFromPrev)
                    inputFromPrevCaption
                }

                ConduitUI.toggleRow(
                    icon: "checkmark.shield",
                    title: "Gate after this step",
                    isOn: sub.gateAfter
                )
                .neonCardSurface(neon, fill: neon.surface2.opacity(0.5), cornerRadius: 12)
            }
        }

        @ViewBuilder
        private func subStepBlockConfigSection(sub: Binding<PipelineSubStep>) -> some View {
            let agentType = sub.wrappedValue.agentType
            let catalog = modelCatalog(for: agentType)
            let showModel = !modelRowHidden(agentType: agentType, catalog: catalog)
            let efforts = effortOptions(model: sub.wrappedValue.model, catalog: catalog)
            let showEffort = !efforts.isEmpty
            let showMode = supportsPlanMode(agentType: agentType)
            let tint = neon.agentTint(forAgent: agentType)

            VStack(alignment: .leading, spacing: 12) {
                if showModel {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("Model")
                        ConduitUI.ModelPickerRow(
                            agentKind: agentType,
                            catalog: catalog.isEmpty ? nil : catalog,
                            model: sub.model,
                            tint: tint,
                            telemetryContext: "pipeline"
                        )
                    }
                    .onChange(of: sub.wrappedValue.model) { _, _ in
                        let newEfforts = effortOptions(model: sub.wrappedValue.model, catalog: catalog)
                        if !newEfforts.contains(sub.wrappedValue.reasoningEffort) {
                            sub.wrappedValue.reasoningEffort = ""
                        }
                    }
                }

                if showEffort {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("Reasoning effort")
                        effortDialRow(effort: sub.reasoningEffort, options: efforts, tint: tint)
                    }
                }

                if showMode {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("Permission mode")
                        modeCapsuleRow(mode: sub.permissionMode)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("Instructions for this block")
                    glassField("Optional standing guidance...", text: sub.instructions)
                }
            }
        }

        // MARK: Per-block config (model / effort / permission mode / instructions)

        @ViewBuilder
        private func blockConfigSection(step: Binding<PipelineStep>) -> some View {
            let agentType = step.wrappedValue.agentType
            let catalog = modelCatalog(for: agentType)
            let showModel = !modelRowHidden(agentType: agentType, catalog: catalog)
            let efforts = effortOptions(model: step.wrappedValue.model, catalog: catalog)
            let showEffort = !efforts.isEmpty
            let showMode = supportsPlanMode(agentType: agentType)
            let tint = neon.agentTint(forAgent: agentType)

            VStack(alignment: .leading, spacing: 12) {
                if showModel {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("Model")
                        ConduitUI.ModelPickerRow(
                            agentKind: agentType,
                            catalog: catalog.isEmpty ? nil : catalog,
                            model: step.model,
                            tint: tint,
                            telemetryContext: "pipeline"
                        )
                    }
                    .onChange(of: step.wrappedValue.model) { _, _ in
                        // A model switch can change the supported effort
                        // range; snap back to Default rather than carry
                        // a stale level the new model doesn't offer.
                        let newEfforts = effortOptions(model: step.wrappedValue.model, catalog: catalog)
                        if !newEfforts.contains(step.wrappedValue.reasoningEffort) {
                            step.wrappedValue.reasoningEffort = ""
                        }
                    }
                }

                if showEffort {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("Reasoning effort")
                        effortDialRow(effort: step.reasoningEffort, options: efforts, tint: tint)
                    }
                }

                if showMode {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("Permission mode")
                        modeCapsuleRow(mode: step.permissionMode)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("Instructions for this block")
                    glassField("Optional standing guidance for this block...", text: step.instructions)
                }
            }
        }

        /// Compact model label for the collapsed block-card summary chip and
        /// the sub-step row detail line -- non-optional catalog, no
        /// "(recommended)" suffix (that's the picker sheet's job).
        private func modelLabel(_ id: String, in catalog: [ConduitUI.AgentModel]) -> String {
            if id.isEmpty { return "Default" }
            if let m = catalog.first(where: { $0.id == id }), !m.displayName.isEmpty { return m.displayName }
            return id
        }

        @ViewBuilder
        private func fanoutSection(step: Binding<PipelineStep>) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                ConduitUI.toggleRow(
                    icon: "arrow.branch",
                    title: "Fan out this step",
                    isOn: step.fanoutEnabled
                )
                .onChange(of: step.wrappedValue.fanoutEnabled) { _, newVal in
                    Telemetry.breadcrumb("pipeline", "fanout toggle",
                        data: ["enabled": newVal ? "true" : "false"])
                    if newVal && step.wrappedValue.fanoutCount < 1 {
                        step.wrappedValue.fanoutCount = 2
                    }
                }

                if step.wrappedValue.fanoutEnabled {
                    // Run count stepper (1-6)
                    HStack {
                        Text("Run count")
                            .font(neon.mono(11).weight(.semibold))
                            .foregroundStyle(neon.textFaint)
                            .textCase(.uppercase)
                        Spacer(minLength: 8)
                        HStack(spacing: 12) {
                            Button {
                                if step.wrappedValue.fanoutCount > 1 {
                                    step.wrappedValue.fanoutCount -= 1
                                    // Trim agent list if too long
                                    if step.wrappedValue.fanoutAgentTypes.count > step.wrappedValue.fanoutCount {
                                        step.wrappedValue.fanoutAgentTypes = Array(step.wrappedValue.fanoutAgentTypes.prefix(step.wrappedValue.fanoutCount))
                                    }
                                }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundStyle(step.wrappedValue.fanoutCount > 1 ? neon.accent : neon.textFaint)
                            }
                            .buttonStyle(.plain)
                            Text("\(step.wrappedValue.fanoutCount)")
                                .font(neon.mono(16).weight(.bold))
                                .foregroundStyle(neon.text)
                                .frame(minWidth: 24, alignment: .center)
                            Button {
                                if step.wrappedValue.fanoutCount < 6 {
                                    step.wrappedValue.fanoutCount += 1
                                }
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundStyle(step.wrappedValue.fanoutCount < 6 ? neon.accent : neon.textFaint)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Per-run agent pickers (optional; defaults to step agent x N)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Per-run agents (optional)")
                                .font(neon.mono(10).weight(.semibold))
                                .foregroundStyle(neon.textFaint)
                                .textCase(.uppercase)
                            Spacer(minLength: 4)
                            if !step.wrappedValue.fanoutAgentTypes.isEmpty {
                                Button {
                                    step.wrappedValue.fanoutAgentTypes = []
                                } label: {
                                    Text("Clear")
                                        .font(neon.mono(10).weight(.semibold))
                                        .foregroundStyle(neon.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Text("Leave unset to run step agent x \(step.wrappedValue.fanoutCount).")
                            .font(neon.sans(11))
                            .foregroundStyle(neon.textFaint)
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(0..<step.wrappedValue.fanoutCount, id: \.self) { runIdx in
                            HStack(alignment: .top, spacing: 8) {
                                Text("Run \(runIdx + 1)")
                                    .font(neon.mono(11))
                                    .foregroundStyle(neon.textFaint)
                                    .frame(width: 44, alignment: .leading)
                                    .padding(.top, 7)
                                capsuleSegments(
                                    agentOptions,
                                    selection: Binding(
                                        get: {
                                            step.wrappedValue.fanoutAgentTypes.indices.contains(runIdx)
                                                ? step.wrappedValue.fanoutAgentTypes[runIdx]
                                                : step.wrappedValue.agentType
                                        },
                                        set: { newAgent in
                                            var arr = step.wrappedValue.fanoutAgentTypes
                                            // Pad if needed
                                            while arr.count <= runIdx {
                                                arr.append(step.wrappedValue.agentType)
                                            }
                                            arr[runIdx] = newAgent
                                            step.wrappedValue.fanoutAgentTypes = arr
                                        }
                                    )
                                ) { AgentGlyph(assistant: $0, size: 14) }
                            }
                            if store.pipelineBlockConfig {
                                runConfigRow(step: step, runIdx: runIdx)
                            }
                        }
                    }
                }
            }
            .padding(10)
            .neonCardSurface(
                neon,
                fill: step.wrappedValue.fanoutEnabled ? neon.accent.opacity(0.06) : neon.surface2.opacity(0.5),
                cornerRadius: 10,
                border: step.wrappedValue.fanoutEnabled ? neon.accent.opacity(0.25) : neon.border.opacity(0.5)
            )
        }

        /// Binding into one of `PipelineStep`'s index-aligned fanout config
        /// arrays (`fanoutModels` / `fanoutReasoningEfforts` /
        /// `fanoutPermissionModes`), padding with the inherit sentinel ("")
        /// -- NOT the step's agent type, since these have a real "inherit
        /// from the step" meaning (2.1 of PLAN-HARNESS-BUILDER).
        private func fanoutArrayBinding(
            _ keyPath: WritableKeyPath<PipelineStep, [String]>,
            step: Binding<PipelineStep>,
            runIdx: Int
        ) -> Binding<String> {
            Binding(
                get: {
                    let arr = step.wrappedValue[keyPath: keyPath]
                    return arr.indices.contains(runIdx) ? arr[runIdx] : ""
                },
                set: { newValue in
                    var arr = step.wrappedValue[keyPath: keyPath]
                    while arr.count <= runIdx { arr.append("") }
                    arr[runIdx] = newValue
                    step.wrappedValue[keyPath: keyPath] = arr
                }
            )
        }

        /// Per-run model/effort/permission-mode pickers (PLAN-HARNESS-BUILDER
        /// 2.1/2.5), index-aligned with the run and resolved against the
        /// RUN's agent (which may differ from the step's agent) -- NOT
        /// instructions, which per owner decision (8.1) are shared from the
        /// block and have no per-run UI.
        @ViewBuilder
        private func runConfigRow(step: Binding<PipelineStep>, runIdx: Int) -> some View {
            let runAgent = step.wrappedValue.fanoutAgentTypes.indices.contains(runIdx)
                ? step.wrappedValue.fanoutAgentTypes[runIdx]
                : step.wrappedValue.agentType
            let catalog = modelCatalog(for: runAgent)
            let showModel = !modelRowHidden(agentType: runAgent, catalog: catalog)
            let modelBinding = fanoutArrayBinding(\.fanoutModels, step: step, runIdx: runIdx)
            let effortBinding = fanoutArrayBinding(\.fanoutReasoningEfforts, step: step, runIdx: runIdx)
            let modeBinding = fanoutArrayBinding(\.fanoutPermissionModes, step: step, runIdx: runIdx)
            let efforts = effortOptions(model: modelBinding.wrappedValue, catalog: catalog)
            let showEffort = !efforts.isEmpty
            let showMode = supportsPlanMode(agentType: runAgent)

            if showModel || showEffort || showMode {
                let tint = neon.agentTint(forAgent: runAgent)
                HStack(alignment: .top, spacing: 8) {
                    Spacer().frame(width: 44)
                    VStack(alignment: .leading, spacing: 6) {
                        if showModel {
                            ConduitUI.ModelPickerRow(
                                agentKind: runAgent,
                                catalog: catalog.isEmpty ? nil : catalog,
                                model: modelBinding,
                                tint: tint,
                                telemetryContext: "pipeline_fanout"
                            )
                        }
                        if showEffort {
                            capsuleSegments(
                                [""] + efforts,
                                selection: effortBinding,
                                label: { $0.isEmpty ? "Default" : ConduitUI.ForkOptions.effortLabel($0) }
                            )
                        }
                        if showMode {
                            capsuleSegments(
                                ConduitUI.ForkOptions.permissionModes,
                                selection: modeBinding,
                                label: { ConduitUI.ForkOptions.permissionModeLabel($0) }
                            )
                        }
                    }
                }
            }
        }

        // MARK: Start button

        private var startButton: some View {
            ConduitUI.ActionButton(variant: .primary, tint: neon.accent) {
                attemptStart()
            } label: {
                HStack(spacing: 8) {
                    if isSubmitting {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(neon.accentText)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                    }
                    Text(isSubmitting ? "Starting..." : "Start flow")
                }
            }
            .disabled(isSubmitting || startDisabled)
            .opacity((isSubmitting || startDisabled) ? 0.45 : 1)
        }

        private var startDisabled: Bool {
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || viewModel.steps.isEmpty
        }

        /// Chain guardrail gate -- runs on every Start tap (including a
        /// pipeline loaded "From template", since the check runs here rather
        /// than at load time). Shows the confirm alert when any top-level
        /// step after the first is still `input_from_prev: "none"`;
        /// otherwise starts immediately.
        private func attemptStart() {
            let unchained = viewModel.unchainedStepIndices()
            guard !unchained.isEmpty else {
                submitPipeline()
                return
            }
            Telemetry.breadcrumb("pipeline", "chain guardrail shown",
                data: ["steps": "\(unchained.count)"])
            chainGuardrailIndices = unchained
        }

        /// "Step(s) N won't receive the previous step's output." -- 1-based
        /// step numbers, matching the numbering shown on the block cards.
        private var chainGuardrailMessage: String {
            let numbers = chainGuardrailIndices.map { "\($0 + 1)" }.joined(separator: ", ")
            let noun = chainGuardrailIndices.count == 1 ? "Step" : "Steps"
            return "\(noun) \(numbers) won't receive the previous step's output."
        }

        // MARK: Helpers

        private func sectionLabel(_ text: String) -> some View {
            Text(text.uppercased())
                .font(neon.mono(11).weight(.bold))
                .foregroundStyle(neon.textDim)
                .textCase(.uppercase)
        }

        private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased())
                    .font(neon.mono(10).weight(.semibold))
                    .foregroundStyle(neon.textFaint)
                content()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(neon.surface2)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(neon.border, lineWidth: 1))
                    )
            }
        }

        private func rolePromptTemplate(_ role: String) -> String {
            switch role {
            case "researcher":   return "Research and summarize the relevant background for the task."
            case "architect":    return "Design the architecture and interface for the task output."
            case "engineer":     return "Implement the solution based on prior steps."
            default:             return ""
            }
        }

        /// Breadcrumb for any step carrying non-default per-block config, at
        /// create/save time. Presence only -- never the instruction text
        /// itself (Telemetry standing order: no user content in telemetry).
        private func logBlockConfigTelemetry() {
            for (i, s) in viewModel.steps.enumerated() {
                let hasConfig = !s.model.isEmpty || !s.reasoningEffort.isEmpty
                    || !s.permissionMode.isEmpty || !s.instructions.isEmpty
                guard hasConfig else { continue }
                Telemetry.breadcrumb("pipeline", "block config set", data: [
                    "step": "\(i)",
                    "model": s.model.isEmpty ? "" : "set",
                    "effort": s.reasoningEffort.isEmpty ? "" : "set",
                    "mode": s.permissionMode,
                    "instructions": s.instructions.isEmpty ? "" : "set",
                ])
            }
        }

        // MARK: - Template API

        private func loadTemplates() {
            let endpoint = store.endpoint
            guard endpoint.isComplete, let base = endpoint.httpBaseURL else { return }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.path = "/api/pipeline-templates"
            guard let url = components?.url else { return }

            isLoadingTemplates = true
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 15
            req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")

            Task { @MainActor in
                defer { isLoadingTemplates = false }
                do {
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    guard let http = resp as? HTTPURLResponse,
                          http.statusCode >= 200 && http.statusCode < 300 else { return }
                    struct TemplatesEnvelope: Decodable {
                        let templates: [PipelineTemplate]
                    }
                    if let env = try? JSONDecoder().decode(TemplatesEnvelope.self, from: data) {
                        templates = env.templates
                    }
                } catch {
                    Telemetry.breadcrumb("pipeline", "templates load error",
                        data: ["error": error.localizedDescription])
                }
            }
        }

        private func applyTemplate(_ tmpl: PipelineTemplate) {
            Telemetry.breadcrumb("pipeline", "template applied",
                data: ["id": tmpl.id, "title": tmpl.title])
            title = tmpl.title
            task = tmpl.task
            viewModel.applyTemplate(tmpl)
            configSheetStepID = nil
        }

        private func saveAsTemplate() {
            let trimTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimTitle.isEmpty, !trimTask.isEmpty else { return }

            let endpoint = store.endpoint
            guard endpoint.isComplete, let base = endpoint.httpBaseURL else { return }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.path = "/api/pipeline-templates"
            guard let url = components?.url else { return }

            isSavingTemplate = true
            Telemetry.breadcrumb("pipeline", "template saved",
                data: ["title": trimTitle, "steps": "\(viewModel.steps.count)"])

            logBlockConfigTelemetry()
            let reqBody = viewModel.templateSaveRequest(title: trimTitle, task: trimTask)
            guard let bodyData = try? JSONEncoder().encode(reqBody) else {
                isSavingTemplate = false
                return
            }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 15
            req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = bodyData

            Task { @MainActor in
                defer { isSavingTemplate = false }
                do {
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    guard let http = resp as? HTTPURLResponse else { return }
                    if http.statusCode < 200 || http.statusCode >= 300 {
                        Telemetry.capture(
                            error: NSError(domain: "ios.pipeline", code: 13,
                                userInfo: [NSLocalizedDescriptionKey: "template save failed"]),
                            message: "template save failed",
                            tags: ["surface": "ios", "phase": "pipeline"],
                            extras: ["status": "\(http.statusCode)", "title": trimTitle]
                        )
                    }
                } catch {
                    Telemetry.capture(
                        error: error,
                        message: "template save network error",
                        tags: ["surface": "ios", "phase": "pipeline"],
                        extras: ["title": trimTitle]
                    )
                }
            }
        }

        private func deleteTemplate(_ tmpl: PipelineTemplate) {
            let endpoint = store.endpoint
            guard endpoint.isComplete, let base = endpoint.httpBaseURL else { return }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.path = "/api/pipeline-templates/\(tmpl.id)"
            guard let url = components?.url else { return }

            Telemetry.breadcrumb("pipeline", "template deleted",
                data: ["id": tmpl.id, "title": tmpl.title])
            var req = URLRequest(url: url)
            req.httpMethod = "DELETE"
            req.timeoutInterval = 15
            req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")

            Task { @MainActor in
                do {
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    if let http = resp as? HTTPURLResponse,
                       http.statusCode >= 200 && http.statusCode < 300 {
                        templates.removeAll { $0.id == tmpl.id }
                    }
                } catch {
                    Telemetry.breadcrumb("pipeline", "template delete error",
                        data: ["id": tmpl.id, "error": error.localizedDescription])
                }
                templateDeleteConfirm = nil
            }
        }

        // MARK: - API call

        /// POST /api/pipeline
        private func submitPipeline() {
            let trimTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimTitle.isEmpty, !trimTask.isEmpty else { return }

            let endpoint = store.endpoint
            guard endpoint.isComplete, let base = endpoint.httpBaseURL else {
                errorAlert = "No active endpoint"
                return
            }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.path = "/api/pipeline"
            guard let url = components?.url else {
                errorAlert = "Bad URL"
                return
            }

            isSubmitting = true
            Telemetry.breadcrumb("pipeline", "create start",
                data: ["title": trimTitle, "steps": "\(viewModel.steps.count)", "host": endpoint.displayHost])

            logBlockConfigTelemetry()
            let reqBody = viewModel.createRequest(
                title: trimTitle,
                task: trimTask,
                cwd: cwd.trimmingCharacters(in: .whitespacesAndNewlines),
                base: baseBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "main" : baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard let bodyData = try? JSONEncoder().encode(reqBody) else {
                isSubmitting = false
                errorAlert = "Encoding error"
                return
            }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 30
            req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = bodyData

            Task { @MainActor in
                defer { isSubmitting = false }
                do {
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    guard let http = resp as? HTTPURLResponse else {
                        errorAlert = "Invalid response"
                        return
                    }
                    struct PipelineResponse: Decodable {
                        let id: String
                        let state: String
                        let current_step: Int
                    }
                    if http.statusCode >= 200 && http.statusCode < 300,
                       let parsed = try? JSONDecoder().decode(PipelineResponse.self, from: data) {
                        Telemetry.breadcrumb("pipeline", "create ok",
                            data: ["id": parsed.id, "state": parsed.state])
                        createdPipeline = CreatedPipeline(
                            id: parsed.id,
                            state: parsed.state,
                            currentStep: parsed.current_step
                        )
                        navigateToMonitor = true
                    } else {
                        // PLAN-HARNESS-BUILDER Phase 3: a branch/loop
                        // validation failure (depth > 2, bad condition,
                        // max_iterations > 5) comes back as a 400 with a
                        // structured {"error":{"message":...}} body -- surface
                        // that message instead of a bare status code so a
                        // rejected harness fails gracefully with a reason.
                        struct ErrorEnvelope: Decodable {
                            struct Detail: Decodable { let message: String? }
                            let error: Detail?
                        }
                        let serverMessage = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error?.message
                        let detail = serverMessage.map { "\($0)" } ?? "HTTP \(http.statusCode)"
                        Telemetry.capture(
                            error: NSError(domain: "ios.pipeline", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "pipeline create failed"]),
                            message: "pipeline create failed",
                            tags: ["surface": "ios", "phase": "pipeline"],
                            extras: ["status": "\(http.statusCode)", "title": trimTitle, "detail": detail]
                        )
                        errorAlert = detail
                    }
                } catch {
                    Telemetry.capture(
                        error: error,
                        message: "pipeline create network error",
                        tags: ["surface": "ios", "phase": "pipeline"],
                        extras: ["title": trimTitle]
                    )
                    errorAlert = error.localizedDescription
                }
            }
        }
    }
}
