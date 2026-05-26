import Testing
import Foundation
@testable import SweKitty

/// `ios-sessions-history` — `SavedSessionsStore` JSON round-trip and
/// upsert semantics. Mirror of the Rust tests in `core/src/saved/mod.rs`
/// so the cross-language contract (idempotency, summary truncation,
/// first-seen sticky, exited-is-terminal) stays in lock-step.
///
/// We instantiate the store with a tmp `storeURL` per test so the
/// suite is hermetic — no shared global state, no clobbering the
/// real Application Support file the app uses.
@Suite("SavedSessionsStore — A.8 resume history")
@MainActor
struct SavedSessionsStoreTests {

    // MARK: - JSON round-trip

    @Test func savedSessionRoundTripsThroughJSON() throws {
        let row = SavedSession(
            id: "s-1",
            serverID: "srv-a",
            agent: "claude",
            cwd: "/repo",
            firstSeen: "2026-05-20T00:00:00Z",
            lastSeen: "2026-05-20T01:00:00Z",
            messageCount: 4,
            summary: "fix the build",
            status: .live
        )

        let data = try JSONEncoder().encode(row)
        let restored = try JSONDecoder().decode(SavedSession.self, from: data)

        #expect(restored == row)
    }

    @Test func jsonKeysUseRustSnakeCase() throws {
        // The on-disk file is produced + consumed by both sides
        // (Rust core + Swift), so the wire keys must match the Rust
        // `#[derive(Serialize)]` repr. Pin the snake_case mapping
        // here so a careless rename of a Swift property doesn't break
        // the cross-language contract.
        let row = SavedSession(
            id: "s-1", serverID: "srv-a", agent: "claude", cwd: nil,
            firstSeen: "ts-0", lastSeen: "ts-1",
            messageCount: 0, summary: "", status: .unknown
        )
        let data = try JSONEncoder().encode(row)
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(raw.contains("\"server_id\""))
        #expect(raw.contains("\"first_seen\""))
        #expect(raw.contains("\"last_seen\""))
        #expect(raw.contains("\"message_count\""))
        // status should be lowercase tag — matching the Rust
        // `#[serde(rename_all = "lowercase")]`.
        #expect(raw.contains("\"unknown\""))
    }

    // MARK: - Upsert preserves IDs

    @Test func upsertPreservesIDsAcrossCalls() {
        let store = makeStore()
        let session = ProjectSession(
            id: "s-keep-id",
            name: "s-keep-id",
            assistant: "claude",
            branch: nil,
            preview: nil,
            reasoningEffort: nil,
            cwd: "/repo",
            startedAt: "2026-05-20T00:00:00Z",
            lastActivityAt: "2026-05-20T00:00:00Z",
            displayName: nil
        )
        store.upsert(
            session: session,
            serverID: "srv-1",
            status: nil,
            firstUserMessage: "first",
            messageCount: 1,
            isExited: false
        )
        store.upsert(
            session: session,
            serverID: "srv-1",
            status: nil,
            firstUserMessage: "first",
            messageCount: 2,
            isExited: false
        )

        let rows = store.recent()
        #expect(rows.count == 1)
        #expect(rows[0].id == "s-keep-id")
        #expect(rows[0].serverID == "srv-1")
        #expect(rows[0].messageCount == 2)
    }

    @Test func upsertSameSessionDifferentServersAreDistinct() {
        let store = makeStore()
        let session = makeSession(id: "s-dup")
        store.upsert(session: session, serverID: "srv-a", status: nil,
                     firstUserMessage: "hi", messageCount: 1, isExited: false)
        store.upsert(session: session, serverID: "srv-b", status: nil,
                     firstUserMessage: "hi", messageCount: 1, isExited: false)
        #expect(store.recent().count == 2)
    }

    @Test func exitedIsTerminal() {
        let store = makeStore()
        let session = makeSession(id: "s-exit")
        store.upsert(session: session, serverID: "srv-a", status: nil,
                     firstUserMessage: "hi", messageCount: 1, isExited: true)
        // A stale "live" upsert must not resurrect the exited row.
        store.upsert(session: session, serverID: "srv-a", status: nil,
                     firstUserMessage: "hi", messageCount: 1, isExited: false)
        let row = store.recent().first
        #expect(row?.status == .exited)
    }

    @Test func summaryTruncatedToHundredChars() {
        let long = String(repeating: "a", count: 250)
        let out = SavedSessionsStore.truncateSummary(long)
        #expect(out.count == 100)
        #expect(out.hasSuffix("…"))
    }

    @Test func summaryDropsToFirstLine() {
        let multi = "line one\nline two"
        #expect(SavedSessionsStore.truncateSummary(multi) == "line one")
    }

    // MARK: - Disk round-trip

    @Test func persistsAndReloadsFromDisk() {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let store = SavedSessionsStore(storeURL: url)
            let session = makeSession(id: "s-disk")
            store.upsert(
                session: session,
                serverID: "srv-a",
                status: nil,
                firstUserMessage: "from disk",
                messageCount: 1,
                isExited: false
            )
        }
        // Second instance — must pick up the on-disk state.
        let restored = SavedSessionsStore(storeURL: url)
        let row = restored.recent().first
        #expect(row?.id == "s-disk")
        #expect(row?.summary == "from disk")
        #expect(row?.serverID == "srv-a")
    }

    // MARK: - Tombstone (delete-is-terminal across broker re-reports)

    @Test func removeTombstonesAndSuppressesReUpsert() {
        // The deployed broker keeps tmux-backed PTYs alive (#199), so a
        // just-deleted session can still surface on the next status/list
        // delta and feed back into `upsert`. The tombstone must block it.
        let store = makeStore()
        let session = makeSession(id: "s-zombie")
        store.upsert(session: session, serverID: "srv-a", status: nil,
                     firstUserMessage: "hi", messageCount: 1, isExited: false)
        #expect(store.recent().count == 1)

        store.remove(id: "s-zombie")
        #expect(store.recent().isEmpty)
        #expect(store.isTombstoned(id: "s-zombie"))

        // Broker re-reports the still-alive session → must NOT reappear.
        store.upsert(session: session, serverID: "srv-a", status: nil,
                     firstUserMessage: "hi", messageCount: 2, isExited: false)
        #expect(store.recent().isEmpty)
        #expect(store.isTombstoned(id: "s-zombie"))
    }

    @Test func tombstonePersistsAcrossLaunches() {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let store = SavedSessionsStore(storeURL: url)
            store.upsert(session: makeSession(id: "s-gone"), serverID: "srv-a",
                         status: nil, firstUserMessage: "bye", messageCount: 1,
                         isExited: false)
            store.remove(id: "s-gone")
        }
        // Relaunch: the tombstone must survive so a broker re-report on
        // the next session-refresh still can't resurrect the row.
        let restored = SavedSessionsStore(storeURL: url)
        #expect(restored.isTombstoned(id: "s-gone"))
        #expect(restored.recent().isEmpty)
        restored.upsert(session: makeSession(id: "s-gone"), serverID: "srv-a",
                        status: nil, firstUserMessage: "bye", messageCount: 1,
                        isExited: false)
        #expect(restored.recent().isEmpty)
    }

    // MARK: - Two-tier delete model (archive vs permanent delete)

    @Test func archiveKeepsHistoryRowWithoutTombstone() {
        // ARCHIVE (home-list swipe → `SessionStore.archive`) ends the live
        // session on the broker but must NOT touch the saved index: the row
        // stays in History as a read-only transcript and is NOT tombstoned,
        // so a later broker re-report can legitimately keep it fresh.
        let store = makeStore()
        let session = makeSession(id: "s-archived")
        store.upsert(session: session, serverID: "srv-a", status: nil,
                     firstUserMessage: "hi", messageCount: 1, isExited: false)

        // Archive does NOT call `remove` — the History row survives, no
        // tombstone is recorded.
        #expect(store.recent().contains { $0.id == "s-archived" })
        #expect(!store.isTombstoned(id: "s-archived"))

        // A subsequent upsert (broker still reports it post-archive) keeps
        // the row in History — archive is not terminal for the saved index.
        store.upsert(session: session, serverID: "srv-a", status: nil,
                     firstUserMessage: "hi", messageCount: 2, isExited: true)
        #expect(store.recent().contains { $0.id == "s-archived" })
        #expect(!store.isTombstoned(id: "s-archived"))
    }

    @Test func permanentDeleteTombstonesAndDropsFromHistory() {
        // PERMANENT DELETE (History-only → `SessionStore.permanentlyDelete`
        // → `SavedSessionsStore.remove`) removes the row from History AND
        // tombstones it so it can never reappear. This is the only path
        // that tombstones — the home-list swipe (archive) must not.
        let store = makeStore()
        let session = makeSession(id: "s-permadelete")
        store.upsert(session: session, serverID: "srv-a", status: nil,
                     firstUserMessage: "hi", messageCount: 1, isExited: false)
        #expect(store.recent().contains { $0.id == "s-permadelete" })

        store.remove(id: "s-permadelete")
        #expect(!store.recent().contains { $0.id == "s-permadelete" })
        #expect(store.isTombstoned(id: "s-permadelete"))
    }

    @Test func resetClearsTombstones() {
        let store = makeStore()
        store.remove(id: "s-x")
        #expect(store.isTombstoned(id: "s-x"))
        store.reset()
        #expect(!store.isTombstoned(id: "s-x"))
    }

    @Test func deletedIDsFieldUsesRustSnakeCaseAndOmitsWhenEmpty() {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SavedSessionsStore(storeURL: url)

        // Empty tombstone set → field omitted so the Rust core
        // round-trips the file untouched.
        store.upsert(session: makeSession(id: "s-1"), serverID: "srv-a",
                     status: nil, firstUserMessage: "x", messageCount: 1,
                     isExited: false)
        let emptyRaw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(!emptyRaw.contains("deleted_ids"))

        // After a delete → snake_case key present.
        store.remove(id: "s-1")
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(raw.contains("\"deleted_ids\""))
    }

    // MARK: - Helpers

    private func makeStore() -> SavedSessionsStore {
        SavedSessionsStore(storeURL: tmpURL())
    }

    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("swekitty-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("saved-sessions.json")
    }

    private func makeSession(id: String) -> ProjectSession {
        ProjectSession(
            id: id,
            name: id,
            assistant: "claude",
            branch: nil,
            preview: nil,
            reasoningEffort: nil,
            cwd: nil,
            startedAt: "2026-05-20T00:00:00Z",
            lastActivityAt: "2026-05-20T00:00:00Z",
            displayName: nil
        )
    }
}
