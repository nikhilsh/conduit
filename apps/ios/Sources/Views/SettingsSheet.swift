import SwiftUI

/// v1: manual endpoint + bearer token entry, or paste from a scanned
/// `swekitty://<host>?token=<bearer>` QR. mDNS browser lands in a
/// post-v1 task.
struct SettingsSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var url: String = ""
    @State private var token: String = ""
    @State private var showScanner: Bool = false
    @State private var scanError: String?

    var body: some View {
        NavigationStack {
            Form {
                pairedSection
                pairingSection
                statusSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(SettingsBackground())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
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

    @ViewBuilder
    private var pairedSection: some View {
        if store.endpoint.isComplete {
            Section("Paired Harness") {
                LabeledContent("Host", value: store.endpoint.displayHost)
                LabeledContent("Token", value: "Stored in Keychain")
                Button(role: .destructive) {
                    store.endpoint = .empty
                    store.disconnect()
                    url = ""
                    token = ""
                } label: {
                    Label("Forget harness", systemImage: "trash")
                }
            }
        }
    }

    private var pairingSection: some View {
        Section(store.endpoint.isComplete ? "Re-pair" : "Pair a harness") {
            TextField("ws://192.168.1.10:1977", text: $url)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField("Bearer token", text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                showScanner = true
            } label: {
                Label("Scan pairing QR", systemImage: "qrcode.viewfinder")
            }

            Button {
                save()
            } label: {
                Label("Save & Connect", systemImage: "link")
            }
            .disabled(url.isEmpty || token.isEmpty)

            if let scanError {
                Text(scanError)
                    .font(.footnote)
                    .foregroundStyle(SweKittyTheme.danger)
            }
        }
    }

    private var statusSection: some View {
        Section("Harness Status") {
            HStack {
                Text("Link")
                Spacer()
                HarnessBadge(state: store.harness)
            }
            if let reason = store.harness.failureReason {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(SweKittyTheme.danger)
            }
            if store.endpoint.isComplete {
                Button {
                    store.reconnect()
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("App", value: "SweKitty")
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                LabeledContent("Version", value: version)
            }
        }
    }

    private func save() {
        store.endpoint = StoredEndpoint(
            url: url.trimmingCharacters(in: .whitespaces),
            token: token.trimmingCharacters(in: .whitespaces)
        )
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

private struct SettingsBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.08, green: 0.11, blue: 0.18),
                Color(red: 0.13, green: 0.15, blue: 0.24),
                Color(red: 0.07, green: 0.09, blue: 0.14),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}
