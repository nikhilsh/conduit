import SwiftUI

// MARK: - ConduitFlowStepEditorSheet
//
// "Flow" (pipeline v2) redesign, PR B -- design_handoff_flow/README.md
// "Screens > C1. Step edit". Edits ONE agent step (Agent / Role / Prompt /
// Gate / Advanced). Mutates the wizard's shared `PipelineBuilderViewModel`
// directly by index -- same model + `/api/pipeline` wire shape as the old
// builder's config sheet, just a fresh layout.

extension ConduitUI {

    struct FlowStepEditorSheet: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        let viewModel: PipelineBuilderViewModel
        let stepID: PipelineStep.ID
        let index: Int

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

        /// Live assistant list from the broker's capabilities descriptors --
        /// mirrors `PipelineBuilderView.agentOptions`.
        private var agentOptions: [String] {
            let descriptors = store.agentDescriptors
            guard !descriptors.isEmpty else { return Self.staticAgentOptions }
            let known = ["claude", "codex"].filter { descriptors.keys.contains($0) }
            let extras = descriptors.keys
                .filter { !known.contains($0) && $0.lowercased() != "shell" }
                .sorted()
            return known + extras
        }

        private var step: Binding<PipelineStep> {
            Binding(
                get: { index < viewModel.steps.count ? viewModel.steps[index] : PipelineStep() },
                set: { if index < viewModel.steps.count { viewModel.steps[index] = $0 } }
            )
        }

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
                        }
                        .padding(16)
                        .padding(.bottom, 80)
                    }
                    .scrollIndicators(.hidden)
                }
                .navigationTitle("Step \(index + 1) \u{00B7} \(roleLabel)")
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
        }

        private var roleLabel: String {
            roleOptions.first(where: { $0.value == step.wrappedValue.role })?.label ?? "Custom"
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
            let selected = step.wrappedValue.agentType == opt
            // Design C1 (design_handoff_flow README screen 5 /
            // flow-proto-editors.jsx): selected = per-agent tint at a soft
            // fill + a ~40%-tint border + glow, label in the agent's own
            // tint -- NOT a solid `neon.accent` pill (device feedback: that
            // rendered as a flat cyan pill with black text, unrelated to
            // the agent being picked). Unselected stays a neutral surface.
            let tint = neon.agentTint(forAgent: opt)
            Button {
                step.wrappedValue.agentType = opt
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
                        ConduitUI.Chip(label: opt.label, isSelected: step.wrappedValue.role == opt.value)
                            .onTapGesture {
                                step.wrappedValue.role = opt.value
                                if opt.value != "custom" {
                                    step.wrappedValue.promptTemplate = rolePromptTemplate(opt.value)
                                }
                            }
                    }
                }
            }
        }

        /// Role -> default prompt template (design_handoff_flow README
        /// "Interactions & state"). "custom" leaves whatever the user typed.
        private func rolePromptTemplate(_ role: String) -> String {
            switch role {
            case "researcher": return "Investigate the codebase and summarize findings."
            case "architect":  return "Design the implementation. Prior work: {{prev}}"
            case "engineer":   return "Implement the approved design. Prior work: {{prev}}"
            default:           return ""
            }
        }

        // MARK: Prompt

        private var promptField: some View {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Prompt")
                TextField("Custom prompt...", text: step.promptTemplate, axis: .vertical)
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
            ConduitUI.toggleRow(
                icon: "pause.circle",
                title: "Pause for my approval",
                subtitle: "pings your phone to continue",
                isOn: step.gateAfter,
                iconTint: neon.yellow,
                switchTint: neon.yellow
            )
            .neonCardSurface(neon, fill: neon.surface2.opacity(0.5), cornerRadius: 12)
        }

        // MARK: Advanced (model / reasoning / permissions)

        private var modelCatalog: [ConduitUI.AgentModel] {
            let key = step.wrappedValue.agentType.lowercased()
            if let m = store.agentDescriptors[key]?.models, !m.isEmpty { return m }
            return store.modelCatalog[step.wrappedValue.agentType] ?? []
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
                    modelRow
                    effortRow
                    permissionRow
                }
            }
            .padding(.vertical, 4)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
        }

        private var modelRow: some View {
            HStack {
                Text("Model").font(neon.sans(13)).foregroundStyle(neon.textDim)
                Spacer()
                Menu {
                    Button("Default") { step.wrappedValue.model = "" }
                    ForEach(modelCatalog) { m in
                        Button(m.displayName) { step.wrappedValue.model = m.id }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(step.wrappedValue.model.isEmpty ? "Default" : step.wrappedValue.model)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .font(neon.mono(12))
                    .foregroundStyle(neon.text)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }

        private var effortOptionsList: [String] {
            let catalogEntry = ConduitUI.ForkOptions.catalogEntry(
                for: step.wrappedValue.model,
                in: modelCatalog.isEmpty ? nil : modelCatalog
            )
            return catalogEntry?.efforts ?? ConduitUI.ForkOptions.efforts(forAssistant: step.wrappedValue.agentType)
        }

        private var effortRow: some View {
            HStack {
                Text("Reasoning").font(neon.sans(13)).foregroundStyle(neon.textDim)
                Spacer()
                Menu {
                    Button("Default") { step.wrappedValue.reasoningEffort = "" }
                    ForEach(effortOptionsList, id: \.self) { e in
                        Button(ConduitUI.ForkOptions.effortLabel(e)) { step.wrappedValue.reasoningEffort = e }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(step.wrappedValue.reasoningEffort.isEmpty ? "Default" : ConduitUI.ForkOptions.effortLabel(step.wrappedValue.reasoningEffort))
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .font(neon.mono(12))
                    .foregroundStyle(neon.text)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }

        private var permissionRow: some View {
            HStack {
                Text("Permissions").font(neon.sans(13)).foregroundStyle(neon.textDim)
                Spacer()
                Menu {
                    Button("Default") { step.wrappedValue.permissionMode = "" }
                    ForEach(ConduitUI.ForkOptions.permissionModes, id: \.self) { m in
                        Button(ConduitUI.ForkOptions.permissionModeLabel(m)) { step.wrappedValue.permissionMode = m }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(step.wrappedValue.permissionMode.isEmpty ? "Default" : ConduitUI.ForkOptions.permissionModeLabel(step.wrappedValue.permissionMode))
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .font(neon.mono(12))
                    .foregroundStyle(neon.text)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}
