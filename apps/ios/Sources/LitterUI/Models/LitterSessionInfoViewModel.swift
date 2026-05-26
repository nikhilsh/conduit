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
        var lastActivityAt: String?

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
            lastActivityAt: nil,
            messagesCount: 0,
            turnsCount: 0,
            commandsCount: 0,
            filesChangedCount: 0,
            mcpCallsCount: 0,
            execTimeMs: 0
        )
    }

    /// A single label/value row in the Session Info "Details" card. The
    /// `value` is the primary string; `caption` is an optional secondary
    /// string (e.g. a relative-time companion to an absolute timestamp).
    struct SessionInfoDetail: Equatable, Identifiable {
        var id: String { label }
        var label: String
        var value: String
        var caption: String?
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

        /// Ordered detail rows for the Session Info "Details" card. Built
        /// from live store/session data: the agent's model, when the
        /// session started (absolute + relative), last activity (relative),
        /// and uptime (started → last activity, or started → now).
        static func details(_ snap: SessionInfoSnapshot, now: Date = Date()) -> [SessionInfoDetail] {
            var rows: [SessionInfoDetail] = []

            // Model — the agent/model the session is driving. We only have
            // the assistant identifier from the broker (no separate model
            // version field), optionally qualified by reasoning effort.
            let model = snap.assistant.isEmpty ? "—" : snap.assistant
            let modelValue = snap.reasoningEffort.map { "\(model) · \($0)" } ?? model
            rows.append(SessionInfoDetail(label: "Model", value: modelValue, caption: nil))

            // Started — absolute date/time + relative companion.
            if let started = parseTimestamp(snap.startedAt) {
                rows.append(SessionInfoDetail(
                    label: "Started",
                    value: absolute(started),
                    caption: relative(started, now: now)
                ))
            }

            // Last activity — relative only (absolute is rarely useful here).
            if let last = parseTimestamp(snap.lastActivityAt ?? snap.startedAt) {
                rows.append(SessionInfoDetail(
                    label: "Last Activity",
                    value: relative(last, now: now),
                    caption: nil
                ))
            }

            // Uptime — started → last activity (or → now if still live).
            if let started = parseTimestamp(snap.startedAt) {
                let end = parseTimestamp(snap.lastActivityAt) ?? now
                let elapsed = max(0, end.timeIntervalSince(started))
                rows.append(SessionInfoDetail(
                    label: "Uptime",
                    value: formatDuration(Int(elapsed * 1000)),
                    caption: nil
                ))
            }

            return rows
        }

        /// Tolerant RFC3339 parse — accepts the broker's fractional-second
        /// variant as well as the plain form.
        static func parseTimestamp(_ raw: String?) -> Date? {
            guard let raw else { return nil }
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = withFraction.date(from: raw) { return d }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: raw)
        }

        /// Absolute medium-date / short-time string in the device locale.
        static func absolute(_ date: Date) -> String {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return f.string(from: date)
        }

        /// Compact relative-time string ("just now", "5m ago", "3h ago",
        /// "2d ago"); older than two weeks falls back to a short date.
        static func relative(_ date: Date, now: Date = Date()) -> String {
            let delta = now.timeIntervalSince(date)
            if delta < 60 { return "just now" }
            if delta < 3600 { return "\(Int(delta / 60))m ago" }
            if delta < 86_400 { return "\(Int(delta / 3600))h ago" }
            if delta < 86_400 * 14 { return "\(Int(delta / 86_400))d ago" }
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .none
            return f.string(from: date)
        }
    }
}
