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

        var body: some View {
            NavigationStack {
                ZStack {
                    LitterUI.Palette.surface.color.ignoresSafeArea()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            hero
                            actionRow
                            statsGrid
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
            return LitterUI.SessionInfoSnapshot(
                sessionID: session.id,
                displayName: store.displayName(for: session),
                assistant: session.assistant,
                reasoningEffort: session.reasoningEffort,
                cwd: session.cwd,
                startedAt: session.startedAt,
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
                    // Appearance edits live in Settings for now.
                }
                actionButton(systemImage: "arrow.triangle.branch", label: "Fork") {
                    store.forkSession(sessionID: session.id)
                    dismiss()
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
