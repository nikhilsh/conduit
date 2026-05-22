import SwiftUI

// MARK: - LitterDiscoveryView
//
// Network-discovery view wrapper. The legacy DiscoveryView handles the
// LAN mDNS browse + tap-to-pair flow; this is the LitterUI shim that
// exposes it under the namespace so call sites read uniformly.

extension LitterUI {
    struct DiscoveryView: View {
        @Environment(SessionStore.self) private var store

        var body: some View {
            LegacyDiscoveryWrapper().environment(store)
        }
    }
}

private struct LegacyDiscoveryWrapper: View {
    var body: some View { DiscoveryView() }
}
