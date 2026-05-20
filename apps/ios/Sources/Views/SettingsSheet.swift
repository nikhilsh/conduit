import SwiftUI

/// Settings — focused on managing **existing** servers and inspecting
/// state. Adding a new server (any of QR / mDNS / SSH / manual) goes
/// through [`AddServerSheet`] now, so this screen no longer has the
/// huge pairing form that used to dominate it.
struct SettingsSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var showAddServer = false

    var body: some View {
        NavigationStack {
            ZStack {
                SweKittyTheme.backgroundGradient(for: colorScheme)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        savedServersCard
                        addServerCTA
                        pairedCard
                        statusCard
                        aboutCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .tint(SweKittyTheme.accentStrong)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showAddServer) {
                AddServerSheet()
                    .environment(store)
            }
        }
    }

    // MARK: - Section cards

    @ViewBuilder
    private var savedServersCard: some View {
        if !store.savedServers.isEmpty {
            SettingsCard(title: "Saved Servers") {
                ForEach(store.savedServers) { server in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                                .foregroundStyle(SweKittyTheme.textBody)
                            Text(server.endpoint.displayHost)
                                .font(.caption)
                                .foregroundStyle(SweKittyTheme.textSecondary)
                        }
                        Spacer()
                        if server.isDefault {
                            Text("Default")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .glassCapsule(interactive: false, tint: SweKittyTheme.accentStrong.opacity(0.22))
                        }
                        Button("Use") {
                            store.selectSavedServer(server.id, autoConnect: true)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(SweKittyTheme.accentStrong)
                        Button(role: .destructive) {
                            store.removeSavedServer(server.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                    if server.id != store.savedServers.last?.id {
                        Divider().background(SweKittyTheme.separator)
                    }
                }
            }
        }
    }

    private var addServerCTA: some View {
        Button {
            showAddServer = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(SweKittyTheme.accentStrong)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add server")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SweKittyTheme.textPrimary)
                    Text("QR · LAN discover · SSH · paste URL+token")
                        .font(.caption)
                        .foregroundStyle(SweKittyTheme.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .glassRoundedRect()
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var pairedCard: some View {
        if store.endpoint.isComplete {
            SettingsCard(title: "Paired Harness") {
                FieldRow(label: "Host", value: store.endpoint.displayHost)
                Divider().background(SweKittyTheme.separator)
                FieldRow(label: "Token", value: "Stored in Keychain")
                Divider().background(SweKittyTheme.separator)
                Button(role: .destructive) {
                    store.endpoint = .empty
                    store.disconnect()
                } label: {
                    HStack(spacing: 10) {
                        Label("Forget harness", systemImage: "trash")
                            .foregroundStyle(SweKittyTheme.danger)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SweKittyTheme.textMuted)
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
        }
    }

    private var statusCard: some View {
        SettingsCard(title: "Harness Status") {
            HStack {
                Text("Link")
                    .foregroundStyle(SweKittyTheme.textBody)
                Spacer()
                HarnessBadge(state: store.harness)
            }
            if let reason = store.harness.failureReason {
                Divider().background(SweKittyTheme.separator)
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(SweKittyTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if shouldShowReconnect {
                Divider().background(SweKittyTheme.separator)
                Button {
                    store.reconnect()
                } label: {
                    HStack(spacing: 10) {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                            .foregroundStyle(SweKittyTheme.textBody)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SweKittyTheme.textMuted)
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
        }
    }

    /// Only show the manual Reconnect affordance when the link
    /// actually needs intervention. While the harness is live or
    /// in the middle of an auto-reconnect, surfacing a button labeled
    /// "Reconnect" reads like the connection is broken when it isn't.
    private var shouldShowReconnect: Bool {
        guard store.endpoint.isComplete else { return false }
        switch store.harness {
        case .disconnected, .failed: return true
        default: return false
        }
    }

    private var aboutCard: some View {
        SettingsCard(title: "About") {
            FieldRow(label: "App", value: "SweKitty")
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Divider().background(SweKittyTheme.separator)
                FieldRow(label: "Version", value: version)
            }
        }
    }
}

/// `swekitty://host[:port]?token=<bearer>` → (endpoint URL, token).
enum PairingURL {
    struct Parsed { let endpoint: String; let token: String }

    static func parse(_ raw: String) -> Parsed? {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased() else { return nil }
        let token = components.queryItems?.first(where: { $0.name.lowercased() == "token" })?.value ?? ""
        guard !token.isEmpty else { return nil }

        if scheme == "swekitty", let host = components.host {
            let port = components.port.map { ":\($0)" } ?? ""
            return Parsed(endpoint: "ws://\(host)\(port)", token: token)
        }

        if (scheme == "ws" || scheme == "wss"),
           let host = components.host {
            let port = components.port.map { ":\($0)" } ?? ""
            return Parsed(endpoint: "\(scheme)://\(host)\(port)", token: token)
        }
        return nil
    }
}

// MARK: - Building blocks

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(SweKittyTheme.textSecondary)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassRoundedRect()
        }
    }
}

private struct FieldRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(SweKittyTheme.textSecondary)
            Spacer()
            Text(value)
                .foregroundStyle(SweKittyTheme.textBody)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
