import SwiftUI

/// Pure derivation of the 2×3 stats grid shown on `SessionInfoView`.
/// Lifted out of `SessionInfoView` so the count/sum logic is unit
/// testable without instantiating SwiftUI — `StatsGridModelTests`
/// exercises every counter independently.
///
/// The fields match the six tiles in the Litter "Info" reference:
/// Messages · Turns · Commands · Files Changed · MCP Calls · Exec Time.
/// Secondary lines (`<n> ok · <m> fail` etc.) are derived alongside the
/// totals so the view stays a thin formatter over this model.
struct StatsGridModel: Equatable {
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

    static let empty = StatsGridModel(
        messages: 0,
        userMessages: 0,
        assistantMessages: 0,
        turns: 0,
        commands: 0,
        commandsOk: 0,
        commandsFail: 0,
        filesChanged: 0,
        mcpCalls: 0,
        execTimeMs: 0
    )

    /// Human-readable exec time. `—` when there is no recorded duration
    /// (e.g. a brand-new session before any tool has run).
    var execTimeLabel: String {
        if execTimeMs == 0 { return "—" }
        let seconds = Double(execTimeMs) / 1000.0
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let mins = seconds / 60.0
        if mins < 60 { return String(format: "%.1fm", mins) }
        let hrs = mins / 60.0
        return String(format: "%.1fh", hrs)
    }

    /// Derive a `StatsGridModel` from the typed conversation log. Each
    /// item is folded into the relevant counter:
    ///
    /// - role=user  → +1 turn, +1 userMessages
    /// - role=assistant → +1 assistantMessages
    /// - kind=tool with a non-empty command → +1 commands, bucketed
    ///   into ok/fail by `exitCode` (no exit code = ok so the secondary
    ///   line always sums to the total)
    /// - kind=tool with a `toolName` containing "mcp" → +1 mcpCalls
    /// - any item with a `durationMs` → folded into exec time
    /// - any item's `files` paths → unioned into the filesChanged set
    static func compute(from events: [ConversationItem]) -> StatsGridModel {
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
                        commandsOk += 1
                    }
                }
                if let tool = ev.toolName, tool.lowercased().contains("mcp") { mcp += 1 }
            }
            if let dur = ev.durationMs { execTime += dur }
            for f in ev.files { files.insert(f.path) }
        }

        return StatsGridModel(
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

/// 2×3 grid of glass tiles — big copper number + mono label per cell.
/// Visual chrome only; all derivation lives in `StatsGridModel`.
struct StatsGrid: View {
    let model: StatsGridModel

    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
        ], spacing: 12) {
            StatsGridTile(
                value: "\(model.messages)",
                label: "Messages",
                secondary: "\(model.userMessages) user · \(model.assistantMessages) assistant"
            )
            StatsGridTile(value: "\(model.turns)", label: "Turns", secondary: nil)
            StatsGridTile(
                value: "\(model.commands)",
                label: "Commands",
                secondary: "\(model.commandsOk) ok · \(model.commandsFail) fail"
            )
            // ConversationItem doesn't track per-file additions/deletions
            // yet, so the secondary line is omitted for "Files Changed".
            StatsGridTile(value: "\(model.filesChanged)", label: "Files Changed", secondary: nil)
            StatsGridTile(value: "\(model.mcpCalls)", label: "MCP Calls", secondary: nil)
            StatsGridTile(value: model.execTimeLabel, label: "Exec Time", secondary: nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .glassRoundedRect()
    }
}

private struct StatsGridTile: View {
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
