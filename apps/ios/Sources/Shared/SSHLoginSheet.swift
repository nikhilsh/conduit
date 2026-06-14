import SwiftUI
import UIKit

/// Conduit-styled sheet that drives the SSH-bootstrap flow. The user supplies
/// host/port + username + password OR PEM key (+ optional passphrase); on
/// Connect we kick off `SessionStore.connectViaSSH`, which handles the
/// docker-run + tunnel + endpoint swap. A blocking install-progress modal
/// overlays the form while bootstrap runs so the user is never left staring
/// at a silent screen.
/// Fix 3: mono section labels (RECENT/SERVER/AUTHENTICATION), API keys behind
/// disclosure, X to close, inline validation hint, glowing Connect CTA.
struct SSHLoginSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.neonTheme) private var neon

    // Captured when the user taps Connect — used in the progress modal title.
    @State private var bootstrapBoxName: String = ""

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
    // Fix 3: API keys hidden behind disclosure (collapsed by default).
    @State private var apiKeysExpanded: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                neon.appBg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        savedCredsCard
                        hostCard
                        authCard
                        // Fix 3: inline validation hint when no host entered.
                        if host.trimmingCharacters(in: .whitespaces).isEmpty {
                            HStack(spacing: 7) {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(neon.textFaint)
                                Text("Enter a host to continue")
                                    .font(neon.mono(11.5))
                                    .foregroundStyle(neon.textFaint)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                        }
                        apiKeysCard
                        connectButton
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)

                // Blocking install-progress modal — overlays the form while
                // bootstrap runs so the user is never staring at a silent screen.
                if store.sshBootstrapState != .idle {
                    installProgressOverlay
                        .zIndex(1)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: store.sshBootstrapState != .idle)
            .navigationTitle("Add via SSH")
            .navigationBarTitleDisplayMode(.inline)
            .neonAccentTint()
            .toolbar {
                // Fix 3: X to close instead of "Cancel".
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.clearSshBootstrap()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(neon.textDim)
                    }
                    .accessibilityLabel("Close")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
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

    // MARK: - Install progress overlay

    /// Full-coverage blocking overlay that appears while SSH bootstrap is running
    /// or has failed. Non-dismissible during running; shows Retry + Cancel on
    /// failure. The form underneath is left in place but inaccessible.
    @ViewBuilder
    private var installProgressOverlay: some View {
        ZStack {
            // Dim the form behind the modal.
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                installProgressCard
                    .padding(.horizontal, 24)
                Spacer()
            }
        }
        .transition(.opacity)
        .onAppear {
            Telemetry.breadcrumb("ssh_install_modal", "overlay appeared", data: [
                "box": bootstrapBoxName,
            ])
        }
    }

    @ViewBuilder
    private var installProgressCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Title row
            HStack(spacing: 10) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(neon.codex)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Setting up \(bootstrapBoxName.isEmpty ? "server" : bootstrapBoxName)")
                        .font(neon.mono(14).weight(.bold))
                        .foregroundStyle(neon.text)
                        .lineLimit(1)
                    Text("INSTALLING CONDUIT BROKER")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(neon.textFaint)
                }
            }

            switch store.sshBootstrapState {
            case .idle:
                EmptyView()

            case .running(let message):
                // Stage indicators — we receive a single message at a time that
                // reflects the current STEP from remote-bootstrap.sh. Show it with
                // a spinner so the user knows work is happening.
                VStack(alignment: .leading, spacing: 16) {
                    stageList(currentMessage: message)
                    HStack(spacing: 10) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(neon.codex)
                        Text(message)
                            .font(neon.mono(13))
                            .foregroundStyle(neon.text)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

            case .failed(let reason):
                VStack(alignment: .leading, spacing: 14) {
                    // Error message with icon
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(neon.red)
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(neon.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Retry + Cancel buttons
                    HStack(spacing: 10) {
                        // Retry: re-run bootstrap with the same credentials.
                        Button {
                            Telemetry.breadcrumb("ssh_install_modal", "retry tapped", data: [
                                "box": bootstrapBoxName,
                            ])
                            connect()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Retry")
                                    .font(neon.mono(13).weight(.semibold))
                            }
                            .foregroundStyle(neon.accentText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(neon.codex)
                            )
                        }
                        .buttonStyle(.plain)

                        // Cancel: clear bootstrap state and leave the form open.
                        Button {
                            Telemetry.breadcrumb("ssh_install_modal", "cancel tapped after failure", data: [
                                "box": bootstrapBoxName,
                            ])
                            store.clearSshBootstrap()
                        } label: {
                            Text("Cancel")
                                .font(neon.mono(13).weight(.semibold))
                                .foregroundStyle(neon.textDim)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .fill(neon.surface)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                                .strokeBorder(neon.border, lineWidth: 1)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(neon.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(neon.border, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 30, x: 0, y: 10)
    }

    /// Stage labels in the order remote-bootstrap.sh emits them.
    private static let bootstrapStages: [(label: String, prefix: String)] = [
        ("Connecting", "Connecting"),
        ("Securing connection", "Securing"),
        ("Authenticating", "Authenticating"),
        ("Opening tunnel", "Opening"),
        ("Checking existing install", "Checking"),
        ("Downloading broker", "Downloading"),
        ("Starting service", "Starting"),
        ("Installing agent", "Installing"),
        ("Verifying readiness", "Waiting"),
    ]

    /// Which stage is active for the given progress message.
    private static func stageIndex(for message: String) -> Int {
        for (i, stage) in bootstrapStages.enumerated() {
            if message.hasPrefix(stage.prefix) { return i }
        }
        return 0
    }

    /// Stage progress dots list — completed stages get a green dot,
    /// active gets a pulsed codex dot, pending dots are dim.
    private func stageList(currentMessage: String) -> some View {
        let activeIdx = Self.stageIndex(for: currentMessage)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.bootstrapStages.indices, id: \.self) { idx in
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(idx < activeIdx ? neon.green
                                  : idx == activeIdx ? neon.codex
                                  : neon.border)
                            .frame(width: 8, height: 8)
                        if idx == activeIdx {
                            Circle()
                                .fill(neon.codex.opacity(0.3))
                                .frame(width: 14, height: 14)
                        }
                    }
                    .frame(width: 14, height: 14)
                    Text(Self.bootstrapStages[idx].label)
                        .font(neon.mono(12))
                        .foregroundStyle(idx <= activeIdx ? neon.text : neon.textFaint)
                        .fontWeight(idx == activeIdx ? .semibold : .regular)
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var savedCredsCard: some View {
        let saved = SshCredentialStore.load()
        if !saved.isEmpty {
            // Fix 3: mono section label "RECENT".
            SSHCard(title: "RECENT") {
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
        // Fix 3: mono section label "SERVER".
        SSHCard(title: "SERVER") {
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
        // Fix 3: mono section label "AUTHENTICATION".
        SSHCard(title: "AUTHENTICATION") {
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

    // Fix 3: API keys behind a disclosure group (collapsed by default).
    private var apiKeysCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { apiKeysExpanded.toggle() }
            } label: {
                HStack {
                    Text("AGENT API KEYS (OPTIONAL)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(neon.textFaint)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(neon.textFaint)
                        .rotationEffect(.degrees(apiKeysExpanded ? 180 : 0))
                }
                .padding(.bottom, 6)
            }
            .buttonStyle(.plain)

            if apiKeysExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Forwarded into the broker so agents can sign in without manual setup.")
                        .font(.caption)
                        .foregroundStyle(neon.textFaint)
                    SecureField("ANTHROPIC_API_KEY", text: $anthropicKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.plain)
                        .padding(.vertical, 4)
                    Divider().background(neon.border)
                    SecureField("OPENAI_API_KEY", text: $openaiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.plain)
                        .padding(.vertical, 4)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(neon.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(neon.border, lineWidth: 1)
                        )
                )
            }
        }
    }

    // Fix 3: glowing "Connect & install broker" CTA.
    private var connectButton: some View {
        VStack(spacing: 6) {
            Button {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
                let reasons = disabledReasons
                Telemetry.breadcrumb("ssh_addbox", "connect tapped", data: [
                    "enabled": reasons.isEmpty ? "true" : "false",
                    "disabled_reason": reasons.joined(separator: "; "),
                ])
                guard reasons.isEmpty else {
                    Telemetry.breadcrumb("ssh_addbox", "ssh connect blocked", data: [
                        "disabled_reasons": reasons.joined(separator: "; "),
                        "mode": mode.rawValue,
                        "host_nonempty": host.trimmingCharacters(in: .whitespaces).isEmpty ? "false" : "true",
                    ])
                    return
                }
                connect()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Connect & install broker")
                        .font(neon.mono(14.5).weight(.bold))
                }
                .foregroundStyle(neon.accentText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(
                            colors: [neon.codex, neon.green],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .opacity(canConnect ? 1.0 : 0.4)
                )
                .neonGlowBox(canConnect && neon.glow ? neon.glowBox?.tinted(neon.codex) : nil)
            }
            .buttonStyle(.plain)
            if !disabledReasons.isEmpty {
                Text(disabledReasons.joined(separator: "  \u{00B7}  "))
                    .font(neon.mono(11))
                    .foregroundStyle(neon.yellow)
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
        if case .running = store.sshBootstrapState {
            reasons.append("Connecting...")
        }
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
        // Capture box name before the bootstrap starts so the modal title is
        // populated even on a Retry (where host/username fields are still set).
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        bootstrapBoxName = "\(trimmedUser)@\(trimmedHost)"

        Telemetry.breadcrumb("ssh_addbox", "connect() entry", data: [
            "host": trimmedHost,
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

        Telemetry.breadcrumb("ssh_addbox", "ssh connect attempt", data: [
            "mode": mode.rawValue,
            "host_nonempty": trimmedHost.isEmpty ? "false" : "true",
            "key_length": mode == .privateKey ? "\(trimmedKey.count)" : "0",
            "looks_pem": looksLikePem ? "true" : "false",
            "looks_encrypted": looksEncrypted ? "true" : "false",
            "has_passphrase": hasPassphrase ? "true" : "false",
        ])

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
            host: trimmedHost,
            port: portValue,
            username: trimmedUser,
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

// Fix 3: SSHCard uses mono section labels (matches ConduitAddServerSheet style).
private struct SSHCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @Environment(\.neonTheme) private var neon

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Mono uppercase label at 11pt bold with letter spacing (~1.4).
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(neon.textFaint)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(neon.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(neon.border, lineWidth: 1)
                    )
            )
        }
    }
}
