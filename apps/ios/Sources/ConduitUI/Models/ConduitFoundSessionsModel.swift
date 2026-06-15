import Foundation

// MARK: - ConduitFoundSessionsModel
//
// Pure-data view-model for the Found Sessions feature. Computes rows,
// discovery state, and grouping from the input snapshot. Lives off SwiftUI
// so it can be driven from XCTest without standing up a view tree.
//
// Mirrors ConduitHomeViewModel.swift exactly (snapshot in -> rows out).
// NO SwiftUI import -- this is the ship-gate per BRIEF §8.13.

extension ConduitUI {

    // MARK: - Row model

    /// State of a single found session, from the broker's `is_running` field
    /// plus a check against live Conduit sessions (adopted).
    enum FoundSessionState: Equatable {
        case idle       // not running -- offer Resume
        case running    // live in a terminal -- offer Branch a copy
        case adopted    // already in Conduit -- dimmed "In Conduit"
    }

    struct FoundSessionRow: Identifiable, Equatable {
        var id: String { externalID }
        let externalID: String
        let agent: String
        let title: String
        let cwd: String
        let gitBranch: String?
        let turnCount: Int
        let lastActivityAt: Date
        let state: FoundSessionState
        /// True if the user has hidden this row via the overflow menu.
        let isHidden: Bool

        /// A human-readable relative timestamp ("2m ago", "3h ago", etc.).
        var relativeTime: String { FoundSessionsModel.relativeTime(lastActivityAt) }

        /// Short display label for the cwd, e.g. "~/projects/api"
        var shortCwd: String {
            if cwd.hasPrefix("/root/") || cwd.hasPrefix("/home/") {
                return "~/" + cwd.split(separator: "/").dropFirst(2).joined(separator: "/")
            }
            return cwd
        }
    }

    // MARK: - Discovery filter

    enum FoundSessionsFilter: String, CaseIterable, Equatable {
        case recent    = "Recent"
        case byFolder  = "By folder"
        case all       = "All"
    }

    // MARK: - Discovery state

    enum FoundSessionsDiscoveryState: Equatable {
        case scanning
        case loaded
        case empty
        case offline
        case error(String)
    }

    // MARK: - Snapshot (input)

    struct FoundSessionsSnapshot: Equatable {
        /// The box's SavedServer.id -- used for hidden-id lookups.
        var boxID: String
        /// Box display name for sheet title ("Found on {box}").
        var boxName: String
        /// Raw discovered sessions from the broker.
        var sessions: [SessionStore.FoundSession]
        /// IDs of sessions already adopted into Conduit (live Conduit sessions
        /// on this box). Used for adopted-dedupe.
        var adoptedExternalIDs: Set<String>
        /// Hidden session IDs for this box.
        var hiddenIDs: Set<String>
        /// Current search query.
        var query: String
        /// Active filter.
        var filter: FoundSessionsFilter
        /// Discovery polling state.
        var discoveryState: FoundSessionsDiscoveryState
        /// Total sessions on disk (from broker -- may exceed what's listed).
        var totalOnDisk: Int
        /// How many "recent" sessions are shown (for the entry card badge).
        var recentCount: Int { sessions.prefix(20).count }

        static let empty = FoundSessionsSnapshot(
            boxID: "",
            boxName: "",
            sessions: [],
            adoptedExternalIDs: [],
            hiddenIDs: [],
            query: "",
            filter: .recent,
            discoveryState: .scanning,
            totalOnDisk: 0
        )
    }

    // MARK: - ViewModel (pure static methods)

    enum FoundSessionsModel {

        /// Compute the visible row list from a snapshot.
        /// Applies filter, search, hidden-id exclusion, adopted-dedupe.
        static func rows(_ snap: FoundSessionsSnapshot) -> [FoundSessionRow] {
            let allRows = snap.sessions.map { session -> FoundSessionRow in
                let state: FoundSessionState
                if snap.adoptedExternalIDs.contains(session.externalID) {
                    state = .adopted
                } else if session.isRunning {
                    state = .running
                } else {
                    state = .idle
                }
                return FoundSessionRow(
                    externalID: session.externalID,
                    agent: session.agent,
                    title: session.title,
                    cwd: session.cwd,
                    gitBranch: session.gitBranch,
                    turnCount: session.turnCount,
                    lastActivityAt: session.lastActivityAt,
                    state: state,
                    isHidden: snap.hiddenIDs.contains(session.externalID)
                )
            }

            // Apply search filter
            let searched = snap.query.isEmpty ? allRows : allRows.filter { row in
                let q = snap.query.lowercased()
                return row.title.lowercased().contains(q)
                    || row.cwd.lowercased().contains(q)
                    || (row.gitBranch?.lowercased().contains(q) ?? false)
            }

            // For "recent" filter: show top 20 non-hidden, sorted by date
            // For "byFolder" / "all": include everything (hidden excluded unless all)
            switch snap.filter {
            case .recent:
                return searched
                    .filter { !$0.isHidden }
                    .sorted { $0.lastActivityAt > $1.lastActivityAt }
                    .prefix(20)
                    .map { $0 }
            case .byFolder:
                return searched
                    .filter { !$0.isHidden }
                    .sorted { $0.lastActivityAt > $1.lastActivityAt }
            case .all:
                return searched
                    .sorted { $0.lastActivityAt > $1.lastActivityAt }
            }
        }

        /// Group rows by cwd for the "By folder" / discovery sheet list.
        /// Returns [(cwd, [FoundSessionRow])] preserving folder recency order.
        static func grouped(_ rows: [FoundSessionRow]) -> [(cwd: String, rows: [FoundSessionRow])] {
            var seen: [String] = []
            var map: [String: [FoundSessionRow]] = [:]
            for row in rows {
                if map[row.cwd] == nil {
                    seen.append(row.cwd)
                    map[row.cwd] = []
                }
                map[row.cwd]?.append(row)
            }
            return seen.compactMap { cwd in
                guard let r = map[cwd], !r.isEmpty else { return nil }
                return (cwd: cwd, rows: r)
            }
        }

        /// Derive discoveryState from the snapshot.
        static func discoveryState(_ snap: FoundSessionsSnapshot) -> FoundSessionsDiscoveryState {
            snap.discoveryState
        }

        /// Footer honest-volume line.
        static func footerText(recentCount: Int, totalOnDisk: Int) -> String {
            if totalOnDisk <= recentCount {
                return "\(recentCount) session\(recentCount == 1 ? "" : "s") found"
            }
            return "\(recentCount) recent \u{00B7} \(totalOnDisk) on disk \u{2014} search to find older"
        }

        /// Human relative time for a session's last activity.
        static func relativeTime(_ date: Date, now: Date = Date()) -> String {
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
    }
}
