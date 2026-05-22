import Foundation

// MARK: - LitterSessionInfoViewModel
//
// Pure-data view-model for the LitterUI session info screen. Computes
// the hero text and the 6-cell stats grid from a snapshot.

extension LitterUI {

    struct SessionInfoStat: Equatable, Identifiable {
        var id: String { title }
        var title: String
        var value: String
        var subtitle: String?
    }

    struct SessionInfoSnapshot: Equatable {
        var sessionID: String
        var displayName: String
        var assistant: String
        var reasoningEffort: String?
        var cwd: String?
        var startedAt: String?

        var messagesCount: Int
        var turnsCount: Int
        var commandsCount: Int
        var filesChangedCount: Int
        var mcpCallsCount: Int
        /// Milliseconds — formatted as h/m/s by the model.
        var execTimeMs: Int

        static let empty = SessionInfoSnapshot(
            sessionID: "",
            displayName: "",
            assistant: "",
            reasoningEffort: nil,
            cwd: nil,
            startedAt: nil,
            messagesCount: 0,
            turnsCount: 0,
            commandsCount: 0,
            filesChangedCount: 0,
            mcpCallsCount: 0,
            execTimeMs: 0
        )
    }

    enum SessionInfoViewModel {
        static func stats(_ snap: SessionInfoSnapshot) -> [SessionInfoStat] {
            [
                SessionInfoStat(title: "Messages",      value: "\(snap.messagesCount)", subtitle: nil),
                SessionInfoStat(title: "Turns",         value: "\(snap.turnsCount)",    subtitle: nil),
                SessionInfoStat(title: "Commands",      value: "\(snap.commandsCount)", subtitle: nil),
                SessionInfoStat(title: "Files Changed", value: "\(snap.filesChangedCount)", subtitle: nil),
                SessionInfoStat(title: "MCP Calls",     value: "\(snap.mcpCallsCount)", subtitle: nil),
                SessionInfoStat(title: "Exec Time",     value: formatDuration(snap.execTimeMs), subtitle: nil),
            ]
        }

        static func formatDuration(_ ms: Int) -> String {
            if ms <= 0 { return "—" }
            let s = ms / 1000
            if s < 60 { return "\(s)s" }
            let m = s / 60
            if m < 60 { return "\(m)m \(s % 60)s" }
            let h = m / 60
            return "\(h)h \(m % 60)m"
        }
    }
}
