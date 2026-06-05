import Foundation

// MARK: - ConduitHomeViewModel
//
// Pure-data view-model for ConduitUI's home screen. Computes the row
// list, top-bar context, and empty-state messaging from the input
// snapshot. Lives off SwiftUI so we can drive it from XCTest /
// Swift Testing without standing up a view tree.
//
// The shape (snapshot in -> rows out) mirrors what we already do for
// `SessionsScreenModel` etc. — it lets the SwiftUI view stay a thin
// renderer.

extension ConduitUI {

    /// One row in the home list.
    struct HomeRow: Equatable, Identifiable {
        enum Kind: Equatable {
            case session(id: String)
            case creatingPlaceholder(id: String)
        }
        var kind: Kind
        /// Prominent friendly name (never a raw UUID — resolved upstream
        /// by `SessionStore.displayName(for:)`).
        var title: String
        /// Agent label for the secondary-line chip ("claude", "codex").
        /// Empty for placeholder rows.
        var agent: String
        /// Human status word for the secondary line: "running" / "idle" /
        /// "exited" (or the placeholder's progress label).
        var statusText: String
        /// Relative "last active" stamp for the secondary line ("2m ago",
        /// "just now"). Empty when we have no timestamp to anchor it.
        var relativeTime: String
        /// A REAL, user-picked cwd worth surfacing, or nil. The ephemeral
        /// per-session work dir (`…/sessions/<id>/work`) is deliberately
        /// dropped — it's not a meaningful project path.
        var workingDir: String?
        /// One-line preview of the latest activity in the session (the
        /// most recent assistant reply / tool action), condensed to a
        /// single line. Empty when the transcript carries nothing useful
        /// yet. The title is the FIRST user message; this complements it
        /// so the user can tell active sessions apart at a glance.
        var lastActivityPreview: String
        var isSelected: Bool
        /// Whether the agent session is live (drives the status dot's
        /// green vs muted). Independent of `isSelected` — device bug #9:
        /// the dot used to track selection, so a second running session
        /// looked stopped. Selection is shown by the row background.
        var isRunning: Bool

        var id: String {
            switch kind {
            case .session(let id): return "real:\(id)"
            case .creatingPlaceholder(let id): return "placeholder:\(id)"
            }
        }
    }

    /// Input snapshot — what the home screen needs to know about the
    /// world to render. Built from the live SessionStore in the
    /// SwiftUI view, or constructed by tests.
    struct HomeSnapshot: Equatable {
        var harness: HomeSnapshotHarness
        var sessions: [HomeSnapshotSession]
        var placeholders: [HomeSnapshotPlaceholder]
        var selectedSessionID: String?
        var endpointDisplayHost: String?

        /// Empty/default state.
        static let empty = HomeSnapshot(
            harness: .disconnected,
            sessions: [],
            placeholders: [],
            selectedSessionID: nil,
            endpointDisplayHost: nil
        )
    }

    /// Minimal harness shape — we don't drag in HarnessState directly
    /// so the snapshot stays pure data.
    enum HomeSnapshotHarness: Equatable {
        case disconnected
        case connecting
        case live
        case reconnecting
        case failed(String)

        var canIssueCommands: Bool {
            switch self {
            case .live, .reconnecting: return true
            default: return false
            }
        }

        /// True only when the WS is actually connected. Gates the
        /// session-row dot so it can't show stale "running" green while
        /// the connection is down (device bug #30).
        var isConnected: Bool {
            if case .live = self { return true }
            return false
        }
    }

    /// A real "needs you" signal: a session whose agent is blocked on the
    /// user (the last transcript item is an unanswered `pending_input` —
    /// an approval prompt or an options menu). Drives the Home banner
    /// (handoff §B.5 / §B.10). Never fabricated: built only from sessions
    /// that actually carry this state.
    struct NeedsYouBanner: Equatable {
        /// Sessions currently awaiting the user, in input order.
        var sessions: [Item]
        struct Item: Equatable {
            var id: String
            var title: String
            var agent: String
        }
        var count: Int { sessions.count }
        /// The session a tap should open (the first one awaiting input).
        var primaryID: String? { sessions.first?.id }
    }

    struct HomeSnapshotSession: Equatable {
        var id: String
        var displayName: String
        var assistant: String
        var phase: String?
        /// RFC3339 last-activity / started timestamp, for the relative
        /// "last active" stamp. Optional — terminal-only sessions may
        /// not carry one yet.
        var lastActivityAt: String?
        /// A real, user-picked cwd to surface, or nil. The view layer
        /// passes nil for the ephemeral per-session work dir; we only
        /// carry a path here when it's worth showing.
        var workingDir: String?
        /// Already-condensed one-line preview of the latest activity (most
        /// recent assistant/tool item) for this session, or nil/empty when
        /// the transcript has nothing to preview. The view layer builds
        /// this from `store.conversationLog` via
        /// `HomeViewModel.activityPreview(from:)`.
        var lastActivityPreview: String?

        init(
            id: String,
            displayName: String,
            assistant: String,
            phase: String?,
            lastActivityAt: String? = nil,
            workingDir: String? = nil,
            lastActivityPreview: String? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.assistant = assistant
            self.phase = phase
            self.lastActivityAt = lastActivityAt
            self.workingDir = workingDir
            self.lastActivityPreview = lastActivityPreview
        }
    }

    struct HomeSnapshotPlaceholder: Equatable {
        var id: String
        var label: String
    }

    /// Computes the visible row list. Real sessions sort first, then
    /// placeholders, both in input order. `now` is injectable so the
    /// relative-time stamps are deterministic in tests.
    enum HomeViewModel {
        static func rows(_ snap: HomeSnapshot, now: Date = Date()) -> [HomeRow] {
            var rows: [HomeRow] = []
            for s in snap.sessions {
                let phase = s.phase ?? "ready"
                let isRunning = snap.harness.isConnected && !phase.hasPrefix("exited")
                rows.append(HomeRow(
                    kind: .session(id: s.id),
                    title: s.displayName,
                    agent: s.assistant,
                    statusText: statusText(phase: phase, connected: snap.harness.isConnected),
                    relativeTime: relativeTime(s.lastActivityAt, now: now),
                    workingDir: s.workingDir,
                    lastActivityPreview: s.lastActivityPreview ?? "",
                    isSelected: snap.selectedSessionID == s.id,
                    // Green only when actually connected AND the agent
                    // hasn't exited — otherwise the dot showed stale
                    // "running" green while disconnected (device bug #30).
                    isRunning: isRunning
                ))
            }
            for p in snap.placeholders {
                rows.append(HomeRow(
                    kind: .creatingPlaceholder(id: p.id),
                    title: "Starting session…",
                    agent: "",
                    statusText: p.label,
                    relativeTime: "",
                    workingDir: nil,
                    lastActivityPreview: "",
                    isSelected: false,
                    isRunning: false
                ))
            }
            return rows
        }

        /// True when a session is blocked on the user: its LAST transcript
        /// item is a non-user `pending_input` (an approval prompt / options
        /// menu) with nothing from the user after it. Mirrors how the chat
        /// view detects an outstanding pending-input (last event carries
        /// `pendingOptions` / `kind == pending_input`). Pure string inputs
        /// so the view-model stays free of the generated `ConversationItem`.
        static func isAwaitingInput(lastItemRole: String?, lastItemKind: String?) -> Bool {
            guard let role = lastItemRole, role.lowercased() != "user" else { return false }
            return (lastItemKind ?? "").lowercased() == "pending_input"
        }

        /// Build the "needs you" banner from the per-session signal the view
        /// layer resolves (last transcript item's role + kind). Only includes
        /// sessions that are genuinely awaiting input — the banner is hidden
        /// (`count == 0`) otherwise, never showing a fabricated count.
        static func needsYouBanner(_ candidates: [(id: String, title: String, agent: String, lastItemRole: String?, lastItemKind: String?)]) -> NeedsYouBanner {
            let items = candidates
                .filter { isAwaitingInput(lastItemRole: $0.lastItemRole, lastItemKind: $0.lastItemKind) }
                .map { NeedsYouBanner.Item(id: $0.id, title: $0.title, agent: $0.agent) }
            return NeedsYouBanner(sessions: items)
        }

        /// Condense the latest transcript activity into a single short
        /// preview line for the home card's secondary row. Prefers a tool
        /// action's command/label (e.g. "Run: cargo test") so an in-flight
        /// session reads "what's happening"; otherwise the latest message
        /// body's first non-empty line. Returns nil when there's nothing
        /// worth previewing (e.g. the only item is the first user message,
        /// which is already the card title).
        ///
        /// Pure string inputs (role / kind / toolName / command / content)
        /// keep the view-model free of the generated core `ConversationItem`
        /// type — the view layer pulls the latest item out of
        /// `store.conversationLog` and hands the fields in.
        static func activityPreview(
            role: String,
            kind: String,
            toolName: String?,
            command: String?,
            content: String,
            budget: Int = 72
        ) -> String? {
            // A tool action: surface the command (most informative for an
            // active session) or fall back to a "<TOOL>: <first line>".
            if role.lowercased() == "tool" || kind.lowercased() == "tool" {
                if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let label = (toolName?.isEmpty == false) ? toolName! : "Run"
                    return clip("\(label): \(firstLine(command))", budget: budget)
                }
                let body = firstLine(content)
                if !body.isEmpty {
                    let prefix = (toolName?.isEmpty == false) ? "\(toolName!): " : ""
                    return clip(prefix + body, budget: budget)
                }
                if let toolName, !toolName.isEmpty { return clip(toolName, budget: budget) }
                return nil
            }
            // Assistant / other text: first non-empty line of the body.
            let body = firstLine(content)
            return body.isEmpty ? nil : clip(body, budget: budget)
        }

        /// First non-empty line of a (possibly multi-line) string with
        /// internal whitespace runs collapsed to single spaces.
        private static func firstLine(_ raw: String) -> String {
            for line in raw.split(whereSeparator: { $0.isNewline }) {
                let collapsed = line
                    .split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !collapsed.isEmpty { return collapsed }
            }
            return ""
        }

        /// Trim to `budget` chars with an ellipsis when over.
        private static func clip(_ s: String, budget: Int) -> String {
            s.count <= budget ? s : String(s.prefix(budget - 1)) + "…"
        }

        /// Human status word for the row's secondary line. Disconnected
        /// sessions can't be trusted as running (device bug #30) so they
        /// read "idle"; an `exited…` phase reads "exited"; otherwise
        /// "running".
        static func statusText(phase: String, connected: Bool) -> String {
            if phase.hasPrefix("exited") { return "exited" }
            if !connected { return "idle" }
            return "running"
        }

        /// Compact relative "last active" stamp ("just now", "2m ago",
        /// "3h ago", "5d ago"); older than two weeks falls back to a short
        /// date. Empty when there's no timestamp to anchor it.
        static func relativeTime(_ raw: String?, now: Date = Date()) -> String {
            guard let raw, let date = SessionNaming.parseTimestamp(raw) else { return "" }
            let delta = now.timeIntervalSince(date)
            if delta < 0 { return "just now" }
            if delta < 60 { return "just now" }
            if delta < 3600 { return "\(Int(delta / 60))m ago" }
            if delta < 86_400 { return "\(Int(delta / 3600))h ago" }
            if delta < 86_400 * 14 { return "\(Int(delta / 86_400))d ago" }
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .none
            return f.string(from: date)
        }

        /// Title shown in the empty-state when there are no rows.
        static func emptyTitle(_ snap: HomeSnapshot) -> String {
            snap.harness.canIssueCommands ? "No sessions yet" : "Waiting for server"
        }

        /// Body shown in the empty-state when there are no rows.
        static func emptyBody(_ snap: HomeSnapshot) -> String {
            snap.harness.canIssueCommands
                ? "Tap + to spin up a new conversation."
                : "Once we can reach the server, your sessions appear here."
        }

        /// SF Symbol shown in the empty-state hero.
        static func emptySymbol(_ snap: HomeSnapshot) -> String {
            snap.harness.canIssueCommands ? "sparkles" : "cloud.slash"
        }
    }
}
