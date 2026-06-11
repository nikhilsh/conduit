import SwiftUI
import UIKit

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
                ConduitTheme.backgroundGradient(for: colorScheme)
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
            .neonAccentTint()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        store.clearSshBootstrap()
                        dismiss()
                    }
                }
            }
            .onChange(of: store.harness) { _, next in
                // Once the underlying ws connection succeeds, close out -- the
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
                                    .foregroundStyle(ConduitTheme.textBody)
                                Text("Port \(cred.port) \u{00B7} \(cred.kind == .password ? "Password" : "SSH Key")")
                                    .font(.caption)
                                    .foregroundStyle(ConduitTheme.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(ConduitTheme.textMuted)
                        }
                    }
                    .buttonStyle(.plain)
                    if cred.id != saved.last?.id {
                        Divider().background(ConduitTheme.separator)
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
            Divider().background(ConduitTheme.separator)
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

            Divider().background(ConduitTheme.separator)

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
                    .foregroundStyle(ConduitTheme.textSecondary)
                // UITextView wrapper: disables smart-quotes, smart-dashes, autocorrect,
                // and autocapitalization -- all of which TextEditor alone cannot suppress
                // and which silently corrupt a pasted PEM key.
                PlainKeyTextEditor(text: $privateKey)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 120)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(ConduitTheme.surface.opacity(0.45))
                    )
                // PEM sanity warnings (client-side only; no key body logged)
                let trimmedKey = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedKey.isEmpty {
                    if !trimmedKey.contains("-----BEGIN") || !trimmedKey.contains("PRIVATE KEY-----") {
                        Label(
                            "This does not look like a PEM private key -- it should start with -----BEGIN ...PRIVATE KEY-----",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(ConduitTheme.warning)
                    } else if (trimmedKey.contains("ENCRYPTED") || trimmedKey.contains("Proc-Type: 4,ENCRYPTED"))
                                && passphrase.isEmpty {
                        Label(
                            "This key appears encrypted -- enter the passphrase below.",
                            systemImage: "lock.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(ConduitTheme.warning)
                    }
                }
                Divider().background(ConduitTheme.separator)
                SecureField("Passphrase (optional)", text: $passphrase)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.plain)
                    .padding(.vertical, 4)
            }

            Divider().background(ConduitTheme.separator)
            Toggle("Remember this server", isOn: $remember)
                .toggleStyle(.switch)
        }
    }

    private var apiKeysCard: some View {
        SSHCard(title: "Agent API Keys (optional)") {
            Text("Forwarded into the broker container so first launch can sign in without you SSHing in.")
                .font(.caption)
                .foregroundStyle(ConduitTheme.textSecondary)
            SecureField("ANTHROPIC_API_KEY", text: $anthropicKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.plain)
                .padding(.vertical, 4)
            Divider().background(ConduitTheme.separator)
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
                        .foregroundStyle(ConduitTheme.textBody)
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        case .failed(let reason):
            SSHCard(title: "Failed") {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(ConduitTheme.danger)
            }
        }
    }

    private var connectButton: some View {
        VStack(spacing: 6) {
            Button {
                let reasons = disabledReasons
                Telemetry.breadcrumb("ssh_addbox", "connect tapped", data: [
                    "enabled": reasons.isEmpty ? "true" : "false",
                    "disabled_reason": reasons.joined(separator: "; "),
                ])
                guard reasons.isEmpty else {
                    // Fire a real Sentry event so the breadcrumb trail is
                    // uploaded even when the tap is blocked. Without a captured
                    // event the ring-buffered breadcrumbs are never flushed.
                    Telemetry.capture(
                        error: NSError(domain: "ios.ssh_addbox", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: "connect blocked"]),
                        message: "ssh connect blocked",
                        tags: ["surface": "ios", "phase": "ssh_connect_blocked"],
                        extras: [
                            "disabled_reasons": reasons.joined(separator: "; "),
                            "mode": mode.rawValue,
                            "host_nonempty": host.trimmingCharacters(in: .whitespaces).isEmpty ? "false" : "true",
                        ]
                    )
                    return
                }
                connect()
            } label: {
                Label("Connect", systemImage: "bolt.horizontal.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(canConnect ? ConduitTheme.textPrimary : ConduitTheme.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .glassCapsule(
                        interactive: canConnect,
                        tint: (canConnect ? ConduitTheme.success : ConduitTheme.separator).opacity(0.55)
                    )
            }
            .buttonStyle(.plain)
            // Surface why the button is disabled so the user does not face a
            // silent dead button.
            if !disabledReasons.isEmpty {
                Text(disabledReasons.joined(separator: "  \u{00B7}  "))
                    .font(.caption)
                    .foregroundStyle(ConduitTheme.warning)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        }
    }

    // MARK: - Logic

    private var canConnect: Bool {
        disabledReasons.isEmpty
    }

    /// Returns a human-readable list of reasons the Connect button should be
    /// disabled. Empty means all preconditions are satisfied.
    private var disabledReasons: [String] {
        var reasons: [String] = []
        if host.trimmingCharacters(in: .whitespaces).isEmpty {
            reasons.append("Enter host")
        }
        if username.trimmingCharacters(in: .whitespaces).isEmpty {
            reasons.append("Enter username")
        }
        if UInt16(port) == nil {
            reasons.append("Port must be 1-65535")
        }
        switch mode {
        case .password:
            if password.isEmpty { reasons.append("Enter password") }
        case .privateKey:
            if privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reasons.append("Paste a private key")
            }
        }
        return reasons
    }

    private func connect() {
        Telemetry.breadcrumb("ssh_addbox", "connect() entry", data: [
            "host": host.trimmingCharacters(in: .whitespaces),
            "port": port,
            "mode": mode.rawValue,
        ])

        guard let portValue = UInt16(port) else { return }
        let trimmedKey = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // Log key metadata only -- never the key body or passphrase.
        let looksLikePem: Bool
        let looksEncrypted: Bool
        let hasPassphrase: Bool
        if mode == .privateKey {
            let header = trimmedKey.components(separatedBy: "\n").first ?? ""
            looksLikePem = trimmedKey.contains("-----BEGIN") && trimmedKey.contains("PRIVATE KEY-----")
            looksEncrypted = trimmedKey.contains("ENCRYPTED") || trimmedKey.contains("Proc-Type: 4,ENCRYPTED")
            hasPassphrase = !passphrase.isEmpty
            Telemetry.breadcrumb("ssh_addbox", "key metadata", data: [
                "header": header,
                "length": "\(trimmedKey.count)",
                "looks_pem": looksLikePem ? "true" : "false",
                "looks_encrypted": looksEncrypted ? "true" : "false",
                "has_passphrase": hasPassphrase ? "true" : "false",
            ])
        } else {
            looksLikePem = false
            looksEncrypted = false
            hasPassphrase = false
        }

        // Captured event so the breadcrumb trail is guaranteed to be uploaded
        // even if connectViaSSH returns early (before its own captures fire).
        Telemetry.capture(
            error: NSError(domain: "ios.ssh_addbox", code: 0,
                           userInfo: [NSLocalizedDescriptionKey: "connect attempt"]),
            message: "ssh connect attempt",
            tags: ["surface": "ios", "phase": "ssh_connect_attempt"],
            extras: [
                "mode": mode.rawValue,
                "host_nonempty": host.trimmingCharacters(in: .whitespaces).isEmpty ? "false" : "true",
                "key_length": mode == .privateKey ? "\(trimmedKey.count)" : "0",
                "looks_pem": looksLikePem ? "true" : "false",
                "looks_encrypted": looksEncrypted ? "true" : "false",
                "has_passphrase": hasPassphrase ? "true" : "false",
            ]
        )

        let auth: SshAuth
        switch mode {
        case .password:
            auth = .password(password: password)
        case .privateKey:
            auth = .privateKey(
                keyPem: trimmedKey,
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
                secret: mode == .password ? password : trimmedKey,
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

// MARK: - PlainKeyTextEditor

/// A UITextView-backed text editor with all iOS smart-editing features
/// disabled. `TextEditor` in SwiftUI does not propagate
/// `.autocorrectionDisabled()` far enough to suppress smart-quotes and
/// smart-dashes, which silently corrupt pasted PEM private keys (straight
/// apostrophes/hyphens become curly/em-dashes). This wrapper fixes that.
private struct PlainKeyTextEditor: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.spellCheckingType = .no
        tv.keyboardType = .asciiCapable
        tv.font = UIFont.monospacedSystemFont(ofSize: UIFont.smallSystemFontSize, weight: .regular)
        tv.backgroundColor = .clear
        tv.textColor = UIColor.label
        tv.isScrollEnabled = false
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // Only push if changed to avoid cursor-jump on every keystroke.
        if uiView.text != text {
            uiView.text = text
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PlainKeyTextEditor
        init(_ parent: PlainKeyTextEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }
    }
}

// MARK: - SSHCard

private struct SSHCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(ConduitTheme.textSecondary)
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
