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
        // Fanout config (present only when fanoutEnabled == true)
        var fanoutEnabled: Bool = false
        var fanoutCount: Int = 2
        // Per-run agent types (index-aligned); empty = use step agent for all runs
        var fanoutAgentTypes: [String] = []
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

        private let agentOptions = ["claude", "codex", "opencode"]
        private let roleOptions = ["researcher", "architect", "engineer", "custom"]
        private let inputFromPrevOptions = ["none", "output", "memory", "memory+output"]

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
                    gateAfter: s.gate_after
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

            struct TemplateRequestFanout: Encodable {
                let count: Int
                let agent_types: [String]?
            }
            struct TemplateRequestStep: Encodable {
                let agent_type: String
                let role: String
                let prompt_template: String
                let input_from_prev: String
                let gate_after: Bool
                let fanout: TemplateRequestFanout?
            }
            struct TemplateRequest: Encodable {
                let title: String
                let task: String
                let steps: [TemplateRequestStep]
            }
            let reqSteps = steps.map { s in
                let fo: TemplateRequestFanout? = s.fanoutEnabled ? TemplateRequestFanout(
                    count: s.fanoutCount,
                    agent_types: s.fanoutAgentTypes.isEmpty ? nil : s.fanoutAgentTypes
                ) : nil
                return TemplateRequestStep(
                    agent_type: s.agentType,
                    role: s.role,
                    prompt_template: s.promptTemplate,
                    input_from_prev: s.inputFromPrev,
                    gate_after: s.gateAfter,
                    fanout: fo
                )
            }
            let reqBody = TemplateRequest(title: trimTitle, task: trimTask, steps: reqSteps)
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

            struct PipelineRequestFanout: Encodable {
                let count: Int
                let agent_types: [String]?
            }
            struct PipelineRequestStep: Encodable {
                let agent_type: String
                let role: String
                let prompt_template: String
                let input_from_prev: String
                let gate_after: Bool
                let fanout: PipelineRequestFanout?
            }
            struct PipelineRequest: Encodable {
                let title: String
                let task: String
                let cwd: String
                let base: String
                let steps: [PipelineRequestStep]
            }
            let reqSteps = steps.map { s in
                let fanoutPayload: PipelineRequestFanout? = s.fanoutEnabled ? PipelineRequestFanout(
                    count: s.fanoutCount,
                    agent_types: s.fanoutAgentTypes.isEmpty ? nil : s.fanoutAgentTypes
                ) : nil
                return PipelineRequestStep(
                    agent_type: s.agentType,
                    role: s.role,
                    prompt_template: s.promptTemplate,
                    input_from_prev: s.inputFromPrev,
                    gate_after: s.gateAfter,
                    fanout: fanoutPayload
                )
            }
            let reqBody = PipelineRequest(
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
