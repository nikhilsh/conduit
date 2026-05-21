import Testing
import Foundation
@testable import SweKitty

/// Litter parity audit item A.3 (iOS half) — defends the merge policy
/// that feeds `ServerPillRow`. The pure-data layer is
/// `DiscoveryMergePolicy.merge`, which combines saved + discovered
/// into the ordered pill list. The merge rule mirrors the Rust
/// `DiscoveryRegistry`'s priority semantics at the iOS layer: saved
/// pills always come first, and a discovered advertiser whose
/// host:port already appears in the saved set is suppressed.
@Suite("DiscoveryMergePolicy — saved + discovered merge")
struct DiscoveryViewModelTests {

    @Test func savedComesBeforeDiscovered() {
        // Visual contract: saved pills appear left, discovered to the
        // right, trailing `+ server` last. The merge must honour that
        // order regardless of the order rows arrive in.
        let saved = [
            mkSaved(name: "Studio", url: "ws://10.0.0.4:1977"),
            mkSaved(name: "Laptop", url: "ws://10.0.0.5:1977"),
        ]
        let discovered = [
            mkDiscovered(id: "kitty-7777", name: "kitty-7777", host: "10.0.0.99", port: 7777),
        ]
        let merged = DiscoveryMergePolicy.merge(
            saved: saved,
            discovered: discovered,
            currentEndpoint: StoredEndpoint.empty,
            harness: .disconnected
        )
        #expect(merged.map(\.kind) == [.saved, .saved, .discovered])
    }

    @Test func dedupeDropsDiscoveredAlreadySaved() {
        // The same advertiser can be both "I saved it last week" and
        // "mDNS just heard from it now". Surfacing both as separate
        // pills is noise — the saved one wins.
        let saved = [
            mkSaved(name: "Studio", url: "ws://10.0.0.4:1977"),
        ]
        let discovered = [
            mkDiscovered(id: "kitty-1977", name: "kitty-1977", host: "10.0.0.4", port: 1977),
            mkDiscovered(id: "kitty-extra", name: "kitty-extra", host: "10.0.0.5", port: 1977),
        ]
        let merged = DiscoveryMergePolicy.merge(
            saved: saved,
            discovered: discovered,
            currentEndpoint: StoredEndpoint.empty,
            harness: .disconnected
        )
        #expect(merged.count == 2)
        // Only the saved + the non-overlapping discovered row.
        let kinds = merged.map(\.kind)
        #expect(kinds == [.saved, .discovered])
        // Surviving discovered row should be the extra one.
        let discoveredSurvivor = merged.first { $0.kind == .discovered }
        #expect(discoveredSurvivor?.host == "10.0.0.5")
    }

    @Test func dedupeIsHostPortNotName() {
        // Names are user-editable / opaque. The merge key has to be
        // the connectible identity (host:port), not the display name.
        let saved = [
            mkSaved(name: "Studio Mac", url: "ws://10.0.0.4:1977"),
        ]
        let discovered = [
            // Same host:port, totally different mDNS name.
            mkDiscovered(id: "studios-mac.local.", name: "studios-mac.local.",
                         host: "10.0.0.4", port: 1977),
        ]
        let merged = DiscoveryMergePolicy.merge(
            saved: saved,
            discovered: discovered,
            currentEndpoint: StoredEndpoint.empty,
            harness: .disconnected
        )
        #expect(merged.count == 1)
        #expect(merged.first?.kind == .saved)
    }

    @Test func activeFlagFlipsForCurrentEndpoint() {
        // The pill that matches the active endpoint gets the green
        // `isActive` highlight. Make sure the merge honours that even
        // when the active endpoint sits at the end of the saved list.
        let active = StoredEndpoint(url: "ws://10.0.0.5:1977", token: "tok")
        let saved = [
            mkSaved(name: "Studio", url: "ws://10.0.0.4:1977"),
            mkSaved(name: "Laptop", url: "ws://10.0.0.5:1977"),
        ]
        let merged = DiscoveryMergePolicy.merge(
            saved: saved,
            discovered: [],
            currentEndpoint: active,
            harness: .live
        )
        #expect(merged[0].isActive == false)
        #expect(merged[1].isActive == true)
        #expect(merged[1].status == .live)
    }

    @Test func emptyDiscoveredYieldsSavedOnly() {
        // No mDNS results yet — the row still renders the saved set
        // (and the caller appends the `+ server` pill outside the
        // merge policy).
        let saved = [mkSaved(name: "Studio", url: "ws://10.0.0.4:1977")]
        let merged = DiscoveryMergePolicy.merge(
            saved: saved,
            discovered: [],
            currentEndpoint: StoredEndpoint.empty,
            harness: .disconnected
        )
        #expect(merged.count == 1)
        #expect(merged.first?.kind == .saved)
    }

    @Test func emptySavedYieldsDiscoveredOnly() {
        // Fresh install / forgot all saved servers: only the mDNS
        // results show. This is the empty-state path.
        let discovered = [
            mkDiscovered(id: "kitty-1977", name: "kitty-1977", host: "10.0.0.4", port: 1977),
        ]
        let merged = DiscoveryMergePolicy.merge(
            saved: [],
            discovered: discovered,
            currentEndpoint: StoredEndpoint.empty,
            harness: .disconnected
        )
        #expect(merged.count == 1)
        #expect(merged.first?.kind == .discovered)
    }

    // MARK: - Helpers

    private func mkSaved(name: String, url: String) -> SavedServer {
        SavedServer(
            id: UUID().uuidString,
            name: name,
            endpoint: StoredEndpoint(url: url, token: "tok"),
            isDefault: false
        )
    }

    private func mkDiscovered(id: String, name: String, host: String, port: Int) -> DiscoveryMergePolicy.DiscoveredInput {
        DiscoveryMergePolicy.DiscoveredInput(
            id: id,
            name: name,
            host: host,
            port: port,
            version: nil
        )
    }
}
