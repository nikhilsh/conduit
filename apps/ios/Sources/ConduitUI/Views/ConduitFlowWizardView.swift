import SwiftUI

// MARK: - ConduitFlowWizardView
//
// "Flow" (pipeline v2) redesign, PR B -- design_handoff_flow/README.md
// "Screens > 3. Task" + "4. Steps". Two-step wizard that replaces
// `ConduitUI.PipelineBuilderView` as the phone create UX (tablet keeps the
// old builder, PR scope §6). Reuses the SAME model layer as the old builder
// (`PipelineStep`, `PipelineBuilderViewModel`, `PipelineCreateRequest`) --
// this is a UI reskin over the same `/api/pipeline` endpoint, not a new
// backend.

extension ConduitUI {

    struct FlowWizardView: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        @State private var viewModel: PipelineBuilderViewModel
        @State private var task: String
        @State private var cwd: String = ""
        @State private var baseBranch: String = "main"
        /// 1 = Task screen, 2 = Steps screen.
        @State private var stepIndex: Int

        @State private var configSheetStepID: UUID?
        @State private var branchEditStepID: UUID?
        @State private var showWhereEditor = false
        @State private var addStepMenuExpanded = false
        @State private var showTemplateReplace = false

        @State private var isSubmitting = false
        @State private var errorAlert: String?
        @State private var createdPipeline: CreatedPipeline?
        @State private var navigateToMonitor = false
        @State private var chainGuardrailIndices: [Int] = []
        /// Fired the moment a flow submits successfully (Home FLOWS fix,
        /// device feedback round 4): lets the presenter (`ConduitHomeView`)
        /// refresh its pipeline summaries immediately instead of waiting for
        /// the wizard sheet to fully dismiss, so a freshly-started flow's
        /// card is already there when the user backs out.
        var onFlowStarted: (() -> Void)?

        init(prefill: FlowWizardPrefill, onFlowStarted: (() -> Void)? = nil) {
            let steps = prefill.steps ?? [PipelineStep()]
            _viewModel = State(initialValue: PipelineBuilderViewModel(steps: steps))
            _task = State(initialValue: prefill.task)
            _stepIndex = State(initialValue: max(1, min(2, prefill.startStep)))
            self.onFlowStarted = onFlowStarted
        }

        var body: some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    if stepIndex == 1 { taskStepView } else { stepsStepView }
                }
                .navigationTitle("New flow")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .foregroundStyle(neon.textDim)
                    }
                }
                .navigationDestination(isPresented: $navigateToMonitor) {
                    if let p = createdPipeline {
                        ConduitUI.PipelineMonitorView(pipelineID: p.id, pipelineTitle: derivedTitle)
                            .environment(store)
                    }
                }
                .sheet(isPresented: Binding(
                    get: { configSheetStepID != nil },
                    set: { if !$0 { configSheetStepID = nil } }
                )) {
                    if let id = configSheetStepID, let idx = viewModel.index(for: id) {
                        ConduitUI.FlowStepEditorSheet(viewModel: viewModel, stepID: id, index: idx)
                            .environment(store)
                    }
                }
                .sheet(isPresented: Binding(
                    get: { branchEditStepID != nil },
                    set: { if !$0 { branchEditStepID = nil } }
                )) {
                    if let id = branchEditStepID, let idx = viewModel.index(for: id) {
                        ConduitUI.FlowBranchEditorSheet(viewModel: viewModel, stepID: id, index: idx)
                            .environment(store)
                    }
                }
                .sheet(isPresented: $showWhereEditor) {
                    whereEditorSheet
                }
                .confirmationDialog("Use a template", isPresented: $showTemplateReplace, titleVisibility: .visible) {
                    Button("Research \u{2192} Design \u{2192} Build") { applyBuiltIn(.researchDesignBuild) }
                    Button("Fix \u{2192} Verify") { applyBuiltIn(.fixVerify) }
                    Button("Cancel", role: .cancel) {}
                }
                .alert("Error", isPresented: Binding(
                    get: { errorAlert != nil },
                    set: { if !$0 { errorAlert = nil } }
                )) {
                    Button("OK") { errorAlert = nil }
                } message: {
                    if let m = errorAlert { Text(m) }
                }
                .alert("Steps aren't chained", isPresented: Binding(
                    get: { !chainGuardrailIndices.isEmpty },
                    set: { if !$0 { chainGuardrailIndices = [] } }
                )) {
                    Button("Chain steps") {
                        viewModel.chainUnchainedSteps()
                        chainGuardrailIndices = []
                        submitFlow()
                    }
                    Button("Start anyway") {
                        chainGuardrailIndices = []
                        submitFlow()
                    }
                    Button("Cancel", role: .cancel) { chainGuardrailIndices = [] }
                } message: {
                    Text(chainGuardrailMessage)
                }
            }
            .appearanceColorScheme()
            .onAppear {
                if cwd.isEmpty, let activeID = store.selectedSessionID,
                   let status = store.statusBySession[activeID], let sessionCwd = status.cwd, !sessionCwd.isEmpty {
                    cwd = sessionCwd
                }
                Telemetry.breadcrumb("flow_wizard", "opened", data: ["step": "\(stepIndex)"])
            }
        }

        // MARK: Stepper header

        private func stepperHeader(step2Active: Bool) -> some View {
            HStack(spacing: 8) {
                Spacer()
                if step2Active {
                    Button { stepIndex = 1 } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
                            Text("1 \u{00B7} TASK")
                        }
                        .font(neon.mono(12).weight(.bold))
                        .tracking(1)
                        .foregroundStyle(neon.textFaint)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("1 \u{00B7} TASK")
                        .font(neon.mono(12).weight(.bold))
                        .tracking(1)
                        .foregroundStyle(neon.accent)
                }
                Text("\u{00B7}").foregroundStyle(neon.textFaint)
                Text("2 \u{00B7} STEPS")
                    .font(neon.mono(12).weight(.bold))
                    .tracking(1)
                    .foregroundStyle(step2Active ? neon.accent : neon.textFaint)
                Spacer()
            }
            .padding(.vertical, 10)
        }

        // MARK: Step 1 -- Task

        private var taskStepView: some View {
            VStack(spacing: 0) {
                stepperHeader(step2Active: false)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("What should this flow do?")
                            .font(neon.sans(28).weight(.bold))
                            .foregroundStyle(neon.text)
                            .fixedSize(horizontal: false, vertical: true)

                        taskField

                        VStack(alignment: .leading, spacing: 6) {
                            sectionLabel("Where")
                            // A custom row (not `ConduitUI.navRow`, whose
                            // canned subtitle isn't mono) -- box name title,
                            // mono "<dir> · <branch>" subtitle, chevron.
                            Button { showWhereEditor = true } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder")
                                        .font(.body)
                                        .foregroundStyle(neon.accent)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(whereTitle)
                                            .font(neon.sans(15).weight(.semibold))
                                            .foregroundStyle(neon.text)
                                        Text("\(cwdDisplay) \u{00B7} \(baseBranch.isEmpty ? "main" : baseBranch)")
                                            .font(neon.mono(12))
                                            .foregroundStyle(neon.textDim)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(neon.textDim)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
                        }

                        Text("You'll pick the steps next \u{2014} working dir and branch are prefilled from the box.")
                            .font(neon.mono(11))
                            .foregroundStyle(neon.textFaint)
                    }
                    .padding(16)
                    .padding(.bottom, 76)
                }
                .scrollIndicators(.hidden)
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 0) {
                        Rectangle().fill(neon.border).frame(height: 1)
                        ConduitUI.ActionButton("Next \u{00B7} choose steps", variant: .primary, tint: neon.accent) {
                            Telemetry.breadcrumb("flow_wizard", "next tapped", data: ["task_len": "\(trimmedTask.count)"])
                            stepIndex = 2
                        }
                        .disabled(trimmedTask.isEmpty)
                        .opacity(trimmedTask.isEmpty ? 0.45 : 1)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 12)
                    }
                    .background(neon.bg.ignoresSafeArea(edges: .bottom))
                }
            }
        }

        private var taskField: some View {
            TextField("Describe the whole job \u{2014} every step will see this.", text: $task, axis: .vertical)
                .font(neon.sans(15))
                .foregroundStyle(neon.text)
                .lineLimit(5...9)
                .frame(minHeight: 110, alignment: .top)
                .textFieldStyle(.plain)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(neon.surface2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(trimmedTask.isEmpty ? neon.border : neon.accent.opacity(0.27), lineWidth: 1)
                        )
                )
                .tint(neon.accent)
        }

        private var whereTitle: String {
            store.savedServers.first(where: { $0.endpoint == store.endpoint })?.name ?? store.endpoint.displayHost
        }

        private var cwdDisplay: String {
            cwd.isEmpty ? "no folder" : (cwd as NSString).lastPathComponent
        }

        /// Reuses the SAME directory/box picker `AgentPickerSheet` uses
        /// (`directoryOnly` mode -- PR B follow-up): Recent + live browse
        /// over `store.listDirectories(path:)`, no per-agent model/effort/
        /// mode UI. That picker has no branch control of its own, so an
        /// inline branch field lives INSIDE this sheet (not on the wizard
        /// face) via its `branch` binding.
        private var whereEditorSheet: some View {
            NavigationStack {
                ConduitUI.DirectoryPicker(
                    agentKind: "claude",
                    directoryOnly: true,
                    branch: $baseBranch,
                    onCreate: { path, _, _, _, _, _ in
                        cwd = path ?? ""
                        showWhereEditor = false
                    }
                )
            }
            .tint(neon.accent)
        }

        // MARK: Step 2 -- Steps

        private var stepsStepView: some View {
            VStack(spacing: 0) {
                stepperHeader(step2Active: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            sectionLabel("Steps \u{00B7} run in order")
                            Spacer()
                            Button {
                                Telemetry.breadcrumb("flow_wizard", "use template tapped", data: [:])
                                showTemplateReplace = true
                            } label: {
                                Text("Use a template")
                                    .font(neon.sans(12.5).weight(.semibold))
                                    .foregroundStyle(neon.accent)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 10)

                        ForEach(Array(viewModel.steps.enumerated()), id: \.element.id) { i, step in
                            stepCard(step: step, index: i)
                                .padding(.horizontal, 16)
                            if i < viewModel.steps.count - 1 {
                                connector(after: step)
                            }
                        }

                        addStepControl
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                    }
                    .padding(.bottom, 100)
                }
                .scrollIndicators(.hidden)
                .safeAreaInset(edge: .bottom) { startFooter }
            }
        }

        @ViewBuilder
        private func stepCard(step: PipelineStep, index: Int) -> some View {
            Button {
                Telemetry.breadcrumb("flow_wizard", "step card tapped", data: ["index": "\(index)", "kind": step.kind])
                if step.kind == "branch" {
                    branchEditStepID = step.id
                } else {
                    configSheetStepID = step.id
                }
            } label: {
                HStack(spacing: 12) {
                    ConduitUI.AgentDot(agent: step.kind.isEmpty ? step.agentType : nil, size: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(index + 1). \(roleLabel(step))")
                            .font(neon.sans(15.5).weight(.semibold))
                            .foregroundStyle(neon.text)
                        HStack(spacing: 6) {
                            if step.kind.isEmpty {
                                ConduitUI.Chip(label: step.agentType, tint: neon.agentTint(forAgent: step.agentType))
                            } else {
                                ConduitUI.Chip(label: "if / else")
                            }
                            Text(handoffNote(index: index))
                                .font(neon.mono(11))
                                .foregroundStyle(neon.textDim)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(neon.textDim)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
            }
            .buttonStyle(.plain)
        }

        private func roleLabel(_ step: PipelineStep) -> String {
            if step.kind == "branch" { return "If / Else" }
            switch step.role {
            case "researcher": return "Research"
            case "architect": return "Design"
            case "engineer": return "Build"
            default: return "Custom"
            }
        }

        private func handoffNote(index: Int) -> String {
            index == 0 ? "reads the repo" : "sees step \(index)"
        }

        @ViewBuilder
        private func connector(after step: PipelineStep) -> some View {
            HStack(spacing: 10) {
                Rectangle().fill(neon.lineSoft).frame(width: 1.5, height: 28)
                if step.gateAfter {
                    ConduitUI.GatePill(label: "Gate \u{2014} you approve", active: true)
                } else {
                    Text("passes work down \u{2193}")
                        .font(neon.mono(11))
                        .foregroundStyle(neon.textFaint)
                }
                Spacer()
            }
            .padding(.leading, 44)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }

        @ViewBuilder
        private var addStepControl: some View {
            if addStepMenuExpanded {
                HStack(spacing: 8) {
                    pillChoice("Agent step") {
                        viewModel.addStep()
                        addStepMenuExpanded = false
                        Telemetry.breadcrumb("flow_wizard", "add step agent", data: [:])
                    }
                    pillChoice("If / Else") {
                        viewModel.addControlFlowStep(kind: "branch")
                        addStepMenuExpanded = false
                        Telemetry.breadcrumb("flow_wizard", "add step branch", data: [:])
                    }
                    pillChoice("Cancel") { addStepMenuExpanded = false }
                }
            } else {
                Button {
                    addStepMenuExpanded = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("Add step")
                    }
                    .font(neon.sans(13).weight(.semibold))
                    .foregroundStyle(neon.textDim)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
        }

        private func pillChoice(_ label: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Text(label)
                    .font(neon.sans(12.5).weight(.semibold))
                    .foregroundStyle(neon.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .conduitGlassCapsule(tint: nil)
            }
            .buttonStyle(.plain)
        }

        private var startFooter: some View {
            VStack(spacing: 10) {
                Rectangle().fill(neon.border).frame(height: 1)
                HStack(spacing: 6) {
                    ConduitUI.GateGlyph(size: 12)
                    Text(gateSummaryCaption)
                        .font(neon.mono(11.5))
                        .foregroundStyle(neon.textDim)
                }
                ConduitUI.ActionButton("Start flow", variant: .primary) {
                    attemptStart()
                }
                .disabled(isSubmitting)
                .opacity(isSubmitting ? 0.7 : 1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .background(neon.bg.ignoresSafeArea(edges: .bottom))
        }

        private var gateCount: Int { viewModel.steps.filter { $0.gateAfter }.count }

        private var gateSummaryCaption: String {
            if gateCount == 0 { return "runs end-to-end \u{2014} no gates" }
            if gateCount == 1 { return "pauses once for your approval" }
            return "pauses \(gateCount)\u{00D7} for your approval"
        }

        private func sectionLabel(_ text: String) -> some View {
            Text(text.uppercased())
                .font(neon.mono(11).weight(.bold))
                .tracking(0.6)
                .foregroundStyle(neon.textFaint)
        }

        // MARK: Mid-wizard "Use a template"
        //
        // Simplification: offers only the two built-in recipes (not saved
        // templates) -- a re-pick mid-Steps is a smaller surface than the
        // Start sheet's full template list.

        private enum BuiltInFlowKind { case researchDesignBuild, fixVerify }

        private func applyBuiltIn(_ kind: BuiltInFlowKind) {
            Telemetry.breadcrumb("flow_wizard", "template replace", data: ["kind": "\(kind)"])
            switch kind {
            case .researchDesignBuild:
                viewModel.steps = [
                    PipelineStep(agentType: "claude", role: "researcher",
                        promptTemplate: "Investigate the codebase and summarize findings.",
                        inputFromPrev: "none", gateAfter: false),
                    PipelineStep(agentType: "claude", role: "architect",
                        promptTemplate: "Design the implementation. Prior work: {{prev}}",
                        inputFromPrev: "output", gateAfter: true),
                    PipelineStep(agentType: "codex", role: "engineer",
                        promptTemplate: "Implement the approved design. Prior work: {{prev}}",
                        inputFromPrev: "output", gateAfter: false),
                ]
                if trimmedTask.isEmpty { task = "Research, design, and build the change." }
            case .fixVerify:
                viewModel.steps = [
                    PipelineStep(agentType: "codex", role: "engineer",
                        promptTemplate: "Fix the reported issue in the codebase.",
                        inputFromPrev: "none", gateAfter: false),
                    PipelineStep(agentType: "claude", role: "custom",
                        promptTemplate: "Verify the fix works and run any existing tests. Prior work: {{prev}}",
                        inputFromPrev: "output", gateAfter: false),
                ]
                if trimmedTask.isEmpty { task = "Fix the reported issue and verify the fix." }
            }
            viewModel.selectedStepID = viewModel.steps.first?.id
        }

        // MARK: Start / submit

        private var trimmedTask: String { task.trimmingCharacters(in: .whitespacesAndNewlines) }

        /// The wizard has no separate title field -- the title derives from
        /// the task, truncated (design_handoff_flow README "Naming").
        private var derivedTitle: String {
            let t = trimmedTask
            guard !t.isEmpty else { return "Flow" }
            return t.count > 34 ? String(t.prefix(34)) + "\u{2026}" : t
        }

        private func attemptStart() {
            let indices = viewModel.unchainedStepIndices()
            if !indices.isEmpty {
                chainGuardrailIndices = indices
                return
            }
            submitFlow()
        }

        private var chainGuardrailMessage: String {
            let list = chainGuardrailIndices.map { "\($0 + 1)" }.joined(separator: ", ")
            return "Step\(chainGuardrailIndices.count == 1 ? "" : "s") \(list) won't see the previous step's work. Chain them so context carries forward?"
        }

        /// POST /api/pipeline -- same endpoint/request shape as the old
        /// builder's `submitPipeline()`.
        private func submitFlow() {
            let trimTitle = derivedTitle
            let trimTaskValue = trimmedTask
            guard !trimTaskValue.isEmpty else { return }

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
            Telemetry.breadcrumb("flow_wizard", "start submit",
                data: ["steps": "\(viewModel.steps.count)", "gates": "\(gateCount)", "host": endpoint.displayHost])

            let reqBody = viewModel.createRequest(
                title: trimTitle,
                task: trimTaskValue,
                cwd: cwd.trimmingCharacters(in: .whitespacesAndNewlines),
                base: baseBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "main" : baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
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
                        Telemetry.breadcrumb("flow_wizard", "start ok", data: ["id": parsed.id, "state": parsed.state])
                        createdPipeline = CreatedPipeline(id: parsed.id, state: parsed.state, currentStep: parsed.current_step)
                        navigateToMonitor = true
                        onFlowStarted?()
                    } else {
                        struct ErrorEnvelope: Decodable {
                            struct Detail: Decodable { let message: String? }
                            let error: Detail?
                        }
                        let serverMessage = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error?.message
                        let detail = serverMessage ?? "HTTP \(http.statusCode)"
                        Telemetry.capture(
                            error: NSError(domain: "ios.flow", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "flow create failed"]),
                            message: "flow create failed",
                            tags: ["surface": "ios", "phase": "flow_wizard"],
                            extras: ["status": "\(http.statusCode)", "detail": detail]
                        )
                        errorAlert = detail
                    }
                } catch {
                    Telemetry.capture(
                        error: error,
                        message: "flow create network error",
                        tags: ["surface": "ios", "phase": "flow_wizard"],
                        extras: [:]
                    )
                    errorAlert = error.localizedDescription
                }
            }
        }
    }
}
