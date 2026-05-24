import Foundation

// MARK: - LitterHomeViewModel
//
// Pure-data view-model for LitterUI's home screen. Computes the row
// list, top-bar context, and empty-state messaging from the input
// snapshot. Lives off SwiftUI so we can drive it from XCTest /
// Swift Testing without standing up a view tree.
//
// The shape (snapshot in -> rows out) mirrors what we already do for
// `SessionsScreenModel` etc. — it lets the SwiftUI view stay a thin
// renderer.

extension LitterUI {

    /// One row in the home list.
    struct HomeRow: Equatable, Identifiable {
        enum Kind: Equatable {
            case session(id: String)
            case creatingPlaceholder(id: String)
        }
        var kind: Kind
        var title: String
        /// e.g. "claude · ready · 192.168.4.30"
        var subtitle: String
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
    }

    struct HomeSnapshotSession: Equatable {
        var id: String
        var displayName: String
        var assistant: String
        var phase: String?
    }

    struct HomeSnapshotPlaceholder: Equatable {
        var id: String
        var label: String
    }

    /// Computes the visible row list. Real sessions sort first, then
    /// placeholders, both in input order.
    enum HomeViewModel {
        static func rows(_ snap: HomeSnapshot) -> [HomeRow] {
            var rows: [HomeRow] = []
            let host = snap.endpointDisplayHost ?? "local"
            for s in snap.sessions {
                let phase = s.phase ?? "ready"
                rows.append(HomeRow(
                    kind: .session(id: s.id),
                    title: s.displayName,
                    subtitle: "\(s.assistant) · \(phase) · \(host)",
                    isSelected: snap.selectedSessionID == s.id,
                    // Alive unless the agent process has exited. Every
                    // other phase (ready / working / swapping) is running.
                    isRunning: !phase.hasPrefix("exited")
                ))
            }
            for p in snap.placeholders {
                rows.append(HomeRow(
                    kind: .creatingPlaceholder(id: p.id),
                    title: "Starting session…",
                    subtitle: p.label,
                    isSelected: false,
                    isRunning: false
                ))
            }
            return rows
        }

        /// Title shown in the empty-state when there are no rows.
        static func emptyTitle(_ snap: HomeSnapshot) -> String {
            snap.harness.canIssueCommands ? "No sessions yet" : "Waiting for harness"
        }

        /// Body shown in the empty-state when there are no rows.
        static func emptyBody(_ snap: HomeSnapshot) -> String {
            snap.harness.canIssueCommands
                ? "Tap + to spin up a new conversation."
                : "Once we can reach the harness, your sessions appear here."
        }

        /// SF Symbol shown in the empty-state hero.
        static func emptySymbol(_ snap: HomeSnapshot) -> String {
            snap.harness.canIssueCommands ? "sparkles" : "cloud.slash"
        }
    }
}
