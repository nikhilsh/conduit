import SwiftUI

/// v1: manual endpoint + bearer token entry, or paste from a scanned
/// `swekitty://<host>?token=<bearer>` QR. mDNS browser lands in a
/// post-v1 task.
struct SettingsSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var url: String = ""
    @State private var token: String = ""
    @State private var showScanner: Bool = false
    @State private var scanError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                SweKittyTheme.backgroundGradient(for: colorScheme)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        savedServersCard
                        pairedCard
                        pairingCard
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
            .onAppear {
                url = store.endpoint.url
                token = store.endpoint.token
            }
            .sheet(isPresented: $showScanner) {
                QRScannerSheet { code in
                    handleScan(code)
                }
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
                            url = server.endpoint.url
                            token = server.endpoint.token
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
                    url = ""
                    token = ""
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

    private var pairingCard: some View {
        SettingsCard(title: store.endpoint.isComplete ? "Re-pair" : "Pair a harness") {
            TextField("ws://192.168.1.10:1977", text: $url)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(.plain)
                .padding(.vertical, 4)

            Divider().background(SweKittyTheme.separator)

            SecureField("Bearer token", text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.plain)
                .padding(.vertical, 4)

            Divider().background(SweKittyTheme.separator)

            Button {
                showScanner = true
            } label: {
                HStack(spacing: 10) {
                    Label("Scan pairing QR", systemImage: "qrcode.viewfinder")
                        .foregroundStyle(SweKittyTheme.textBody)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SweKittyTheme.textMuted)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)

            Button { save() } label: {
                Label("Save & Connect", systemImage: "link")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .glassCapsule(
                        interactive: true,
                        tint: SweKittyTheme.accentStrong.opacity(0.55)
                    )
            }
            .buttonStyle(.plain)
            .disabled(url.isEmpty || token.isEmpty)
            .padding(.top, 4)

            if let scanError {
                Text(scanError)
                    .font(.footnote)
                    .foregroundStyle(SweKittyTheme.danger)
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
            if store.endpoint.isComplete {
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

    private var aboutCard: some View {
        SettingsCard(title: "About") {
            FieldRow(label: "App", value: "SweKitty")
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Divider().background(SweKittyTheme.separator)
                FieldRow(label: "Version", value: version)
            }
        }
    }

    private func save() {
        let next = StoredEndpoint(
            url: url.trimmingCharacters(in: .whitespaces),
            token: token.trimmingCharacters(in: .whitespaces)
        )
        store.endpoint = next
        store.upsertSavedServer(name: next.displayHost, endpoint: next, makeDefault: true)
        store.disconnect()
        store.connect()
        dismiss()
    }

    private func handleScan(_ code: String) {
        guard let parsed = PairingURL.parse(code) else {
            scanError = "Not a SweKitty pairing URL: \(code.prefix(40))…"
            return
        }
        scanError = nil
        url = parsed.endpoint
        token = parsed.token
    }
}

/// `swekitty://host[:port]?token=<bearer>` → (endpoint URL, token).
enum PairingURL {
    struct Parsed { let endpoint: String; let token: String }

    static func parse(_ raw: String) -> Parsed? {
        guard let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "swekitty",
              let host = components.host else { return nil }
        let token = components.queryItems?.first(where: { $0.name == "token" })?.value ?? ""
        guard !token.isEmpty else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        return Parsed(endpoint: "ws://\(host)\(port)", token: token)
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
