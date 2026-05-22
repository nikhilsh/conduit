import SwiftUI

/// Add-Server entry point. Replaces the three side-by-side entry
/// buttons in the old Settings form with a focused four-card sheet:
/// Scan QR · Discover on LAN · SSH bootstrap · Paste URL+token.
///
/// Each card pushes (or sheets) into a specialised flow; once that
/// flow finishes setting the endpoint, this sheet auto-dismisses.
struct AddServerSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var showScanner = false
    @State private var showDiscover = false
    @State private var showSshLogin = false
    @State private var showManual = false

    /// We watch this so manual entry can auto-dismiss after success.
    private var lastEndpoint: String { store.endpoint.url }

    var body: some View {
        NavigationStack {
            ZStack {
                SweKittyTheme.backgroundGradient(for: colorScheme).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 14) {
                        intro
                        entryCard(
                            icon: "qrcode.viewfinder",
                            tint: SweKittyTheme.accentStrong,
                            title: "Scan pairing QR",
                            subtitle: "Camera-scan the QR from the broker terminal.",
                            action: { showScanner = true }
                        )
                        entryCard(
                            icon: "wifi.circle",
                            tint: SweKittyTheme.codexAccent,
                            title: "Discover on LAN",
                            subtitle: "Find a broker advertising via mDNS on the same Wi-Fi.",
                            action: { showDiscover = true }
                        )
                        entryCard(
                            icon: "terminal",
                            tint: SweKittyTheme.claudeAccent,
                            title: "SSH bootstrap",
                            subtitle: "Cold-start a broker on a remote box you can SSH to.",
                            action: { showSshLogin = true }
                        )
                        entryCard(
                            icon: "link",
                            tint: SweKittyTheme.warning,
                            title: "Paste URL + token",
                            subtitle: "If you already have ws://… + the bearer token.",
                            action: { showManual = true }
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Add server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showScanner) {
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
            .sheet(isPresented: $showDiscover) {
                DiscoveryView()
                    .environment(store)
                    .onDisappear { if store.endpoint.isComplete { dismiss() } }
            }
            .sheet(isPresented: $showSshLogin) {
                SSHLoginSheet()
                    .environment(store)
                    .onDisappear { if store.endpoint.isComplete { dismiss() } }
            }
            .sheet(isPresented: $showManual) {
                ManualPairSheet()
                    .environment(store)
                    .onDisappear { if store.endpoint.isComplete { dismiss() } }
            }
        }
        .tint(SweKittyTheme.accentStrong)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where is the broker?")
                .font(.headline)
                .foregroundStyle(SweKittyTheme.textPrimary)
            Text("Pick how this device should reach the swe-kitty server. You can change servers later.")
                .font(.subheadline)
                .foregroundStyle(SweKittyTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassRoundedRect()
    }

    private func entryCard(icon: String, tint: Color, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(SweKittyTheme.textOnAccent)
                    .frame(width: 42, height: 42)
                    .background(tint)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SweKittyTheme.textPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(SweKittyTheme.textMuted)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .glassRect(cornerRadius: SweKittyTheme.cardCornerRadius, tint: tint.opacity(0.16))
        }
        .buttonStyle(.plain)
    }
}

/// Plain URL+token manual-entry sheet, extracted from the old
/// `SettingsSheet.pairingCard`. Only the bare-minimum fields — no
/// Browse-directory, no Connect+Start triple. After saving, the
/// post-pair agent picker handles the "start a session" step.
struct ManualPairSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var url: String = ""
    @State private var token: String = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                SweKittyTheme.backgroundGradient(for: colorScheme).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Harness URL")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(SweKittyTheme.textSecondary)
                            TextField("ws://192.168.1.10:1977", text: $url)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(SweKittyTheme.surface.opacity(0.6))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                            Text("Bearer token")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(SweKittyTheme.textSecondary)
                            SecureField("Bearer token", text: $token)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(SweKittyTheme.surface.opacity(0.6))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                            if let error {
                                Text(error)
                                    .font(.footnote)
                                    .foregroundStyle(SweKittyTheme.danger)
                            }
                        }
                        .padding(14)
                        .glassRoundedRect()

                        Button(action: save) {
                            Label("Save & connect", systemImage: "link")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(SweKittyTheme.textPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .glassCapsule(interactive: true, tint: SweKittyTheme.accentStrong.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        .disabled(url.isEmpty || token.isEmpty)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Paste URL + token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                url = store.endpoint.url
                token = store.endpoint.token
            }
        }
        .tint(SweKittyTheme.accentStrong)
    }

    private func save() {
        let trimmedUrl = url.trimmingCharacters(in: .whitespaces)
        let trimmedToken = token.trimmingCharacters(in: .whitespaces)
        guard !trimmedUrl.isEmpty, !trimmedToken.isEmpty else {
            error = "URL and token are both required."
            return
        }
        let next = StoredEndpoint(url: trimmedUrl, token: trimmedToken)
        store.endpoint = next
        store.upsertSavedServer(name: next.displayHost, endpoint: next, makeDefault: true)
        store.disconnect()
        store.connect()
        dismiss()
    }
}
