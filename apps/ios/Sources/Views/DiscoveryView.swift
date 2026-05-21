import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

import Foundation

/// LAN-discovery sheet: browses `_swe-kitty._tcp.local`, presents
/// saved + discovered harnesses side by side, taps connect through the
/// existing `SessionStore.upsertSavedServer` + `connect()` path.
///
/// Litter parity audit item A.3 (iOS half) — turns the scaffold into a
/// real "browse the LAN, see who's there" surface:
///   - Top: ServerPillRow (same strip as Home) so the user always sees
///     the saved + discovered set at a glance.
///   - "Saved servers": vertical list of richer rows, tap to switch.
///   - "Nearby": live mDNS results, refreshed continuously, each with
///     a `Pair` button calling the existing connect flow.
///   - Empty state with QR + manual-add CTAs.
///   - Pull-to-refresh re-triggers mDNS browse.
struct DiscoveryView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var browser = LANDiscoveryBrowser()
    @State private var showAddServer = false
    @State private var showQRScanner = false
    @State private var showManualPair = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    pillRow
                    savedSection
                    nearbySection
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
            }
            .refreshable {
                browser.restart()
                // Give the browser a beat to (re)collect rows so the
                // pull animation doesn't snap back to "no results" the
                // moment the user lets go.
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            .background(SweKittyTheme.backgroundGradient(for: colorScheme).ignoresSafeArea())
            .navigationTitle("Discover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { browser.start() }
            .onDisappear { browser.stop() }
            .sheet(isPresented: $showAddServer) {
                AddServerSheet().environment(store)
            }
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
                ManualPairSheet().environment(store)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SweKitty on your network")
                .font(.headline)
                .foregroundStyle(SweKittyTheme.textPrimary)
            Text("Saved servers up top, plus anything advertising `_swe-kitty._tcp` on this Wi-Fi. Pull down to rescan.")
                .font(.subheadline)
                .foregroundStyle(SweKittyTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassRect(cornerRadius: SweKittyTheme.cardCornerRadius)
    }

    // MARK: - Pill row

    private var pillRow: some View {
        ServerPillRow(discovered: browser.results, showAddServer: $showAddServer)
    }

    // MARK: - Saved section

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
                .font(.title2)
                .foregroundStyle(isActive ? SweKittyTheme.success : SweKittyTheme.textMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textBody)
                Text(server.endpoint.displayHost)
                    .font(.caption.monospaced())
                    .foregroundStyle(SweKittyTheme.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(SweKittyTheme.textMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassRoundedRect(cornerRadius: 16)
    }

    // MARK: - Nearby section

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
                    Label("Rescan", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .labelStyle(.iconOnly)
                        .foregroundStyle(SweKittyTheme.accentStrong)
                        .padding(8)
                        .glassCircle(tint: SweKittyTheme.surface.opacity(0.6))
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
                    .font(.title3)
                    .foregroundStyle(SweKittyTheme.warning)
                Text("No nearby servers")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textBody)
            }
            Text("Make sure the broker is on the same Wi-Fi, or scan a QR. mDNS doesn't cross subnets.")
                .font(.caption)
                .foregroundStyle(SweKittyTheme.textSecondary)
            HStack(spacing: 8) {
                Button {
                    showQRScanner = true
                } label: {
                    Label("Scan QR", systemImage: "qrcode.viewfinder")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .glassCapsule(interactive: true, tint: SweKittyTheme.accentStrong.opacity(0.4))
                        .foregroundStyle(SweKittyTheme.textPrimary)
                }
                .buttonStyle(.plain)
                Button {
                    showManualPair = true
                } label: {
                    Label("Manual add", systemImage: "link")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .glassCapsule(interactive: true, tint: SweKittyTheme.surface.opacity(0.7))
                        .foregroundStyle(SweKittyTheme.textPrimary)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassRect(cornerRadius: SweKittyTheme.cardCornerRadius)
    }

    @ViewBuilder
    private func discoveredRow(_ row: LANDiscoveryBrowser.Discovered) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.circle.fill")
                .font(.title2)
                .foregroundStyle(SweKittyTheme.accentStrong)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textBody)
                Text("\(row.host):\(row.port)")
                    .font(.caption.monospaced())
                    .foregroundStyle(SweKittyTheme.textSecondary)
                if let v = row.version, !v.isEmpty {
                    Text("v\(v)")
                        .font(.caption2)
                        .foregroundStyle(SweKittyTheme.textMuted)
                }
            }
            Spacer()
            Button {
                connect(row)
            } label: {
                Text("Pair")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textOnAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(SweKittyTheme.accentStrong)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassRoundedRect(cornerRadius: 16)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(SweKittyTheme.textMuted)
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

// MARK: - NetService-backed browser
//
// NetService is officially deprecated in iOS 17+, but it's the
// shortest path to host+port+TXT resolution and is still present in
// iOS 26. NWBrowser doesn't surface hostName directly — you have to
// dance with NWConnection to resolve. We'll migrate when we promote
// discovery to the Rust shared core (PLAN-2026-05-19.md Package 4).

@Observable
final class LANDiscoveryBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    struct Discovered: Identifiable, Equatable {
        let id: String
        let name: String
        let host: String
        let port: Int
        let token: String
        let version: String?
    }

    private(set) var results: [Discovered] = []
    /// True while the NetServiceBrowser is actively searching — used
    /// by the view to surface a spinner next to the "Nearby" header.
    private(set) var isBrowsing: Bool = false

    private let browser = NetServiceBrowser()
    private var pending: [NetService] = []

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        results.removeAll()
        pending.removeAll()
        browser.stop()
        isBrowsing = true
        browser.searchForServices(ofType: "_swe-kitty._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        pending.forEach { $0.stop() }
        pending.removeAll()
        isBrowsing = false
    }

    /// Stop + start so a pull-to-refresh or explicit "rescan" button
    /// surfaces newly-up advertisers without dropping rows that are
    /// still live (NetServiceBrowser re-delivers `didFind` for every
    /// active service after the new search begins).
    func restart() {
        stop()
        start()
    }

    // MARK: NetServiceBrowserDelegate

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        pending.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        results.removeAll { $0.id == service.name }
        pending.removeAll { $0 === service }
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        isBrowsing = false
    }

    // MARK: NetServiceDelegate

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName, sender.port > 0 else { return }
        let txt = sender.txtRecordData().map { NetService.dictionary(fromTXTRecord: $0) } ?? [:]
        let token = txt["token"].flatMap { String(data: $0, encoding: .utf8) } ?? ""
        guard !token.isEmpty else { return }
        let version = txt["v"].flatMap { String(data: $0, encoding: .utf8) }
        let cleanHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        let row = Discovered(
            id: sender.name,
            name: sender.name,
            host: cleanHost,
            port: sender.port,
            token: token,
            version: version
        )
        if !results.contains(where: { $0.id == row.id }) {
            results.append(row)
        }
        pending.removeAll { $0 === sender }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        pending.removeAll { $0 === sender }
    }
}
