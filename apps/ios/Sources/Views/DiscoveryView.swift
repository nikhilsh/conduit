import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

import Foundation

/// LAN-discovery sheet: browses `_swe-kitty._tcp.local`, presents
/// resolved harnesses, taps connect through the existing
/// `SessionStore.upsertSavedServer` + `connect()` path.
///
/// Mirrors the Android `DiscoveryScreen.kt`. Sibling to
/// `QRScannerSheet` / `SSHLoginSheet` as a third add-server entry.
struct DiscoveryView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var browser = LANDiscoveryBrowser()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if browser.results.isEmpty {
                        emptyCard
                    } else {
                        ForEach(browser.results) { row in
                            Button {
                                connect(row)
                            } label: {
                                discoveredRow(row)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
            }
            .background(SweKittyTheme.backgroundGradient(for: colorScheme).ignoresSafeArea())
            .navigationTitle("Discover on LAN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { browser.start() }
            .onDisappear { browser.stop() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SweKitty on your network")
                .font(.headline)
                .foregroundStyle(SweKittyTheme.textPrimary)
            Text("Browsing for `_swe-kitty._tcp` advertisers. The harness must be running with `--local` on the same Wi-Fi.")
                .font(.subheadline)
                .foregroundStyle(SweKittyTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassRect(cornerRadius: SweKittyTheme.cardCornerRadius)
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                Text("Looking for harnesses…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textBody)
            }
            Text("Nothing yet. If you've just started the harness, give it a few seconds. mDNS doesn't cross subnets — phone and harness must share the LAN.")
                .font(.caption)
                .foregroundStyle(SweKittyTheme.textSecondary)
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
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(SweKittyTheme.textMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassRoundedRect(cornerRadius: 16)
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
        browser.searchForServices(ofType: "_swe-kitty._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        pending.forEach { $0.stop() }
        pending.removeAll()
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
