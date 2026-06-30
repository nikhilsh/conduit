import SwiftUI

// MARK: - ConduitFanOutView  (handoff §B.11 — "Fan-out · parallel runs")
//
// One task, many runs. Configure a single task + N branches, then launch
// N parallel sessions of that same task — one per branch — and watch each
// run's progress / status (running / done / failed). `images/13-fan-out.png`.
//
// ── How to present ────────────────────────────────────────────────────
// Push or sheet-present `ConduitUI.FanOutView()` with the `SessionStore`
// already in the environment (it reads `@Environment(SessionStore.self)`),
// e.g.
//
//     .sheet(isPresented: $showFanOut) {
//         ConduitUI.FanOutView(
//             onLaunch: { task, branches in
//                 // host wires the REAL launch here, one session per branch:
//                 for b in branches {
//                     store.createSession(assistant: "claude", branch: b,
//                                         initialPrompt: task)
//                 }
//             },
//             onCompare: { runs in /* present ConduitFanOutCompareView */ }
//         )
//         .environment(store)
//     }
//
// ── What is real vs. stub ─────────────────────────────────────────────
// • LAUNCH is real: the host's `onLaunch(task, branches)` closure calls
//   `store.createSession(assistant:branch:reasoningEffort:model:cwd:)` (or
//   the convenience `createSession(assistant:branch:initialPrompt:)`
//   overload) once per branch. There is no dedicated fan-out/orchestration
//   backend — a fan-out is literally N independent sessions of the same
//   task across N branches.
// • PROGRESS is real, but only AFTER launch: each run's status is derived
//   from the live `SessionStatus.phase` for the session keyed to that
//   branch (running → cyan, exited(0) → done/green, exited(≠0) → failed/
//   red). Before launch we show the configured branches in a neutral
//   "queued" state — never a fake in-progress bar.
// • COMPARE — calls POST /api/fanout/compare with the session IDs of the
//   launched runs, then presents ConduitFanOutCompareView with the result.
//
// This view does NOT call `createSession` itself and does NOT mutate the
// store — it only reflects status the store already holds. Launch wiring
// is the host's job (keep this surface presentation-only).

extension ConduitUI {

    /// One configured run inside a fan-out: a branch name + the box it
    /// runs on. `sessionID` is `nil` until the host launches the run and
    /// hands the freshly-created session id back (see `runs:`); once set,
    /// the row's progress/status is driven from the live `SessionStatus`.
    struct FanOutRun: Identifiable, Equatable {
        var id: String { branch }
        let branch: String
        /// The box / machine label this run targets (display-only).
        var box: String
        /// The created session's id once launched, else nil (queued).
        var sessionID: String?

        init(branch: String, box: String = "", sessionID: String? = nil) {
            self.branch = branch
            self.box = box
            self.sessionID = sessionID
        }
    }

    /// Pure status of a single run, derived from the session phase.
    enum FanOutRunState: Equatable {
        case queued        // configured, not yet launched
        case running
        case done
        case failed

        /// Map a launched run's live `SessionStatus.phase` to a state.
        /// `phase` mirrors the broker vocabulary: `"running"`, `"ready"`,
        /// `"exited"`, `"exited(0)"`, `"exited(137)"`, … An exited phase
        /// with a non-zero code is a failure; `exited(0)`/`exited` is done;
        /// anything else (and a connected, un-exited session) is running.
        static func from(phase: String?) -> FanOutRunState {
            guard let phase, !phase.isEmpty else { return .running }
            guard phase.hasPrefix("exited") else { return .running }
            // Pull an exit code out of "exited(<n>)" if present.
            if let open = phase.firstIndex(of: "("),
               let close = phase.firstIndex(of: ")"),
               open < close {
                let inner = phase[phase.index(after: open)..<close]
                if let code = Int(inner) {
                    return code == 0 ? .done : .failed
                }
            }
            // Bare "exited" with no code → treat as a clean finish.
            return .done
        }
    }

    struct FanOutView: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        /// Host wires the real launch: called once with the task text and
        /// the chosen branches; the host fans out into `createSession`
        /// per branch. No-op by default (presentation-only).
        var onLaunch: (String, [String]) -> Void = { _, _ in }
        /// "Compare & keep best" — calls POST /api/fanout/compare with the
        /// launched session IDs and presents ConduitFanOutCompareView on
        /// success. No-op by default so the view compiles standalone.
        var onCompare: () -> Void = {}

        /// Optional pre-configured runs (e.g. the host already launched and
        /// is handing back the live sessions, keyed by branch). When empty,
        /// the view offers the launch affordance (enter task + add branches).
        var runs: [ConduitUI.FanOutRun] = []

        /// Editable task text (the single shared task fanned across runs).
        @State private var task: String = ""
        /// Branch drafts the user is composing before launch.
        @State private var branchDrafts: [String]
        @State private var newBranch: String = ""
        /// Runs already launched (seeded from `runs`; status comes live
        /// from the store, NOT stored here).
        @State private var launched: [ConduitUI.FanOutRun]

        // MARK: Compare state
        @State private var isComparing = false
        @State private var compareResults: [ConduitUI.FanOutCompareRun]? = nil
        @State private var showCompareSheet = false
        @State private var compareErrorAlert: String? = nil

        init(
            onLaunch: @escaping (String, [String]) -> Void = { _, _ in },
            onCompare: @escaping () -> Void = {},
            runs: [ConduitUI.FanOutRun] = []
        ) {
            self.onLaunch = onLaunch
            self.onCompare = onCompare
            self.runs = runs
            _branchDrafts = State(initialValue: [])
            _launched = State(initialValue: runs)
        }

        /// Runs to render: the launched set if present, else the drafts
        /// shown as queued rows.
        private var visibleRuns: [ConduitUI.FanOutRun] {
            if !launched.isEmpty { return launched }
            return branchDrafts.map { ConduitUI.FanOutRun(branch: $0) }
        }

        private var hasLaunched: Bool { !launched.isEmpty }

        var body: some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            sharedTaskCard
                            parallelRunsSection
                            if !hasLaunched {
                                launchButton
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                    .safeAreaInset(edge: .bottom) {
                        if hasLaunched {
                            compareBar
                        }
                    }
                }
                .navigationTitle("Fan-out")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text("Fan-out")
                            .font(neon.sans(17).weight(.bold))
                            .foregroundStyle(neon.text)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Text("\(visibleRuns.count) runs")
                            .font(neon.mono(11).weight(.semibold))
                            .foregroundStyle(neon.textDim)
                    }
                }
                .tint(neon.accent)
                .sheet(isPresented: $showCompareSheet) {
                    if let results = compareResults {
                        ConduitUI.FanOutCompareView(runs: results)
                            .environment(store)
                    }
                }
                .alert("Compare failed", isPresented: Binding(
                    get: { compareErrorAlert != nil },
                    set: { if !$0 { compareErrorAlert = nil } }
                )) {
                    Button("OK") { compareErrorAlert = nil }
                } message: {
                    if let msg = compareErrorAlert { Text(msg) }
                }
            }
            .appearanceColorScheme()
        }

        // MARK: Shared task

        private var sharedTaskCard: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("Shared task")
                    .font(neon.mono(11).weight(.bold))
                    .foregroundStyle(neon.textDim)
                    .textCase(.uppercase)

                if hasLaunched {
                    Text(task.isEmpty ? "—" : task)
                        .font(neon.sans(16).weight(.semibold))
                        .foregroundStyle(neon.text)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Editable before launch (configure state).
                    TextField("Describe the task to run across branches…", text: $task, axis: .vertical)
                        .font(neon.sans(16).weight(.semibold))
                        .foregroundStyle(neon.text)
                        .lineLimit(1...4)
                        .tint(neon.accent)
                }

                HStack(spacing: 8) {
                    NeonAgentChip(label: "1 task", tint: neon.green)
                    NeonAgentChip(label: branchesBoxesLabel, tint: neon.accent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
        }

        private var branchesBoxesLabel: String {
            let n = visibleRuns.count
            let boxes = Set(visibleRuns.map { $0.box }.filter { !$0.isEmpty }).count
            if boxes > 0 {
                return "\(n) branches · \(boxes) boxes"
            }
            return "\(n) branches"
        }

        // MARK: Parallel runs

        private var parallelRunsSection: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("Parallel runs")
                    .font(neon.mono(11).weight(.bold))
                    .foregroundStyle(neon.textDim)
                    .textCase(.uppercase)

                if visibleRuns.isEmpty {
                    Text("Add branches below to configure runs.")
                        .font(neon.sans(13))
                        .foregroundStyle(neon.textFaint)
                        .padding(.vertical, 6)
                } else {
                    ForEach(visibleRuns) { run in
                        runRow(run)
                    }
                }

                if !hasLaunched {
                    addBranchRow
                }
            }
        }

        /// One run row: branch + box + progress bar + status chip. When the
        /// run is launched, status/progress comes live from the store; when
        /// it's still a draft it reads as a neutral "queued" row.
        private func runRow(_ run: ConduitUI.FanOutRun) -> some View {
            let phase = run.sessionID.flatMap { store.statusBySession[$0]?.phase }
            let state: ConduitUI.FanOutRunState = run.sessionID == nil
                ? .queued
                : ConduitUI.FanOutRunState.from(phase: phase)
            let tint = stateTint(state)

            return VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ConduitUI.ConduitMark(size: 16, color: tint, glow: neon.glow)
                    Text(run.branch)
                        .font(neon.mono(13).weight(.semibold))
                        .foregroundStyle(neon.text)
                    Spacer(minLength: 8)
                    if !run.box.isEmpty {
                        Text(run.box)
                            .font(neon.mono(10))
                            .foregroundStyle(neon.textFaint)
                    }
                }
                HStack(spacing: 10) {
                    progressBar(state: state, tint: tint)
                    Text(statusLabel(state))
                        .font(neon.mono(10).weight(.bold))
                        .foregroundStyle(tint)
                        .textCase(.uppercase)
                        .fixedSize()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(
                neon,
                fill: neon.surface,
                cornerRadius: 14,
                failed: state == .failed,
                glowTint: state == .queued ? nil : tint
            )
        }

        /// Determinate bar for done/failed (full), a steady partial fill for
        /// running (we have no % from the backend, so show a partial fill
        /// rather than fabricating progress), empty for queued.
        private func progressBar(state: ConduitUI.FanOutRunState, tint: Color) -> some View {
            GeometryReader { geo in
                let fraction: CGFloat = {
                    switch state {
                    case .queued:  return 0
                    case .running: return 0.5   // running, % unknown (no backend signal)
                    case .done:    return 1
                    case .failed:  return 1
                    }
                }()
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(neon.surface2)
                    Capsule()
                        .fill(tint)
                        .frame(width: geo.size.width * fraction)
                        .neonGlowBox(state == .running && neon.glow ? neon.glowBox?.tinted(tint) : nil)
                }
            }
            .frame(height: 6)
            .frame(maxWidth: .infinity)
        }

        private func stateTint(_ state: ConduitUI.FanOutRunState) -> Color {
            switch state {
            case .queued:  return neon.textFaint
            case .running: return neon.accent   // cyan
            case .done:    return neon.green
            case .failed:  return neon.red
            }
        }

        private func statusLabel(_ state: ConduitUI.FanOutRunState) -> String {
            switch state {
            case .queued:  return "queued"
            case .running: return "running"
            case .done:    return "done"
            case .failed:  return "failed"
            }
        }

        // MARK: Configure (add branch)

        private var addBranchRow: some View {
            HStack(spacing: 8) {
                TextField("branch name (e.g. fix/ratelimit-a)", text: $newBranch)
                    .font(neon.mono(12))
                    .foregroundStyle(neon.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .tint(neon.accent)
                    .onSubmit(addBranch)
                Button(action: addBranch) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(neon.accentText)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(neon.accent))
                }
                .buttonStyle(.plain)
                .disabled(trimmedNewBranch.isEmpty)
                .opacity(trimmedNewBranch.isEmpty ? 0.4 : 1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
        }

        private var trimmedNewBranch: String {
            newBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func addBranch() {
            let b = trimmedNewBranch
            guard !b.isEmpty, !branchDrafts.contains(b) else { return }
            branchDrafts.append(b)
            newBranch = ""
        }

        // MARK: Actions

        private var launchButton: some View {
            Button {
                let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedTask.isEmpty, !branchDrafts.isEmpty else { return }
                // Hand the host the task + branches; the host fans out into
                // createSession per branch and may re-present this view with
                // `runs:` populated (sessionID per branch) to show live status.
                onLaunch(trimmedTask, branchDrafts)
            } label: {
                Text("Launch \(branchDrafts.count) runs")
                    .font(neon.sans(15).weight(.bold))
                    .foregroundStyle(neon.accentText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(neon.accent)
                    )
                    .neonGlowBox(neon.glow ? neon.glowBox : nil)
            }
            .buttonStyle(.plain)
            .disabled(launchDisabled)
            .opacity(launchDisabled ? 0.4 : 1)
        }

        private var launchDisabled: Bool {
            task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || branchDrafts.isEmpty
        }

        private var compareBar: some View {
            Button {
                postCompare()
            } label: {
                HStack(spacing: 8) {
                    if isComparing {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(neon.accentText)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                    }
                    Text(isComparing ? "Comparing..." : "Compare & keep best")
                        .font(neon.sans(15).weight(.bold))
                }
                .foregroundStyle(neon.accentText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(neon.accent)
                )
                .neonGlowBox(neon.glow ? neon.glowBox : nil)
            }
            .buttonStyle(.plain)
            .disabled(isComparing)
            .opacity(isComparing ? 0.7 : 1)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }

        // MARK: - Compare API call

        /// POST /api/fanout/compare  {"base":"main","runs":[{"session_id":"...","label":"..."}]}
        private func postCompare() {
            let endpoint = store.endpoint
            guard endpoint.isComplete, let base = endpoint.httpBaseURL else {
                compareErrorAlert = "No active endpoint"
                return
            }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.path = "/api/fanout/compare"
            guard let url = components?.url else {
                compareErrorAlert = "Bad URL"
                return
            }

            struct FanOutCompareRequestRun: Encodable {
                let session_id: String
                let label: String
            }
            struct FanOutCompareRequest: Encodable {
                let base: String
                let runs: [FanOutCompareRequestRun]
            }

            let sessionRuns = launched.compactMap { run -> FanOutCompareRequestRun? in
                guard let sid = run.sessionID else { return nil }
                return FanOutCompareRequestRun(session_id: sid, label: run.branch)
            }
            guard !sessionRuns.isEmpty else {
                compareErrorAlert = "No launched sessions to compare"
                return
            }

            isComparing = true
            Telemetry.breadcrumb("fanout", "compare start",
                data: ["run_count": "\(sessionRuns.count)", "host": endpoint.displayHost])

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 60
            req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            guard let body = try? JSONEncoder().encode(FanOutCompareRequest(base: "main", runs: sessionRuns)) else {
                isComparing = false
                compareErrorAlert = "Encoding error"
                return
            }
            req.httpBody = body

            Task { @MainActor in
                defer { isComparing = false }
                do {
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    guard let http = resp as? HTTPURLResponse else {
                        compareErrorAlert = "Invalid response"
                        return
                    }
                    struct FanOutCompareResponse: Decodable {
                        let base: String
                        let runs: [ConduitUI.FanOutCompareRun]
                    }
                    if http.statusCode >= 200 && http.statusCode < 300,
                       let parsed = try? JSONDecoder().decode(FanOutCompareResponse.self, from: data) {
                        Telemetry.breadcrumb("fanout", "compare ok",
                            data: ["run_count": "\(parsed.runs.count)"])
                        compareResults = parsed.runs
                        showCompareSheet = true
                    } else {
                        let detail = "HTTP \(http.statusCode)"
                        Telemetry.capture(
                            error: NSError(domain: "ios.fanout", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "compare failed"]),
                            message: "fanout compare failed",
                            tags: ["surface": "ios", "phase": "fanout"],
                            extras: ["status": "\(http.statusCode)"]
                        )
                        compareErrorAlert = detail
                    }
                } catch {
                    Telemetry.capture(
                        error: error,
                        message: "fanout compare network error",
                        tags: ["surface": "ios", "phase": "fanout"],
                        extras: ["host": endpoint.displayHost]
                    )
                    compareErrorAlert = error.localizedDescription
                }
            }
        }
    }
}
