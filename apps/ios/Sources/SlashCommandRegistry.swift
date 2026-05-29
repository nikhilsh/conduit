import Foundation

/// Recognises `/`-prefixed commands typed in the chat composer and
/// classifies how each should be routed. Pure value types + parsing — no
/// SwiftUI, no I/O — so it unit-tests directly. Mirror of
/// `apps/android/app/src/main/kotlin/sh/nikhil/swekitty/ui/SlashCommandRegistry.kt`;
/// keep the two in sync (a test pins the command-name set on each platform).
///
/// See docs/SLASH-COMMANDS.md for the design + the per-CLI capability
/// matrix that drives `SlashCommand.claudeOnly`.
enum SlashCommandClass {
    /// Sent to the agent unchanged. Only the Claude stream-json backend
    /// intercepts these (Codex `exec` can't — openai/codex#3641).
    case passThrough
    /// swe-kitty handles it on the client; never reaches the agent.
    case appHandled
}

struct SlashCommand: Equatable {
    let name: String
    let clazz: SlashCommandClass
    let description: String
    var aliases: [String] = []
    /// Pass-through commands only work on a Claude stream-json session.
    var claudeOnly: Bool = false
}

struct SlashCommandMatch: Equatable {
    let command: SlashCommand
    /// Everything after the command token, trimmed (e.g. `opus` for `/model opus`).
    let args: String
    /// False when a pass-through command is used on a non-Claude agent —
    /// the caller surfaces an in-chat "not supported with this agent" note.
    let supported: Bool
}

enum SlashCommandRegistry {

    static let commands: [SlashCommand] = [
        SlashCommand(name: "compact", clazz: .passThrough, description: "Summarize the conversation to free up context", claudeOnly: true),
        SlashCommand(name: "clear", clazz: .passThrough, description: "Start a fresh context", claudeOnly: true),
        SlashCommand(name: "context", clazz: .passThrough, description: "Show context-window usage", claudeOnly: true),
        SlashCommand(name: "usage", clazz: .passThrough, description: "Show token usage and cost", aliases: ["cost", "stats"], claudeOnly: true),
        SlashCommand(name: "model", clazz: .appHandled, description: "Fork the session onto a different model"),
        SlashCommand(name: "effort", clazz: .appHandled, description: "Fork with a different reasoning effort"),
        SlashCommand(name: "loop", clazz: .appHandled, description: "Repeat a prompt on a loop"),
        SlashCommand(name: "help", clazz: .appHandled, description: "List the available slash commands"),
    ]

    private static func lookup(_ name: String) -> SlashCommand? {
        let n = name.lowercased()
        return commands.first { $0.name == n || $0.aliases.contains(n) }
    }

    /// Classify `input` for a session running `agent` ("claude" / "codex" / …).
    /// Returns nil when `input` isn't a recognised slash command (so the
    /// caller sends it as a normal chat message).
    static func classify(_ input: String, agent: String) -> SlashCommandMatch? {
        let trimmed = input.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.first == "/" else { return nil }
        let body = trimmed.dropFirst()
        let name = String(body.prefix(while: { !$0.isWhitespace }))
        guard !name.isEmpty, let cmd = lookup(name) else { return nil }
        let args = String(body.dropFirst(name.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        let supported = !(cmd.claudeOnly && agent.lowercased() != "claude")
        return SlashCommandMatch(command: cmd, args: args, supported: supported)
    }

    /// Autocomplete candidates for a `draft` that begins with `/`. Filters
    /// by the typed command prefix (name or alias). Empty when the draft
    /// isn't a bare command token (e.g. already has arguments).
    static func autocomplete(_ draft: String) -> [SlashCommand] {
        let trimmed = draft.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.first == "/" else { return [] }
        let body = trimmed.dropFirst()
        if body.contains(where: { $0.isWhitespace }) { return [] }
        let typed = body.lowercased()
        return commands.filter { cmd in
            cmd.name.hasPrefix(typed) || cmd.aliases.contains { $0.hasPrefix(typed) }
        }
    }
}
