import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

import Foundation

// MARK: - LitterDiscoveryView
//
// Native LitterUI port of the legacy `DiscoveryView`. Browses
// `_swe-kitty._tcp.local` via the NetService-backed
// `LANDiscoveryBrowser`, lists saved + discovered harnesses, and taps
// connect through the existing `SessionStore` flow.
//
// Visual style:
//   - small-caps "SAVED" / "NEARBY" section labels
//   - neon card surfaces (`neonCardSurface(...)`)
//   - footnote-sized row titles, mono caption secondary
//   - pull-to-refresh re-runs the mDNS browse

extension LitterUI {
    struct DiscoveryView: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        @State private var browser = LANDiscoveryBrowser()
        @State private var showQRScanner = false
        @State private var showManualPair = false

        var body: some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            header
                            savedSection
                            nearbySection
                        }
                        // PLAN-LITTER-VISUAL-PARITY audit §A.4 / PR 5
                        // deferred — bump outer container to 20h/12v
                        // so saved + nearby cards breathe like litter's
                        // discovery reference (vs the prior 14/16
                        // which had cards kissing the screen edge).
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    }
                    .refreshable {
                        browser.restart()
                        try? await Task.sleep(nanoseconds: 600_000_000)
                    }
                }
                .navigationTitle("Discover")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") { dismiss() }
                    }
                }
                .onAppear { browser.start() }
                .onDisappear { browser.stop() }
                .sheet(isPresented: $showQRScanner) {
                    QRScannerSheet { code in
                        if let parsed = PairingURL.parse(code) {
                            let next = StoredEndpoint(url: parsed.endpoint, token: parsed.token)
                            store.endpoint = next
                            store.upsertSavedServer(name: next.displayHost, endpoint: next, makeDefault: true)
                            store.disconnect()
                            store.connect()
                            dismiss()
                        }
                    }
                }
                .sheet(isPresented: $showManualPair) {
                    LitterManualPairSheet().environment(store)
                }
            }
            .tint(neon.accent)
        }

        private var header: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("SweKitty on your network")
                    .font(neon.sans(13).weight(.semibold))
                    .foregroundStyle(neon.text)
                Text("Saved servers up top, plus anything advertising `_swe-kitty._tcp` on this Wi-Fi. Pull down to rescan.")
                    .font(neon.sans(11))
                    .foregroundStyle(neon.textDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 13)
        }

        @ViewBuilder
        private var savedSection: some View {
            if !store.savedServers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Saved servers")
                    ForEach(store.savedServers) { server in
                        Button {
                            store.selectSavedServer(server.id, autoConnect: true)
                            dismiss()
                        } label: {
                            savedRow(server)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }

        private func savedRow(_ server: SavedServer) -> some View {
            let isActive = store.endpoint == server.endpoint
            return HStack(spacing: 12) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.title3)
                    .foregroundStyle(isActive ? neon.green : neon.textFaint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(neon.sans(13).weight(.semibold))
                        .foregroundStyle(neon.text)
                    Text(server.endpoint.displayHost)
                        .font(neon.mono(11))
                        .foregroundStyle(neon.textDim)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(neon.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .neonCardSurface(
                neon,
                fill: isActive ? neon.accent.opacity(neon.dark ? 0.14 : 0.10) : neon.surface,
                cornerRadius: 13,
                glowTint: isActive ? neon.accent : nil
            )
        }

        @ViewBuilder
        private var nearbySection: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    sectionLabel("Nearby")
                    if browser.isBrowsing {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer()
                    Button {
                        browser.restart()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(neon.accent)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(neon.surface))
                            .overlay(Circle().stroke(neon.borderStrong, lineWidth: 1))
                            .neonGlowBox(neon.glow ? neon.glowBox : nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rescan for nearby servers")
                }
                if browser.results.isEmpty {
                    emptyNearby
                } else {
                    ForEach(browser.results) { row in
                        discoveredRow(row)
                    }
                }
            }
        }

        private var emptyNearby: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 13))
                        .foregroundStyle(neon.yellow)
                    Text("No nearby servers")
                        .font(neon.sans(13).weight(.semibold))
                        .foregroundStyle(neon.text)
                }
                Text("Make sure the broker is on the same Wi-Fi, or scan a QR. mDNS doesn't cross subnets.")
                    .font(neon.sans(11))
                    .foregroundStyle(neon.textDim)
                HStack(spacing: 8) {
                    Button {
                        showQRScanner = true
                    } label: {
                        Label("Scan QR", systemImage: "qrcode.viewfinder")
                            .font(neon.sans(12).weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .foregroundStyle(neon.accentText)
                            .background(Capsule().fill(neon.accent))
                            .neonGlowBox(neon.glow ? neon.glowBox : nil)
                    }
                    .buttonStyle(.plain)
                    Button {
                        showManualPair = true
                    } label: {
                        Label("Manual add", systemImage: "link")
                            .font(neon.sans(12).weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .foregroundStyle(neon.text)
                            .background(Capsule().fill(neon.surface))
                            .overlay(Capsule().stroke(neon.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 13)
        }

        @ViewBuilder
        private func discoveredRow(_ row: LANDiscoveryBrowser.Discovered) -> some View {
            HStack(spacing: 12) {
                Image(systemName: "wifi.circle.fill")
                    .font(.title3)
                    .foregroundStyle(neon.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(neon.sans(13).weight(.semibold))
                        .foregroundStyle(neon.text)
                    Text("\(row.host):\(row.port)")
                        .font(neon.mono(11))
                        .foregroundStyle(neon.textDim)
                    if let v = row.version, !v.isEmpty {
                        Text("v\(v)")
                            .font(neon.sans(11))
                            .foregroundStyle(neon.textFaint)
                    }
                }
                Spacer()
                Button {
                    connect(row)
                } label: {
                    Text("Pair")
                        .font(neon.sans(12).weight(.semibold))
                        .foregroundStyle(neon.accentText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(neon.accent))
                        .neonGlowBox(neon.glow ? neon.glowBox : nil)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 13)
        }

        private func sectionLabel(_ text: String) -> some View {
            Text(text.uppercased())
                .font(neon.mono(11).weight(.bold))
                .tracking(0.6)
                .foregroundStyle(neon.textFaint)
                .padding(.leading, 4)
        }

        private func connect(_ row: LANDiscoveryBrowser.Discovered) {
            let endpoint = StoredEndpoint(
                url: "ws://\(row.host):\(row.port)",
                token: row.token
            )
            store.endpoint = endpoint
            store.upsertSavedServer(name: row.name, endpoint: endpoint, makeDefault: true)
            store.disconnect()
            store.connect()
            dismiss()
        }
    }
}
