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

    /// Resolved persistence path, exposed for tests + diagnostics.
    let storeURL: URL

    init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? SavedSessionsStore.defaultStoreURL()
        self.sessions = Self.loadFromDisk(at: self.storeURL)
    }

    /// Latest-first slice clamped to `limit`. Ties broken by id so
    /// snapshot tests stay deterministic — mirrors the Rust
    /// `list_recent` ordering rule.
    func recent(limit: Int = 200) -> [SavedSession] {
        let sorted = sessions.sorted { lhs, rhs in
            if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
            return lhs.id < rhs.id
        }
        if sorted.count <= limit { return sorted }
        return Array(sorted.prefix(limit))
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

    /// Drop every row. Test-only convenience — the production app has
    /// no "clear history" affordance yet.
    func reset() {
        sessions = []
        persist()
    }

    /// Remove every saved-session row whose session-id equals `id`.
    /// Idempotent — no-op when the id is unknown. Used by the Sessions
    /// history screen's swipe-to-delete: the user already deleted the
    /// live row via `store.exit(...)`, this clears the persistent
    /// `Resume` entry so the row doesn't reappear on next launch.
    /// Matches across servers because the harness mints UUIDs unique
    /// per session and the user expects "delete" to be terminal.
    func remove(id: String) {
        let before = sessions.count
        sessions.removeAll { $0.id == id }
        if sessions.count != before {
            persist()
        }
    }

    // MARK: - Persistence

    private func persist() {
        do {
            try Self.write(sessions: sessions, to: storeURL)
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

    nonisolated private static func loadFromDisk(at url: URL) -> [SavedSession] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(StoreEnvelope.self, from: data) {
            return Array(envelope.sessions.values)
        }
        // Belt-and-braces: also accept a bare top-level array in case a
        // future Rust revision flattens the envelope.
        return (try? decoder.decode([SavedSession].self, from: data)) ?? []
    }

    nonisolated private static func write(sessions: [SavedSession], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let envelope = StoreEnvelope(
            sessions: Dictionary(
                uniqueKeysWithValues: sessions.map { ($0.compoundID, $0) }
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        try data.write(to: url, options: .atomic)
    }

    /// Matches the Rust serde wrapper:
    /// `struct SavedSessionStore { sessions: HashMap<String, SavedSession> }`.
    private struct StoreEnvelope: Codable {
        var sessions: [String: SavedSession]
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
