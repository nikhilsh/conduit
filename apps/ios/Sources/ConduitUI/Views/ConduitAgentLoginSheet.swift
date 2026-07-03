import SafariServices
import SwiftUI
import UIKit

// MARK: - ConduitAgentLoginSheet
//
// Native ConduitUI sign-in surface for per-user agent OAuth. Drives the
// litter-faithful phone-side flow via `OAuthClient`:
//
//   1. Tap "Login with ChatGPT" / "Login with Claude".
//   2. The phone generates PKCE and opens the provider's real authorize
//      URL in a browser:
//        - ChatGPT/Codex: loopback redirect (`http://localhost:1455`)
//          captured in-app by `AgentLoginLoopbackServer`; the code is
//          captured automatically.
//        - Claude/Anthropic: the code-display page on platform.claude.com;
//          the user copies the shown `code#state` and pastes it back into
//          the sheet's paste field.
//   3. The phone exchanges the code for tokens itself, then ships the
//      provider-native credential blob to the broker via
//      `SessionStore.sendAgentCredentials` (the broker stores it
//      encrypted and materializes a per-session credential file).
//
// The credential is also stashed in the local Keychain so a transient
// WS outage doesn't lose it — the user can retry the "send to broker"
// step without re-authenticating.

extension ConduitUI {
    struct AgentLoginSheet: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.dismiss) private var dismiss
        @Environment(\.neonTheme) private var neon

        /// When set (e.g. the picker's per-box readiness "Sign in" CTA), the
        /// sheet auto-launches the REAL OAuth flow for that provider on appear
        /// instead of just listing accounts — so a fresh box can be signed into
        /// even when the device already has a global credential. nil = the
        /// normal accounts-list behaviour.
        @Binding var autoStartProvider: OAuthProvider?

        init(autoStartProvider: Binding<OAuthProvider?> = .constant(nil)) {
            self._autoStartProvider = autoStartProvider
        }

        @State private var didAutoStart = false
        @State private var isWorking = false
        @State private var statusMessage: String?
        @State private var errorMessage: String?

        /// Retained across the Claude code-paste round-trip: it holds the
        /// PKCE verifier between opening the browser and the user pasting
        /// the displayed code.
        @State private var pasteClient: OAuthClient?
        @State private var awaitingPaste = false
        @State private var pastedCode: String = ""

        /// Claude's authorize page, shown IN-APP (SFSafariViewController
        /// sheet) instead of bouncing to external Safari — the user copies
        /// the code, taps Done, and lands back on the paste card.
        @State private var claudeAuthURL: URL?

        /// Providers with a credential in the Keychain — drives the
        /// persistent "Signed in" state on each row (the transient status
        /// pill alone left the rows looking logged-out after success).
        @State private var signedInProviders: Set<OAuthProvider> = []

        var body: some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            // Fix 2: "Agent accounts" title shown as section header.
                            intro
                            providersCard
                            if awaitingPaste {
                                pasteCard
                            }
                            if let statusMessage {
                                statusPill(text: statusMessage, tint: neon.accent)
                            }
                            if let errorMessage {
                                statusPill(text: errorMessage, tint: ConduitUI.Palette.danger.color)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.hidden)
                }
                .safeAreaInset(edge: .bottom) {
                    // Fix 2: green Done CTA anchored at the bottom.
                    if !awaitingPaste {
                        Button {
                            dismiss()
                        } label: {
                            Text("Done")
                                .font(neon.sans(15).weight(.semibold))
                                .foregroundStyle(neon.accentText)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(neon.green)
                                )
                                .neonGlowBox(neon.glow ? neon.glowBox?.tinted(neon.green) : nil)
                        }
                        .buttonStyle(.plain)
                        .disabled(isWorking)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 12)
                        .background(
                            neon.bg
                                .overlay(alignment: .top) {
                                    Rectangle().fill(neon.border).frame(height: 1)
                                }
                                .ignoresSafeArea(edges: .bottom)
                        )
                    }
                }
                // Fix 2: renamed to "Agent accounts"; trailing X replaces "Cancel".
                .navigationTitle("Agent accounts")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(neon.textDim)
                        }
                        .disabled(isWorking)
                        .accessibilityLabel("Close")
                    }
                }
            }
            .neonAccentTint()
            .appearanceColorScheme()
            .onAppear {
                signedInProviders = Set(
                    [OAuthProvider.openai, .anthropic].filter {
                        OAuthCredentialStore.load(provider: $0) != nil
                    }
                )
                // Per-box readiness "Sign in": launch the real OAuth flow for
                // the requested provider straight away (the credential ships to
                // the connected box via sendAgentCredentials). Guarded so it
                // fires once even if onAppear re-runs.
                if let provider = autoStartProvider, !didAutoStart {
                    didAutoStart = true
                    // Consume the intent in the presenting view before opening
                    // another presentation layer. If SwiftUI reconstructs this
                    // sheet when the browser closes, it must not auto-launch
                    // the same provider again.
                    autoStartProvider = nil
                    Telemetry.breadcrumb("agent_login", "auto-start from readiness",
                        data: ["provider": provider.rawValue])
                    launchLogin(provider)
                }
            }
            .sheet(isPresented: Binding(
                get: { claudeAuthURL != nil },
                set: { if !$0 { claudeAuthURL = nil } }
            )) {
                if let claudeAuthURL {
                    SafariSheet(url: claudeAuthURL)
                        .ignoresSafeArea()
                }
            }
        }

        // MARK: Subviews

        private var intro: some View {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Agent accounts")
                Text("Sign in to the model providers you want to use through Conduit. You sign in in your own browser; Conduit ships the resulting credential to the broker so agents run on your account.")
                    .font(neon.sans(13))
                    .foregroundStyle(neon.textDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        // Fix 2: structured provider card with plan badge + signed-in status + Manage/Sign-in trailing.
        private var providersCard: some View {
            VStack(alignment: .leading, spacing: 0) {
                // Claude row
                let claudeStatus = agentStatus(agent: "claude", provider: .anthropic)
                agentRow(
                    status: claudeStatus,
                    signedIn: signedInProviders.contains(.anthropic),
                    enabled: !isWorking,
                    action: { launchLogin(.anthropic) }
                )
                Divider()
                    .background(neon.border)
                // ChatGPT / Codex row
                let codexStatus = agentStatus(agent: "codex", provider: .openai)
                agentRow(
                    status: codexStatus,
                    signedIn: signedInProviders.contains(.openai),
                    enabled: !isWorking,
                    action: { launchLogin(.openai) }
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
        }

        /// Build a fresh AgentAccountStatus snapshot for the given provider.
        /// Used to surface the plan badge without a full store refresh.
        private func agentStatus(agent: String, provider: OAuthProvider) -> AgentAccountStatus {
            let displayName = agent == "claude" ? "Claude" : "ChatGPT"
            let credential = OAuthCredentialStore.load(provider: provider)
            let planLabel = credential.flatMap(AgentAccountStatus.planLabel(for:))
            let expired = credential.map { AgentAccountStatus.isExpired($0) } ?? false
            return AgentAccountStatus(
                agent: agent,
                provider: provider,
                displayName: displayName,
                signedIn: credential != nil,
                expired: expired,
                planLabel: planLabel
            )
        }

        /// Stage-2 two-line account row:
        /// tinted avatar | name + plan badge + LINE 1 phone status + LINE 2
        /// connected-box readiness | trailing ... menu (re-auth / remove from
        /// phone / remove pushed credential from this box).
        private func agentRow(
            status: AgentAccountStatus,
            signedIn: Bool,
            enabled: Bool,
            action: @escaping () -> Void
        ) -> some View {
            let tint = neon.agentTint(forAgent: status.agent)
            // LINE 1 -- phone (device-local Keychain) sign-in status.
            let phoneText: String = !signedIn ? "Not signed in"
                : status.expired ? "Signed in - expired" : "Signed in"
            let phoneColor: Color = !signedIn ? neon.textFaint
                : status.expired ? neon.yellow : neon.green
            // LINE 2 -- connected-box readiness for THIS agent.
            let boxLine = AgentBoxStatus.make(
                agent: status.agent,
                boxName: store.connectedBoxName,
                signedIn: store.brokerReadiness?.agents[status.agent]?.signedIn
            )
            return HStack(spacing: 12) {
                // Tinted avatar tile
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 38, height: 38)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(tint.opacity(0.35), lineWidth: 1)
                    )
                    .overlay(ConduitUI.ConduitMark(size: 22, color: tint, glow: neon.glow))
                VStack(alignment: .leading, spacing: 3) {
                    // Name + optional plan badge
                    HStack(spacing: 7) {
                        Text(status.displayName)
                            .font(neon.sans(15).weight(.bold))
                            .foregroundStyle(enabled ? neon.text : neon.textFaint)
                        if let plan = status.planLabel {
                            Text(plan)
                                .font(neon.mono(9).weight(.bold))
                                .tracking(0.6)
                                .foregroundStyle(tint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(tint.opacity(0.14)))
                                .overlay(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 1))
                        }
                    }
                    // LINE 1 -- phone status dot + text
                    HStack(spacing: 5) {
                        Circle()
                            .fill(phoneColor)
                            .frame(width: 5, height: 5)
                        Text(phoneText)
                            .font(neon.mono(10.5))
                            .foregroundStyle(phoneColor)
                    }
                    // LINE 2 -- connected-box readiness (hidden when unknown)
                    if let boxLine {
                        Text(boxLine.text)
                            .font(neon.mono(10))
                            .foregroundStyle(boxLine.tone == .ready ? neon.green : neon.textFaint)
                    }
                }
                Spacer(minLength: 8)
                // Trailing ... menu
                if isWorking && enabled {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tint)
                        .frame(width: 24, height: 24)
                } else {
                    accountMenu(status: status, signedIn: signedIn, action: action)
                        .disabled(!enabled)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }

        /// The trailing ... menu shared by both rows. Re-authenticate always
        /// shown; the two destructive removes are scoped to phone vs box.
        @ViewBuilder
        private func accountMenu(
            status: AgentAccountStatus,
            signedIn: Bool,
            action: @escaping () -> Void
        ) -> some View {
            Menu {
                Button {
                    action()
                } label: {
                    Label(signedIn ? "Re-authenticate" : "Sign in", systemImage: "arrow.clockwise")
                }
                if signedIn {
                    Button(role: .destructive) {
                        OAuthCredentialStore.clear(provider: status.provider)
                        signedInProviders.remove(status.provider)
                        Telemetry.breadcrumb("agent_creds", "removed from phone",
                            data: ["provider": status.provider.rawValue])
                    } label: {
                        Label("Remove from phone", systemImage: "iphone.slash")
                    }
                }
                // Only when a connected box exists -- removes the app-pushed
                // credential from the broker store, NOT the box owner's shell
                // login.
                if store.connectedBoxName != nil {
                    Button(role: .destructive) {
                        let provider = status.provider
                        let endpoint = store.endpoint
                        Task {
                            await store.clearAgentCredential(provider: provider, on: endpoint)
                            await store.refreshModelCatalog()
                        }
                    } label: {
                        Label("Remove pushed credential from this box", systemImage: "externaldrive.badge.minus")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(neon.textDim)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(status.displayName) account options")
        }

        /// Claude's code-display flow: after the browser shows a code, the
        /// user pastes it here. Codex never shows this (loopback captures
        /// the code automatically).
        private var pasteCard: some View {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Paste Claude code")
                Text("After signing in, Claude shows a code. Copy it and paste it here.")
                    .font(neon.sans(12))
                    .foregroundStyle(neon.textDim)
                TextField("code#state", text: $pastedCode)
                    .font(neon.mono(14))
                    .foregroundStyle(neon.text)
                    .tint(neon.accent)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .disabled(isWorking)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(neon.surface2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(neon.borderStrong, lineWidth: 1)
                            )
                    )
                ConduitUI.ActionButton("Submit code", variant: .primary) {
                    submitClaudeCode()
                }
                .disabled(isWorking || pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(
                    isWorking || pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? 0.45 : 1
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
        }

        private func statusPill(text: String, tint: Color) -> some View {
            Text(text)
                .font(neon.sans(13))
                .foregroundStyle(tint)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
        }

        private func sectionLabel(_ text: String) -> some View {
            Text(text.uppercased())
                .font(neon.mono(11).weight(.bold))
                .tracking(0.6)
                .foregroundStyle(neon.textFaint)
        }

        // MARK: Actions

        /// Claim the UI synchronously before creating an async task. Relying on
        /// the next SwiftUI render to disable the menu/button leaves a window
        /// where two taps can enqueue two browser presentations.
        @MainActor
        private func launchLogin(_ provider: OAuthProvider) {
            guard !isWorking else {
                Telemetry.breadcrumb("agent_login", "duplicate launch dropped",
                    data: ["provider": provider.rawValue])
                return
            }
            isWorking = true
            Task {
                switch provider {
                case .openai:    await loginChatGPT()
                case .anthropic: await beginClaude()
                }
            }
        }

        /// ChatGPT/Codex — one-shot loopback flow (no paste step).
        @MainActor
        private func loginChatGPT() async {
            statusMessage = "Opening ChatGPT sign-in…"
            errorMessage = nil
            awaitingPaste = false
            defer { isWorking = false }
            Telemetry.breadcrumb("agent_login", "openai: start (loopback)")
            do {
                let client = OAuthClient(provider: .openai)
                let credential = try await client.startLogin()
                Telemetry.breadcrumb("agent_login", "openai: token exchange ok")
                try await deliver(credential, provider: .openai)
            } catch let err as OAuthClientError {
                statusMessage = nil
                errorMessage = describe(err)
                Telemetry.capture(error: err, message: "agent login failed: openai", tags: ["flow": "agent_login", "provider": "openai"], extras: ["reason": describe(err)])
            } catch {
                statusMessage = nil
                errorMessage = "Sign-in failed: \(error.localizedDescription)"
                Telemetry.capture(error: error, message: "agent login failed: openai", tags: ["flow": "agent_login", "provider": "openai"])
            }
        }

        /// Claude/Anthropic step 1 — open the authorize page IN-APP
        /// (SFSafariViewController sheet, like Codex's in-app browser);
        /// the user copies the displayed code, taps Done, and pastes it
        /// into `pasteCard`. The old `UIApplication.shared.open` bounced
        /// to external Safari and stranded the user outside the app.
        @MainActor
        private func beginClaude() async {
            errorMessage = nil
            defer { isWorking = false }
            Telemetry.breadcrumb("agent_login", "anthropic: begin code-paste, opening in-app browser")
            do {
                let client = OAuthClient(provider: .anthropic)
                let url = try client.beginCodePasteAuthorize()
                pasteClient = client
                awaitingPaste = true
                statusMessage = "Sign in, copy the code Claude shows, tap Done, then paste it below."
                claudeAuthURL = url
            } catch {
                statusMessage = nil
                errorMessage = "Could not start Claude sign-in: \(error.localizedDescription)"
                Telemetry.capture(error: error, message: "agent login failed: anthropic begin", tags: ["flow": "agent_login", "provider": "anthropic"])
            }
        }

        /// Claude/Anthropic step 2 — exchange the pasted code.
        @MainActor
        private func submitClaudeCode() {
            guard !isWorking else {
                Telemetry.breadcrumb("agent_login", "duplicate anthropic code submit dropped")
                return
            }
            isWorking = true
            Task { await finishClaude() }
        }

        @MainActor
        private func finishClaude() async {
            guard let client = pasteClient else {
                errorMessage = "Start the Claude sign-in first."
                isWorking = false
                return
            }
            statusMessage = "Exchanging the Claude code…"
            errorMessage = nil
            defer { isWorking = false }
            Telemetry.breadcrumb("agent_login", "anthropic: submit pasted code, exchanging")
            do {
                let credential = try await client.finishCodePaste(pasted: pastedCode)
                Telemetry.breadcrumb("agent_login", "anthropic: token exchange ok")
                try await deliver(credential, provider: .anthropic)
                awaitingPaste = false
                pastedCode = ""
                pasteClient = nil
            } catch let err as OAuthClientError {
                statusMessage = nil
                errorMessage = describe(err)
                Telemetry.capture(error: err, message: "agent login failed: anthropic", tags: ["flow": "agent_login", "provider": "anthropic"], extras: ["reason": describe(err)])
            } catch {
                statusMessage = nil
                errorMessage = "Sign-in failed: \(error.localizedDescription)"
                Telemetry.capture(error: error, message: "agent login failed: anthropic", tags: ["flow": "agent_login", "provider": "anthropic"])
            }
        }

        /// Stash the credential locally (so it survives a WS outage / a
        /// not-yet-connected session) and ship it to the broker.
        @MainActor
        private func deliver(_ credential: OAuthCredential, provider: OAuthProvider) async throws {
            try? OAuthCredentialStore.save(credential)
            signedInProviders.insert(provider)
            Telemetry.breadcrumb("agent_login", "shipping credential to broker", data: ["provider": provider.rawValue])
            do {
                try await store.sendAgentCredentials(provider: provider, credential: credential)
                statusMessage = "Signed in. The broker now has your \(provider.rawValue) credentials for future sessions."
                errorMessage = nil
                // Refresh readiness so the per-box LINE 2 ("Ready on <box>")
                // flips after the broker accepts the pushed credential.
                await store.refreshModelCatalog()
                // Standalone visible event for every terminal outcome (a
                // breadcrumb alone is invisible unless a later event fires).
                Telemetry.debug("oauth_result", "shipped \(provider.rawValue)", data: ["provider": provider.rawValue])
            } catch {
                // Token exchange succeeded and the credential is saved in the
                // Keychain. The broker hand-off needs a live session (the core
                // carries it over an active session WS); if none is live yet,
                // `replayStoredAgentCredentials()` resends it the moment the
                // user starts a session — so this is NOT a failure. Show a
                // benign "saved" message, not a scary error.
                statusMessage = "Signed in — saved. It’ll sync to the broker when you start a session."
                errorMessage = nil
                Telemetry.debug("oauth_result", "saved-deferred \(provider.rawValue)", data: ["provider": provider.rawValue, "reason": "\(error)"])
            }
        }

        private func describe(_ err: OAuthClientError) -> String {
            switch err {
            case .userCancelled:                  return "Sign-in cancelled."
            case .missingCallback:                return "The browser didn't return a result."
            case .missingCode:                    return "No authorization code came back. If you pasted, check you copied the whole code."
            case .tokenExchangeFailed(let s, _):  return "Token exchange failed (HTTP \(s))."
            case .malformedTokenResponse:         return "The provider's token response was malformed."
            case .underlying(let m):              return "Sign-in failed: \(m)"
            }
        }
    }
}

/// In-app browser sheet for the Claude code-paste flow. A plain
/// `SFSafariViewController` (not `ASWebAuthenticationSession`) because
/// there is no redirect to intercept — the user manually copies the
/// displayed `code#state` and taps Done, so the natural Done-button
/// chrome is exactly the affordance we want.
private struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.dismissButtonStyle = .done
        return vc
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
