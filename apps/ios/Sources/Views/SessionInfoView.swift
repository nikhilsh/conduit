import Charts
import SwiftUI

/// Session "Info" screen — opened from the ⓘ button in the chat header.
/// Hero (status dot + name + agent/effort pills + folder/hash/time) →
/// action row (Appearance / Fork / Rename) → 2-column stats grid →
/// server-usage chart. Visual pass to match the Litter "Info" reference.
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
                        serverUsageSection
                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Info")
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

    // MARK: - Hero block

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                HealthDot(health: status?.health ?? "unknown", size: 10)
                Text(store.displayName(for: session))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(SweKittyTheme.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                AgentPill(
                    label: session.assistant,
                    tint: SweKittyTheme.accent(forAgent: session.assistant),
                    monospaced: true
                )
                // Reasoning effort pill — reads `session.reasoningEffort`
                // (populated by `ProjectSessionState.apply_status` from the
                // `reasoning_effort` field on the broker's status frame).
                // Falls back to "medium" when the harness hasn't emitted one.
                AgentPill(
                    label: reasoningEffortLabel,
                    tint: SweKittyTheme.surface.opacity(0.7),
                    monospaced: false
                )
                Spacer(minLength: 0)
            }

            // Folder row — `cwd` isn't exposed on ProjectSession yet, so
            // `session.name` is the best proxy (same fallback used by
            // ProjectView's path label).
            heroMetaRow(
                icon: "folder.fill",
                text: folderPath,
                font: .system(.caption, design: .monospaced)
            )

            // Hash row — full session id, selectable.
            heroMetaRow(
                icon: "number",
                text: session.id,
                font: .system(.caption2, design: .monospaced),
                selectable: true
            )

            // Time row — derived from the conversation timeline because
            // ProjectSession has no created/touched timestamps yet.
            if let timeLine {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(SweKittyTheme.textMuted)
                    Text(timeLine.created)
                        .font(.caption2)
                        .foregroundStyle(SweKittyTheme.textMuted)
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(SweKittyTheme.textMuted)
                        .padding(.leading, 4)
                    Text(timeLine.touched)
                        .font(.caption2)
                        .foregroundStyle(SweKittyTheme.textMuted)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassRoundedRect()
    }

    private func heroMetaRow(
        icon: String,
        text: String,
        font: Font,
        selectable: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(SweKittyTheme.textMuted)
            Group {
                if selectable {
                    Text(text).textSelection(.enabled)
                } else {
                    Text(text)
                }
            }
            .font(font)
            .foregroundStyle(SweKittyTheme.textMuted)
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    /// Reasoning effort surfaced by the harness status frame; falls
    /// back to "medium" when the harness hasn't emitted one yet.
    private var reasoningEffortLabel: String {
        if let raw = session.reasoningEffort?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            return raw
        }
        return "medium"
    }

    /// Real cwd from the harness; falls back to the session name (the
    /// workspace folder) when the harness hasn't emitted one yet.
    private var folderPath: String {
        if let cwd = session.cwd?.trimmingCharacters(in: .whitespaces), !cwd.isEmpty {
            return cwd
        }
        return session.name
    }

    private struct TimeLine { let created: String; let touched: String }

    private var timeLine: TimeLine? {
        // Prefer the authoritative timestamps from the harness status
        // frame; fall back to the first/last ConversationItem ts for
        // older builds that haven't shipped the new fields yet.
        let createdDate = session.startedAt.flatMap(Self.parseTimestamp)
            ?? events.first.flatMap { Self.parseTimestamp($0.ts) }
        let touchedDate = session.lastActivityAt.flatMap(Self.parseTimestamp)
            ?? events.last.flatMap { Self.parseTimestamp($0.ts) }
        guard let createdDate, let touchedDate else { return nil }
        let createdRel = Self.relativeFormatter.localizedString(for: createdDate, relativeTo: Date())
        let touchedRel = Self.relativeFormatter.localizedString(for: touchedDate, relativeTo: Date())
        return TimeLine(
            created: "created \(createdRel)",
            touched: "touched \(touchedRel)"
        )
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseTimestamp(_ s: String) -> Date? {
        if s.isEmpty { return nil }
        if let d = isoFormatter.date(from: s) { return d }
        if let d = isoFormatterNoFraction.date(from: s) { return d }
        return nil
    }

    // MARK: - Action tiles

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

    // MARK: - Stats

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Conversation Stats")
                .font(.title3.weight(.bold))
                .foregroundStyle(SweKittyTheme.textPrimary)
                .padding(.horizontal, 4)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
            ], spacing: 12) {
                StatTile(
                    value: "\(stats.messages)",
                    label: "Messages",
                    secondary: "\(stats.userMessages) user · \(stats.assistantMessages) assistant"
                )
                StatTile(value: "\(stats.turns)", label: "Turns", secondary: nil)
                StatTile(
                    value: "\(stats.commands)",
                    label: "Commands",
                    secondary: "\(stats.commandsOk) ok · \(stats.commandsFail) fail"
                )
                // ConversationItem doesn't track per-file additions/deletions
                // yet, so the secondary line is omitted for "Files Changed".
                StatTile(value: "\(stats.filesChanged)", label: "Files Changed", secondary: nil)
                StatTile(value: "\(stats.mcpCalls)", label: "MCP Calls", secondary: nil)
                StatTile(value: stats.execTimeLabel, label: "Exec Time", secondary: nil)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .glassRoundedRect()
        }
    }

    // MARK: - Server usage / token chart

    private var serverUsageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Server Usage")
                .font(.title3.weight(.bold))
                .foregroundStyle(SweKittyTheme.textPrimary)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 12) {
                Text("Token Usage by Conversation")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textSecondary)

                tokenChart
                    .frame(height: 140)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassRoundedRect()
        }
    }

    private var tokenSeries: [TokenPoint] {
        // No first-class token telemetry yet — approximate per-event token
        // count as `content.count / 4` (a rough char-to-token heuristic)
        // and chart the cumulative sum across the message index.
        var running = 0
        return events.enumerated().map { idx, ev in
            running += max(0, ev.content.count / 4)
            return TokenPoint(index: idx + 1, tokens: running)
        }
    }

    @ViewBuilder
    private var tokenChart: some View {
        let series = tokenSeries
        if series.isEmpty {
            Text("No conversation activity yet.")
                .font(.caption)
                .foregroundStyle(SweKittyTheme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Chart(series) { point in
                LineMark(
                    x: .value("Message", point.index),
                    y: .value("Tokens", point.tokens)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(SweKittyTheme.accentStrong)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(SweKittyTheme.border.opacity(0.4))
                    AxisValueLabel()
                        .foregroundStyle(SweKittyTheme.textMuted)
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(SweKittyTheme.border.opacity(0.4))
                    AxisValueLabel()
                        .foregroundStyle(SweKittyTheme.textMuted)
                }
            }
        }
    }
}

// MARK: - Token series

private struct TokenPoint: Identifiable {
    let index: Int
    let tokens: Int
    var id: Int { index }
}

// MARK: - Stats

struct SessionStats: Equatable {
    let messages: Int
    let userMessages: Int
    let assistantMessages: Int
    let turns: Int
    let commands: Int
    let commandsOk: Int
    let commandsFail: Int
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
        var userMessages = 0
        var assistantMessages = 0
        var commands = 0
        var commandsOk = 0
        var commandsFail = 0
        var mcp = 0
        var files = Set<String>()
        var execTime: UInt64 = 0

        for ev in events {
            switch ev.role.lowercased() {
            case "user":
                turns += 1
                userMessages += 1
            case "assistant":
                assistantMessages += 1
            default:
                break
            }
            if ev.kind == "tool" {
                if let cmd = ev.command, !cmd.isEmpty {
                    commands += 1
                    if let code = ev.exitCode {
                        if code == 0 { commandsOk += 1 } else { commandsFail += 1 }
                    } else {
                        // No exit code recorded — assume success so the
                        // "X ok · Y fail" line still adds up to total.
                        commandsOk += 1
                    }
                }
                if let tool = ev.toolName, tool.lowercased().contains("mcp") { mcp += 1 }
            }
            if let dur = ev.durationMs { execTime += dur }
            for f in ev.files { files.insert(f.path) }
        }

        return SessionStats(
            messages: events.count,
            userMessages: userMessages,
            assistantMessages: assistantMessages,
            turns: turns,
            commands: commands,
            commandsOk: commandsOk,
            commandsFail: commandsFail,
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
    var monospaced: Bool = false

    var body: some View {
        Text(label)
            .font(pillFont)
            .foregroundStyle(SweKittyTheme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassCapsule(interactive: false, tint: tint.opacity(0.30))
    }

    private var pillFont: Font {
        if monospaced {
            return .system(.caption, design: .monospaced).weight(.bold)
        }
        return .caption.weight(.semibold)
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
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: SweKittyTheme.cardCornerRadius, style: .continuous)
                    .fill(SweKittyTheme.surface.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SweKittyTheme.cardCornerRadius, style: .continuous)
                    .strokeBorder(SweKittyTheme.border.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct StatTile: View {
    let value: String
    let label: String
    let secondary: String?

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title2, design: .monospaced).weight(.bold))
                .foregroundStyle(SweKittyTheme.accentStrong)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(SweKittyTheme.textSecondary)
                .lineLimit(1)
            if let secondary, !secondary.isEmpty {
                Text(secondary)
                    .font(.caption2)
                    .foregroundStyle(SweKittyTheme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
