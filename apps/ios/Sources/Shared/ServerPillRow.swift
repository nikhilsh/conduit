import SwiftUI

/// Horizontal scrollable strip of `ServerPill` — saved first, then
/// discovered, then trailing `+ server` CTA. Used both on Home and
/// inside the DiscoveryView so the litter-style "pill row" affordance
/// stays consistent across the two surfaces.
///
/// Discovery state is provided by the caller (an `@State` browser),
/// not owned by this view. That keeps the row reusable: HomeView can
/// hold a long-lived browser; DiscoveryView can show the same row as
/// a "what you'll see on Home" preview.
struct ServerPillRow: View {
    @Environment(SessionStore.self) private var store
    /// Discovered rows piped in from a `LANDiscoveryBrowser` (or any
    /// other source). Empty when discovery is off.
    var discovered: [LANDiscoveryBrowser.Discovered] = []
    @Binding var showAddServer: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(savedModels) { model in
                    ServerPill(
                        model: model,
                        onTap: { selectSaved(model) },
                        onForget: { forgetSaved(model) },
                        onRename: { renameSaved(model) }
                    )
                }
                ForEach(discoveredModels) { model in
                    ServerPill(
                        model: model,
                        onTap: { connectDiscovered(model) },
                        onAdopt: { connectDiscovered(model) }
                    )
                }
                addPill
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Models

    private var savedModels: [ServerPillModel] {
        store.savedServers.map {
            ServerPillModel.fromSaved($0, currentEndpoint: store.endpoint, harness: store.harness)
        }
    }

    /// Discovered rows minus any whose host:port already appears in the
    /// saved list — surfacing the same advertiser twice would just be
    /// noise (and pairing flow naturally adopts it into `savedServers`).
    private var discoveredModels: [ServerPillModel] {
        let savedKeys: Set<String> = Set(store.savedServers.compactMap { savedKey($0) })
        return discovered.compactMap { row in
            let key = "\(row.host):\(row.port)"
            if savedKeys.contains(key) { return nil }
            return ServerPillModel.fromDiscovered(
                id: row.id,
                name: row.name,
                host: row.host,
                port: row.port,
                version: row.version,
                isActive: false
            )
        }
    }

    private func savedKey(_ server: SavedServer) -> String? {
        guard let (host, port) = ServerPillModel.splitHostPort(server.endpoint.url) else { return nil }
        return "\(host):\(port)"
    }

    // MARK: - Actions

    private func selectSaved(_ model: ServerPillModel) {
        let savedID = String(model.id.dropFirst("saved:".count))
        store.selectSavedServer(savedID, autoConnect: true)
    }

    private func forgetSaved(_ model: ServerPillModel) {
        let savedID = String(model.id.dropFirst("saved:".count))
        store.forgetServer(savedID)
    }

    private func renameSaved(_ model: ServerPillModel) {
        // The actual rename UI lives in SettingsSheet; the
        // context-menu hook in v1 of this row is a no-op placeholder
        // — wiring up an alert/sheet from inside a horizontal-scroll
        // cell is out of scope for the discovery-flesh-out PR. The
        // hook stays so a later pass can drop in an alert presenter
        // without churning the call sites.
        _ = model
    }

    private func connectDiscovered(_ model: ServerPillModel) {
        guard let row = discovered.first(where: { "discovered:\($0.id)" == model.id }) else { return }
        let endpoint = StoredEndpoint(
            url: "ws://\(row.host):\(row.port)",
            token: row.token
        )
        store.endpoint = endpoint
        store.upsertSavedServer(name: row.name, endpoint: endpoint, makeDefault: true)
        store.disconnect()
        store.connect()
    }

    private var addPill: some View {
        Button {
            showAddServer = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.caption.weight(.bold))
                Text("server")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(SweKittyTheme.accentStrong)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .stroke(SweKittyTheme.accentStrong, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add server")
    }
}

/// Pure-data merge policy for the `ServerPillRow`. Lifted out so the
/// dedupe-by-host:port rule and the saved-first ordering can be pinned
/// without a SwiftUI host. Mirrors the Rust `DiscoveryRegistry`'s
/// merge semantics (Saved wins over Discovered when host:port matches)
/// at the iOS layer — the registry will eventually own this, but until
/// the UniFFI surface lands we keep the policy here so the iOS view
/// has somewhere to point its tests at.
enum DiscoveryMergePolicy {
    struct DiscoveredInput: Equatable {
        let id: String
        let name: String
        let host: String
        let port: Int
        let version: String?
    }

    /// Merge saved + discovered into the ordered list of pills the row
    /// will render. Saved pills come first; discovered pills are
    /// filtered to remove anything whose host:port already appears in
    /// the saved set.
    static func merge(
        saved: [SavedServer],
        discovered: [DiscoveredInput],
        currentEndpoint: StoredEndpoint,
        harness: HarnessState
    ) -> [ServerPillModel] {
        let savedModels = saved.map {
            ServerPillModel.fromSaved($0, currentEndpoint: currentEndpoint, harness: harness)
        }
        let savedKeys: Set<String> = Set(saved.compactMap { server in
            guard let (host, port) = ServerPillModel.splitHostPort(server.endpoint.url) else { return nil }
            return "\(host):\(port)"
        })
        let discoveredModels = discovered.compactMap { input -> ServerPillModel? in
            let key = "\(input.host):\(input.port)"
            if savedKeys.contains(key) { return nil }
            return ServerPillModel.fromDiscovered(
                id: input.id,
                name: input.name,
                host: input.host,
                port: input.port,
                version: input.version,
                isActive: false
            )
        }
        return savedModels + discoveredModels
    }
}
