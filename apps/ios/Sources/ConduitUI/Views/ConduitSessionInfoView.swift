import SwiftUI

// MARK: - ConduitSessionInfoView
//
// Conduit-faithful session info screen. Hero (status dot + display name
// + agent chip), action row (appearance / fork / rename), stats grid
// (six metrics in a 2-col LazyVGrid), and a small server-info card.
// All rows + cards are ConduitGlass surfaces; the stats are big mono
// values matching upstream's number-forward stat treatment.

extension ConduitUI {

    struct SessionInfoView: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss
        @Environment(\.colorScheme) private var colorScheme

        let session: ProjectSession
        /// Hosted inline as the tablet Sessions right pane (not a sheet) →
        /// drop the "Done" affordance.
        var embedded: Bool = false

        @State private var showRename = false
        @State private var showAppearance = false
        @State private var showFork = false

        var body: some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            hero
                            actionRow
                            statsGrid
                            ConduitUI.UsageCard(session: session)
                            // Account usage (5-hour + weekly) comes from the
                            // Claude OAuth usage endpoint; codex/other agents
                            // have no equivalent, so the card would show
                            // "tap refresh to update" forever. Gate to claude.
                            if (store.statusBySession[session.id]?.assistant ?? session.assistant) == "claude" {
                                ConduitUI.AccountUsageCard(session: session)
                            }
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
                    if !embedded {
                        ToolbarItem(placement: .confirmationAction) {
                            // Plain Button per PLAN-CONDUIT-VISUAL-PARITY
                            // audit §A.3.5 — drop the explicit brand
                            // overlay; the navigation `.tint(...)` below
                            // already paints the link in the accent.
                            Button("Done") { dismiss() }
                        }
                    }
                }
                .tint(neon.accent)
                .sheet(isPresented: $showRename) {
                    ConduitUI.RenameSessionSheet(
                        session: session,
                        initialDraft: store.displayName(for: session)
                    )
                }
                .sheet(isPresented: $showAppearance) {
                    ConduitUI.AppearanceSheet()
                }
                .sheet(isPresented: $showFork) {
                    ConduitUI.ForkSheet(
                        session: session,
                        currentEffort: store.statusBySession[session.id]?.reasoningEffort ?? session.reasoningEffort
                    )
                }
            }
            // This screen is itself presented as a sheet (own
            // UIHostingController), so re-bind \.colorScheme + re-resolve
            // \.neonTheme here too — otherwise a Dark↔Light swap made
            // from the Appearance sub-sheet leaves this screen half-stale
            // until it's closed + reopened (device bug, Neon UI).
            .appearanceColorScheme()
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

        private var hero: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(neon.green)
                        .frame(width: 10, height: 10)
                        .neonGlowBox(neon.glow ? neon.glowBox?.tinted(neon.green) : nil)
                    Text(store.displayName(for: session))
                        .font(neon.sans(22).weight(.bold))
                        .foregroundStyle(neon.text)
                        .neonTextGlow(neon.textGlow)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    NeonAgentChip(label: session.assistant, tint: neon.agentTint(forAgent: session.assistant))
                    if let effort = session.reasoningEffort {
                        NeonAgentChip(label: effort, tint: neon.textDim)
                    }
                }
                if let cwd = session.cwd {
                    Text(cwd)
                        .font(neon.mono(11))
                        .foregroundStyle(neon.textFaint)
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
                        .foregroundStyle(neon.accent)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(neon.surface))
                        .overlay(Circle().stroke(neon.borderStrong, lineWidth: 1))
                        .neonGlowBox(neon.glow ? neon.glowBox : nil)
                    Text(label)
                        .font(neon.sans(11).weight(.semibold))
                        .foregroundStyle(neon.text)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }

        private var statsGrid: some View {
            let stats = ConduitUI.SessionInfoViewModel.stats(snapshot)
            return LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(stats) { stat in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stat.value)
                            .font(ConduitUI.Typography.statBig)
                            .foregroundStyle(neon.accent)
                            .neonTextGlow(neon.textGlow)
                        Text(stat.title)
                            .font(neon.mono(11).weight(.semibold))
                            .foregroundStyle(neon.textDim)
                            .textCase(.uppercase)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
                }
            }
        }

        private var detailsCard: some View {
            let details = ConduitUI.SessionInfoViewModel.details(snapshot)
            return Group {
                if !details.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Details")
                            .font(neon.mono(11).weight(.bold))
                            .foregroundStyle(neon.textDim)
                            .textCase(.uppercase)
                            .padding(.bottom, 8)
                        ForEach(Array(details.enumerated()), id: \.element.id) { index, detail in
                            detailRow(detail)
                            if index < details.count - 1 {
                                Divider()
                                    .background(neon.border)
                                    .padding(.vertical, 8)
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
                }
            }
        }

        private func detailRow(_ detail: ConduitUI.SessionInfoDetail) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(detail.label)
                    .font(neon.sans(13).weight(.semibold))
                    .foregroundStyle(neon.textDim)
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(detail.value)
                        .font(neon.sans(13).weight(.semibold))
                        .foregroundStyle(neon.text)
                        .multilineTextAlignment(.trailing)
                    if let caption = detail.caption {
                        Text(caption)
                            .font(neon.mono(11))
                            .foregroundStyle(neon.textFaint)
                    }
                }
            }
        }

        private var serverCard: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("Server")
                    .font(neon.mono(11).weight(.bold))
                    .foregroundStyle(neon.textDim)
                    .textCase(.uppercase)
                Text(store.endpoint.isComplete ? store.endpoint.displayHost : "—")
                    .font(neon.sans(14).weight(.semibold))
                    .foregroundStyle(neon.text)
                Text(store.harness.badgeLabel)
                    .font(neon.mono(11))
                    .foregroundStyle(neon.textFaint)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
        }
    }
}
