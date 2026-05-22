import Foundation

// MARK: - NetService-backed browser
//
// NetService is officially deprecated in iOS 17+, but it's the
// shortest path to host+port+TXT resolution and is still present in
// iOS 26. NWBrowser doesn't surface hostName directly — you have to
// dance with NWConnection to resolve. We'll migrate when we promote
// discovery to the Rust shared core (PLAN-2026-05-19.md Package 4).
//
// Extracted from the legacy `Views/DiscoveryView.swift` so the
// LitterUI tree can drive the same NetService glue without dragging
// the SwiftUI surface along. Behaviour is unchanged — see the
// original PR for the design rationale.

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
