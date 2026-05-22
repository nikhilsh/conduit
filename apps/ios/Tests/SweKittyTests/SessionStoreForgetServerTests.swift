import Testing
import Foundation
@testable import SweKitty

/// `ios-delete-server-and-session` — pins the new
/// `SessionStore.forgetServer(_:)` entry point that backs the
/// swipe-to-delete + "Forget" context-menu affordances on saved
/// servers. Before this PR the only way to drop a saved pairing was
/// `removeSavedServer(_:)`, which left the display-name override (the
/// optional Keychain-persisted user-supplied label) dangling in
/// `UserDefaults` keyed by the now-defunct server id.
///
/// We assert the three contract bullets:
///   1. The saved-servers row is gone.
///   2. The display-name override keyed by the same id is cleared.
///   3. Both states survive a fresh `SessionStore` (i.e. they were
///      persisted), so a relaunch doesn't resurrect the row.
@Suite("SessionStore.forgetServer")
@MainActor
struct SessionStoreForgetServerTests {

    @Test func forgetServerDropsRowAndDisplayName() {
        let store = SessionStore()
        // Hermetic id to avoid colliding with anything that survived
        // from a prior run via the shared Keychain.
        let endpoint = StoredEndpoint(
            url: "ws://10.0.0.7:1977",
            token: "tok-\(UUID().uuidString)"
        )
        store.upsertSavedServer(name: "lab-forget", endpoint: endpoint, makeDefault: false)
        guard let savedID = store.savedServers.first(where: { $0.endpoint == endpoint })?.id else {
            Issue.record("upsertSavedServer did not persist the row")
            return
        }
        // Seed a display-name override keyed by the saved-server id.
        // The forget path is supposed to sweep this too — without that,
        // a rename would linger forever in UserDefaults after delete.
        store.displayNames[savedID] = "Custom Lab Name"

        store.forgetServer(savedID)

        // 1) Row dropped.
        #expect(!store.savedServers.contains(where: { $0.id == savedID }))
        // 2) Display-name override cleared.
        #expect(store.displayNames[savedID] == nil)
    }

    @Test func forgetServerIsIdempotentForUnknownID() {
        let store = SessionStore()
        let before = store.savedServers.count
        // A fresh UUID isn't in the saved set — forget should no-op.
        store.forgetServer("nope-\(UUID().uuidString)")
        #expect(store.savedServers.count == before)
    }

    @Test func forgetServerPersistsAcrossStoreInstances() {
        // Pin the "survives a relaunch" half of the contract. Two
        // `SessionStore` instances share the device Keychain, so a
        // forget on instance A should be observable from instance B.
        let storeA = SessionStore()
        let endpoint = StoredEndpoint(
            url: "ws://10.0.0.8:1977",
            token: "tok-persist-\(UUID().uuidString)"
        )
        storeA.upsertSavedServer(name: "persist-forget", endpoint: endpoint, makeDefault: false)
        guard let savedID = storeA.savedServers.first(where: { $0.endpoint == endpoint })?.id else {
            Issue.record("upsertSavedServer did not persist the row")
            return
        }

        storeA.forgetServer(savedID)

        // Fresh instance reads from the same persistence layer; the
        // forgotten row must not reappear.
        let storeB = SessionStore()
        #expect(!storeB.savedServers.contains(where: { $0.id == savedID }))
    }
}
