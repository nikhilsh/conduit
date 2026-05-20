import SwiftUI

/// Session "Info" screen — opened from the ⓘ button in the chat header.
/// Hero (status dot + name + agent pills + id/branch) → action row
/// (Appearance / Fork / Rename) → stats grid (Messages / Turns /
/// Commands / Files / MCP / Exec time).
struct SessionInfoView: View {
    @Environment(SessionStore.self) private var store
    @Environment(AppearanceStore.self) private var appearance
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let session: ProjectSession

    @State private var isRenaming = false
    @State private var renameDraft = ""
    @State private var showAppearance = false
    @State private var showForkConfirm = false

    var body: some View {
        NavigationStack {
            ZStack {
                SweKittyTheme.backgroundGradient(for: colorScheme)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        hero
                        actionRow
                        statsSection
                        if let serverUsage {
                            serverUsageCard(serverUsage)
                        }
                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Session")
            .navigationBarTitleDisplayMode(.inline)
            .tint(SweKittyTheme.accentStrong)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showAppearance) {
                AppearanceSheet()
                    .environment(appearance)
                    .presentationDetents([.medium, .large])
            }
            .alert("Rename session", isPresented: $isRenaming) {
                TextField("Display name", text: $renameDraft)
                Button("Save") {
                    store.renameSession(sessionID: session.id, to: renameDraft)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Choose a label for this session. The harness name stays the same — this rename is local to your device.")
            }
            .alert("Fork session", isPresented: $showForkConfirm) {
                Button("Fork", role: .none) {
                    store.forkSession(sessionID: session.id)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Creates a new session with the same agent and branch. The new session is seeded with a hand-off note pointing at this one.")
            }
        }
    }

    private var status: SessionStatus? { store.statusBySession[session.id] }
    private var events: [ConversationItem] { store.conversationLog[session.id] ?? [] }
    private var stats: SessionStats { SessionStats.compute(from: events) }

    /// Server-usage card placeholder. Real instrumentation lands later;
    /// for now we only show the card when there's something useful to
    /// say (`session.preview` is the only signal we already capture).
    private var serverUsage: PreviewInfo? { session.preview }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HealthDot(health: status?.health ?? "unknown", size: 12)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.displayName(for: session))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(SweKittyTheme.textPrimary)
                        .lineLimit(2)
                    if let phase = status?.phase, !phase.isEmpty {
                        Text(phase)
                            .font(.caption)
                            .foregroundStyle(SweKittyTheme.textSecondary)
                    }
                }
                Spacer()
            }
            HStack(spacing: 8) {
                AgentPill(label: session.assistant, tint: SweKittyTheme.accent(forAgent: session.assistant))
                if let branch = session.branch, !branch.isEmpty {
                    AgentPill(label: branch, tint: SweKittyTheme.surface.opacity(0.7))
                }
            }
            Text(session.id)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(SweKittyTheme.textMuted)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassRoundedRect()
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            ActionTile(
                icon: "paintpalette.fill",
                title: "Appearance",
                tint: SweKittyTheme.accentStrong
            ) {
                showAppearance = true
            }
            ActionTile(
                icon: "arrow.triangle.branch",
                title: "Fork",
                tint: SweKittyTheme.accentStrong
            ) {
                showForkConfirm = true
            }
            ActionTile(
                icon: "pencil",
                title: "Rename",
                tint: SweKittyTheme.accentStrong
            ) {
                renameDraft = store.displayName(for: session)
                isRenaming = true
            }
        }
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STATS")
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .tracking(0.9)
                .foregroundStyle(SweKittyTheme.textSecondary)
                .padding(.horizontal, 4)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
            ], spacing: 12) {
                StatTile(value: "\(stats.messages)", label: "MESSAGES")
                StatTile(value: "\(stats.turns)", label: "TURNS")
                StatTile(value: "\(stats.commands)", label: "COMMANDS")
                StatTile(value: "\(stats.filesChanged)", label: "FILES")
                StatTile(value: "\(stats.mcpCalls)", label: "MCP")
                StatTile(value: stats.execTimeLabel, label: "EXEC TIME")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .glassRoundedRect()
        }
    }

    private func serverUsageCard(_ preview: PreviewInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SERVER USAGE")
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .tracking(0.9)
                .foregroundStyle(SweKittyTheme.textSecondary)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "globe")
                        .foregroundStyle(SweKittyTheme.accentStrong)
                    Text("Preview")
                        .foregroundStyle(SweKittyTheme.textBody)
                    Spacer()
                    Text("port \(preview.port)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(SweKittyTheme.textSecondary)
                }
                Text(preview.url)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(SweKittyTheme.textMuted)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassRoundedRect()
        }
    }
}

// MARK: - Stats

struct SessionStats: Equatable {
    let messages: Int
    let turns: Int
    let commands: Int
    let filesChanged: Int
    let mcpCalls: Int
    let execTimeMs: UInt64

    var execTimeLabel: String {
        if execTimeMs == 0 { return "—" }
        let seconds = Double(execTimeMs) / 1000.0
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let mins = seconds / 60.0
        if mins < 60 { return String(format: "%.1fm", mins) }
        let hrs = mins / 60.0
        return String(format: "%.1fh", hrs)
    }

    static func compute(from events: [ConversationItem]) -> SessionStats {
        var turns = 0
        var commands = 0
        var mcp = 0
        var files = Set<String>()
        var execTime: UInt64 = 0

        for ev in events {
            if ev.role.lowercased() == "user" { turns += 1 }
            if ev.kind == "tool" {
                if let cmd = ev.command, !cmd.isEmpty { commands += 1 }
                if let tool = ev.toolName, tool.lowercased().contains("mcp") { mcp += 1 }
            }
            if let dur = ev.durationMs { execTime += dur }
            for f in ev.files { files.insert(f.path) }
        }

        return SessionStats(
            messages: events.count,
            turns: turns,
            commands: commands,
            filesChanged: files.count,
            mcpCalls: mcp,
            execTimeMs: execTime
        )
    }
}

// MARK: - Building blocks

private struct AgentPill: View {
    let label: String
    let tint: Color

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(SweKittyTheme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassCapsule(interactive: false, tint: tint.opacity(0.30))
    }
}

private struct ActionTile: View {
    let icon: String
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .glassRoundedRect()
        }
        .buttonStyle(.plain)
    }
}

private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title2, design: .monospaced).weight(.bold))
                .foregroundStyle(SweKittyTheme.accentStrong)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .tracking(0.7)
                .foregroundStyle(SweKittyTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}
