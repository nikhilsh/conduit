import SwiftUI

// MARK: - ConduitFlowStartSheet
//
// "Flow" (pipeline v2) redesign, PR B -- design_handoff_flow/README.md
// "Screens > 2. Start". Single entry point for both a plain new session AND
// a new flow: a segmented Session/Flow control (default Session) replaces
// the old separate "New session" / "New pipeline" affordances.
//
// Session tab hosts the EXISTING `AgentPickerSheet` flow unmodified (its own
// NavigationStack/title/Cancel) -- deliberately NOT rewritten, per the PR
// scope. This nests a NavigationStack inside this sheet's own chrome, which
// reads as two stacked headers ("Start" + segmented control, then
// AgentPickerSheet's own "New session" title) -- flagged for on-device
// verification; functionally correct (its own `dismiss()` still tears down
// this whole sheet since `\.dismiss` resolves to the nearest presentation,
// not the nearest NavigationStack).

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

        init(initialTab: Tab = .session, onStartWizard: @escaping (FlowWizardPrefill) -> Void) {
            self.onStartWizard = onStartWizard
            self._tab = State(initialValue: initialTab)
        }

        var body: some View {
            VStack(spacing: 0) {
                header
                Picker("", selection: $tab) {
                    Text("Session").tag(Tab.session)
                    Text("Flow").tag(Tab.flow)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 10)
                .onChange(of: tab) { _, newValue in
                    Telemetry.breadcrumb("flow_start", "tab switch", data: ["tab": newValue.rawValue])
                    if newValue == .flow { loadTemplates() }
                }

                Group {
                    if tab == .session {
                        ConduitUI.AgentPickerSheet(
                            onOpenPipelineBuilder: {
                                Telemetry.breadcrumb("flow_start", "session tab pipeline row tapped", data: [:])
                                onStartWizard(.blank)
                                dismiss()
                            },
                            embedded: true
                        )
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
