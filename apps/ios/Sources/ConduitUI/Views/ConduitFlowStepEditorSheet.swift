import SwiftUI

// MARK: - ConduitFlowStepEditorSheet
//
// "Flow" (pipeline v2) redesign, PR B -- design_handoff_flow/README.md
// "Screens > C1. Step edit". Edits ONE agent step (Agent / Role / Prompt /
// Gate / Advanced). Mutates the wizard's shared `PipelineBuilderViewModel`
// directly by index -- same model + `/api/pipeline` wire shape as the old
// builder's config sheet, just a fresh layout.
//
// design_handoff_review_fixes R1: dual-mode. A branch's Then/Else rows are
// now FULL step cards (ConduitFlowBranchEditorSheet) that open this SAME
// sheet against a `PipelineSubStep` instead of a top-level `PipelineStep`.
// `PipelineStep` and `PipelineSubStep` are different wire types, but every
// field this editor actually surfaces (agent/role/prompt/gate/model/effort/
// permission) exists on both -- `field(step:subStep:)` below picks the right
// storage by keypath so the body reads/writes ONE binding per field
// regardless of target, and the two `init`s just decide which storage that
// is. Sub-steps have no numeric index and no control-flow fields, so
// `Target` intentionally carries no index for `.subStep` and the Advanced
// section never grows loop/branch-only controls.

extension ConduitUI {

    struct FlowStepEditorSheet: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        enum Target {
            case step(id: PipelineStep.ID, index: Int)
            case subStep(SubStepEditTarget)
        }

        let viewModel: PipelineBuilderViewModel
        let target: Target

        @State private var advancedExpanded = false

        private static let staticAgentOptions = ["claude", "codex", "opencode"]

        private struct RoleOption: Identifiable {
            let value: String
            let label: String
            var id: String { value }
        }

        private let roleOptions: [RoleOption] = [
            RoleOption(value: "researcher", label: "Research"),
            RoleOption(value: "architect", label: "Design"),
            RoleOption(value: "engineer", label: "Build"),
            RoleOption(value: "custom", label: "Custom"),
        ]

        init(viewModel: PipelineBuilderViewModel, stepID: PipelineStep.ID, index: Int) {
            self.viewModel = viewModel
            self.target = .step(id: stepID, index: index)
        }

        init(viewModel: PipelineBuilderViewModel, subStepTarget: SubStepEditTarget) {
            self.viewModel = viewModel
            self.target = .subStep(subStepTarget)
        }

        /// Live assistant list from the broker's capabilities descriptors.
        private var agentOptions: [String] {
            let descriptors = store.agentDescriptors
            guard !descriptors.isEmpty else { return Self.staticAgentOptions }
            let known = ["claude", "codex"].filter { descriptors.keys.contains($0) }
            let extras = descriptors.keys
                .filter { !known.contains($0) && $0.lowercased() != "shell" }
                .sorted()
            return known + extras
        }

        // MARK: Field bindings (common to PipelineStep + PipelineSubStep)

        /// Reads/writes one field through whichever storage `target` points
        /// at -- a top-level step (by array index) or a branch sub-step (via
        /// the view model's sub-step get/set, PLAN-HARNESS-BUILDER shape).
        private func field<Value>(
            step stepPath: WritableKeyPath<PipelineStep, Value>,
            subStep subStepPath: WritableKeyPath<PipelineSubStep, Value>
        ) -> Binding<Value> {
            switch target {
            case .step(_, let index):
                return Binding(
                    get: { index < viewModel.steps.count ? viewModel.steps[index][keyPath: stepPath] : PipelineStep()[keyPath: stepPath] },
                    set: { if index < viewModel.steps.count { viewModel.steps[index][keyPath: stepPath] = $0 } }
                )
            case .subStep(let t):
                return Binding(
                    get: { viewModel.subStepBinding(stepID: t.stepID, arm: t.arm, subStepID: t.subStepID)[keyPath: subStepPath] },
                    set: { newValue in
                        var sub = viewModel.subStepBinding(stepID: t.stepID, arm: t.arm, subStepID: t.subStepID)
                        sub[keyPath: subStepPath] = newValue
                        viewModel.updateSubStep(stepID: t.stepID, arm: t.arm, subStep: sub)
                    }
                )
            }
        }

        private var agentType: Binding<String> { field(step: \.agentType, subStep: \.agentType) }
        private var role: Binding<String> { field(step: \.role, subStep: \.role) }
        private var promptTemplate: Binding<String> { field(step: \.promptTemplate, subStep: \.promptTemplate) }
        private var gateAfter: Binding<Bool> { field(step: \.gateAfter, subStep: \.gateAfter) }
        private var model: Binding<String> { field(step: \.model, subStep: \.model) }
        private var reasoningEffort: Binding<String> { field(step: \.reasoningEffort, subStep: \.reasoningEffort) }
        private var permissionMode: Binding<String> { field(step: \.permissionMode, subStep: \.permissionMode) }

        var body: some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            agentField
                            roleField
                            promptField
                            gateRow
                            advancedSection
                            deleteSection
                        }
                        .padding(16)
                        .padding(.bottom, 80)
                    }
                    .scrollIndicators(.hidden)
                }
                .navigationTitle(navTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(neon.textDim)
                        }
                        .accessibilityLabel("Close")
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 0) {
                        Rectangle().fill(neon.border).frame(height: 1)
                        ConduitUI.ActionButton("Done", variant: .primary, tint: neon.accent) {
                            dismiss()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 12)
                    }
                    .background(neon.bg.ignoresSafeArea(edges: .bottom))
                }
            }
            .tint(neon.accent)
            .onAppear {
                // Step editor prompt is empty on open -- prefill from the
                // selected role (device feedback: a fresh step opened to
                // role "Engineer" with a blank prompt). "custom" has no
                // canned template, so it's left blank for the user. A fresh
                // branch sub-step already opens with role "custom"
                // (addSubStep), so this is a no-op there by construction.
                if promptTemplate.wrappedValue.isEmpty && role.wrappedValue != "custom" {
                    promptTemplate.wrappedValue = PipelineStep.defaultPromptTemplate(forRole: role.wrappedValue)
                }
            }
        }

        private var roleLabel: String {
            roleOptions.first(where: { $0.value == role.wrappedValue })?.label ?? "Custom"
        }

        /// Top-level steps read "Step N · Role"; branch sub-steps have no
        /// rail position to number, so they read "Step · Role".
        private var navTitle: String {
            switch target {
            case .step(_, let index):
                return "Step \(index + 1) \u{00B7} \(roleLabel)"
            case .subStep:
                return "Step \u{00B7} \(roleLabel)"
            }
        }

        private func sectionLabel(_ text: String) -> some View {
            Text(text.uppercased())
                .font(neon.mono(11).weight(.bold))
                .tracking(0.6)
                .foregroundStyle(neon.textFaint)
        }

        // MARK: Agent

        private var agentField: some View {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Agent")
                // Single row of equal-width tiles (design_handoff_flow audit
                // §B.3) -- NOT a 2-column grid, which orphaned a 3rd tile on
                // its own row. 4+ agents split into two balanced equal-width
                // rows rather than shrinking to illegibility.
                let opts = agentOptions
                if opts.count <= 3 {
                    HStack(spacing: 8) {
                        ForEach(opts, id: \.self) { opt in agentTile(opt) }
                    }
                } else {
                    let mid = (opts.count + 1) / 2
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(Array(opts.prefix(mid)), id: \.self) { opt in agentTile(opt) }
                        }
                        HStack(spacing: 8) {
                            ForEach(Array(opts.suffix(from: mid)), id: \.self) { opt in agentTile(opt) }
                        }
                    }
                }
            }
        }

        @ViewBuilder
        private func agentTile(_ opt: String) -> some View {
            let selected = agentType.wrappedValue == opt
            // Design C1 (design_handoff_flow README screen 5 /
            // flow-proto-editors.jsx): selected = per-agent tint at a soft
            // fill + a ~40%-tint border + glow, label in the agent's own
            // tint -- NOT a solid `neon.accent` pill (device feedback: that
            // rendered as a flat cyan pill with black text, unrelated to
            // the agent being picked). Unselected stays a neutral surface.
            let tint = neon.agentTint(forAgent: opt)
            Button {
                agentType.wrappedValue = opt
            } label: {
                HStack(spacing: 6) {
                    AgentGlyph(assistant: opt, size: 16)
                    Text(opt)
                        .font(neon.mono(12).weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(selected ? tint : neon.textDim)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selected ? tint.opacity(0.11) : neon.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(selected ? tint.opacity(0.4) : neon.lineSoft, lineWidth: 1)
                )
                .neonGlowBox(selected && neon.glow ? neon.glowBox?.tinted(tint) : nil)
            }
            .buttonStyle(.plain)
        }

        // MARK: Role

        private var roleField: some View {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Role")
                HStack(spacing: 6) {
                    ForEach(roleOptions) { opt in
                        ConduitUI.Chip(label: opt.label, isSelected: role.wrappedValue == opt.value)
                            .onTapGesture {
                                role.wrappedValue = opt.value
                                if opt.value != "custom" {
                                    promptTemplate.wrappedValue = PipelineStep.defaultPromptTemplate(forRole: opt.value)
                                }
                            }
                    }
                }
            }
        }

        // MARK: Prompt

        private var promptField: some View {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Prompt")
                TextField("Custom prompt...", text: promptTemplate, axis: .vertical)
                    .font(neon.mono(13))
                    .foregroundStyle(neon.text)
                    .lineLimit(3...6)
                    .frame(minHeight: 78, alignment: .top)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .conduitGlassRoundedRect(cornerRadius: 13)
                    .tint(neon.accent)
                Text("{{prev}} = what the step before produced. Prefilled by the role \u{2014} edit freely.")
                    .font(neon.mono(10.5))
                    .foregroundStyle(neon.textFaint)
            }
        }

        // MARK: Gate

        private var gateRow: some View {
            ConduitUI.GateToggleRow(
                title: "Pause for my approval",
                subtitle: "pings your phone to continue",
                isOn: gateAfter
            )
            .neonCardSurface(neon, fill: neon.surface2.opacity(0.5), cornerRadius: 12)
        }

        // MARK: Advanced (model / reasoning / permissions)

        private var modelCatalog: [ConduitUI.AgentModel] {
            let key = agentType.wrappedValue.lowercased()
            if let m = store.agentDescriptors[key]?.models, !m.isEmpty { return m }
            return store.modelCatalog[agentType.wrappedValue] ?? []
        }

        @ViewBuilder
        private var advancedSection: some View {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    advancedExpanded.toggle()
                } label: {
                    ConduitUI.ListRow(icon: "gearshape", title: "Advanced", subtitle: "model \u{00B7} reasoning \u{00B7} permissions") {
                        Image(systemName: advancedExpanded ? "chevron.up" : "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(neon.textDim)
                    }
                }
                .buttonStyle(.plain)

                if advancedExpanded {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            sectionLabel("Model")
                            modelRow
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            sectionLabel("Reasoning")
                            effortRow
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            sectionLabel("Permissions")
                            permissionRow
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                }
            }
            .padding(.vertical, 4)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
        }

        // Model / reasoning / permissions all open the Conduit kit sheet
        // (design_handoff_review_fixes R2) instead of a stock `Menu` --
        // `ModelPickerRow` already dedupes the catalog's own inherit entry
        // against the injected "Default" row (see `ForkOptions.models`);
        // `OptionPickerRow` is the same sheet reused for the two static
        // option lists that don't carry a model catalog.

        private var modelRow: some View {
            ConduitUI.ModelPickerRow(
                agentKind: agentType.wrappedValue,
                catalog: modelCatalog.isEmpty ? nil : modelCatalog,
                model: model,
                tint: neon.agentTint(forAgent: agentType.wrappedValue),
                telemetryContext: "flow_step"
            )
        }

        private var effortOptionsList: [String] {
            let catalogEntry = ConduitUI.ForkOptions.catalogEntry(
                for: model.wrappedValue,
                in: modelCatalog.isEmpty ? nil : modelCatalog
            )
            return catalogEntry?.efforts ?? ConduitUI.ForkOptions.efforts(forAssistant: agentType.wrappedValue)
        }

        private var effortPickerOptions: [ConduitUI.OptionPickerItem] {
            [ConduitUI.OptionPickerItem(value: "", label: "Default")] +
                effortOptionsList.map { ConduitUI.OptionPickerItem(value: $0, label: ConduitUI.ForkOptions.effortLabel($0)) }
        }

        private var effortRow: some View {
            ConduitUI.OptionPickerRow(
                title: "Reasoning",
                options: effortPickerOptions,
                selection: reasoningEffort,
                tint: neon.agentTint(forAgent: agentType.wrappedValue),
                telemetryContext: "flow_step_reasoning"
            )
        }

        // No separate injected "Default" row here: `ForkOptions.autoMode` is
        // already "" (the same sentinel a "Default" row would use), so
        // `permissionModes` alone covers it -- prepending "Default" would
        // duplicate the "" row under two labels (the R2 dedupe rule).
        private var permissionPickerOptions: [ConduitUI.OptionPickerItem] {
            ConduitUI.ForkOptions.permissionModes.map {
                ConduitUI.OptionPickerItem(value: $0, label: ConduitUI.ForkOptions.permissionModeLabel($0))
            }
        }

        private var permissionRow: some View {
            ConduitUI.OptionPickerRow(
                title: "Permissions",
                options: permissionPickerOptions,
                selection: permissionMode,
                tint: neon.agentTint(forAgent: agentType.wrappedValue),
                telemetryContext: "flow_step_permissions"
            )
        }

        // MARK: Delete (sub-step mode only)
        //
        // design_handoff_review_fixes R1: the branch row's minus badge is
        // gone -- delete now lives inside the editor. Top-level steps have
        // no delete affordance here (none existed before this change; the
        // Flow wizard's step rail doesn't support removing a step yet, and
        // this PR doesn't add one to avoid a second delete UI).

        @ViewBuilder
        private var deleteSection: some View {
            if case .subStep(let t) = target {
                Button {
                    Telemetry.breadcrumb("flow_wizard", "sub step delete", data: ["arm": "\(t.arm)"])
                    viewModel.removeSubStep(stepID: t.stepID, arm: t.arm, subStepID: t.subStepID)
                    dismiss()
                } label: {
                    ConduitUI.ListRow(icon: "trash", title: "Delete step", iconTint: neon.red) {
                        EmptyView()
                    }
                }
                .buttonStyle(.plain)
                .neonCardSurface(neon, fill: neon.surface2.opacity(0.5), cornerRadius: 12)
            }
        }
    }
}
