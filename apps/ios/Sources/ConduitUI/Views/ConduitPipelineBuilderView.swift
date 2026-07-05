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

        @State private var title: String = ""
        @State private var task: String = ""
        @State private var cwd: String = ""
        @State private var baseBranch: String = "main"
        @State private var steps: [PipelineStep] = [PipelineStep()]

        @State private var isSubmitting = false
        @State private var errorAlert: String? = nil
        @State private var createdPipeline: CreatedPipeline? = nil
        @State private var navigateToMonitor = false

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

        /// Per PLAN-HARNESS-BUILDER §8.3 (owner decision, overriding the
        /// plan's "disabled with caption" text): the model override is a
        /// silent no-op for gemini (ACP picks its model at `session/new`,
        /// `backend_acpwire.go:611-613`), so the model row is HIDDEN
        /// entirely for gemini rather than shown disabled.
        private func modelRowHidden(agentType: String, catalog: [ConduitUI.AgentModel]) -> Bool {
            agentType.lowercased() == "gemini" || catalog.isEmpty
        }

        private func effortOptions(model: String, catalog: [ConduitUI.AgentModel]) -> [String] {
            ConduitUI.ForkOptions.catalogEntry(for: model, in: catalog.isEmpty ? nil : catalog)?.efforts ?? []
        }

        private func supportsPlanMode(agentType: String) -> Bool {
            store.agentDescriptors[agentType.lowercased()]?.supports.planMode ?? false
        }

        var body: some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            metadataSection
                            stepsSection
                            if store.pipelineTemplates {
                                saveTemplateButton
                            }
                            startButton
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                }
                .navigationTitle("New pipeline")
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
                            pipelineTitle: title.isEmpty ? "Pipeline" : title
                        )
                        .environment(store)
                    }
                }
                .sheet(isPresented: $showTemplatePicker) {
                    templatePickerSheet
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
                            Text("Use \"Save as template\" after filling in a pipeline.")
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
            Button {
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
                        .font(neon.sans(13).weight(.semibold))
                }
                .foregroundStyle(neon.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(neon.accent.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(neon.accent.opacity(0.30), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(isSavingTemplate || startDisabled)
            .opacity((isSavingTemplate || startDisabled) ? 0.4 : 1)
        }

        // MARK: Metadata section

        private var metadataSection: some View {
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("Pipeline details")

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

        // MARK: Steps section

        private var stepsSection: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    sectionLabel("Steps")
                    Spacer(minLength: 8)
                    Button {
                        steps.append(PipelineStep())
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .bold))
                            Text("Add step")
                                .font(neon.sans(12).weight(.semibold))
                        }
                        .foregroundStyle(neon.accent)
                    }
                    .buttonStyle(.plain)
                }

                ForEach($steps) { $step in
                    stepCard(step: $step, index: steps.firstIndex(where: { $0.id == step.id }) ?? 0)
                }
            }
        }

        private func stepCard(step: Binding<PipelineStep>, index: Int) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Step \(index + 1)")
                        .font(neon.mono(11).weight(.bold))
                        .foregroundStyle(neon.textDim)
                        .textCase(.uppercase)
                    Spacer(minLength: 8)
                    if steps.count > 1 {
                        Button {
                            steps.removeAll { $0.id == step.wrappedValue.id }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(neon.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Agent type picker
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agent")
                        .font(neon.mono(10).weight(.semibold))
                        .foregroundStyle(neon.textFaint)
                        .textCase(.uppercase)
                    Picker("Agent", selection: step.agentType) {
                        ForEach(agentOptions, id: \.self) { opt in
                            Text(opt).tag(opt)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(neon.accent)
                }

                // Per-block config (model / effort / permission mode /
                // instructions), gated on pipeline_block_config so an old
                // broker never sees controls it would silently drop.
                if store.pipelineBlockConfig {
                    blockConfigSection(step: step)
                }

                // Role picker
                VStack(alignment: .leading, spacing: 4) {
                    Text("Role")
                        .font(neon.mono(10).weight(.semibold))
                        .foregroundStyle(neon.textFaint)
                        .textCase(.uppercase)
                    Picker("Role", selection: step.role) {
                        ForEach(roleOptions, id: \.self) { opt in
                            Text(opt).tag(opt)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(neon.accent)
                    .onChange(of: step.wrappedValue.role) { _, newRole in
                        if newRole != "custom" {
                            step.wrappedValue.promptTemplate = rolePromptTemplate(newRole)
                        }
                    }
                }

                // Prompt template
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prompt template")
                        .font(neon.mono(10).weight(.semibold))
                        .foregroundStyle(neon.textFaint)
                        .textCase(.uppercase)
                    TextField("Custom prompt...", text: step.promptTemplate, axis: .vertical)
                        .font(neon.sans(13))
                        .foregroundStyle(neon.text)
                        .lineLimit(2...5)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(neon.surface2)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(neon.border, lineWidth: 1))
                        )
                        .tint(neon.accent)
                }

                // Input from prev
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input from prev")
                        .font(neon.mono(10).weight(.semibold))
                        .foregroundStyle(neon.textFaint)
                        .textCase(.uppercase)
                    Picker("Input from prev", selection: step.inputFromPrev) {
                        ForEach(inputFromPrevOptions, id: \.self) { opt in
                            Text(opt).tag(opt)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(neon.accent)
                }

                // Gate after toggle
                HStack {
                    Text("Gate after this step")
                        .font(neon.sans(13))
                        .foregroundStyle(neon.text)
                    Spacer(minLength: 8)
                    Toggle("", isOn: step.gateAfter)
                        .tint(neon.accent)
                }

                // Fan out toggle (gated on pipeline_fanout capability)
                if store.pipelineFanout {
                    fanoutSection(step: step)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
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

            VStack(alignment: .leading, spacing: 10) {
                if showModel {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Model")
                            .font(neon.mono(10).weight(.semibold))
                            .foregroundStyle(neon.textFaint)
                            .textCase(.uppercase)
                        Menu {
                            Picker("Model", selection: step.model) {
                                Text("Default").tag("")
                                ForEach(catalog, id: \.id) { m in
                                    Text(m.displayName.isEmpty ? m.id : m.displayName).tag(m.id)
                                }
                            }
                        } label: {
                            HStack {
                                Text(modelLabel(step.wrappedValue.model, in: catalog))
                                    .foregroundStyle(neon.text)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(neon.textFaint)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(neon.surface2)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(neon.border, lineWidth: 1))
                            )
                        }
                        .tint(neon.accent)
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
                }

                if showEffort {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reasoning effort")
                            .font(neon.mono(10).weight(.semibold))
                            .foregroundStyle(neon.textFaint)
                            .textCase(.uppercase)
                        Picker("Reasoning effort", selection: step.reasoningEffort) {
                            Text("Default").tag("")
                            ForEach(efforts, id: \.self) { level in
                                Text(ConduitUI.ForkOptions.effortLabel(level)).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                        .tint(neon.accent)
                    }
                }

                if showMode {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Permission mode")
                            .font(neon.mono(10).weight(.semibold))
                            .foregroundStyle(neon.textFaint)
                            .textCase(.uppercase)
                        Picker("Permission mode", selection: step.permissionMode) {
                            ForEach(ConduitUI.ForkOptions.permissionModes, id: \.self) { mode in
                                Text(ConduitUI.ForkOptions.permissionModeLabel(mode)).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .tint(neon.accent)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Instructions for this block")
                        .font(neon.mono(10).weight(.semibold))
                        .foregroundStyle(neon.textFaint)
                        .textCase(.uppercase)
                    TextField("Optional standing guidance for this block...", text: step.instructions, axis: .vertical)
                        .font(neon.sans(13))
                        .foregroundStyle(neon.text)
                        .lineLimit(2...5)
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

        private func modelLabel(_ id: String, in catalog: [ConduitUI.AgentModel]) -> String {
            if id.isEmpty { return "Default" }
            if let m = catalog.first(where: { $0.id == id }), !m.displayName.isEmpty { return m.displayName }
            return id
        }

        @ViewBuilder
        private func fanoutSection(step: Binding<PipelineStep>) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "arrow.branch")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(step.wrappedValue.fanoutEnabled ? neon.accent : neon.textFaint)
                    Text("Fan out this step")
                        .font(neon.sans(13))
                        .foregroundStyle(neon.text)
                    Spacer(minLength: 8)
                    Toggle("", isOn: step.fanoutEnabled)
                        .tint(neon.accent)
                        .onChange(of: step.wrappedValue.fanoutEnabled) { _, newVal in
                            Telemetry.breadcrumb("pipeline", "fanout toggle",
                                data: ["enabled": newVal ? "true" : "false"])
                            if newVal && step.wrappedValue.fanoutCount < 1 {
                                step.wrappedValue.fanoutCount = 2
                            }
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
                            HStack(spacing: 8) {
                                Text("Run \(runIdx + 1)")
                                    .font(neon.mono(11))
                                    .foregroundStyle(neon.textFaint)
                                    .frame(width: 44, alignment: .leading)
                                Picker("Run \(runIdx + 1)", selection: Binding(
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
                                )) {
                                    ForEach(agentOptions, id: \.self) { opt in
                                        Text(opt).tag(opt)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .tint(neon.accent)
                            }
                            if store.pipelineBlockConfig {
                                runConfigRow(step: step, runIdx: runIdx)
                            }
                        }
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(step.wrappedValue.fanoutEnabled
                          ? neon.accent.opacity(0.06)
                          : neon.surface2.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(step.wrappedValue.fanoutEnabled
                            ? neon.accent.opacity(0.25)
                            : neon.border.opacity(0.5), lineWidth: 1)
            )
        }

        /// Binding into one of `PipelineStep`'s index-aligned fanout config
        /// arrays (`fanoutModels` / `fanoutReasoningEfforts` /
        /// `fanoutPermissionModes`), padding with the inherit sentinel ("")
        /// -- NOT the step's agent type, since these have a real "inherit
        /// from the step" meaning (§2.1 of PLAN-HARNESS-BUILDER).
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
        /// §2.1/§2.5), index-aligned with the run and resolved against the
        /// RUN's agent (which may differ from the step's agent) -- NOT
        /// instructions, which per owner decision (§8.1) are shared from the
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
                HStack(alignment: .top, spacing: 8) {
                    Spacer().frame(width: 44)
                    VStack(alignment: .leading, spacing: 6) {
                        if showModel {
                            Menu {
                                Picker("Model", selection: modelBinding) {
                                    Text("Default").tag("")
                                    ForEach(catalog, id: \.id) { m in
                                        Text(m.displayName.isEmpty ? m.id : m.displayName).tag(m.id)
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("Model: \(modelLabel(modelBinding.wrappedValue, in: catalog))")
                                        .font(neon.mono(11))
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .foregroundStyle(neon.textDim)
                            }
                        }
                        if showEffort {
                            Picker("Effort", selection: effortBinding) {
                                Text("Default").tag("")
                                ForEach(efforts, id: \.self) { level in
                                    Text(ConduitUI.ForkOptions.effortLabel(level)).tag(level)
                                }
                            }
                            .pickerStyle(.segmented)
                            .tint(neon.accent)
                        }
                        if showMode {
                            Picker("Mode", selection: modeBinding) {
                                ForEach(ConduitUI.ForkOptions.permissionModes, id: \.self) { mode in
                                    Text(ConduitUI.ForkOptions.permissionModeLabel(mode)).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .tint(neon.accent)
                        }
                    }
                }
            }
        }

        // MARK: Start button

        private var startButton: some View {
            Button {
                submitPipeline()
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
                    Text(isSubmitting ? "Starting..." : "Start pipeline")
                        .font(neon.sans(15).weight(.bold))
                }
                .foregroundStyle(neon.accentText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(neon.accent)
                )
                .neonGlowBox(neon.glow && !isSubmitting ? neon.glowBox : nil)
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting || startDisabled)
            .opacity((isSubmitting || startDisabled) ? 0.4 : 1)
        }

        private var startDisabled: Bool {
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || steps.isEmpty
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
            for (i, s) in steps.enumerated() {
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
                data: ["title": trimTitle, "steps": "\(steps.count)"])

            logBlockConfigTelemetry()
            let reqSteps = steps.map { ConduitUI.PipelineRequestStep($0) }
            let reqBody = ConduitUI.PipelineTemplateSaveRequest(title: trimTitle, task: trimTask, steps: reqSteps)
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
                data: ["title": trimTitle, "steps": "\(steps.count)", "host": endpoint.displayHost])

            logBlockConfigTelemetry()
            let reqSteps = steps.map { ConduitUI.PipelineRequestStep($0) }
            let reqBody = ConduitUI.PipelineCreateRequest(
                title: trimTitle,
                task: trimTask,
                cwd: cwd.trimmingCharacters(in: .whitespacesAndNewlines),
                base: baseBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "main" : baseBranch.trimmingCharacters(in: .whitespacesAndNewlines),
                steps: reqSteps
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
                        let detail = "HTTP \(http.statusCode)"
                        Telemetry.capture(
                            error: NSError(domain: "ios.pipeline", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "pipeline create failed"]),
                            message: "pipeline create failed",
                            tags: ["surface": "ios", "phase": "pipeline"],
                            extras: ["status": "\(http.statusCode)", "title": trimTitle]
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
