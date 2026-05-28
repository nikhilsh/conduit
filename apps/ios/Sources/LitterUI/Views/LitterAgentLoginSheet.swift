import SwiftUI

// MARK: - LitterAgentLoginSheet
//
// Native LitterUI sign-in surface for per-user agent OAuth. Drives the
// v2 (litter-pattern) flow via `AgentLoginCoordinator`:
//
//   1. Tap "Login with Claude" / "Login with ChatGPT"
//   2. Sheet creates an `AgentLoginCoordinator`, registers it on
//      `SessionStore.activeLoginCoordinator`, calls `start(provider:)`
//   3. The transport ships `start_agent_login` over WS; the broker
//      replies with an `agent_login_url` view_event, the store dispatches
//      it back into the coordinator via `routeAgentLoginViewEvent`.
//   4. Coordinator opens the URL in `ASWebAuthenticationSession`, the
//      loopback listener captures the redirect, ships the callback
//      back to the broker.
//   5. Coordinator state moves to `.succeeded` (or `.failed`); the
//      sheet observes via a tick state value and surfaces the result.
//
// The Rust→Swift bridge for the outbound control envelopes hasn't
// shipped yet (PR #131's missing piece); when the user taps a button
// today the transport throws `AgentLoginTransportError` and the sheet
// surfaces "broker bridge not yet wired" in its error pill. This is
// intentional: shipping the UI behind the missing transport keeps the
// state machine exercisable while we wait for the UDL update.

extension LitterUI {
    struct AgentLoginSheet: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.dismiss) private var dismiss

        @State private var isWorking = false
        @State private var statusMessage: String?
        @State private var errorMessage: String?
        @State private var coordinator: AgentLoginCoordinator?
        /// Bumped after every coordinator state transition so the
        /// SwiftUI view body re-evaluates derived bindings. The
        /// coordinator itself isn't `@Observable` (deliberate — see
        /// the comment in `AgentLoginCoordinator`), so we re-render
        /// via this tick instead of via property observation.
        @State private var stateTick: Int = 0

        var body: some View {
            NavigationStack {
                ZStack {
                    LitterUI.Palette.surface.color.ignoresSafeArea()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            intro
                            providersCard
                            if let statusMessage {
                                statusPill(text: statusMessage, tint: LitterUI.Palette.brand.color)
                            }
                            if let errorMessage {
                                statusPill(text: errorMessage, tint: LitterUI.Palette.danger.color)
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
                            coordinator?.cancel()
                            store.activeLoginCoordinator = nil
                            dismiss()
                        }
                        .disabled(isWorking)
                    }
                }
            }
            .tint(LitterUI.Palette.brand.color)
            .appearanceColorScheme()
        }

        // MARK: Subviews

        private var intro: some View {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Agent accounts")
                Text("Sign in to the model providers you want to use through SweKitty. Tokens are minted by the broker via the v2 OAuth flow (litter pattern) — credentials never live on your phone.")
                    .font(.footnote)
                    .foregroundStyle(LitterUI.Palette.textMuted.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private var providersCard: some View {
            VStack(alignment: .leading, spacing: 0) {
                providerRow(
                    icon: "person.crop.circle.badge.checkmark",
                    tint: SweKittyTheme.accent(forAgent: "codex"),
                    title: "Login with ChatGPT",
                    subtitle: "Codex / ChatGPT OAuth · auth.openai.com",
                    enabled: !isWorking,
                    action: { Task { await startLogin(.openai) } }
                )
                Divider()
                    .background(LitterUI.Palette.separator.color)
                    .padding(.vertical, 6)
                providerRow(
                    icon: "ant.circle",
                    tint: SweKittyTheme.accent(forAgent: "claude"),
                    title: "Login with Claude",
                    subtitle: "Claude OAuth · claude.ai",
                    enabled: !isWorking,
                    action: { Task { await startLogin(.anthropic) } }
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .litterGlassRoundedRect(cornerRadius: 14)
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
                        .foregroundStyle(enabled ? tint : LitterUI.Palette.textMuted.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(enabled ? LitterUI.Palette.textPrimary.color : LitterUI.Palette.textMuted.color)
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(LitterUI.Palette.textMuted.color)
                    }
                    Spacer()
                    if isWorking, enabled {
                        ProgressView()
                            .controlSize(.small)
                            .tint(tint)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LitterUI.Palette.textMuted.color)
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
                .litterGlassRoundedRect(cornerRadius: 14)
        }

        private func sectionLabel(_ text: String) -> some View {
            Text(text.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(LitterUI.Palette.textMuted.color)
        }

        // MARK: Actions

        @MainActor
        private func startLogin(_ provider: AgentLoginProvider) async {
            isWorking = true
            statusMessage = "Asking the broker to start the \(provider.rawValue) login flow…"
            errorMessage = nil
            defer { isWorking = false }

            // The transport throws `AgentLoginTransportError` until
            // the Rust UDL bridge for the v2 control messages lands,
            // so we never reach the ASWebAuthenticationSession
            // presentation path today — no presentation-provider is
            // needed. Once the bridge ships, a follow-up will hand a
            // concrete `ASWebAuthenticationPresentationContextProviding`
            // (typically a thin wrapper that returns the foreground
            // key window) to the coordinator init.
            let transport = SessionStoreAgentLoginTransport(store: store)
            let coord = AgentLoginCoordinator(transport: transport)
            coordinator = coord
            store.activeLoginCoordinator = coord

            do {
                try await coord.start(provider)
                // Wait briefly to surface synchronous transitions
                // (e.g. transport throw → .failed). Real flows resolve
                // via inbound view_events; this is just for the
                // happy-path / quick-fail visibility.
                try? await Task.sleep(nanoseconds: 200_000_000)
                stateTick &+= 1
                applyCoordinatorState(coord.state)
            } catch let err as AgentLoginTransportError {
                store.activeLoginCoordinator = nil
                statusMessage = nil
                errorMessage = "Sign-in unavailable: \(err.errorDescription ?? "transport error")"
            } catch {
                store.activeLoginCoordinator = nil
                statusMessage = nil
                errorMessage = "Sign-in failed to start: \(error.localizedDescription)"
            }
        }

        @MainActor
        private func applyCoordinatorState(_ state: AgentLoginCoordinator.State) {
            switch state {
            case .idle:
                break
            case .waitingForBrokerURL:
                statusMessage = "Waiting for the broker to mint the login URL…"
            case .awaitingBrowserRedirect:
                statusMessage = "Complete the sign-in in the browser sheet."
            case .forwardingCallback:
                statusMessage = "Forwarding callback to the broker…"
            case .succeeded:
                statusMessage = "Signed in. The broker now has your credentials for future sessions."
                errorMessage = nil
            case .failed(let reason):
                statusMessage = nil
                errorMessage = "Sign-in failed: \(reason)"
            case .cancelled:
                statusMessage = nil
                errorMessage = "Sign-in cancelled."
            }
        }
    }
}
