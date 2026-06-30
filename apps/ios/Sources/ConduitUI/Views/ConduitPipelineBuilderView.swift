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
    }

    struct CreatedPipeline: Identifiable {
        let id: String
        let state: String
        let currentStep: Int
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
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
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

            struct PipelineRequestStep: Encodable {
                let agent_type: String
                let role: String
                let prompt_template: String
                let input_from_prev: String
                let gate_after: Bool
            }
            struct PipelineRequest: Encodable {
                let title: String
                let task: String
                let cwd: String
                let base: String
                let steps: [PipelineRequestStep]
            }
            let reqSteps = steps.map { s in
                PipelineRequestStep(
                    agent_type: s.agentType,
                    role: s.role,
                    prompt_template: s.promptTemplate,
                    input_from_prev: s.inputFromPrev,
                    gate_after: s.gateAfter
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
