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
//   • There is **no broker/store commit/push/PR method** in the bindings
//     today (grep of `SessionStore` + the UDL finds none). So the two CTAs
//     are caller-supplied closures (`onCommitPush` / `onOpenPR`), defaulted
//     to no-ops. WIRE THE BACKEND ACTION LATER — the buttons are inert until
//     a real `commit_push` / `open_pr` core method lands.
//
// HOW TO PRESENT / ENTRY SUGGESTION (caller wires later):
//   • Push as a full screen (`NavigationStack` push) from the chat header's
//     "Changes" affordance, OR add a "Review changes" row to the Session
//     Info sheet (`ConduitSessionInfoView`) that pushes this. Gate the entry
//     on `session.linesAdded`/`linesRemoved` > 0 or a `kind == "diff"` item
//     existing in `store.conversationLog[session.id]` so it only appears when
//     there's something to review.
//   • Reads `@Environment(SessionStore.self)` for `conversationLog` — same
//     access pattern as `ConduitSessionInfoView`.

extension ConduitUI {

    struct DiffReviewView: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        let session: ProjectSession

        /// Commit message + "Commit & push" tap. Default no-op — the backend
        /// action does not exist yet (see header note); the caller wires a
        /// real handler once a core `commit_push` method lands.
        var onCommitPush: (String) -> Void = { _ in }
        /// "Open PR" tap. Default no-op for the same reason.
        var onOpenPR: () -> Void = {}
        /// Hosted inline (tablet right pane) rather than as a pushed screen →
        /// drop the leading back button.
        var embedded: Bool = false

        @State private var commitMessage: String = ""
        @State private var expanded: Set<String> = []

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
                }
                .safeAreaInset(edge: .bottom) { commitBar }
            }
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
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
                    Button {
                        onCommitPush(commitMessage)
                    } label: {
                        Label("Commit & push", systemImage: "arrow.up.circle.fill")
                            .font(neon.mono(13).weight(.semibold))
                            .foregroundStyle(neon.accentText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(neon.green))
                            .neonGlowBox(neon.glow ? neon.glowBox?.tinted(neon.green) : nil)
                    }
                    .buttonStyle(.plain)
                    .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)

                    Button {
                        onOpenPR()
                    } label: {
                        Label("Open PR", systemImage: "arrow.triangle.pull")
                            .font(neon.mono(13).weight(.semibold))
                            .foregroundStyle(neon.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(neon.surface))
                            .overlay(Capsule().stroke(neon.borderStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) { Divider().background(neon.border) }
        }
    }
}
