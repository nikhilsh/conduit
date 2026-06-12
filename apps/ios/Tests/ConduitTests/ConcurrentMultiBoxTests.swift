import Testing
import Foundation
@testable import Conduit

/// `concurrent-multibox-ios` (first cut) — pins the two load-bearing
/// invariants of the multi-box registry + op-routing seam:
///
///   1. **Flag OFF = byte-equivalent single-box behaviour.** With the flag
///      off, `clientForSession` ignores any `sessionBox` stamp and always
///      resolves to the single global `client`, and the registry helpers are
///      inert (`connectBox` is a no-op). Exactly as before this PR.
///
///   2. **Flag ON routes by ownership.** A session stamped to a connected box
///      resolves to THAT box's client; disconnecting one box drops only its
///      connection and leaves the others. (We can't open a real WS in a unit
///      test, so we drive the registry state directly and assert the
///      routing/teardown bookkeeping — the part that decides which broker an
///      op reaches.)
///
/// The flag is read statically from `UserDefaults.standard`
/// (`FeatureFlags.concurrentMultiBoxEnabled`), so each test sets it
/// explicitly and restores it after.
@Suite("ConcurrentMultiBox")
@MainActor
struct ConcurrentMultiBoxTests {

    private static let flagKey = "conduit.flags.transport.concurrentMultiBox"

    private func withFlag(_ on: Bool, _ body: () -> Void) {
        let prior = UserDefaults.standard.object(forKey: Self.flagKey)
        UserDefaults.standard.set(on, forKey: Self.flagKey)
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: Self.flagKey) }
            else { UserDefaults.standard.removeObject(forKey: Self.flagKey) }
        }
        body()
    }

    // MARK: - Invariant 1: flag OFF is inert / single-box

    @Test func flagOffMeansMultiBoxDisabledAndRegistryInert() {
        withFlag(false) {
            let store = SessionStore()
            #expect(store.multiBoxEnabled == false)
            // Even with a stamp present, flag OFF → the seam ignores it and
            // falls back to the single client (nil here — nothing connected).
            store.sessionBox["s1"] = "box-A"
            #expect(store.clientForSession("s1") == nil)
            // connectBox is a no-op when the flag is off.
            let ep = StoredEndpoint(url: "ws://10.0.0.9:1977", token: "tok-\(UUID().uuidString)")
            store.upsertSavedServer(name: "off-box", endpoint: ep, makeDefault: false)
            let id = store.savedServers.first(where: { $0.endpoint == ep })!.id
            store.connectBox(id)
            #expect(store.boxConnections.isEmpty)
            #expect(store.isBoxConnected(id) == false)
        }
    }

    // MARK: - Invariant 2: flag ON, ownership + independent teardown

    @Test func ownershipRoutingAndIndependentTeardown() {
        withFlag(true) {
            let store = SessionStore()
            #expect(store.multiBoxEnabled == true)

            let epA = StoredEndpoint(url: "ws://10.0.0.10:1977", token: "tA-\(UUID().uuidString)")
            let epB = StoredEndpoint(url: "ws://10.0.0.11:1977", token: "tB-\(UUID().uuidString)")
            store.upsertSavedServer(name: "box-A", endpoint: epA, makeDefault: false)
            store.upsertSavedServer(name: "box-B", endpoint: epB, makeDefault: false)
            let idA = store.savedServers.first(where: { $0.endpoint == epA })!.id
            let idB = store.savedServers.first(where: { $0.endpoint == epB })!.id

            // Drive registry state directly (no live WS in a unit test).
            let connA = BoxConnection(
                server: store.savedServers.first(where: { $0.id == idA })!,
                client: ConduitClient(endpoint: epA.url, bearerToken: epA.token),
                delegate: StoreDelegate(store: store, boxID: idA)
            )
            let connB = BoxConnection(
                server: store.savedServers.first(where: { $0.id == idB })!,
                client: ConduitClient(endpoint: epB.url, bearerToken: epB.token),
                delegate: StoreDelegate(store: store, boxID: idB)
            )
            store.boxConnections[idA] = connA
            store.boxConnections[idB] = connB
            store.primaryBoxID = idA
            store.sessionBox["sA"] = idA
            store.sessionBox["sB"] = idB

            // Ownership routing: each session resolves to ITS box's client.
            #expect(store.clientForSession("sA") === connA.client)
            #expect(store.clientForSession("sB") === connB.client)

            // Disconnect box A: only A's connection drops; B stays whole.
            store.disconnectBox(idA)
            #expect(store.isBoxConnected(idA) == false)
            #expect(store.isBoxConnected(idB) == true)
            // Primary moved off the disconnected box.
            #expect(store.primaryBoxID == idB)
            // sA now has no connected owner → falls back to the single client (nil).
            #expect(store.clientForSession("sA") == nil)
            // B still routes correctly.
            #expect(store.clientForSession("sB") === connB.client)
        }
    }

    @Test func loopbackSshBoxIsDeferredFromRegistry() {
        // First-cut scope: SSH/loopback boxes don't join the multi-box
        // registry (their endpoint is bound to a tunnel the single-box path
        // holds). connectBox must skip rather than dial a dead port.
        withFlag(true) {
            let store = SessionStore()
            let loop = StoredEndpoint(url: "ws://127.0.0.1:54321", token: "loop-\(UUID().uuidString)")
            store.upsertSavedServer(name: "ssh-box", endpoint: loop, makeDefault: false)
            let id = store.savedServers.first(where: { $0.endpoint == loop })!.id
            store.connectBox(id)
            #expect(store.isBoxConnected(id) == false)
            #expect(SessionStore.isLoopbackEndpoint(loop) == true)
        }
    }
}
