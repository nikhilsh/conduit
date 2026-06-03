import Testing
import Foundation
@testable import Conduit

/// Cold-launch terminal restore: `SessionStore` mirrors each session's
/// scrollback to a small per-session file so a reopened session paints the
/// last-known terminal instantly instead of a blank wait for the socket. The
/// broker's live snapshot then replaces it. These tests exercise the
/// persist → (new process) → hydrate round-trip, the tail cap, and cleanup.
@Suite("SessionStore.terminalPersistence")
@MainActor
struct TerminalScrollbackPersistenceTests {

    @Test func persistThenHydrateRoundTrip() {
        let sessionID = "term-persist-roundtrip-\(UUID().uuidString)"
        let writer = SessionStore()
        writer.ingestPtyData(sessionID, Data("scrollback survives a kill".utf8))
        writer.flushTerminalPersist()
        writer.waitForTerminalPersistIO()   // writes are async now

        // A fresh store models the next app launch: nothing in memory yet.
        let reader = SessionStore()
        #expect(reader.terminalBuffer[sessionID] == nil)
        reader.hydrateTerminalBuffer(sessionID)
        #expect(reader.terminalBuffer[sessionID] == Data("scrollback survives a kill".utf8))

        reader.discardPersistedTerminal(sessionID)
    }

    @Test func hydrateDoesNotClobberLiveBytes() {
        let sessionID = "term-persist-noclobber-\(UUID().uuidString)"
        let writer = SessionStore()
        writer.ingestPtyData(sessionID, Data("stale-on-disk".utf8))
        writer.flushTerminalPersist()
        writer.waitForTerminalPersistIO()   // writes are async now

        let store = SessionStore()
        // Live bytes already present (e.g. a fresh snapshot arrived first).
        store.ingestSnapshot(sessionID, Data("live-and-authoritative".utf8))
        store.hydrateTerminalBuffer(sessionID)
        #expect(store.terminalBuffer[sessionID] == Data("live-and-authoritative".utf8))

        store.discardPersistedTerminal(sessionID)
    }

    @Test func persistKeepsTailWithinCap() {
        let sessionID = "term-persist-cap-\(UUID().uuidString)"
        let cap = 256 * 1024
        // Distinguishable tail: 0x00 filler then a known marker at the very end.
        let marker = Data("THE-LATEST-BYTES".utf8)
        var big = Data(count: cap)            // exactly cap of zeros
        big.append(Data(count: 5_000))        // push us over the cap
        big.append(marker)

        let writer = SessionStore()
        writer.ingestPtyData(sessionID, big)
        writer.flushTerminalPersist()
        writer.waitForTerminalPersistIO()   // writes are async now

        let reader = SessionStore()
        reader.hydrateTerminalBuffer(sessionID)
        let restored = reader.terminalBuffer[sessionID] ?? Data()
        #expect(restored.count == cap)
        // The most-recent bytes (the marker) must be retained at the tail.
        #expect(restored.suffix(marker.count) == marker)

        reader.discardPersistedTerminal(sessionID)
    }

    @Test func discardRemovesPersistedFile() {
        let sessionID = "term-persist-discard-\(UUID().uuidString)"
        let writer = SessionStore()
        writer.ingestPtyData(sessionID, Data("temporary".utf8))
        writer.flushTerminalPersist()
        writer.waitForTerminalPersistIO()   // writes are async now
        writer.discardPersistedTerminal(sessionID)

        let reader = SessionStore()
        reader.hydrateTerminalBuffer(sessionID)
        #expect(reader.terminalBuffer[sessionID] == nil)
    }
}
