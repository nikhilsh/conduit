import SwiftUI

// MARK: - LitterAddServerSheet
//
// Native LitterUI Add-Server sheet. Replaces the legacy
// `AddServerSheet` (now deleted) with a litter-faithful surface:
//   - small-caps "WHERE" section label
//   - .ultraThinMaterial cards with 14pt corners (LitterCard)
//   - footnote-sized row titles (matches AgentPickerSheet)
//
// Four entry points (same as legacy): Scan QR · Discover on LAN ·
// SSH bootstrap · Paste URL+token. Each opens its own sub-sheet
// (carried over from legacy: QRScannerSheet, LitterDiscoveryView,
// SSHLoginSheet, LitterManualPairSheet).

extension LitterUI {
    struct AddServerSheet: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.dismiss) private var dismiss

        @State private var showScanner = false
        @State private var showDiscover = false
        @State private var showSshLogin = false
        @State private var showManual = false

        var body: some View {
            NavigationStack {
                ZStack {
                    LitterUI.Palette.surface.color.ignoresSafeArea()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            sectionLabel("Where is the broker?")
                            Text("Pick how this device should reach the swe-kitty server. You can change servers later.")
                                .font(.footnote)
                                .foregroundStyle(LitterUI.Palette.textMuted.color)
                                .padding(.bottom, 4)

                            entryCard(
                                icon: "qrcode.viewfinder",
                                tint: LitterUI.Palette.accentStrong.color,
                                title: "Scan pairing QR",
                                subtitle: "Camera-scan the QR from the broker terminal.",
                                action: { showScanner = true }
                            )
                            entryCard(
                                icon: "wifi.circle",
                                tint: LitterUI.Palette.success.color,
                                title: "Discover on LAN",
                                subtitle: "Find a broker advertising via mDNS on the same Wi-Fi.",
                                action: { showDiscover = true }
                            )
                            entryCard(
                                icon: "terminal",
                                tint: LitterUI.Palette.brand.color,
                                title: "SSH bootstrap",
                                subtitle: "Cold-start a broker on a remote box you can SSH to.",
                                action: { showSshLogin = true }
                            )
                            entryCard(
                                icon: "link",
                                tint: LitterUI.Palette.warning.color,
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
                    LitterUI.DiscoveryView()
                        .environment(store)
                        .onDisappear { if store.endpoint.isComplete { dismiss() } }
                }
                .sheet(isPresented: $showSshLogin) {
                    SSHLoginSheet()
                        .environment(store)
                        .onDisappear { if store.endpoint.isComplete { dismiss() } }
                }
                .sheet(isPresented: $showManual) {
                    LitterManualPairSheet()
                        .environment(store)
                        .onDisappear { if store.endpoint.isComplete { dismiss() } }
                }
            }
            .tint(LitterUI.Palette.brand.color)
        }

        private func sectionLabel(_ text: String) -> some View {
            Text(text.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(LitterUI.Palette.textMuted.color)
        }

        private func entryCard(icon: String, tint: Color, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(LitterUI.Palette.textOnAccent.color)
                        .frame(width: 36, height: 36)
                        .background(tint)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(LitterUI.Palette.textPrimary.color)
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(LitterUI.Palette.textMuted.color)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LitterUI.Palette.textMuted.color)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .litterGlassRoundedRect(cornerRadius: 14)
            }
            .buttonStyle(.plain)
        }
    }
}

/// LitterUI port of the legacy `ManualPairSheet`. Plain URL + token
/// entry; auto-dismisses on save.
struct LitterManualPairSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var url: String = ""
    @State private var token: String = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                LitterUI.Palette.surface.color.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("HARNESS URL")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(0.6)
                            .foregroundStyle(LitterUI.Palette.textMuted.color)
                        TextField("ws://192.168.1.10:1977", text: $url)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .litterGlassRoundedRect(cornerRadius: 14)

                        Text("BEARER TOKEN")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(0.6)
                            .foregroundStyle(LitterUI.Palette.textMuted.color)
                            .padding(.top, 4)
                        SecureField("Bearer token", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.plain)
                            .padding(12)
                            .litterGlassRoundedRect(cornerRadius: 14)

                        if let error {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(LitterUI.Palette.danger.color)
                        }

                        Button(action: save) {
                            HStack(spacing: 8) {
                                Image(systemName: "link")
                                Text("Save & connect")
                                    .fontWeight(.semibold)
                            }
                            .font(.footnote)
                            .foregroundStyle(LitterUI.Palette.textOnAccent.color)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(LitterUI.Palette.brand.color)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(url.isEmpty || token.isEmpty)
                        .opacity((url.isEmpty || token.isEmpty) ? 0.5 : 1)
                        .padding(.top, 8)
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
        .tint(LitterUI.Palette.brand.color)
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
