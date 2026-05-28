import SwiftUI

/// Form-style sheet that drives the SSH-bootstrap flow. The user supplies
/// host/port + username + password OR PEM key (+ optional passphrase); on
/// Connect we kick off `SessionStore.connectViaSSH`, which handles the
/// docker-run + tunnel + endpoint swap. Progress + errors render inline so
/// the user can correct typos without losing context.
struct SSHLoginSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    enum AuthMode: String, CaseIterable, Identifiable {
        case password = "Password"
        case privateKey = "SSH Key"
        var id: String { rawValue }
    }

    @State private var host: String = ""
    @State private var port: String = "22"
    @State private var username: String = "root"
    @State private var mode: AuthMode = .password
    @State private var password: String = ""
    @State private var privateKey: String = ""
    @State private var passphrase: String = ""
    @State private var remember: Bool = true
    @State private var anthropicKey: String = ""
    @State private var openaiKey: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                SweKittyTheme.backgroundGradient(for: colorScheme)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        savedCredsCard
                        hostCard
                        authCard
                        apiKeysCard
                        progressCard
                        connectButton
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Add via SSH")
            .navigationBarTitleDisplayMode(.inline)
            .tint(SweKittyTheme.accentStrong)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        store.clearSshBootstrap()
                        dismiss()
                    }
                }
            }
            .onChange(of: store.harness) { _, next in
                // Once the underlying ws connection succeeds, close out — the
                // bootstrap path already swapped the endpoint and called connect.
                if case .running = store.sshBootstrapState { return }
                if next.isReachable, case .idle = store.sshBootstrapState {
                    dismiss()
                }
            }
        }
        .appearanceColorScheme()
    }

    // MARK: - Sections

    @ViewBuilder
    private var savedCredsCard: some View {
        let saved = SshCredentialStore.load()
        if !saved.isEmpty {
            SSHCard(title: "Recent Servers") {
                ForEach(saved) { cred in
                    Button {
                        applySaved(cred)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(cred.username)@\(cred.host)")
                                    .foregroundStyle(SweKittyTheme.textBody)
                                Text("Port \(cred.port) · \(cred.kind == .password ? "Password" : "SSH Key")")
                                    .font(.caption)
                                    .foregroundStyle(SweKittyTheme.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(SweKittyTheme.textMuted)
                        }
                    }
                    .buttonStyle(.plain)
                    if cred.id != saved.last?.id {
                        Divider().background(SweKittyTheme.separator)
                    }
                }
            }
        }
    }

    private var hostCard: some View {
        SSHCard(title: "Server") {
            HStack(spacing: 10) {
                TextField("hostname or IP", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity)
                TextField("22", text: $port)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.plain)
                    .frame(width: 60)
            }
            .padding(.vertical, 4)
            Divider().background(SweKittyTheme.separator)
            TextField("username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.plain)
                .padding(.vertical, 4)
        }
    }

    private var authCard: some View {
        SSHCard(title: "Authentication") {
            Picker("Auth", selection: $mode) {
                ForEach(AuthMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)

            Divider().background(SweKittyTheme.separator)

            switch mode {
            case .password:
                SecureField("Password", text: $password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.plain)
                    .padding(.vertical, 4)
            case .privateKey:
                Text("Paste the PEM-encoded private key. The passphrase, if any, is stored only in the Keychain.")
                    .font(.caption)
                    .foregroundStyle(SweKittyTheme.textSecondary)
                TextEditor(text: $privateKey)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 120)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(SweKittyTheme.surface.opacity(0.45))
                    )
                Divider().background(SweKittyTheme.separator)
                SecureField("Passphrase (optional)", text: $passphrase)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.plain)
                    .padding(.vertical, 4)
            }

            Divider().background(SweKittyTheme.separator)
            Toggle("Remember this server", isOn: $remember)
                .toggleStyle(.switch)
        }
    }

    private var apiKeysCard: some View {
        SSHCard(title: "Agent API Keys (optional)") {
            Text("Forwarded into the broker container so first launch can sign in without you SSHing in.")
                .font(.caption)
                .foregroundStyle(SweKittyTheme.textSecondary)
            SecureField("ANTHROPIC_API_KEY", text: $anthropicKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.plain)
                .padding(.vertical, 4)
            Divider().background(SweKittyTheme.separator)
            SecureField("OPENAI_API_KEY", text: $openaiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.plain)
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var progressCard: some View {
        switch store.sshBootstrapState {
        case .idle:
            EmptyView()
        case .running(let message):
            SSHCard(title: "Bootstrapping") {
                HStack(spacing: 10) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text(message)
                        .foregroundStyle(SweKittyTheme.textBody)
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        case .failed(let reason):
            SSHCard(title: "Failed") {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(SweKittyTheme.danger)
            }
        }
    }

    private var connectButton: some View {
        Button {
            connect()
        } label: {
            Label("Connect", systemImage: "bolt.horizontal.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SweKittyTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .glassCapsule(
                    interactive: true,
                    tint: SweKittyTheme.success.opacity(0.55)
                )
        }
        .buttonStyle(.plain)
        .disabled(!canConnect)
    }

    // MARK: - Logic

    private var canConnect: Bool {
        if host.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if username.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if UInt16(port) == nil { return false }
        switch mode {
        case .password:   return !password.isEmpty
        case .privateKey: return !privateKey.isEmpty
        }
        // unreachable
    }

    private func connect() {
        guard let portValue = UInt16(port) else { return }
        let auth: SshAuth
        switch mode {
        case .password:
            auth = .password(password: password)
        case .privateKey:
            auth = .privateKey(
                keyPem: privateKey,
                passphrase: passphrase.isEmpty ? nil : passphrase
            )
        }
        let creds = SshCredentials(
            host: host.trimmingCharacters(in: .whitespaces),
            port: portValue,
            username: username.trimmingCharacters(in: .whitespaces),
            auth: auth
        )

        if remember {
            let saved = SavedSshCredential(
                host: creds.host,
                port: creds.port,
                username: creds.username,
                kind: mode == .password ? .password : .privateKey,
                secret: mode == .password ? password : privateKey,
                passphrase: mode == .privateKey && !passphrase.isEmpty ? passphrase : nil
            )
            SshCredentialStore.save(saved)
        }

        store.connectViaSSH(
            credentials: creds,
            serverName: "\(creds.username)@\(creds.host)",
            anthropicApiKey: anthropicKey,
            openaiApiKey: openaiKey,
            imageRef: nil
        )
    }

    private func applySaved(_ cred: SavedSshCredential) {
        host = cred.host
        port = "\(cred.port)"
        username = cred.username
        mode = cred.kind == .password ? .password : .privateKey
        switch cred.kind {
        case .password:
            password = cred.secret
            privateKey = ""
            passphrase = ""
        case .privateKey:
            privateKey = cred.secret
            passphrase = cred.passphrase ?? ""
            password = ""
        }
    }
}

private struct SSHCard<Content: View>: View {
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
