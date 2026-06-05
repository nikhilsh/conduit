import SwiftUI

// MARK: - ConduitSessionRecapView
//
// Conduit redesign "Session recap" surface (handoff §B.9, image 10): an
// exportable end-of-session summary. Top-to-bottom IA, mirroring the
// reference render:
//
//   • Header   — agent-tinted ConduitMark avatar, the real session name,
//                an OUTCOME chip (PR / merged / ended / failed — derived
//                from prState/prNumber + lifecycle; honest "neutral" when
//                unknown), and a `+added / −removed` mini stat.
//   • What changed — a bulleted list. There is NO server-generated
//                "what changed" prose, so this is derived HONESTLY from
//                real signal in priority order: the agent's own
//                result-summary / task-text / diff-summary lines from the
//                conversation log, else the distinct changed-file paths,
//                else the commit count. Never fabricated prose. The gap is
//                documented in the handoff report.
//   • File stats — `N files` / `+added` / `−removed` tiles from
//                linesAdded / linesRemoved (ProjectSession/SessionStatus)
//                and the distinct file-path count from the log.
//   • Commands run — the recent real `command` fields from the
//                conversation log, mono-styled.
//   • Duration / tokens — wall-clock (started → last activity) and the
//                token totals from the usage snapshot.
//   • Actions  — Export markdown (a `ShareLink` over the assembled doc →
//                the system share sheet) and Share link. There is no real
//                shareable URL in the stack, so "Share link" shares the
//                SAME markdown rather than faking a URL (it is labelled
//                "Share text" to stay honest).
//
// HOW TO PRESENT / ENTRY SUGGESTION
//   Present as its own `.sheet` (full NavigationStack chrome, like
//   SessionInfoView) or — on tablet — `embedded: true` inside the right
//   pane. Suggested entry points (wired separately by the host):
//     · the Session Info "Export" affordance → Recap instead of a bare
//       markdown share, so the user previews before sharing;
//     · a row tap in History (a finished session is exactly a recap);
//     · an end-of-session prompt after `End session`.
//   Reads `@Environment(SessionStore.self)` for the live conversation log,
//   status deltas, display name, and lifecycle.
//
// Reuses the Session Info data idioms (the same snapshot shape, the same
// `fmtK`, the same wall-clock duration) by re-deriving them locally rather
// than touching SessionInfoView (constraint: new files only).

extension ConduitUI {

    struct SessionRecapView: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        let session: ProjectSession
        /// Hosted inline as a tablet right-pane tab (not a sheet) → drop the
        /// close affordance + the outer NavigationStack chrome.
        var embedded: Bool = false

        var body: some View {
            if embedded {
                content
            } else {
                NavigationStack {
                    content
                        .navigationTitle("Recap")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button {
                                    dismiss()
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .accessibilityLabel("Close")
                            }
                        }
                        .tint(neon.accent)
                }
                .appearanceColorScheme()
            }
        }

        private var content: some View {
            ZStack {
                GlassAppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        headerCard
                        whatChangedSection
                        fileStatsSection
                        commandsSection
                        durationTokensSection
                        actionRow
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
            }
        }

        // MARK: Derived recap model

        private var recap: Recap { Recap(session: session, store: store) }

        // MARK: Header

        private var headerCard: some View {
            let agent = recap.assistant
            let tint = neon.agentTint(forAgent: agent)
            return HStack(spacing: 12) {
                avatarTile(tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(recap.displayName)
                        .font(neon.sans(17).weight(.bold))
                        .foregroundStyle(neon.text)
                        .neonTextGlow(neon.textGlow)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(agent.lowercased())
                            .font(neon.mono(11.5).weight(.semibold))
                            .foregroundStyle(tint)
                        if let branch = session.branch, !branch.isEmpty {
                            Text("·").font(neon.mono(11.5)).foregroundStyle(neon.textFaint)
                            Text(branch)
                                .font(neon.mono(11.5))
                                .foregroundStyle(neon.textDim)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    outcomeChip
                    if recap.linesAdded > 0 || recap.linesRemoved > 0 {
                        HStack(spacing: 6) {
                            Text("+\(recap.linesAdded)")
                                .font(neon.mono(11).weight(.semibold))
                                .foregroundStyle(neon.green)
                            Text("−\(recap.linesRemoved)")
                                .font(neon.mono(11).weight(.semibold))
                                .foregroundStyle(neon.red)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: neon.radius - 4)
        }

        private func avatarTile(_ tint: Color) -> some View {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(neon.dark ? 0.14 : 0.10))
                .frame(width: 46, height: 46)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(tint.opacity(0.35), lineWidth: 1)
                )
                .overlay(ConduitUI.ConduitMark(size: 26, color: tint, glow: neon.glow))
                .neonGlowBox(neon.glow ? neon.glowBox?.tinted(tint) : nil)
        }

        private var outcomeChip: some View {
            let o = recap.outcome
            return HStack(spacing: 5) {
                Image(systemName: o.systemImage)
                    .font(.system(size: 9, weight: .bold))
                Text(o.label)
                    .font(neon.mono(10.5).weight(.semibold))
            }
            .foregroundStyle(o.color(neon))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(o.color(neon).opacity(0.12))
                    .overlay(Capsule().strokeBorder(o.color(neon).opacity(0.3), lineWidth: 1))
            )
        }

        // MARK: What changed

        @ViewBuilder
        private var whatChangedSection: some View {
            let bullets = recap.whatChanged
            if !bullets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    eyebrow("What changed")
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(bullets.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                Circle()
                                    .fill(neon.green)
                                    .frame(width: 5, height: 5)
                                    .neonGlowBox(neon.glow ? neon.glowBox?.tinted(neon.green) : nil)
                                    .padding(.top, 5)
                                Text(line)
                                    .font(neon.sans(13.5))
                                    .foregroundStyle(neon.text)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .neonCardSurface(neon, fill: neon.surface, cornerRadius: neon.radius - 4)
                }
            }
        }

        // MARK: File stats

        @ViewBuilder
        private var fileStatsSection: some View {
            if recap.filesChanged > 0 || recap.linesAdded > 0 || recap.linesRemoved > 0 {
                HStack(spacing: 12) {
                    statTile(value: "\(recap.filesChanged)", label: "files", tint: neon.text)
                    statTile(value: "+\(recap.linesAdded)", label: "added", tint: neon.green)
                    statTile(value: "−\(recap.linesRemoved)", label: "removed", tint: neon.red)
                }
            }
        }

        private func statTile(value: String, label: String, tint: Color) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(neon.mono(20).weight(.bold))
                    .foregroundStyle(tint)
                    .neonTextGlow(neon.textGlow)
                Text(label)
                    .font(neon.mono(10.5))
                    .foregroundStyle(neon.textDim)
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
        }

        // MARK: Commands run

        @ViewBuilder
        private var commandsSection: some View {
            let cmds = recap.commands
            if !cmds.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    eyebrow("Commands run")
                    VStack(spacing: 8) {
                        ForEach(Array(cmds.enumerated()), id: \.offset) { _, cmd in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("$")
                                    .font(neon.mono(12).weight(.semibold))
                                    .foregroundStyle(neon.accent)
                                Text(cmd)
                                    .font(neon.mono(12))
                                    .foregroundStyle(neon.text)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 12)
                        }
                    }
                }
            }
        }

        // MARK: Duration / tokens

        @ViewBuilder
        private var durationTokensSection: some View {
            let duration = recap.durationLabel
            let tokens = recap.totalTokens
            if duration != nil || tokens > 0 {
                VStack(spacing: 0) {
                    if let duration {
                        recapRow(
                            title: "Duration",
                            value: duration,
                            caption: recap.turnsCount > 0 ? "\(recap.turnsCount) turns" : nil
                        )
                    }
                    if duration != nil && tokens > 0 {
                        Rectangle().fill(neon.border).frame(height: 1)
                    }
                    if tokens > 0 {
                        recapRow(
                            title: "Tokens",
                            value: Self.fmtK(tokens),
                            caption: recap.tokenBreakdown
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: neon.radius - 4)
            }
        }

        private func recapRow(title: String, value: String, caption: String?) -> some View {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(neon.sans(14).weight(.semibold))
                    .foregroundStyle(neon.text)
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(value)
                        .font(neon.mono(15).weight(.bold))
                        .foregroundStyle(neon.text)
                    if let caption {
                        Text(caption)
                            .font(neon.mono(10.5))
                            .foregroundStyle(neon.textFaint)
                    }
                }
            }
            .padding(.vertical, 12)
        }

        // MARK: Actions

        private var actionRow: some View {
            HStack(spacing: 10) {
                ShareLink(item: recap.markdown) {
                    actionPillBody(systemImage: "square.and.arrow.up", label: "Export markdown", tint: neon.green)
                }
                .buttonStyle(.plain)
                // No real shareable URL exists in the stack, so "Share link"
                // shares the SAME markdown text rather than faking a URL.
                // Labelled "Share text" to stay honest.
                ShareLink(item: recap.markdown) {
                    actionPillBody(systemImage: "link", label: "Share text", tint: neon.accent)
                }
                .buttonStyle(.plain)
            }
        }

        private func actionPillBody(systemImage: String, label: String, tint: Color) -> some View {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                Text(label)
                    .font(neon.sans(13).weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .neonCardSurface(
                neon,
                fill: neon.surface,
                cornerRadius: 13,
                border: tint.opacity(0.4),
                glowTint: neon.glow ? tint : nil
            )
        }

        // MARK: Helpers

        private func eyebrow(_ text: String) -> some View {
            Text(text)
                .font(neon.mono(11).weight(.bold))
                .foregroundStyle(neon.textDim)
                .textCase(.uppercase)
                .tracking(0.8)
        }

        static func fmtK(_ n: UInt64) -> String {
            if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
            if n >= 1_000 { return "\(Int((Double(n) / 1_000).rounded()))k" }
            return "\(n)"
        }
    }

    // MARK: - Recap outcome

    /// The single header outcome chip. Derived honestly from PR state +
    /// lifecycle: a real PR (open/merged) wins, then a terminal lifecycle
    /// (ended/failed), then a neutral "in progress" / "session" when there
    /// is no signal — never a fabricated success.
    enum RecapOutcome {
        case merged
        case pr
        case ended
        case failed
        case neutral

        var label: String {
            switch self {
            case .merged:  return "merged"
            case .pr:      return "PR open"
            case .ended:   return "ended"
            case .failed:  return "failed"
            case .neutral: return "session"
            }
        }

        var systemImage: String {
            switch self {
            case .merged:  return "checkmark.seal.fill"
            case .pr:      return "arrow.triangle.pull"
            case .ended:   return "stop.circle"
            case .failed:  return "exclamationmark.triangle"
            case .neutral: return "circle"
            }
        }

        func color(_ neon: NeonTheme) -> Color {
            switch self {
            case .merged:  return neon.purple
            case .pr:      return neon.green
            case .ended:   return neon.textDim
            case .failed:  return neon.red
            case .neutral: return neon.textDim
            }
        }
    }

    // MARK: - Recap data

    /// Pure-ish derivation of every recap section from the live store +
    /// `ProjectSession`. Mirrors the Session Info snapshot idioms (status
    /// delta preferred over the session snapshot; `fmtK`; wall-clock
    /// duration) without touching SessionInfoView.
    struct Recap {
        let displayName: String
        let assistant: String
        let outcome: RecapOutcome
        let linesAdded: Int
        let linesRemoved: Int
        let filesChanged: Int
        let commits: Int
        let prNumber: Int?
        let prState: String?
        let whatChanged: [String]
        let commands: [String]
        let turnsCount: Int
        let durationLabel: String?
        let totalTokens: UInt64
        let tokenBreakdown: String?
        let branch: String?
        let cwd: String?
        let startedLabel: String?

        @MainActor
        init(session: ProjectSession, store: SessionStore) {
            let status = store.statusBySession[session.id]
            let log = store.conversationLog[session.id] ?? []

            self.displayName = store.displayName(for: session)
            self.assistant = status?.assistant ?? session.assistant
            self.branch = session.branch
            self.cwd = status?.cwd ?? session.cwd

            let added = Int(status?.linesAdded ?? session.linesAdded ?? 0)
            let removed = Int(status?.linesRemoved ?? session.linesRemoved ?? 0)
            self.linesAdded = added
            self.linesRemoved = removed
            self.commits = Int(status?.commits ?? session.commits ?? 0)
            let pr = (status?.prNumber ?? session.prNumber).map { Int($0) }
            self.prNumber = pr
            let prSt = status?.prState ?? session.prState
            self.prState = prSt

            // Distinct changed file paths from the conversation log.
            let filePaths = Recap.distinctFiles(log)
            self.filesChanged = filePaths.count

            // Outcome — PR wins, then terminal lifecycle, then neutral.
            self.outcome = Recap.deriveOutcome(
                prNumber: pr, prState: prSt,
                lifecycle: store.sessionLifecycle[session.id]
            )

            // What changed — HONEST derivation in priority order.
            self.whatChanged = Recap.deriveWhatChanged(
                log: log,
                displayName: store.displayName(for: session),
                filePaths: filePaths,
                commits: Int(status?.commits ?? session.commits ?? 0)
            )

            // Commands — recent real `command` fields (most-recent last,
            // capped so the card stays compact).
            let allCommands = log.compactMap { item -> String? in
                guard let c = item.command?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !c.isEmpty else { return nil }
                return c
            }
            self.commands = Array(allCommands.suffix(6))

            self.turnsCount = log.filter { $0.role.lowercased() == "user" }.count

            // Duration — wall-clock started → last activity (Session Info idiom).
            let started = Recap.parseISO(status?.startedAt ?? session.startedAt)
            let last = Recap.parseISO(status?.lastActivityAt ?? session.lastActivityAt) ?? started
            if let started, let last {
                let secs = max(0, last.timeIntervalSince(started))
                if secs >= 3600 {
                    self.durationLabel = "\(Int(secs) / 3600)h \((Int(secs) % 3600) / 60)m"
                } else if secs >= 60 {
                    self.durationLabel = "\(Int(secs) / 60)m"
                } else if secs > 0 {
                    self.durationLabel = "\(Int(secs))s"
                } else {
                    self.durationLabel = nil
                }
            } else {
                self.durationLabel = nil
            }

            if let started {
                let f = DateFormatter()
                f.timeStyle = .short
                f.dateStyle = Calendar.current.isDateInToday(started) ? .none : .short
                self.startedLabel = f.string(from: started)
            } else {
                self.startedLabel = nil
            }

            // Tokens.
            let input = status?.totalInputTokens ?? session.totalInputTokens ?? 0
            let output = status?.totalOutputTokens ?? session.totalOutputTokens ?? 0
            let cached = status?.totalCachedTokens ?? session.totalCachedTokens ?? 0
            self.totalTokens = input + output
            if input > 0 || output > 0 {
                self.tokenBreakdown = "↓ \(ConduitUI.SessionRecapView.fmtK(input)) ↑ \(ConduitUI.SessionRecapView.fmtK(output)) ⛁ \(ConduitUI.SessionRecapView.fmtK(cached))"
            } else {
                self.tokenBreakdown = nil
            }
        }

        // MARK: Markdown export

        var markdown: String {
            var lines: [String] = []
            lines.append("# \(displayName)")
            var ident = assistant.lowercased()
            if let branch, !branch.isEmpty { ident += " · \(branch)" }
            lines.append(ident)
            lines.append("")
            lines.append("**Outcome:** \(outcome.label)")
            if let prNumber {
                lines.append("**PR:** #\(prNumber)\(prState.map { " \($0)" } ?? "")")
            }
            lines.append("")

            if !whatChanged.isEmpty {
                lines.append("## What changed")
                for b in whatChanged { lines.append("- \(b)") }
                lines.append("")
            }

            if filesChanged > 0 || linesAdded > 0 || linesRemoved > 0 {
                lines.append("## File stats")
                lines.append("- \(filesChanged) files · +\(linesAdded) −\(linesRemoved)")
                if commits > 0 { lines.append("- \(commits) commit\(commits == 1 ? "" : "s")") }
                lines.append("")
            }

            if !commands.isEmpty {
                lines.append("## Commands run")
                lines.append("```")
                for c in commands { lines.append("$ \(c)") }
                lines.append("```")
                lines.append("")
            }

            var meta: [String] = []
            if let durationLabel { meta.append("- Duration: \(durationLabel)") }
            if turnsCount > 0 { meta.append("- Turns: \(turnsCount)") }
            if totalTokens > 0 {
                var t = "- Tokens: \(ConduitUI.SessionRecapView.fmtK(totalTokens))"
                if let tokenBreakdown { t += " (\(tokenBreakdown))" }
                meta.append(t)
            }
            if let cwd, !cwd.isEmpty { meta.append("- Working dir: \(cwd)") }
            if let startedLabel { meta.append("- Started: \(startedLabel)") }
            if !meta.isEmpty {
                lines.append("## Session")
                lines.append(contentsOf: meta)
            }

            return lines.joined(separator: "\n")
        }

        // MARK: Derivation helpers (pure / testable)

        static func deriveOutcome(prNumber: Int?, prState: String?, lifecycle: SessionLifecycle?) -> RecapOutcome {
            if let prState = prState?.lowercased() {
                if prState == "merged" { return .merged }
                if prState == "open" || prState == "draft" { return .pr }
            }
            if (prNumber ?? 0) > 0 { return .pr }
            switch lifecycle {
            case .failed: return .failed
            case .exited: return .ended
            default:      return .neutral
            }
        }

        /// Distinct changed-file paths in conversation order.
        static func distinctFiles(_ log: [ConversationItem]) -> [String] {
            var seen = Set<String>()
            var ordered: [String] = []
            for item in log {
                for f in item.files where !f.path.isEmpty {
                    if seen.insert(f.path).inserted { ordered.append(f.path) }
                }
            }
            return ordered
        }

        /// HONEST "what changed" bullets. Priority:
        ///   1. The agent's own summaries from the log (resultSummary /
        ///      taskText / diffSummary) — real prose the agent emitted.
        ///   2. Otherwise the distinct changed-file paths (capped).
        ///   3. Otherwise a single commit-count line.
        /// Returns [] when there is no signal at all (caller hides the
        /// section) — we never fabricate change descriptions.
        static func deriveWhatChanged(
            log: [ConversationItem],
            displayName: String,
            filePaths: [String],
            commits: Int
        ) -> [String] {
            var bullets: [String] = []
            var seen = Set<String>()
            func add(_ raw: String?) {
                guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return }
                // First line only — these can be multi-paragraph.
                let first = s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? s
                let trimmed = first.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
                bullets.append(trimmed)
            }
            for item in log {
                add(item.resultSummary)
                add(item.diffSummary)
            }
            // Fall back to task text only if no summaries surfaced.
            if bullets.isEmpty {
                for item in log { add(item.taskText) }
            }
            if !bullets.isEmpty { return Array(bullets.prefix(6)) }

            // No agent prose — list real changed files instead.
            if !filePaths.isEmpty {
                return Array(filePaths.prefix(8))
            }
            // Last resort: a single honest commit-count line.
            if commits > 0 {
                return ["\(commits) commit\(commits == 1 ? "" : "s") landed"]
            }
            return []
        }

        static func parseISO(_ s: String?) -> Date? {
            guard let s else { return nil }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        }
    }
}
