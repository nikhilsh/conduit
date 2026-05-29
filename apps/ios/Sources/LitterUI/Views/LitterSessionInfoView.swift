import SwiftUI

// MARK: - LitterSessionInfoView
//
// Litter-faithful session info screen. Hero (status dot + display name
// + agent chip), action row (appearance / fork / rename), stats grid
// (six metrics in a 2-col LazyVGrid), and a small server-info card.
// All rows + cards are LitterGlass surfaces; the stats are big mono
// values matching litter's number-forward stat treatment.

extension LitterUI {

    struct SessionInfoView: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.dismiss) private var dismiss
        @Environment(\.colorScheme) private var colorScheme

        let session: ProjectSession

        @State private var showRename = false
        @State private var showAppearance = false
        @State private var showFork = false

        var body: some View {
            NavigationStack {
                ZStack {
                    LitterUI.Palette.surface.color.ignoresSafeArea()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            hero
                            actionRow
                            statsGrid
                            usageCard
                            detailsCard
                            serverCard
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                    }
                }
                .navigationTitle("Session")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        // Plain Button per PLAN-LITTER-VISUAL-PARITY
                        // audit §A.3.5 — drop the explicit brand
                        // overlay; the navigation `.tint(...)` below
                        // already paints the link in the accent.
                        Button("Done") { dismiss() }
                    }
                }
                .tint(LitterUI.Palette.brand.color)
                .sheet(isPresented: $showRename) {
                    LitterUI.RenameSessionSheet(
                        session: session,
                        initialDraft: store.displayName(for: session)
                    )
                }
                .sheet(isPresented: $showAppearance) {
                    LitterUI.AppearanceSheet()
                }
                .sheet(isPresented: $showFork) {
                    LitterUI.ForkSheet(
                        session: session,
                        currentEffort: store.statusBySession[session.id]?.reasoningEffort ?? session.reasoningEffort
                    )
                }
            }
        }

        private var snapshot: SessionInfoSnapshot {
            // Derive whatever we can from the conversation log. The
            // rest (turns/commands/files/MCP/exec) is best-effort
            // counted from `ConversationItem` rows by inspecting kind
            // and toolName.
            let log = store.conversationLog[session.id] ?? []
            let turns = log.filter { $0.role.lowercased() == "user" }.count
            let commands = log.filter { ($0.command?.isEmpty == false) }.count
            let mcp = log.filter { ($0.toolName ?? "").lowercased().contains("mcp") }.count
            let files = Set(log.flatMap { $0.files.map { $0.path } }).count
            let exec = Int(log.compactMap { $0.durationMs }.reduce(0, +))
            // Prefer the live `SessionStatus` for the agent/timestamps —
            // it's refreshed by broker deltas, whereas the `ProjectSession`
            // is a snapshot from when the row was last materialized. Fall
            // back to the session fields when no status delta has landed.
            let status = store.statusBySession[session.id]
            return LitterUI.SessionInfoSnapshot(
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

        private var hero: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(LitterUI.Palette.success.color)
                        .frame(width: 10, height: 10)
                    Text(store.displayName(for: session))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(LitterUI.Palette.textPrimary.color)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    LitterUI.Chip(label: session.assistant, tint: SweKittyTheme.accent(forAgent: session.assistant))
                    if let effort = session.reasoningEffort {
                        LitterUI.Chip(label: effort)
                    }
                }
                if let cwd = session.cwd {
                    Text(cwd)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LitterUI.Palette.textMuted.color)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }

        private var actionRow: some View {
            HStack(spacing: 12) {
                actionButton(systemImage: "paintbrush.fill", label: "Appearance") {
                    showAppearance = true
                }
                actionButton(systemImage: "arrow.triangle.branch", label: "Fork") {
                    showFork = true
                }
                actionButton(systemImage: "pencil", label: "Rename") {
                    showRename = true
                }
            }
        }

        private func actionButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                VStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(LitterUI.Palette.brand.color)
                        .frame(width: 44, height: 44)
                        .litterGlassCircle(tint: LitterUI.Palette.surfaceLight.color, config: .floating)
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LitterUI.Palette.textPrimary.color)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }

        private var statsGrid: some View {
            let stats = LitterUI.SessionInfoViewModel.stats(snapshot)
            return LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(stats) { stat in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stat.value)
                            .font(LitterUI.Typography.statBig)
                            .foregroundStyle(LitterUI.Palette.brand.color)
                        Text(stat.title)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(LitterUI.Palette.textSecondary.color)
                            .textCase(.uppercase)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .litterGlassRoundedRect(cornerRadius: 14, config: .card)
                }
            }
        }

        // Per-session token/cost usage + a context-window gauge, sourced
        // from the live SessionStatus (broker-accumulated). Cost + the
        // context bar are claude-only (codex reports neither); the card
        // hides entirely until a turn has reported usage.
        @ViewBuilder private var usageCard: some View {
            let status = store.statusBySession[session.id]
            let input = status?.totalInputTokens ?? 0
            let output = status?.totalOutputTokens ?? 0
            let cached = status?.totalCachedTokens ?? 0
            if input > 0 || output > 0 {
                LitterUI.Card {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Usage & Context")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(LitterUI.Palette.textSecondary.color)
                            .textCase(.uppercase)
                            .padding(.bottom, 8)
                        usageRow("Input", Self.formatTokens(input))
                        usageDivider
                        usageRow("Output", Self.formatTokens(output))
                        if cached > 0 {
                            usageDivider
                            usageRow("Cached", Self.formatTokens(cached))
                        }
                        if let cost = status?.totalCostUsd, cost > 0 {
                            usageDivider
                            usageRow("Cost", String(format: "$%.4f", cost))
                        }
                        if let used = status?.contextUsedTokens,
                           let window = status?.contextWindowTokens, window > 0 {
                            usageDivider
                            contextGauge(used: used, window: window)
                        }
                    }
                }
            }
        }

        private var usageDivider: some View {
            Divider()
                .background(LitterUI.Palette.separator.color)
                .padding(.vertical, 8)
        }

        private func usageRow(_ label: String, _ value: String) -> some View {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LitterUI.Palette.textSecondary.color)
                Spacer(minLength: 12)
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LitterUI.Palette.textPrimary.color)
            }
        }

        private func contextGauge(used: UInt64, window: UInt64) -> some View {
            let pct = min(1.0, Double(used) / Double(window))
            return VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Context")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LitterUI.Palette.textSecondary.color)
                    Spacer(minLength: 12)
                    Text("\(Self.formatTokens(used)) / \(Self.formatTokens(window)) · \(Int(pct * 100))%")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LitterUI.Palette.textPrimary.color)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(LitterUI.Palette.separator.color)
                        Capsule().fill(LitterUI.Palette.brand.color)
                            .frame(width: max(2, geo.size.width * pct))
                    }
                }
                .frame(height: 6)
            }
        }

        static func formatTokens(_ n: UInt64) -> String {
            if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
            if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
            return "\(n)"
        }

        private var detailsCard: some View {
            let details = LitterUI.SessionInfoViewModel.details(snapshot)
            return Group {
                if !details.isEmpty {
                    LitterUI.Card {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Details")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(LitterUI.Palette.textSecondary.color)
                                .textCase(.uppercase)
                                .padding(.bottom, 8)
                            ForEach(Array(details.enumerated()), id: \.element.id) { index, detail in
                                detailRow(detail)
                                if index < details.count - 1 {
                                    Divider()
                                        .background(LitterUI.Palette.separator.color)
                                        .padding(.vertical, 8)
                                }
                            }
                        }
                    }
                }
            }
        }

        private func detailRow(_ detail: LitterUI.SessionInfoDetail) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(detail.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LitterUI.Palette.textSecondary.color)
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(detail.value)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LitterUI.Palette.textPrimary.color)
                        .multilineTextAlignment(.trailing)
                    if let caption = detail.caption {
                        Text(caption)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(LitterUI.Palette.textMuted.color)
                    }
                }
            }
        }

        private var serverCard: some View {
            LitterUI.Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Server")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(LitterUI.Palette.textSecondary.color)
                        .textCase(.uppercase)
                    Text(store.endpoint.isComplete ? store.endpoint.displayHost : "—")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LitterUI.Palette.textPrimary.color)
                    Text(store.harness.badgeLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LitterUI.Palette.textMuted.color)
                }
            }
        }
    }
}
