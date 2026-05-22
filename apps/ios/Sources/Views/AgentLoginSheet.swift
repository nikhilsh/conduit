import SwiftUI

/// Stage 0/1 spike sheet for per-user agent OAuth. Two rows:
///
/// - "Login with ChatGPT" — kicks off the OpenAI / Codex OAuth flow via
///   `OAuthClient(provider: .openai).startLogin()`, persists the
///   resulting `AuthDotJson` blob in Keychain (service
///   `"sh.nikhil.swekitty.oauth"`), and `print()`s the credential JSON
///   to the console so a human can eyeball it during the spike demo
///   (see PLAN-AGENT-OAUTH §I "Stage 0 acceptance").
/// - "Login with Claude" — same flow, provider `.anthropic`, persists a
///   `ClaudeCredentialsJson` blob. The OAuth params for Claude were
///   reverse-engineered from the `claude` CLI binary (see PR #for
///   `oauth-stage1-claude-button`) — Anthropic doesn't publish them,
///   so on-device verification is the gating step.
///
/// No broker traffic, no `set_agent_credentials` WS message, no token
/// refresh. Stage 2 adds the broker wiring.
struct AgentLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                SweKittyTheme.backgroundGradient(for: colorScheme).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 22) {
                        intro
                        providersCard
                        if let statusMessage {
                            statusPill(text: statusMessage, tint: SweKittyTheme.accentStrong)
                        }
                        if let errorMessage {
                            statusPill(text: errorMessage, tint: SweKittyTheme.danger)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .tint(SweKittyTheme.accentStrong)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
            }
        }
    }

    // MARK: - Sections

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agent accounts")
                .font(.title3.weight(.bold))
                .foregroundStyle(SweKittyTheme.textPrimary)
            Text("Stage 0 spike — credential is stashed in Keychain and printed to the Xcode console. Broker wiring follows in Stage 2.")
                .font(.footnote)
                .foregroundStyle(SweKittyTheme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var providersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            providerRow(
                icon: "person.crop.circle.badge.checkmark",
                tint: SweKittyTheme.codexAccent,
                title: "Login with ChatGPT",
                subtitle: "Codex / ChatGPT OAuth · auth.openai.com",
                enabled: !isWorking,
                action: { Task { await startChatGPTLogin() } }
            )
            Divider().background(SweKittyTheme.separator)
            providerRow(
                icon: "ant.circle",
                tint: SweKittyTheme.claudeAccent,
                title: "Login with Claude",
                subtitle: "Claude OAuth · claude.ai",
                enabled: !isWorking,
                action: { Task { await startClaudeLogin() } }
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassRoundedRect()
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
                    .foregroundStyle(enabled ? tint : SweKittyTheme.textMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(enabled ? SweKittyTheme.textPrimary : SweKittyTheme.textMuted)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(SweKittyTheme.textMuted)
                }
                Spacer()
                if isWorking, enabled {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tint)
                } else if enabled {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SweKittyTheme.textMuted)
                } else {
                    Text("Soon")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .glassCapsule(interactive: false, tint: SweKittyTheme.textMuted.opacity(0.18))
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
            .glassRoundedRect()
    }

    // MARK: - Actions

    @MainActor
    private func startChatGPTLogin() async {
        await startLogin(provider: .openai)
    }

    @MainActor
    private func startClaudeLogin() async {
        await startLogin(provider: .anthropic)
    }

    @MainActor
    private func startLogin(provider: OAuthProvider) async {
        isWorking = true
        statusMessage = "Opening sign-in browser…"
        errorMessage = nil
        defer { isWorking = false }

        let client = OAuthClient(provider: provider)
        do {
            let credential = try await client.startLogin()
            try OAuthCredentialStore.save(credential)
            statusMessage = "Signed in — credential saved to Keychain."
            logCredentialToConsole(credential)
        } catch OAuthClientError.userCancelled {
            statusMessage = nil
            errorMessage = "Sign-in cancelled."
        } catch {
            statusMessage = nil
            errorMessage = "Sign-in failed: \(error)"
        }
    }

    /// Prints the credential JSON to stdout so the spike demo can
    /// eyeball `access_token` / `refresh_token`. Stage 2 deletes this
    /// — broker materialization will be the only consumer.
    ///
    /// Encodes the **inner native blob**, not the discriminated enum,
    /// because that's the exact shape the broker will write to disk —
    /// printing it now lets us diff against `~/.codex/auth.json` and
    /// `~/.claude/.credentials.json` from a real CLI install.
    private func logCredentialToConsole(_ credential: OAuthCredential) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data?
        switch credential {
        case .openai(let blob):    data = try? encoder.encode(blob)
        case .anthropic(let blob): data = try? encoder.encode(blob)
        }
        if let data, let json = String(data: data, encoding: .utf8) {
            print("[AgentLoginSheet] credential blob (\(credential.provider.rawValue)):\n\(json)")
        } else {
            print("[AgentLoginSheet] credential blob: <encode failed>")
        }
    }
}
