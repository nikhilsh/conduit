import SwiftUI

// MARK: - ConduitSessionInfoView
//
// Conduit redesign Session Info sheet (handoff §A.1, images 01/02).
// Replaces the old 2×3 grid of stat cards — which read as a wall of
// `0 / —` boxes on a fresh session — with a top-to-bottom IA:
//
//   1. Identity   — agent avatar, real session name (inline rename),
//                   `agent · branch`, live/idle badge.
//   2. Usage      — one block: context ring, `used / window`, the agent
//                   line, and a single mono token line (↓ in ↑ out ⛁ cache).
//   3. Limits     — this session's agent only, 5h + weekly windows.
//   4. Activity   — one compact line; degrades to "Just started …" on a
//                   fresh session instead of a grid of zeros.
//   5. Details    — hairline rows: working dir, box, started.
//   6. Actions    — Fork · Export · End (End is destructive/red).
//
// Per-box quota is never shown here (limits are account-level). All
// surfaces are NeonTheme cards so they read in the active ice palette.

extension ConduitUI {

    struct SessionInfoView: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss
        @Environment(\.colorScheme) private var colorScheme

        let session: ProjectSession
        /// Hosted inline as the tablet Sessions right pane (not a sheet) →
        /// drop the close affordance + the outer NavigationStack chrome.
        var embedded: Bool = false

        @State private var showRename = false
        @State private var showFork = false
        @State private var showEndConfirm = false

        var body: some View {
            if embedded {
                content
            } else {
                NavigationStack {
                    content
                        .navigationTitle("Session Info")
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
                // Presented as its own sheet (own UIHostingController), so
                // re-bind \.colorScheme + re-resolve \.neonTheme here too —
                // otherwise a Dark↔Light swap from a sub-sheet leaves this
                // screen half-stale until reopened (device bug, Neon UI).
                .appearanceColorScheme()
            }
        }

        private var content: some View {
            ZStack {
                GlassAppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        identityCard
                        usageSection
                        limitsSection
                        activitySection
                        detailsSection
                        actionRow
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
            }
            .sheet(isPresented: $showRename) {
                ConduitUI.RenameSessionSheet(
                    session: session,
                    initialDraft: store.displayName(for: session)
                )
            }
            .sheet(isPresented: $showFork) {
                ConduitUI.ForkSheet(
                    session: session,
                    currentEffort: store.statusBySession[session.id]?.reasoningEffort ?? session.reasoningEffort
                )
            }
            .confirmationDialog(
                "End this session?",
                isPresented: $showEndConfirm,
                titleVisibility: .visible
            ) {
                Button("End session", role: .destructive) {
                    store.archive(sessionID: session.id)
                    if !embedded { dismiss() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The agent stops and the box is released. The transcript stays in History.")
            }
        }

        // MARK: Derived

        private var liveAssistant: String {
            store.statusBySession[session.id]?.assistant ?? session.assistant
        }

        private var snapshot: SessionInfoSnapshot {
            let log = store.conversationLog[session.id] ?? []
            let turns = log.filter { $0.role.lowercased() == "user" }.count
            let commands = log.filter { ($0.command?.isEmpty == false) }.count
            let mcp = log.filter { ($0.toolName ?? "").lowercased().contains("mcp") }.count
            let files = Set(log.flatMap { $0.files.map { $0.path } }).count
            let exec = Int(log.compactMap { $0.durationMs }.reduce(0, +))
            let status = store.statusBySession[session.id]
            return ConduitUI.SessionInfoSnapshot(
                sessionID: session.id,
                displayName: store.displayName(for: session),
                assistant: status?.assistant ?? session.assistant,
                reasoningEffort: status?.reasoningEffort ?? session.reasoningEffort,
                cwd: status?.cwd ?? session.cwd,
                startedAt: status?.startedAt ?? session.startedAt,
                lastActivityAt: status?.lastActivityAt ?? session.lastActivityAt,
                messagesCount: log.count,
                turnsCount: turns,
                commandsCount: commands,
                filesChangedCount: files,
                mcpCallsCount: mcp,
                execTimeMs: exec
            )
        }

        // MARK: 1 · Identity

        private var identityCard: some View {
            let agent = liveAssistant
            let tint = neon.agentTint(forAgent: agent)
            return HStack(spacing: 12) {
                avatarTile(tint)
                VStack(alignment: .leading, spacing: 4) {
                    Button { showRename = true } label: {
                        HStack(spacing: 6) {
                            Text(store.displayName(for: session))
                                .font(neon.sans(17).weight(.bold))
                                .foregroundStyle(neon.text)
                                .neonTextGlow(neon.textGlow)
                                .lineLimit(1)
                            Image(systemName: "pencil")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(neon.textFaint)
                        }
                    }
                    .buttonStyle(.plain)
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
                statusBadge
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

        private var statusBadge: some View {
            let badge = lifecycleBadge
            return HStack(spacing: 5) {
                Circle()
                    .fill(badge.color)
                    .frame(width: 6, height: 6)
                    .neonGlowBox(neon.glow ? neon.glowBox?.tinted(badge.color) : nil)
                Text(badge.label)
                    .font(neon.mono(10.5).weight(.semibold))
                    .foregroundStyle(badge.color)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(badge.color.opacity(0.12))
                    .overlay(Capsule().strokeBorder(badge.color.opacity(0.3), lineWidth: 1))
            )
        }

        private var lifecycleBadge: (label: String, color: Color) {
            switch store.sessionLifecycle[session.id] {
            case .creating: return ("Starting", neon.yellow)
            case .live:     return ("Live", neon.green)
            case .exited:   return ("Ended", neon.textDim)
            case .failed:   return ("Failed", neon.red)
            case .none:     return store.harness.isReachable ? ("Live", neon.green) : ("Idle", neon.textDim)
            }
        }

        // MARK: 2 · Usage

        @ViewBuilder
        private var usageSection: some View {
            let status = store.statusBySession[session.id]
            let input = status?.totalInputTokens ?? session.totalInputTokens ?? 0
            let output = status?.totalOutputTokens ?? session.totalOutputTokens ?? 0
            let cached = status?.totalCachedTokens ?? session.totalCachedTokens ?? 0
            let used = status?.contextUsedTokens ?? session.contextUsedTokens ?? 0
            let window = status?.contextWindowTokens ?? session.contextWindowTokens ?? 0
            let cost = status?.totalCostUsd ?? session.totalCostUsd
            if window > 0 || input > 0 || output > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    eyebrow("Usage")
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 16) {
                            contextRing(used: used, window: window)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("CONTEXT")
                                    .font(neon.mono(10).weight(.semibold))
                                    .foregroundStyle(neon.textFaint)
                                    .tracking(1.2)
                                Text(window > 0 ? "\(Self.fmtK(used)) / \(Self.fmtK(window))" : Self.fmtK(used))
                                    .font(neon.mono(18).weight(.bold))
                                    .foregroundStyle(neon.text)
                                Text(modelLine)
                                    .font(neon.mono(11.5))
                                    .foregroundStyle(neon.textDim)
                            }
                            Spacer(minLength: 0)
                        }
                        Rectangle().fill(neon.border).frame(height: 1)
                        HStack(spacing: 18) {
                            Text("↓ \(Self.fmtK(input))")
                                .foregroundStyle(neon.blue)
                            Text("↑ \(Self.fmtK(output))")
                                .foregroundStyle(neon.green)
                            Text("⛁ \(Self.fmtK(cached))")
                                .foregroundStyle(neon.purple)
                            Spacer(minLength: 0)
                            if let cost, cost > 0 {
                                Text(String(format: "$%.2f", cost))
                                    .foregroundStyle(neon.textDim)
                            }
                        }
                        .font(neon.mono(12.5).weight(.medium))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .neonCardSurface(neon, fill: neon.surface, cornerRadius: neon.radius - 4)
                }
            }
        }

        private func contextRing(used: UInt64, window: UInt64) -> some View {
            let pct = window > 0 ? min(1.0, Double(used) / Double(window)) : 0
            return ZStack {
                Circle().stroke(neon.border, lineWidth: 9)
                Circle()
                    .trim(from: 0, to: pct)
                    .stroke(neon.accentBright, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .neonGlowBox(neon.glow ? neon.glowBox?.tinted(neon.accentBright) : nil)
                VStack(spacing: 0) {
                    Text("\(Int((pct * 100).rounded()))")
                        .font(neon.mono(22).weight(.bold))
                        .foregroundStyle(neon.text)
                        .neonTextGlow(neon.textGlow)
                    Text("%")
                        .font(neon.mono(10))
                        .foregroundStyle(neon.textFaint)
                }
            }
            .frame(width: 84, height: 84)
        }

        /// Honest stand-in for the design's model line: the broker doesn't
        /// report a model string, so show the agent + reasoning effort we
        /// do have rather than fabricating "sonnet-4.5".
        private var modelLine: String {
            let effort = store.statusBySession[session.id]?.reasoningEffort ?? session.reasoningEffort
            if let effort, !effort.isEmpty {
                return "\(liveAssistant.lowercased()) · \(effort)"
            }
            return liveAssistant.lowercased()
        }

        // MARK: 3 · Limits (this session's agent only)

        @ViewBuilder
        private var limitsSection: some View {
            // Claude maps from the Anthropic OAuth usage endpoint, codex
            // from ChatGPT /wham/usage; other agents have no source, so the
            // card would read "tap refresh" forever — gate to the two.
            let agent = liveAssistant.lowercased()
            if ["claude", "codex"].contains(agent) {
                ConduitUI.AccountUsageCard(
                    session: session,
                    heading: "\(agent) limits · 5h & weekly"
                )
            }
        }

        // MARK: 4 · Activity

        private var activitySection: some View {
            let s = snapshot
            let hasActivity = s.turnsCount > 0 || s.filesChangedCount > 0 || s.commandsCount > 0
            return VStack(alignment: .leading, spacing: 8) {
                eyebrow("Activity")
                HStack(spacing: 0) {
                    if hasActivity {
                        Text(activityText(s))
                            .font(neon.mono(12.5).weight(.medium))
                            .foregroundStyle(neon.text)
                    } else {
                        Text("Just started · no activity yet")
                            .font(neon.mono(12.5))
                            .foregroundStyle(neon.textFaint)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: neon.radius - 4)
            }
        }

        private func activityText(_ s: SessionInfoSnapshot) -> String {
            var parts: [String] = []
            if s.turnsCount > 0 { parts.append("\(s.turnsCount) turns") }
            if s.filesChangedCount > 0 { parts.append("\(s.filesChangedCount) files") }
            if s.commandsCount > 0 { parts.append("\(s.commandsCount) cmds") }
            if let dur = durationLabel(s) { parts.append(dur) }
            return parts.joined(separator: " · ")
        }

        // MARK: 5 · Details

        private var detailsSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                eyebrow("Details")
                VStack(spacing: 0) {
                    detailRow("Working dir", session.cwd ?? store.statusBySession[session.id]?.cwd ?? "—", mono: true)
                    hairline
                    detailRow("Box", boxLine, mono: true)
                    hairline
                    detailRow("Started", startedLabel, mono: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: neon.radius - 4)
            }
        }

        private var hairline: some View {
            Rectangle().fill(neon.border).frame(height: 1).padding(.vertical, 9)
        }

        private func detailRow(_ label: String, _ value: String, mono: Bool) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .font(neon.sans(13).weight(.semibold))
                    .foregroundStyle(neon.textDim)
                Spacer(minLength: 12)
                Text(value)
                    .font(mono ? neon.mono(12) : neon.sans(13).weight(.semibold))
                    .foregroundStyle(neon.text)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }

        /// `<host> · broker`. No round-trip latency is surfaced anywhere in
        /// the stack, so the design's "· 8ms" is intentionally omitted
        /// rather than faked.
        private var boxLine: String {
            store.endpoint.isComplete ? "\(store.endpoint.displayHost) · broker" : "—"
        }

        private var startedLabel: String {
            guard let iso = session.startedAt ?? store.statusBySession[session.id]?.startedAt,
                  let date = Self.parseISO(iso) else { return "—" }
            let f = DateFormatter()
            f.timeStyle = .short
            f.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
            return f.string(from: date)
        }

        // MARK: 6 · Actions

        private var actionRow: some View {
            HStack(spacing: 10) {
                actionPill(systemImage: "arrow.triangle.branch", label: "Fork", tint: neon.accent) {
                    showFork = true
                }
                ShareLink(item: exportMarkdown) {
                    actionPillBody(systemImage: "square.and.arrow.up", label: "Export", tint: neon.accent)
                }
                .buttonStyle(.plain)
                actionPill(systemImage: "stop.circle", label: "End", tint: neon.red) {
                    showEndConfirm = true
                }
            }
        }

        private func actionPill(systemImage: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                actionPillBody(systemImage: systemImage, label: label, tint: tint)
            }
            .buttonStyle(.plain)
        }

        private func actionPillBody(systemImage: String, label: String, tint: Color) -> some View {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                Text(label)
                    .font(neon.sans(13).weight(.semibold))
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

        private var exportMarkdown: String {
            let s = snapshot
            var lines: [String] = []
            lines.append("# \(s.displayName)")
            var ident = s.assistant.lowercased()
            if let branch = session.branch, !branch.isEmpty { ident += " · \(branch)" }
            lines.append(ident)
            lines.append("")
            let used = store.statusBySession[session.id]?.contextUsedTokens ?? session.contextUsedTokens ?? 0
            let window = store.statusBySession[session.id]?.contextWindowTokens ?? session.contextWindowTokens ?? 0
            if window > 0 { lines.append("- Context: \(Self.fmtK(used)) / \(Self.fmtK(window))") }
            let input = store.statusBySession[session.id]?.totalInputTokens ?? session.totalInputTokens ?? 0
            let output = store.statusBySession[session.id]?.totalOutputTokens ?? session.totalOutputTokens ?? 0
            let cached = store.statusBySession[session.id]?.totalCachedTokens ?? session.totalCachedTokens ?? 0
            if input > 0 || output > 0 {
                lines.append("- Tokens: ↓ \(Self.fmtK(input)) ↑ \(Self.fmtK(output)) ⛁ \(Self.fmtK(cached))")
            }
            if s.turnsCount > 0 || s.filesChangedCount > 0 || s.commandsCount > 0 {
                lines.append("- Activity: \(activityText(s))")
            }
            if let cwd = session.cwd { lines.append("- Working dir: \(cwd)") }
            lines.append("- Started: \(startedLabel)")
            return lines.joined(separator: "\n")
        }

        // MARK: Helpers

        private func eyebrow(_ text: String) -> some View {
            Text(text)
                .font(neon.mono(11).weight(.bold))
                .foregroundStyle(neon.textDim)
                .textCase(.uppercase)
                .tracking(0.8)
        }

        private func durationLabel(_ s: SessionInfoSnapshot) -> String? {
            // Prefer wall-clock (started → last activity); fall back to
            // summed exec time when timestamps are missing.
            if let start = s.startedAt.flatMap(Self.parseISO),
               let last = (s.lastActivityAt ?? s.startedAt).flatMap(Self.parseISO) {
                let secs = max(0, last.timeIntervalSince(start))
                if secs >= 60 { return "\(Int(secs) / 60)m" }
                if secs > 0 { return "\(Int(secs))s" }
            }
            let ms = s.execTimeMs
            guard ms > 0 else { return nil }
            let secs = ms / 1000
            return secs >= 60 ? "\(secs / 60)m" : "\(secs)s"
        }

        private static func parseISO(_ s: String) -> Date? {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        }

        static func fmtK(_ n: UInt64) -> String {
            if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
            if n >= 1_000 { return "\(Int((Double(n) / 1_000).rounded()))k" }
            return "\(n)"
        }
    }
}
