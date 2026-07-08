import SwiftUI

// MARK: - ConduitFlowStartSheet
//
// "Flow" (pipeline v2) redesign, PR B -- design_handoff_flow/README.md
// "Screens > 2. Start". Single entry point for both a plain new session AND
// a new flow: a segmented Session/Flow control (default Session) replaces
// the old separate "New session" / "New pipeline" affordances.
//
// Session tab is a compact native form (design_handoff_flow audit, screen 2):
// a 2-per-row agent-card grid, a task input, the wizard's "Where" row, and a
// pinned "Start session" button tinted with the selected agent -- NOT the
// full `AgentPickerSheet` (that sheet's own model/effort/permission config is
// out of scope here; this tab always creates with the agent's defaults, same
// as picking "Start without a folder" used to). `AgentPickerSheet` itself
// stays for its other call sites (the "+" button, deep-link post-pair).

extension ConduitUI {

    /// What `FlowWizardView` should be prefilled with -- a blank single step
    /// (default), or a template's steps + task with the wizard opened
    /// straight to the Steps screen ("prefilled directly", README).
    struct FlowWizardPrefill {
        var task: String = ""
        var steps: [PipelineStep]? = nil
        /// 1 = Task screen, 2 = Steps screen.
        var startStep: Int = 1

        static let blank = FlowWizardPrefill()
    }

    /// One selectable recipe on the Flow tab: a built-in recipe or a
    /// user-saved template (`GET /api/pipeline-templates`).
    struct FlowTemplateOption: Identifiable {
        let id: String
        let title: String
        let topoSteps: [FlowTopoStep]
        let gateCount: Int
        let build: () -> FlowWizardPrefill
    }

    struct FlowStartSheet: View {
        enum Tab: String { case session, flow }

        @Environment(SessionStore.self) private var store
        @Environment(FeatureFlags.self) private var flags
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        /// Caller stashes the prefill and dismisses this sheet; the caller's
        /// own `.sheet(isPresented:onDismiss:)` chain opens the wizard next
        /// (double-sheet-presentation avoidance -- mirrors
        /// `pendingOpenPipelineBuilder` in `ConduitHomeView`).
        var onStartWizard: (FlowWizardPrefill) -> Void

        @State private var tab: Tab
        @State private var templates: [PipelineTemplate] = []
        @State private var isLoadingTemplates = false

        // MARK: Compact Session tab state
        @State private var sessionAgentKind: String = "claude"
        @State private var sessionTask: String = ""
        @State private var sessionCwd: String = ""
        @State private var sessionBranch: String = "main"
        @State private var showSessionWhereEditor = false
        @State private var isStartingSession = false

        init(initialTab: Tab = .session, onStartWizard: @escaping (FlowWizardPrefill) -> Void) {
            self.onStartWizard = onStartWizard
            self._tab = State(initialValue: initialTab)
        }

        var body: some View {
            VStack(spacing: 0) {
                header
                NeonSegmentedPill(
                    segments: [
                        NeonSegmentedPill<Tab>.Segment(id: .session, label: "Session"),
                        NeonSegmentedPill<Tab>.Segment(id: .flow, label: "Flow"),
                    ],
                    selection: $tab
                )
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 10)
                .onChange(of: tab) { _, newValue in
                    Telemetry.breadcrumb("flow_start", "tab switch", data: ["tab": newValue.rawValue])
                    if newValue == .flow { loadTemplates() }
                }

                Group {
                    if tab == .session {
                        sessionTab
                    } else {
                        flowTab
                    }
                }
            }
            .background(GlassAppBackground())
            .tint(neon.accent)
            .appearanceColorScheme()
            .onAppear {
                Telemetry.breadcrumb("flow_start", "opened", data: ["tab": tab.rawValue])
                if tab == .flow { loadTemplates() }
                // Prefill the Session tab's "Where" row the same way the
                // Flow wizard's Task screen does (`store.defaultSessionCwd`)
                // -- the active session's cwd, else the box's most recent
                // directory, else "" -- rather than always showing
                // "no folder" when this sheet is opened from Home with no
                // session selected (device feedback).
                if sessionCwd.isEmpty {
                    sessionCwd = store.defaultSessionCwd
                }
            }
        }

        private var header: some View {
            HStack {
                Text("Start")
                    .font(neon.sans(17).weight(.bold))
                    .foregroundStyle(neon.text)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(neon.textDim)
                }
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 4)
        }

        // MARK: Compact Session tab
        //
        // design_handoff_flow audit §A.1: a compact native form, not the
        // full AgentPickerSheet. Wired to the SAME session-create path
        // (`store.createSession`) with model/effort/permission left at
        // their defaults -- advanced knobs are out of this tab's scope.

        private var sessionTab: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("Agent")
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                            spacing: 10
                        ) {
                            ForEach(sessionAgentKinds, id: \.self) { kind in
                                sessionAgentCard(kind)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("Task")
                        TextField("What should the agent do?", text: $sessionTask, axis: .vertical)
                            .font(neon.sans(15))
                            .foregroundStyle(neon.text)
                            .lineLimit(4...7)
                            .frame(minHeight: 96, alignment: .top)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .neonCardSurface(neon, fill: neon.surface2, cornerRadius: 14)
                            .tint(neon.accent)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("Where")
                        Button {
                            if store.isDemoMode {
                                Telemetry.breadcrumb("flow_start", "session where row demo no-op", data: [:])
                            } else {
                                showSessionWhereEditor = true
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "server.rack")
                                    .font(.body)
                                    .foregroundStyle(neon.green)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sessionWhereTitle)
                                        .font(neon.sans(15).weight(.semibold))
                                        .foregroundStyle(neon.text)
                                    Text("\(sessionCwdDisplay) \u{00B7} \(sessionBranch.isEmpty ? "main" : sessionBranch)")
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
                }
                .padding(16)
                .padding(.bottom, 76)
            }
            .scrollIndicators(.hidden)
            .sheet(isPresented: $showSessionWhereEditor) { sessionWhereEditorSheet }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Rectangle().fill(neon.border).frame(height: 1)
                    ConduitUI.ActionButton(
                        "Start session",
                        variant: .primary,
                        tint: neon.agentTint(forAgent: sessionAgentKind)
                    ) {
                        startSession()
                    }
                    .disabled(isStartingSession || !store.harness.canIssueCommands)
                    .opacity(isStartingSession || !store.harness.canIssueCommands ? 0.6 : 1)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
                }
                .background(neon.bg.ignoresSafeArea(edges: .bottom))
            }
        }

        /// Hardcoded first-class agents plus any extra broker-descriptor
        /// agents, filtered by `flags.enabledAgents` -- mirrors
        /// `ConduitAgentPickerSheet.allAgentKinds`.
        private var sessionAgentKinds: [String] {
            let enabled = Set(flags.enabledAgents.map { $0.lowercased() })
            let base: [String] = ["claude", "codex"].filter { enabled.contains($0) }
            let extras = store.agentDescriptors.keys
                .filter { !["claude", "codex"].contains($0.lowercased()) && enabled.contains($0.lowercased()) }
                .sorted()
            return base + extras
        }

        private func sessionAgentCard(_ kind: String) -> some View {
            let tint = neon.agentTint(forAgent: kind)
            let selected = sessionAgentKind == kind
            let name = sessionAgentName(kind)
            let modelTitle = ConduitUI.ForkOptions.defaultModelTitle(forCatalog: store.modelCatalog[kind])
                ?? store.agentDescriptors[kind.lowercased()]?.displayName ?? ""
            return Button {
                sessionAgentKind = kind
            } label: {
                HStack(spacing: 10) {
                    ConduitUI.AgentDot(agent: kind, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(neon.sans(15).weight(.bold))
                            .foregroundStyle(neon.text)
                        Text(modelTitle)
                            .font(neon.mono(10.5))
                            .foregroundStyle(selected ? tint : neon.textFaint)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .neonCardSurface(
                    neon,
                    fill: selected ? tint.opacity(neon.dark ? 0.14 : 0.10) : neon.surface,
                    cornerRadius: 14,
                    border: selected ? tint.opacity(0.66) : neon.lineSoft,
                    glowTint: selected ? tint : nil
                )
            }
            .buttonStyle(.plain)
        }

        private func sessionAgentName(_ kind: String) -> String {
            switch kind.lowercased() {
            case "claude": return "Claude"
            case "codex": return "Codex"
            default:
                let desc = store.agentDescriptors[kind.lowercased()]
                return (desc?.displayName.isEmpty == false) ? desc!.displayName : kind.capitalized
            }
        }

        private var sessionWhereTitle: String {
            if store.isDemoMode { return DemoData.boxName }
            return store.savedServers.first(where: { $0.endpoint == store.endpoint })?.name ?? store.endpoint.displayHost
        }

        private var sessionCwdDisplay: String {
            sessionCwd.isEmpty ? "no folder" : (sessionCwd as NSString).lastPathComponent
        }

        /// Reuses the SAME directory/box picker `AgentPickerSheet` and the
        /// wizard's "Where" step use (`directoryOnly` mode).
        private var sessionWhereEditorSheet: some View {
            NavigationStack {
                ConduitUI.DirectoryPicker(
                    agentKind: sessionAgentKind,
                    directoryOnly: true,
                    branch: $sessionBranch,
                    onCreate: { path, _, _, _, _, _ in
                        sessionCwd = path ?? ""
                        showSessionWhereEditor = false
                    }
                )
            }
            .tint(neon.accent)
        }

        private func startSession() {
            guard !isStartingSession else { return }
            isStartingSession = true
            let trimmedTask = sessionTask.trimmingCharacters(in: .whitespacesAndNewlines)
            Telemetry.breadcrumb("flow_start", "session tab start tapped",
                data: ["agent": sessionAgentKind, "hasTask": "\(!trimmedTask.isEmpty)", "hasCwd": "\(!sessionCwd.isEmpty)"])
            store.createSession(
                assistant: sessionAgentKind,
                startupCwd: sessionCwd.isEmpty ? nil : sessionCwd,
                initialPrompt: trimmedTask.isEmpty ? nil : trimmedTask
            )
            dismiss()
        }

        // MARK: Flow tab

        private var flowTab: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionLabel("Start from")

                    ForEach(builtInTemplates) { option in
                        templateCard(option)
                    }
                    if isLoadingTemplates {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    ForEach(savedTemplateOptions) { option in
                        templateCard(option)
                    }

                    Button {
                        Telemetry.breadcrumb("flow_start", "blank flow tapped", data: [:])
                        onStartWizard(.blank)
                        dismiss()
                    } label: {
                        ConduitUI.navRow(
                            icon: "plus.square",
                            title: "Blank flow",
                            subtitle: "define steps yourself",
                            iconTint: neon.accent
                        )
                    }
                    .buttonStyle(.plain)
                    .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)

                    Text("A flow chains agents in order \u{2014} each step sees the last step's work. Add a gate to approve from your phone before the next step runs.")
                        .font(neon.sans(13))
                        .foregroundStyle(neon.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .padding(.bottom, 76)
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Rectangle().fill(neon.border).frame(height: 1)
                    ConduitUI.ActionButton("Continue", variant: .primary, tint: neon.accent) {
                        Telemetry.breadcrumb("flow_start", "continue tapped", data: [:])
                        onStartWizard(.blank)
                        dismiss()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
                }
                .background(neon.bg.ignoresSafeArea(edges: .bottom))
            }
        }

        private func sectionLabel(_ text: String) -> some View {
            Text(text.uppercased())
                .font(neon.mono(11).weight(.bold))
                .tracking(0.6)
                .foregroundStyle(neon.textFaint)
        }

        @ViewBuilder
        private func templateCard(_ option: FlowTemplateOption) -> some View {
            Button {
                Telemetry.breadcrumb("flow_start", "template picked", data: ["id": option.id])
                onStartWizard(option.build())
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(option.title)
                            .font(neon.sans(15.5).weight(.semibold))
                            .foregroundStyle(neon.text)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(neon.textDim)
                    }
                    HStack(spacing: 10) {
                        ConduitUI.TopoMini(steps: option.topoSteps, size: 20)
                        Text("\(option.topoSteps.count) steps \u{00B7} \(option.gateCount) gate\(option.gateCount == 1 ? "" : "s")")
                            .font(neon.mono(11))
                            .foregroundStyle(neon.textDim)
                            .lineLimit(1)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
            }
            .buttonStyle(.plain)
        }

        // MARK: Built-in recipes

        private var builtInTemplates: [FlowTemplateOption] {
            [
                FlowTemplateOption(
                    id: "builtin.research-design-build",
                    title: "Research \u{2192} Design \u{2192} Build",
                    topoSteps: [
                        FlowTopoStep(agent: "claude", gateAfter: false),
                        FlowTopoStep(agent: "claude", gateAfter: true),
                        FlowTopoStep(agent: "codex", gateAfter: false),
                    ],
                    gateCount: 1,
                    build: {
                        FlowWizardPrefill(
                            task: "Research, design, and build the change.",
                            steps: [
                                PipelineStep(
                                    agentType: "claude", role: "researcher",
                                    promptTemplate: "Investigate the codebase and summarize findings.",
                                    inputFromPrev: "none", gateAfter: false
                                ),
                                PipelineStep(
                                    agentType: "claude", role: "architect",
                                    promptTemplate: "Design the implementation. Prior work: {{prev}}",
                                    inputFromPrev: "output", gateAfter: true
                                ),
                                PipelineStep(
                                    agentType: "codex", role: "engineer",
                                    promptTemplate: "Implement the approved design. Prior work: {{prev}}",
                                    inputFromPrev: "output", gateAfter: false
                                ),
                            ],
                            startStep: 2
                        )
                    }
                ),
                FlowTemplateOption(
                    id: "builtin.fix-verify",
                    title: "Fix \u{2192} Verify",
                    topoSteps: [
                        FlowTopoStep(agent: "codex", gateAfter: false),
                        FlowTopoStep(agent: "claude", gateAfter: false),
                    ],
                    gateCount: 0,
                    build: {
                        FlowWizardPrefill(
                            task: "Fix the reported issue and verify the fix.",
                            steps: [
                                PipelineStep(
                                    agentType: "codex", role: "engineer",
                                    promptTemplate: "Fix the reported issue in the codebase.",
                                    inputFromPrev: "none", gateAfter: false
                                ),
                                PipelineStep(
                                    agentType: "claude", role: "custom",
                                    promptTemplate: "Verify the fix works and run any existing tests. Prior work: {{prev}}",
                                    inputFromPrev: "output", gateAfter: false
                                ),
                            ],
                            startStep: 2
                        )
                    }
                ),
            ]
        }

        private var savedTemplateOptions: [FlowTemplateOption] {
            templates.map { tmpl in
                FlowTemplateOption(
                    id: tmpl.id,
                    title: tmpl.title.isEmpty ? "Untitled flow" : tmpl.title,
                    topoSteps: tmpl.steps.map { FlowTopoStep(agent: $0.agent_type, gateAfter: $0.gate_after) },
                    gateCount: tmpl.steps.filter { $0.gate_after }.count,
                    build: {
                        let vm = PipelineBuilderViewModel()
                        vm.applyTemplate(tmpl)
                        return FlowWizardPrefill(task: tmpl.task, steps: vm.steps, startStep: 2)
                    }
                )
            }
        }

        // MARK: Templates network (GET /api/pipeline-templates)

        private func loadTemplates() {
            // Demo mode is zero-network -- built-in recipes only, saved
            // templates never fetched.
            guard !store.isDemoMode else { return }
            guard store.pipelineTemplates, templates.isEmpty, !isLoadingTemplates else { return }
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
                    struct TemplatesEnvelope: Decodable { let templates: [PipelineTemplate] }
                    if let env = try? JSONDecoder().decode(TemplatesEnvelope.self, from: data) {
                        templates = env.templates
                    }
                } catch {
                    Telemetry.breadcrumb("flow_start", "templates load error",
                        data: ["error": error.localizedDescription])
                }
            }
        }
    }
}
