import SwiftUI

// MARK: - ConduitDiffReviewView  (handoff §B.6 — Diff review → commit / PR)
//
// A session's changed files, top to bottom:
//   1. Summary bar — `N files · +added −removed` + a stacked add/del bar
//      (green additions / red deletions), driven by parsed per-file totals
//      (precise) or the session `linesAdded`/`linesRemoved` rollup.
//   2. File list — one row per changed file, path + per-file `+/−` chips,
//      tappable to expand an inline unified diff (mono, +green / −red).
//   3. Commit bar — a message TextField + `Commit & push` / `Open PR`.
//
// HONEST DATA NOTES (see `ConduitDiffReviewModel` for the full audit):
//   • Per-file +/- and the inline diff body are RECOVERED BY PARSING the
//     raw patch text in the most recent `kind == "diff"` `ConversationItem`
//     (`content`). They are never fabricated. `ViewEventFile` only carries
//     `(path, rev)` — no per-file counts — so when no parseable `diff` item
//     exists we render the summary bar + the distinct file paths + a
//     "Open the chat for the full diff" note instead of inventing hunks.
//   • Commit/push and Open PR call the broker via
//     `POST /api/session/{id}/git/commit` and `POST /api/session/{id}/git/pr`
//     respectively (broker PR #764). Both endpoints return `{"ok":bool,...}`.

extension ConduitUI {

    struct DiffReviewView: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        let session: ProjectSession

        /// Hosted inline (tablet right pane) rather than as a pushed screen →
        /// drop the leading back button.
        var embedded: Bool = false

        @State private var commitMessage: String = ""
        @State private var expanded: Set<String> = []

        // MARK: Inflight state
        @State private var isCommitting = false
        @State private var isOpeningPR = false

        // MARK: Commit result alert
        @State private var commitAlert: CommitAlert? = nil

        // MARK: PR sheet
        @State private var showPRSheet = false
        @State private var prTitle: String = ""
        @State private var prBody: String = ""

        // MARK: PR result alert
        @State private var prAlert: PRAlert? = nil

        // MARK: Error alert (shared)
        @State private var errorAlert: ErrorAlert? = nil

        private var log: [ConversationItem] { store.conversationLog[session.id] ?? [] }
        private var files: [ConduitUI.DiffFile] { ConduitUI.DiffReviewModel.files(from: log) }
        private var hasInlineDiff: Bool { ConduitUI.DiffReviewModel.hasInlineDiff(in: log) }
        private var summary: ConduitUI.DiffSummary {
            ConduitUI.DiffReviewModel.summary(session: session, files: files, log: log)
        }

        var body: some View {
            ZStack {
                GlassAppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        summaryCard
                        fileSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 12)
                    .frame(maxWidth: embedded ? .infinity : 760)
                    .frame(maxWidth: .infinity)
                }
                .safeAreaInset(edge: .bottom) { commitBar }
            }
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            // Commit result alert
            .alert("Committed", isPresented: Binding(
                get: { commitAlert != nil },
                set: { if !$0 { commitAlert = nil } }
            )) {
                Button("OK") { commitAlert = nil }
            } message: {
                if let a = commitAlert {
                    Text("SHA: \(a.sha)")
                }
            }
            // Error alert (commit or PR failure)
            .alert("Error", isPresented: Binding(
                get: { errorAlert != nil },
                set: { if !$0 { errorAlert = nil } }
            )) {
                Button("OK") { errorAlert = nil }
            } message: {
                if let a = errorAlert {
                    Text(a.message)
                }
            }
            // PR URL result alert — shows URL and an "Open in Safari" button
            .alert("Pull Request Opened", isPresented: Binding(
                get: { prAlert != nil },
                set: { if !$0 { prAlert = nil } }
            )) {
                if let a = prAlert, let url = URL(string: a.prUrl) {
                    Link("Open in Safari", destination: url)
                }
                Button("OK") { prAlert = nil }
            } message: {
                if let a = prAlert {
                    Text(a.prUrl)
                }
            }
            // PR input sheet
            .sheet(isPresented: $showPRSheet) {
                prInputSheet
            }
        }

        // MARK: Header (display name + branch chip)

        private var header: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(store.displayName(for: session))
                    .font(neon.sans(20).weight(.bold))
                    .foregroundStyle(neon.text)
                    .neonTextGlow(neon.textGlow)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    NeonAgentChip(label: session.assistant, tint: neon.agentTint(forAgent: session.assistant))
                    if let branch = session.branch, !branch.isEmpty {
                        NeonAgentChip(label: branch, tint: neon.accent)
                    }
                }
                // Commits / PR state, from the session rollups, when present.
                ConduitUI.OutcomeChips(
                    linesAdded: nil,
                    linesRemoved: nil,
                    commits: session.commits.map(Int.init),
                    prNumber: session.prNumber.map(Int.init),
                    prState: session.prState,
                    prUrl: session.prUrl
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        // MARK: Summary bar (N files · +added −removed + stacked bar)

        private var summaryCard: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(summary.fileCount)")
                        .font(ConduitUI.Typography.statBig)
                        .foregroundStyle(neon.accent)
                        .neonTextGlow(neon.textGlow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FILES")
                            .font(neon.mono(11).weight(.semibold))
                            .foregroundStyle(neon.textDim)
                            .textCase(.uppercase)
                        HStack(spacing: 8) {
                            Text("+\(summary.added)")
                                .foregroundStyle(neon.green)
                            Text("−\(summary.removed)")
                                .foregroundStyle(neon.red)
                        }
                        .font(neon.mono(13).weight(.semibold))
                    }
                    Spacer(minLength: 0)
                }
                stackedBar
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
        }

        /// Stacked add/del bar — green additions left, red deletions right.
        private var stackedBar: some View {
            GeometryReader { geo in
                let w = geo.size.width
                let greenW = max(0, min(w, w * summary.addedFraction))
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(neon.green)
                        .frame(width: greenW)
                    Rectangle()
                        .fill(neon.red)
                        .frame(width: w - greenW)
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
        }

        // MARK: File section

        @ViewBuilder
        private var fileSection: some View {
            Text("Files")
                .font(neon.mono(11).weight(.bold))
                .foregroundStyle(neon.textDim)
                .textCase(.uppercase)

            if !files.isEmpty {
                VStack(spacing: 8) {
                    ForEach(files) { file in
                        fileRow(file)
                    }
                }
            } else if hasInlineDiff {
                // A diff item existed but parsed to nothing — show the note.
                fallbackNote("No file detail in this diff. Open the chat for the full diff.")
            } else if summary.fileCount > 0 || summary.added > 0 || summary.removed > 0 {
                // Session rollup says there are changes, but no inline diff
                // item is in the log — show distinct paths + the note.
                if !distinctPaths.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(distinctPaths, id: \.self) { path in
                            pathOnlyRow(path)
                        }
                    }
                }
                fallbackNote("Open the chat for the full diff.")
            } else {
                fallbackNote("No changes yet.")
            }
        }

        private var distinctPaths: [String] {
            Array(Set(log.filter { $0.kind == "diff" }.flatMap { $0.files.map(\.path) })).sorted()
        }

        private func fileRow(_ file: ConduitUI.DiffFile) -> some View {
            let isOpen = expanded.contains(file.path)
            return VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        if isOpen { expanded.remove(file.path) } else { expanded.insert(file.path) }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(neon.textFaint)
                        Text(file.path)
                            .font(neon.mono(12).weight(.medium))
                            .foregroundStyle(neon.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text("+\(file.added)")
                            .font(neon.mono(11).weight(.semibold))
                            .foregroundStyle(neon.green)
                        Text("−\(file.removed)")
                            .font(neon.mono(11).weight(.semibold))
                            .foregroundStyle(neon.red)
                        if !file.lines.isEmpty {
                            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(neon.textFaint)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .disabled(file.lines.isEmpty)

                if isOpen, !file.lines.isEmpty {
                    Divider().background(neon.border)
                    inlineDiff(file.lines)
                }
            }
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 12)
        }

        private func pathOnlyRow(_ path: String) -> some View {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(neon.textFaint)
                Text(path)
                    .font(neon.mono(12).weight(.medium))
                    .foregroundStyle(neon.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 12)
        }

        private func inlineDiff(_ lines: [ConduitUI.DiffLine]) -> some View {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(neon.mono(11))
                            .foregroundStyle(color(for: line.kind))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(for: line.kind))
                    }
                }
            }
            .padding(.vertical, 6)
        }

        private func color(for kind: ConduitUI.DiffLine.Kind) -> Color {
            switch kind {
            case .added:   return neon.green
            case .removed: return neon.red
            case .hunk:    return neon.accent
            case .meta:    return neon.textFaint
            case .context: return neon.textDim
            }
        }

        private func background(for kind: ConduitUI.DiffLine.Kind) -> Color {
            switch kind {
            case .added:   return neon.green.opacity(0.10)
            case .removed: return neon.red.opacity(0.10)
            default:       return Color.clear
            }
        }

        private func fallbackNote(_ text: String) -> some View {
            Text(text)
                .font(neon.sans(13))
                .foregroundStyle(neon.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: 12)
        }

        // MARK: Commit bar

        private var commitBar: some View {
            VStack(spacing: 10) {
                TextField("Commit message", text: $commitMessage, axis: .vertical)
                    .font(neon.sans(14))
                    .foregroundStyle(neon.text)
                    .lineLimit(1...3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(neon.surface2)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(neon.border, lineWidth: 1))
                    )
                HStack(spacing: 10) {
                    let canCommit = !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !isCommitting && !isOpeningPR
                    Button {
                        commitAndPush()
                    } label: {
                        HStack(spacing: 6) {
                            if isCommitting {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(neon.accentText)
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            Text(isCommitting ? "Committing..." : "Commit & push")
                                .font(neon.mono(13).weight(.semibold))
                        }
                        .foregroundStyle(neon.accentText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(neon.green.opacity(canCommit ? 1 : 0.55)))
                        .neonGlowBox(neon.glow && canCommit ? neon.glowBox?.tinted(neon.green) : nil)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canCommit)

                    Button {
                        prTitle = ""
                        prBody = ""
                        showPRSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            if isOpeningPR {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(neon.accent)
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.triangle.pull")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            Text(isOpeningPR ? "Opening..." : "Open PR")
                                .font(neon.mono(13).weight(.semibold))
                        }
                        .foregroundStyle(neon.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(neon.surface))
                        .overlay(Capsule().stroke(neon.borderStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(isCommitting || isOpeningPR)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) { Divider().background(neon.border) }
        }

        // MARK: PR input sheet

        private var prInputSheet: some View {
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
                        Button("Cancel") { showPRSheet = false }
                            .foregroundStyle(neon.textDim)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Open PR") {
                            showPRSheet = false
                            openPR()
                        }
                        .font(neon.sans(14).weight(.semibold))
                        .foregroundStyle(neon.accent)
                        .disabled(prTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .environment(\.neonTheme, neon)
        }

        // MARK: - API calls

        /// POST /api/session/{id}/git/commit {"message": ..., "push": true}
        private func commitAndPush() {
            let msg = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !msg.isEmpty else { return }

            let endpoint = store.endpoint
            guard endpoint.isComplete, let base = endpoint.httpBaseURL else {
                errorAlert = ErrorAlert(message: "No active endpoint")
                return
            }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.path = "/api/session/\(session.id)/git/commit"
            guard let url = components?.url else {
                errorAlert = ErrorAlert(message: "Bad URL")
                return
            }

            isCommitting = true
            Telemetry.breadcrumb("diff-review", "commit start",
                data: ["session": session.id, "host": endpoint.displayHost])

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
                isCommitting = false
                errorAlert = ErrorAlert(message: "Encoding error")
                return
            }
            req.httpBody = body

            Task { @MainActor in
                defer { isCommitting = false }
                do {
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    guard let http = resp as? HTTPURLResponse else {
                        errorAlert = ErrorAlert(message: "Invalid response")
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
                        Telemetry.breadcrumb("diff-review", "commit ok",
                            data: ["session": session.id, "sha": sha])
                        commitMessage = ""
                        commitAlert = CommitAlert(sha: sha)
                    } else {
                        let detail = parsed?.stderr ?? "HTTP \(http.statusCode)"
                        Telemetry.capture(
                            error: NSError(domain: "ios.diff-review", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "commit failed"]),
                            message: "diff-review commit failed",
                            tags: ["surface": "ios", "phase": "diff-review"],
                            extras: ["session": session.id, "status": "\(http.statusCode)",
                                     "stderr": detail]
                        )
                        errorAlert = ErrorAlert(message: detail)
                    }
                } catch {
                    Telemetry.capture(
                        error: error,
                        message: "diff-review commit network error",
                        tags: ["surface": "ios", "phase": "diff-review"],
                        extras: ["session": session.id]
                    )
                    errorAlert = ErrorAlert(message: error.localizedDescription)
                }
            }
        }

        /// POST /api/session/{id}/git/pr {"title": ..., "body": ...}
        private func openPR() {
            let title = prTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }

            let endpoint = store.endpoint
            guard endpoint.isComplete, let base = endpoint.httpBaseURL else {
                errorAlert = ErrorAlert(message: "No active endpoint")
                return
            }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.path = "/api/session/\(session.id)/git/pr"
            guard let url = components?.url else {
                errorAlert = ErrorAlert(message: "Bad URL")
                return
            }

            isOpeningPR = true
            Telemetry.breadcrumb("diff-review", "open-pr start",
                data: ["session": session.id, "host": endpoint.displayHost])

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 30
            req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            struct PRBody: Encodable {
                let title: String
                let body: String
            }
            guard let bodyData = try? JSONEncoder().encode(PRBody(title: title, body: prBody)) else {
                isOpeningPR = false
                errorAlert = ErrorAlert(message: "Encoding error")
                return
            }
            req.httpBody = bodyData

            Task { @MainActor in
                defer { isOpeningPR = false }
                do {
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    guard let http = resp as? HTTPURLResponse else {
                        errorAlert = ErrorAlert(message: "Invalid response")
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
                        Telemetry.breadcrumb("diff-review", "open-pr ok",
                            data: ["session": session.id, "url": prUrl])
                        prAlert = PRAlert(prUrl: prUrl)
                    } else {
                        let detail = parsed?.stderr ?? "HTTP \(http.statusCode)"
                        Telemetry.capture(
                            error: NSError(domain: "ios.diff-review", code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "open PR failed"]),
                            message: "diff-review open-pr failed",
                            tags: ["surface": "ios", "phase": "diff-review"],
                            extras: ["session": session.id, "status": "\(http.statusCode)",
                                     "stderr": detail]
                        )
                        errorAlert = ErrorAlert(message: detail)
                    }
                } catch {
                    Telemetry.capture(
                        error: error,
                        message: "diff-review open-pr network error",
                        tags: ["surface": "ios", "phase": "diff-review"],
                        extras: ["session": session.id]
                    )
                    errorAlert = ErrorAlert(message: error.localizedDescription)
                }
            }
        }

        // MARK: Alert models

        private struct CommitAlert: Identifiable {
            let id = UUID()
            let sha: String
        }

        private struct PRAlert: Identifiable {
            let id = UUID()
            let prUrl: String
        }

        private struct ErrorAlert: Identifiable {
            let id = UUID()
            let message: String
        }
    }
}
