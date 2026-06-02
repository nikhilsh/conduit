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

        @State private var isWorking = false
        @State private var statusMessage: String?
        @State private var errorMessage: String?

        /// Retained across the Claude code-paste round-trip: it holds the
        /// PKCE verifier between opening the browser and the user pasting
        /// the displayed code.
        @State private var pasteClient: OAuthClient?
        @State private var awaitingPaste = false
        @State private var pastedCode: String = ""

        var body: some View {
            NavigationStack {
                ZStack {
                    ConduitUI.Palette.surface.color.ignoresSafeArea()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
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
                    }
                    .scrollIndicators(.hidden)
                }
                .navigationTitle("Sign in")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                        .disabled(isWorking)
                    }
                }
            }
            .neonAccentTint()
            .appearanceColorScheme()
        }

        // MARK: Subviews

        private var intro: some View {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Agent accounts")
                Text("Sign in to the model providers you want to use through Conduit. You sign in in your own browser; Conduit ships the resulting credential to the broker so agents run on your account.")
                    .font(.footnote)
                    .foregroundStyle(ConduitUI.Palette.textMuted.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private var providersCard: some View {
            VStack(alignment: .leading, spacing: 0) {
                providerRow(
                    icon: "person.crop.circle.badge.checkmark",
                    tint: neon.agentTint(forAgent: "codex"),
                    title: "Login with ChatGPT",
                    subtitle: "Codex / ChatGPT OAuth · auth.openai.com",
                    enabled: !isWorking,
                    action: { Task { await loginChatGPT() } }
                )
                Divider()
                    .background(ConduitUI.Palette.separator.color)
                    .padding(.vertical, 6)
                providerRow(
                    icon: "ant.circle",
                    tint: neon.agentTint(forAgent: "claude"),
                    title: "Login with Claude",
                    subtitle: "Claude OAuth · claude.ai (paste code)",
                    enabled: !isWorking,
                    action: { Task { await beginClaude() } }
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .conduitGlassRoundedRect(cornerRadius: 14)
        }

        /// Claude's code-display flow: after the browser shows a code, the
        /// user pastes it here. Codex never shows this (loopback captures
        /// the code automatically).
        private var pasteCard: some View {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Paste Claude code")
                Text("After signing in, Claude shows a code. Copy it and paste it here.")
                    .font(.caption2)
                    .foregroundStyle(ConduitUI.Palette.textMuted.color)
                TextField("code#state", text: $pastedCode)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .disabled(isWorking)
                Button(action: { Task { await finishClaude() } }) {
                    Text("Submit code")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .conduitGlassRoundedRect(cornerRadius: 14)
        }

        @ViewBuilder
        private func providerRow(
            icon: String,
            tint: Color,
            title: String,
            subtitle: String,
            enabled: Bool,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.body)
                        .frame(width: 22)
                        .foregroundStyle(enabled ? tint : ConduitUI.Palette.textMuted.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(enabled ? ConduitUI.Palette.textPrimary.color : ConduitUI.Palette.textMuted.color)
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(ConduitUI.Palette.textMuted.color)
                    }
                    Spacer()
                    if isWorking, enabled {
                        ProgressView()
                            .controlSize(.small)
                            .tint(tint)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ConduitUI.Palette.textMuted.color)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
        }

        private func statusPill(text: String, tint: Color) -> some View {
            Text(text)
                .font(.footnote)
                .foregroundStyle(tint)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .conduitGlassRoundedRect(cornerRadius: 14)
        }

        private func sectionLabel(_ text: String) -> some View {
            Text(text.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(ConduitUI.Palette.textMuted.color)
        }

        // MARK: Actions

        /// ChatGPT/Codex — one-shot loopback flow (no paste step).
        @MainActor
        private func loginChatGPT() async {
            isWorking = true
            statusMessage = "Opening ChatGPT sign-in…"
            errorMessage = nil
            awaitingPaste = false
            defer { isWorking = false }
            do {
                let client = OAuthClient(provider: .openai)
                let credential = try await client.startLogin()
                try await deliver(credential, provider: .openai)
            } catch let err as OAuthClientError {
                statusMessage = nil
                errorMessage = describe(err)
            } catch {
                statusMessage = nil
                errorMessage = "Sign-in failed: \(error.localizedDescription)"
            }
        }

        /// Claude/Anthropic step 1 — open the browser; the user copies the
        /// displayed code and pastes it into `pasteCard`.
        @MainActor
        private func beginClaude() async {
            isWorking = true
            errorMessage = nil
            defer { isWorking = false }
            do {
                let client = OAuthClient(provider: .anthropic)
                let url = try client.beginCodePasteAuthorize()
                pasteClient = client
                _ = await UIApplication.shared.open(url)
                awaitingPaste = true
                statusMessage = "Sign in, copy the code Claude shows, then paste it below."
            } catch {
                statusMessage = nil
                errorMessage = "Could not start Claude sign-in: \(error.localizedDescription)"
            }
        }

        /// Claude/Anthropic step 2 — exchange the pasted code.
        @MainActor
        private func finishClaude() async {
            guard let client = pasteClient else {
                errorMessage = "Start the Claude sign-in first."
                return
            }
            isWorking = true
            statusMessage = "Exchanging the Claude code…"
            errorMessage = nil
            defer { isWorking = false }
            do {
                let credential = try await client.finishCodePaste(pasted: pastedCode)
                try await deliver(credential, provider: .anthropic)
                awaitingPaste = false
                pastedCode = ""
                pasteClient = nil
            } catch let err as OAuthClientError {
                statusMessage = nil
                errorMessage = describe(err)
            } catch {
                statusMessage = nil
                errorMessage = "Sign-in failed: \(error.localizedDescription)"
            }
        }

        /// Stash the credential locally (so a WS outage doesn't lose it)
        /// and ship it to the broker.
        @MainActor
        private func deliver(_ credential: OAuthCredential, provider: OAuthProvider) async throws {
            try? OAuthCredentialStore.save(credential)
            do {
                try await store.sendAgentCredentials(provider: provider, credential: credential)
                statusMessage = "Signed in. The broker now has your \(provider.rawValue) credentials for future sessions."
                errorMessage = nil
            } catch {
                // Token exchange succeeded; only the broker hand-off
                // failed. The Keychain copy survives — surface a retry.
                statusMessage = nil
                errorMessage = "Signed in, but couldn't reach the broker. Reconnect and try again — your login is saved locally."
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
