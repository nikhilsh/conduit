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
//   - .ultraThinMaterial cards (`litterGlassRoundedRect`)
//   - footnote-sized row titles, mono caption secondary
//   - pull-to-refresh re-runs the mDNS browse

extension LitterUI {
    struct DiscoveryView: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.dismiss) private var dismiss

        @State private var browser = LANDiscoveryBrowser()
        @State private var showQRScanner = false
        @State private var showManualPair = false

        var body: some View {
            NavigationStack {
                ZStack {
                    LitterUI.Palette.surface.color.ignoresSafeArea()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            header
                            savedSection
                            nearbySection
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
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
            .tint(LitterUI.Palette.brand.color)
        }

        private var header: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("SweKitty on your network")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LitterUI.Palette.textPrimary.color)
                Text("Saved servers up top, plus anything advertising `_swe-kitty._tcp` on this Wi-Fi. Pull down to rescan.")
                    .font(.caption2)
                    .foregroundStyle(LitterUI.Palette.textMuted.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .litterGlassRoundedRect(cornerRadius: 14)
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
                    .foregroundStyle(isActive ? LitterUI.Palette.success.color : LitterUI.Palette.textMuted.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LitterUI.Palette.textBody.color)
                    Text(server.endpoint.displayHost)
                        .font(.caption2.monospaced())
                        .foregroundStyle(LitterUI.Palette.textSecondary.color)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LitterUI.Palette.textMuted.color)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .litterGlassRoundedRect(cornerRadius: 14)
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
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LitterUI.Palette.brand.color)
                            .frame(width: 28, height: 28)
                            .litterGlassCircle(tint: LitterUI.Palette.surfaceLight.color, config: .floating)
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
                        .font(.footnote)
                        .foregroundStyle(LitterUI.Palette.warning.color)
                    Text("No nearby servers")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LitterUI.Palette.textBody.color)
                }
                Text("Make sure the broker is on the same Wi-Fi, or scan a QR. mDNS doesn't cross subnets.")
                    .font(.caption2)
                    .foregroundStyle(LitterUI.Palette.textSecondary.color)
                HStack(spacing: 8) {
                    Button {
                        showQRScanner = true
                    } label: {
                        Label("Scan QR", systemImage: "qrcode.viewfinder")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .foregroundStyle(LitterUI.Palette.textOnAccent.color)
                            .background(LitterUI.Palette.brand.color.opacity(0.85))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Button {
                        showManualPair = true
                    } label: {
                        Label("Manual add", systemImage: "link")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .foregroundStyle(LitterUI.Palette.textPrimary.color)
                            .litterGlassCapsule(config: .pill)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .litterGlassRoundedRect(cornerRadius: 14)
        }

        @ViewBuilder
        private func discoveredRow(_ row: LANDiscoveryBrowser.Discovered) -> some View {
            HStack(spacing: 12) {
                Image(systemName: "wifi.circle.fill")
                    .font(.title3)
                    .foregroundStyle(LitterUI.Palette.brand.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LitterUI.Palette.textBody.color)
                    Text("\(row.host):\(row.port)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(LitterUI.Palette.textSecondary.color)
                    if let v = row.version, !v.isEmpty {
                        Text("v\(v)")
                            .font(.caption2)
                            .foregroundStyle(LitterUI.Palette.textMuted.color)
                    }
                }
                Spacer()
                Button {
                    connect(row)
                } label: {
                    Text("Pair")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LitterUI.Palette.textOnAccent.color)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(LitterUI.Palette.brand.color)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .litterGlassRoundedRect(cornerRadius: 14)
        }

        private func sectionLabel(_ text: String) -> some View {
            Text(text.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(LitterUI.Palette.textMuted.color)
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
