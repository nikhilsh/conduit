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
                Section("Endpoint") {
                    TextField("ws://192.168.1.10:1977", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Bearer token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan pairing QR", systemImage: "qrcode.viewfinder")
                    }
                    Button("Save & Connect") {
                        store.endpoint = StoredEndpoint(url: url.trimmingCharacters(in: .whitespaces),
                                                        token: token.trimmingCharacters(in: .whitespaces))
                        store.disconnect()
                        store.connect()
                        dismiss()
                    }
                    .disabled(url.isEmpty || token.isEmpty)
                }
                if let scanError {
                    Section { Text(scanError).foregroundStyle(.red) }
                }
                Section("Status") {
                    LabeledContent("Connection") {
                        Text(connectionLabel).foregroundStyle(.secondary)
                    }
                }
            }
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

    private func handleScan(_ code: String) {
        guard let parsed = PairingURL.parse(code) else {
            scanError = "Not a SweKitty pairing URL: \(code.prefix(40))…"
            return
        }
        scanError = nil
        url = parsed.endpoint
        token = parsed.token
    }

    private var connectionLabel: String {
        switch store.connection {
        case .disconnected:  return "Disconnected"
        case .connecting:    return "Connecting…"
        case .connected:     return "Connected"
        case .failed(let e): return "Failed: \(e)"
        }
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
