import SwiftUI

// MARK: - ConduitFanOutCompareView  (handoff §B.11 — compare results)
//
// Shown after POST /api/fanout/compare succeeds. Receives an array of
// compare results and presents them sorted by files_changed descending
// (most impact first); failed runs (non-empty error) go last, dimmed.
//
// Each card shows branch label, status chip, diff stat line, agent
// summary, expandable diff block, error (if any), and Open / Commit+PR
// action buttons.

extension ConduitUI {

    /// One run result from POST /api/fanout/compare response.
    struct FanOutCompareRun: Identifiable, Decodable {
        var id: String { session_id }
        let session_id: String
        let label: String
        let phase: String
        let files_changed: Int
        let insertions: Int
        let deletions: Int
        let diff_stat: String
        let agent_summary: String
        let error: String

        var hasError: Bool { !error.isEmpty }

        /// Parse "exited(0)" as success, anything else as fail or error.
        var isSuccess: Bool {
            phase == "exited(0)" || phase == "exited"
        }
    }

    struct FanOutCompareView: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        let runs: [FanOutCompareRun]

        @State private var expandedDiff: Set<String> = []
        @State private var isCommittingID: String? = nil
        @State private var commitMessage: String = ""
        @State private var showCommitSheetFor: FanOutCompareRun? = nil
        @State private var showPRSheetFor: FanOutCompareRun? = nil
        @State private var prTitle: String = ""
        @State private var prBody: String = ""
        @State private var errorAlert: String? = nil
        @State private var commitAlert: String? = nil
        @State private var prAlert: String? = nil

        /// Sort: successful runs by files_changed desc, failed runs last.
        private var sortedRuns: [FanOutCompareRun] {
            let good = runs.filter { !$0.hasError }.sorted { $0.files_changed > $1.files_changed }
            let bad = runs.filter { $0.hasError }
            return good + bad
        }

        var body: some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            headerLabel
                            ForEach(sortedRuns) { run in
                                runCard(run)
                                    .opacity(run.hasError ? 0.4 : 1)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                }
                .navigationTitle("Compare runs")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .foregroundStyle(neon.textDim)
                    }
                }
                .tint(neon.accent)
                .alert("Error", isPresented: Binding(
                    get: { errorAlert != nil },
                    set: { if !$0 { errorAlert = nil } }
                )) {
                    Button("OK") { errorAlert = nil }
                } message: {
                    if let m = errorAlert { Text(m) }
                }
                .alert("Committed", isPresented: Binding(
                    get: { commitAlert != nil },
                    set: { if !$0 { commitAlert = nil } }
                )) {
                    Button("OK") { commitAlert = nil }
                } message: {
                    if let m = commitAlert { Text(m) }
                }
                .alert("Pull Request Opened", isPresented: Binding(
                    get: { prAlert != nil },
                    set: { if !$0 { prAlert = nil } }
                )) {
                    if let m = prAlert, let url = URL(string: m) {
                        Link("Open in Safari", destination: url)
                    }
                    Button("OK") { prAlert = nil }
                } message: {
                    if let m = prAlert { Text(m) }
                }
                .sheet(item: $showCommitSheetFor) { run in
                    commitInputSheet(run: run)
                }
                .sheet(item: $showPRSheetFor) { run in
                    prInputSheet(run: run)
                }
            }
            .appearanceColorScheme()
            .onAppear {
                Telemetry.breadcrumb("fanout", "compare view opened",
                    data: ["run_count": "\(runs.count)"])
            }
        }

        // MARK: Header

        private var headerLabel: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("Compare & keep best")
                    .font(neon.sans(18).weight(.bold))
                    .foregroundStyle(neon.text)
                    .neonTextGlow(neon.textGlow)
                Text("Review each run below. Open the chat to inspect, or commit and push the best one.")
                    .font(neon.sans(13))
                    .foregroundStyle(neon.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        // MARK: Run card

        private func runCard(_ run: FanOutCompareRun) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                // Header row: branch label + status chip
                HStack(spacing: 8) {
                    Text(run.label)
                        .font(neon.mono(14).weight(.bold))
                        .foregroundStyle(neon.text)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    statusChip(run)
                }

                // Diff stat line
                if run.files_changed > 0 {
                    HStack(spacing: 6) {
                        Text("\(run.files_changed) files")
                            .font(neon.mono(12).weight(.semibold))
                            .foregroundStyle(neon.textDim)
                        Text("+\(run.insertions)")
                            .font(neon.mono(12).weight(.semibold))
                            .foregroundStyle(neon.green)
                        Text("-\(run.deletions)")
                            .font(neon.mono(12).weight(.semibold))
                            .foregroundStyle(neon.red)
                    }
                }

                // Agent summary
                if !run.agent_summary.isEmpty {
                    Text(run.agent_summary)
                        .font(neon.sans(13))
                        .foregroundStyle(neon.textDim)
                        .lineLimit(2)
                }

                // Expandable diff_stat block
                if !run.diff_stat.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.14)) {
                            if expandedDiff.contains(run.session_id) {
                                expandedDiff.remove(run.session_id)
                            } else {
                                expandedDiff.insert(run.session_id)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: expandedDiff.contains(run.session_id)
                                    ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(neon.textFaint)
                            Text(expandedDiff.contains(run.session_id) ? "Hide diff" : "Show diff")
                                .font(neon.mono(11).weight(.semibold))
                                .foregroundStyle(neon.textDim)
                        }
                    }
                    .buttonStyle(.plain)

                    if expandedDiff.contains(run.session_id) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(run.diff_stat)
                                .font(neon.mono(10))
                                .foregroundStyle(neon.textDim)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(neon.surface2)
                                )
                        }
                    }
                }

                // Error row
                if run.hasError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(neon.red)
                        Text(run.error)
                            .font(neon.sans(12))
                            .foregroundStyle(neon.red)
                            .lineLimit(3)
                    }
                }

                // Action buttons
                if !run.hasError {
                    HStack(spacing: 10) {
                        Button {
                            Telemetry.breadcrumb("fanout", "compare open session",
                                data: ["session": run.session_id, "label": run.label])
                            store.selectedSessionID = run.session_id
                            dismiss()
                        } label: {
                            Text("Open")
                                .font(neon.mono(13).weight(.semibold))
                                .foregroundStyle(neon.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Capsule().fill(neon.surface2))
                                .overlay(Capsule().stroke(neon.borderStrong, lineWidth: 1))
                        }
                        .buttonStyle(.plain)

                        Button {
                            Telemetry.breadcrumb("fanout", "compare commit+pr tapped",
                                data: ["session": run.session_id, "label": run.label])
                            commitMessage = ""
                            showCommitSheetFor = run
                        } label: {
                            Text("Commit & PR")
                                .font(neon.mono(13).weight(.semibold))
                                .foregroundStyle(neon.accentText)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Capsule().fill(neon.green))
                                .neonGlowBox(neon.glow ? neon.glowBox?.tinted(neon.green) : nil)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
        }

        private func statusChip(_ run: FanOutCompareRun) -> some View {
            let (label, color): (String, Color) = {
                if run.hasError { return ("error", neon.yellow) }
                if run.isSuccess { return ("done", neon.green) }
                return ("failed", neon.red)
            }()
            return Text(label)
                .font(neon.mono(10).weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(color)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(0.14)))
                .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1))
        }

        // MARK: Commit input sheet

        private func commitInputSheet(run: FanOutCompareRun) -> some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Commit message")
                                .font(neon.mono(11).weight(.semibold))
                                .foregroundStyle(neon.textDim)
                                .textCase(.uppercase)
                            TextField("Commit message (required)", text: $commitMessage, axis: .vertical)
                                .font(neon.sans(14))
                                .foregroundStyle(neon.text)
                                .lineLimit(2...4)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(neon.surface2)
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(neon.border, lineWidth: 1))
                                )
                        }
                        Spacer()
                    }
                    .padding(16)
                }
                .navigationTitle("Commit & push")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showCommitSheetFor = nil }
                            .foregroundStyle(neon.textDim)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Commit") {
                            showCommitSheetFor = nil
                            commitAndPush(run: run, message: commitMessage)
                        }
                        .font(neon.sans(14).weight(.semibold))
                        .foregroundStyle(neon.accent)
                        .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .environment(\.neonTheme, neon)
        }

        // MARK: PR input sheet

        private func prInputSheet(run: FanOutCompareRun) -> some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("PR Title")
                                .font(neon.mono(11).weight(.semibold))
                                .foregroundStyle(neon.textDim)
                                .textCase(.uppercase)
                            TextField("Title (required)", text: $prTitle)
                                .font(neon.sans(14))
                                .foregroundStyle(neon.text)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(neon.surface2)
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(neon.border, lineWidth: 1))
                                )
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Description (optional)")
                                .font(neon.mono(11).weight(.semibold))
                                .foregroundStyle(neon.textDim)
                                .textCase(.uppercase)
                            TextField("Body", text: $prBody, axis: .vertical)
                                .font(neon.sans(14))
                                .foregroundStyle(neon.text)
                                .lineLimit(4...8)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(neon.surface2)
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(neon.border, lineWidth: 1))
                                )
                        }
                        Spacer()
                    }
                    .padding(16)
                }
                .navigationTitle("Open Pull Request")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showPRSheetFor = nil }
                            .foregroundStyle(neon.textDim)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Open PR") {
                            showPRSheetFor = nil
                            openPR(run: run, title: prTitle, body: prBody)
                        }
                        .font(neon.sans(14).weight(.semibold))
                        .foregroundStyle(neon.accent)
                        .disabled(prTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .environment(\.neonTheme, neon)
        }

        // MARK: - API calls (same pattern as DiffReviewView)

        private func commitAndPush(run: FanOutCompareRun, message: String) {
            let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !msg.isEmpty else { return }

            let endpoint = store.endpoint
            guard endpoint.isComplete, let base = endpoint.httpBaseURL else {
                errorAlert = "No active endpoint"
                return
            }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.path = "/api/session/\(run.session_id)/git/commit"
            guard let url = components?.url else {
                errorAlert = "Bad URL"
                return
            }

            Telemetry.breadcrumb("fanout", "compare commit start",
                data: ["session": run.session_id, "host": endpoint.displayHost])

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 30
            req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            struct CommitBody: Encodable {
                let message: String
                let push: Bool
            }
            guard let body = try? JSONEncoder().encode(CommitBody(message: msg, push: true)) else {
                errorAlert = "Encoding error"
                return
            }
            req.httpBody = body

            Task { @MainActor in
                do {
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    guard let http = resp as? HTTPURLResponse else {
                        errorAlert = "Invalid response"
                        return
                    }
                    struct CommitResponse: Decodable {
                        let ok: Bool
                        let stderr: String?
                        let commit_sha: String?
                    }
                    let parsed = try? JSONDecoder().decode(CommitResponse.self, from: data)
                    if http.statusCode >= 200 && http.statusCode < 300, let r = parsed, r.ok {
                        let sha = r.commit_sha ?? "(unknown)"
                        Telemetry.breadcrumb("fanout", "compare commit ok",
                            data: ["session": run.session_id, "sha": sha])
                        commitAlert = "SHA: \(sha)"
                        // After commit, open PR sheet
                        prTitle = ""
                        prBody = ""
                        showPRSheetFor = run
                    } else {
                        let detail = parsed?.stderr ?? "HTTP \(http.statusCode)"
                        Telemetry.capture(
                            error: NSError(domain: "ios.fanout", code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "compare commit failed"]),
                            message: "fanout compare commit failed",
                            tags: ["surface": "ios", "phase": "fanout"],
                            extras: ["session": run.session_id, "status": "\(http.statusCode)"]
                        )
                        errorAlert = detail
                    }
                } catch {
                    Telemetry.capture(
                        error: error,
                        message: "fanout compare commit network error",
                        tags: ["surface": "ios", "phase": "fanout"],
                        extras: ["session": run.session_id]
                    )
                    errorAlert = error.localizedDescription
                }
            }
        }

        private func openPR(run: FanOutCompareRun, title: String, body prBodyText: String) {
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }

            let endpoint = store.endpoint
            guard endpoint.isComplete, let base = endpoint.httpBaseURL else {
                errorAlert = "No active endpoint"
                return
            }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.path = "/api/session/\(run.session_id)/git/pr"
            guard let url = components?.url else {
                errorAlert = "Bad URL"
                return
            }

            Telemetry.breadcrumb("fanout", "compare open-pr start",
                data: ["session": run.session_id, "host": endpoint.displayHost])

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 30
            req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            struct PRBody: Encodable {
                let title: String
                let body: String
            }
            guard let bodyData = try? JSONEncoder().encode(PRBody(title: title, body: prBodyText)) else {
                errorAlert = "Encoding error"
                return
            }
            req.httpBody = bodyData

            Task { @MainActor in
                do {
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    guard let http = resp as? HTTPURLResponse else {
                        errorAlert = "Invalid response"
                        return
                    }
                    struct PRResponse: Decodable {
                        let ok: Bool
                        let pr_url: String?
                        let stderr: String?
                    }
                    let parsed = try? JSONDecoder().decode(PRResponse.self, from: data)
                    if http.statusCode >= 200 && http.statusCode < 300, let r = parsed, r.ok,
                       let prUrl = r.pr_url {
                        Telemetry.breadcrumb("fanout", "compare open-pr ok",
                            data: ["session": run.session_id, "url": prUrl])
                        prAlert = prUrl
                    } else {
                        let detail = parsed?.stderr ?? "HTTP \(http.statusCode)"
                        Telemetry.capture(
                            error: NSError(domain: "ios.fanout", code: 3,
                                userInfo: [NSLocalizedDescriptionKey: "compare open-pr failed"]),
                            message: "fanout compare open-pr failed",
                            tags: ["surface": "ios", "phase": "fanout"],
                            extras: ["session": run.session_id, "status": "\(http.statusCode)"]
                        )
                        errorAlert = detail
                    }
                } catch {
                    Telemetry.capture(
                        error: error,
                        message: "fanout compare open-pr network error",
                        tags: ["surface": "ios", "phase": "fanout"],
                        extras: ["session": run.session_id]
                    )
                    errorAlert = error.localizedDescription
                }
            }
        }
    }
}
