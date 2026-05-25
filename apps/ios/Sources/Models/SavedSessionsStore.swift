import Foundation
import Observation

/// Lifecycle bucket mirrored from `core/src/saved/mod.rs::SavedSessionStatus`.
/// Stringly-encoded `lowercase` to match the Rust serde repr —
/// `#[serde(rename_all = "lowercase")]` on the Rust enum.
enum SavedSessionStatus: String, Codable, Equatable {
    case live
    case exited
    case unknown
}

/// Swift mirror of `core/src/saved/mod.rs::SavedSession`. The on-disk
/// JSON is shared with the Rust core (no UniFFI surface yet — the
/// "Sessions" screen reads + writes this file directly so we can
/// iterate on the shape on a single platform before promoting it).
///
/// `CodingKeys` map Swift's camelCase fields to the Rust snake_case
/// serde repr so the same JSON is round-trippable from either side.
struct SavedSession: Codable, Equatable, Identifiable {
    var id: String
    var serverID: String
    var agent: String
    var cwd: String?
    var firstSeen: String
    var lastSeen: String
    var messageCount: UInt32
    var summary: String
    var status: SavedSessionStatus

    /// Compound identity for `SwiftUI.ForEach` — `id` alone is not
    /// unique across servers (the harness mints UUIDs per session, but
    /// nothing prevents a collision if a user paired two harnesses that
    /// happen to reuse the same id). Match the Rust `compound_key`.
    var compoundID: String { "\(serverID)::\(id)" }

    enum CodingKeys: String, CodingKey {
        case id
        case serverID = "server_id"
        case agent
        case cwd
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
        case messageCount = "message_count"
        case summary
        case status
    }
}

/// Persisted index of every session the client has ever seen, across
/// every server. Backs the "Resume an old thread" screen (litter parity
/// audit item A.8). Mirrors `core/src/saved/mod.rs::SavedSessionStore`:
///
/// * Persistence path: `Application Support/swe-kitty/saved-sessions.json`.
/// * Wire shape: `{"sessions": {"<server_id>::<session_id>": SavedSession, ...}}`,
///   matching the Rust `HashMap` serde repr so either side can produce
///   or consume the file without a schema dance.
/// * Singleton: there's only one historical index per device. We expose
///   `shared` so call sites (`SessionStore.ingestStatus`, the
///   `SessionsScreen` view) don't have to thread an instance through.
@Observable
@MainActor
final class SavedSessionsStore {

    /// Process-wide singleton. The first access reads the JSON file off
    /// disk synchronously — the file is tiny (one record per session
    /// the user has ever seen) so blocking on init is fine and saves
    /// the screen from a "loading…" flash.
    static let shared = SavedSessionsStore()

    /// All known rows. Mutations go through `upsert`, which keeps this
    /// in sync with disk; reads in the UI go through `recent`.
    private(set) var sessions: [SavedSession] = []

    /// Persisted set of session ids the user has explicitly deleted.
    /// A tombstoned id is permanently suppressed from `upsert` (so a
    /// status/list refresh can't re-add it) and excluded from `recent`
    /// (so the history screen never shows it). Keyed by bare session id
    /// — the harness mints UUIDs unique per session, and a delete is
    /// terminal across servers, matching `remove(id:)`. We cap the set
    /// at `tombstoneCap` newest-first so it can't grow unbounded; an
    /// id evicted from the cap can theoretically reappear, but only
    /// after `tombstoneCap` *other* sessions have been deleted, by
    /// which point the broker has long since reaped the original.
    private(set) var deletedIDs: Set<String> = []

    /// Insertion-ordered companion to `deletedIDs` so we can evict the
    /// oldest tombstone when the cap is exceeded. Newest at the end.
    private var deletedOrder: [String] = []

    /// Upper bound on retained tombstones. Generous — the on-disk cost
    /// is one short string per entry.
    private let tombstoneCap = 500

    /// Resolved persistence path, exposed for tests + diagnostics.
    let storeURL: URL

    init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? SavedSessionsStore.defaultStoreURL()
        let loaded = Self.loadFromDisk(at: self.storeURL)
        self.sessions = loaded.sessions
        self.deletedOrder = loaded.deletedOrder
        self.deletedIDs = Set(loaded.deletedOrder)
    }

    /// Latest-first slice clamped to `limit`. Ties broken by id so
    /// snapshot tests stay deterministic — mirrors the Rust
    /// `list_recent` ordering rule.
    func recent(limit: Int = 200) -> [SavedSession] {
        // Belt-and-braces: a tombstoned row is normally already absent
        // from `sessions` (delete removes it), but filter here too so a
        // race (status frame in flight during delete) can never leak a
        // deleted session into the history screen.
        let sorted = sessions
            .filter { !deletedIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
                return lhs.id < rhs.id
            }
        if sorted.count <= limit { return sorted }
        return Array(sorted.prefix(limit))
    }

    /// True when the id has been explicitly deleted by the user. Call
    /// sites (e.g. `SessionStore.refreshSessions`) consult this to keep
    /// a tombstoned session out of the *live* list as well, since the
    /// broker can keep reporting a deleted session whose tmux lingers.
    func isTombstoned(id: String) -> Bool {
        deletedIDs.contains(id)
    }

    /// Fold a live `ProjectSession` + `SessionStatus` snapshot into the
    /// saved index. Idempotent — calling with the same input twice
    /// leaves the file unchanged. Mirrors the Rust `upsert` algorithm:
    /// first_seen is sticky, last_seen advances, the first non-empty
    /// summary wins, and once we record `.exited` the row is locked.
    func upsert(
        session: ProjectSession,
        serverID: String,
        status: SessionStatus?,
        firstUserMessage: String?,
        messageCount: Int,
        isExited: Bool
    ) {
        // A deleted session must STAY deleted. The deployed broker keeps
        // tmux-backed PTYs alive (#199), so a just-deleted session can
        // still surface on the next listSessions/status delta and feed
        // back into here. Without this guard it would be re-added and
        // reappear in history (reading as live → interactive). The
        // tombstone is the client-side guarantee.
        if deletedIDs.contains(session.id) { return }
        let now = status?.lastActivityAt
            ?? status?.startedAt
            ?? session.lastActivityAt
            ?? session.startedAt
            ?? ISO8601DateFormatter().string(from: Date())
        let summary = Self.truncateSummary(firstUserMessage ?? "")
        let nextStatus: SavedSessionStatus = isExited ? .exited : .live
        let agent = session.assistant
        let cwd = status?.cwd ?? session.cwd

        if let idx = sessions.firstIndex(where: {
            $0.id == session.id && $0.serverID == serverID
        }) {
            var row = sessions[idx]
            row.lastSeen = max(row.lastSeen, now)
            row.messageCount = max(row.messageCount, UInt32(clamping: messageCount))
            row.agent = agent
            if let cwd { row.cwd = cwd }
            if row.summary.isEmpty, !summary.isEmpty {
                row.summary = summary
            }
            row.status = mergeStatus(existing: row.status, next: nextStatus)
            // Avoid a no-op write — checked equality before persisting.
            if row != sessions[idx] {
                sessions[idx] = row
                persist()
            }
        } else {
            let row = SavedSession(
                id: session.id,
                serverID: serverID,
                agent: agent,
                cwd: cwd,
                firstSeen: now,
                lastSeen: now,
                messageCount: UInt32(clamping: messageCount),
                summary: summary,
                status: nextStatus
            )
            sessions.append(row)
            persist()
        }
    }

    /// Drop every row + tombstone. Test-only convenience — the
    /// production app has no "clear history" affordance yet.
    func reset() {
        sessions = []
        deletedIDs = []
        deletedOrder = []
        persist()
    }

    /// Tombstone + remove every saved-session row whose session-id
    /// equals `id`. Idempotent. Used by every delete path
    /// (`SessionStore.exit`): the live row is already gone, this records
    /// the tombstone so a subsequent `upsert` (from a status/list
    /// refresh while the broker's tmux lingers) can NEVER re-add it, and
    /// clears the persistent `Resume` entry so the row doesn't reappear
    /// on next launch. Matches across servers because the harness mints
    /// UUIDs unique per session and the user expects delete to be
    /// terminal.
    func remove(id: String) {
        let removedRow = sessions.contains { $0.id == id }
        sessions.removeAll { $0.id == id }
        let newTombstone = deletedIDs.insert(id).inserted
        if newTombstone {
            deletedOrder.append(id)
            // Cap the tombstone set so it can't grow forever. Evict the
            // oldest ids; by the time we've deleted `tombstoneCap`
            // sessions the broker has long reaped the early ones, so an
            // evicted tombstone is harmless.
            if deletedOrder.count > tombstoneCap {
                let overflow = deletedOrder.count - tombstoneCap
                let evicted = deletedOrder.prefix(overflow)
                deletedOrder.removeFirst(overflow)
                for id in evicted where !deletedOrder.contains(id) {
                    deletedIDs.remove(id)
                }
            }
        }
        if removedRow || newTombstone {
            persist()
        }
    }

    // MARK: - Persistence

    private func persist() {
        do {
            try Self.write(sessions: sessions, deletedOrder: deletedOrder, to: storeURL)
        } catch {
            // Persistence failure is logged but never propagated — the
            // saved store is best-effort. The in-memory state is still
            // accurate for the current session; we just won't survive
            // a relaunch. (Same posture as `SessionStore.persist`.)
            #if DEBUG
            print("SavedSessionsStore persist failed: \(error)")
            #endif
        }
    }

    nonisolated static func defaultStoreURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("swe-kitty", isDirectory: true)
            .appendingPathComponent("saved-sessions.json", isDirectory: false)
    }

    nonisolated private static func loadFromDisk(
        at url: URL
    ) -> (sessions: [SavedSession], deletedOrder: [String]) {
        guard let data = try? Data(contentsOf: url) else { return ([], []) }
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(StoreEnvelope.self, from: data) {
            // De-dup the persisted tombstone list while preserving order.
            var seen = Set<String>()
            let order = (envelope.deletedIDs ?? []).filter { seen.insert($0).inserted }
            return (Array(envelope.sessions.values), order)
        }
        // Belt-and-braces: also accept a bare top-level array in case a
        // future Rust revision flattens the envelope.
        if let bare = try? decoder.decode([SavedSession].self, from: data) {
            return (bare, [])
        }
        return ([], [])
    }

    nonisolated private static func write(
        sessions: [SavedSession],
        deletedOrder: [String],
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let envelope = StoreEnvelope(
            sessions: Dictionary(
                uniqueKeysWithValues: sessions.map { ($0.compoundID, $0) }
            ),
            deletedIDs: deletedOrder.isEmpty ? nil : deletedOrder
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        try data.write(to: url, options: .atomic)
    }

    /// Matches the Rust serde wrapper
    /// `struct SavedSessionStore { sessions: HashMap<String, SavedSession> }`,
    /// extended with an optional `deleted_ids` tombstone list. The field
    /// is optional + omitted-when-empty so the Rust core (which does not
    /// yet model it) round-trips the file untouched — serde ignores
    /// unknown fields by default, and an absent field decodes to nil
    /// here. Ordered newest-last for cap eviction.
    private struct StoreEnvelope: Codable {
        var sessions: [String: SavedSession]
        var deletedIDs: [String]?

        enum CodingKeys: String, CodingKey {
            case sessions
            case deletedIDs = "deleted_ids"
        }
    }

    // MARK: - Helpers

    /// UTF-8 safe truncation to 100 chars (`SUMMARY_MAX_CHARS` in Rust).
    /// Drops to the first line, trims, and appends `…` when the input is
    /// longer than the budget. Mirrors `core/src/saved/mod.rs::truncate_summary`
    /// so the Swift-side computed summary matches what the Rust side
    /// would have written for the same input.
    nonisolated static func truncateSummary(_ text: String) -> String {
        let firstLine = text
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init) ?? ""
        let cleaned = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let budget = 100
        if cleaned.count <= budget { return cleaned }
        return String(cleaned.prefix(budget - 1)) + "…"
    }

    private func mergeStatus(existing: SavedSessionStatus, next: SavedSessionStatus) -> SavedSessionStatus {
        // Exited is terminal — once we've seen it, never resurrect. Match
        // the Rust `merge_status` lattice (Unknown ⊏ Live ⊏ Exited).
        if existing == .exited || next == .exited { return .exited }
        if existing == .live || next == .live { return .live }
        return .unknown
    }
}
