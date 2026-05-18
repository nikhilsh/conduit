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
    @State private var startCwd: String = "~"
    @State private var showScanner: Bool = false
    @State private var showDirectoryPicker: Bool = false
    @State private var browsingPath: String = "~"
    @State private var directoryEntries: [RemoteDirectoryEntry] = []
    @State private var directoryParent: String = "~"
    @State private var directoryLoading: Bool = false
    @State private var directoryError: String?
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
                startCwd = "~"
            }
            .sheet(isPresented: $showScanner) {
                QRScannerSheet { code in
                    handleScan(code)
                }
            }
            .sheet(isPresented: $showDirectoryPicker) {
                directoryPickerSheet
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

            TextField("Start directory (e.g. ~/projects/kitty)", text: $startCwd)
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

            HStack(spacing: 8) {
                Button {
                    showDirectoryPicker = true
                    Task { await loadDirectories(path: startCwd) }
                } label: {
                    Label("Browse", systemImage: "folder")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SweKittyTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .glassCapsule(interactive: true, tint: SweKittyTheme.warning.opacity(0.40))
                }
                .buttonStyle(.plain)
                .disabled(url.isEmpty || token.isEmpty)

                Button {
                    connectAndStart(assistant: "claude")
                } label: {
                    Label("Connect + Start Claude", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SweKittyTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .glassCapsule(interactive: true, tint: SweKittyTheme.success.opacity(0.45))
                }
                .buttonStyle(.plain)
                .disabled(url.isEmpty || token.isEmpty)

                Button {
                    connectAndStart(assistant: "codex")
                } label: {
                    Label("Connect + Start Codex", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SweKittyTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .glassCapsule(interactive: true, tint: SweKittyTheme.accentStrong.opacity(0.50))
                }
                .buttonStyle(.plain)
                .disabled(url.isEmpty || token.isEmpty)
            }

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

    private func connectAndStart(assistant: String) {
        let next = StoredEndpoint(
            url: url.trimmingCharacters(in: .whitespaces),
            token: token.trimmingCharacters(in: .whitespaces)
        )
        store.connectAndStart(endpoint: next, assistant: assistant, cwd: startCwd)
        dismiss()
    }

    @ViewBuilder
    private var directoryPickerSheet: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack {
                    Text(browsingPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(SweKittyTheme.textSecondary)
                        .lineLimit(2)
                    Spacer()
                    if directoryLoading {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 16)
                if let directoryError {
                    Text(directoryError)
                        .font(.footnote)
                        .foregroundStyle(SweKittyTheme.danger)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                List {
                    Button {
                        Task { await loadDirectories(path: directoryParent) }
                    } label: {
                        Label("..", systemImage: "arrow.up.left")
                    }
                    ForEach(directoryEntries) { entry in
                        Button {
                            Task { await loadDirectories(path: entry.path) }
                        } label: {
                            Label(entry.name, systemImage: "folder")
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Select Directory")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showDirectoryPicker = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use This") {
                        startCwd = browsingPath
                        showDirectoryPicker = false
                    }
                }
            }
        }
    }

    private func loadDirectories(path: String?) async {
        let next = StoredEndpoint(
            url: url.trimmingCharacters(in: .whitespaces),
            token: token.trimmingCharacters(in: .whitespaces)
        )
        guard !next.url.isEmpty, !next.token.isEmpty else {
            directoryError = "Set endpoint and token first."
            return
        }
        directoryLoading = true
        directoryError = nil
        store.endpoint = next
        do {
            let listing = try await store.listDirectories(path: path)
            browsingPath = listing.path
            directoryParent = listing.parent
            directoryEntries = listing.entries.filter(\.is_dir)
        } catch {
            directoryError = String(describing: error)
        }
        directoryLoading = false
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
