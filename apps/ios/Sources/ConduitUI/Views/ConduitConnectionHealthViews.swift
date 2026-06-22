import SwiftUI

// MARK: - WS-H.2: Broker-update banner
//
// Non-blocking banner shown on the home / box screen when the broker is
// outdated. SSH-paired boxes get a one-tap re-bootstrap; token-paired boxes
// get the install.sh one-liner to copy. The banner disappears once a fresh
// capabilities fetch confirms the new version.
//
// "dev" / unparseable broker versions are NEVER nagged (honest-state: hand-built
// boxes should not be told to "update" to a release they don't track).

extension ConduitUI {
    /// Non-blocking broker-update banner for the home / box screen.
    /// Shows only when `brokerVersionStatus` returns `.updateAvailable`.
    /// `isSshPaired`: true when the active endpoint was paired via SSH
    /// (the bootstrap re-run path is available). false = token-paired
    /// (show the install.sh copy affordance instead).
    /// `liveCount`: number of currently running sessions on this box.
    /// When > 0 the SSH "Update now" button shows a confirmation alert
    /// explaining that sessions will be ended but their history is saved.
    struct BrokerUpdateBanner: View {
        let brokerVersion: String
        let isSshPaired: Bool
        /// Pass 0 to skip the live-session warning. Pass the real count so
        /// the confirmation alert can name the exact number.
        let liveCount: Int
        let onRebootstrap: () -> Void

        @Environment(\.neonTheme) private var neon
        @State private var copyConfirmed = false
        @State private var showConfirmAlert = false

        private let installOneliner = "curl -fsSL https://conduit.nikhil.sh/install.sh | sh"

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(neon.accent)
                    .frame(width: 22)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Broker update available")
                        .font(neon.sans(13).weight(.semibold))
                        .foregroundStyle(neon.text)
                    Text("This box runs conduit \(brokerVersion). A newer version is available.")
                        .font(neon.sans(12))
                        .foregroundStyle(neon.textDim)
                        .fixedSize(horizontal: false, vertical: true)

                    if liveCount > 0 {
                        let plural = liveCount == 1 ? "session" : "sessions"
                        Text("Updating restarts the broker and ends \(liveCount) running \(plural). Their history is saved — they'll resume automatically afterward.")
                            .font(neon.sans(12))
                            .foregroundStyle(neon.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if isSshPaired {
                        Button {
                            if liveCount > 0 {
                                showConfirmAlert = true
                            } else {
                                onRebootstrap()
                            }
                        } label: {
                            Text("Update now")
                                .font(neon.sans(12).weight(.semibold))
                                .foregroundStyle(neon.accentText)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(neon.accent))
                        }
                        .buttonStyle(.plain)
                        .alert(
                            "End \(liveCount) running \(liveCount == 1 ? "session" : "sessions") to update?",
                            isPresented: $showConfirmAlert
                        ) {
                            Button("Update", role: .destructive) { onRebootstrap() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("History is saved and sessions resume after the restart.")
                        }
                    } else {
                        // Token-paired: show the one-liner to copy.
                        Button {
                            UIPasteboard.general.string = installOneliner
                            copyConfirmed = true
                            Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copyConfirmed = false }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: copyConfirmed ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(copyConfirmed ? "Copied!" : "Copy install command")
                                    .font(neon.sans(12).weight(.semibold))
                            }
                            .foregroundStyle(neon.accentText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(neon.accent))
                        }
                        .buttonStyle(.plain)
                        .animation(.easeInOut(duration: 0.15), value: copyConfirmed)

                        Text(installOneliner)
                            .font(neon.mono(10.5))
                            .foregroundStyle(neon.textFaint)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .neonCardSurface(
                neon,
                fill: neon.accent.opacity(neon.dark ? 0.08 : 0.06),
                cornerRadius: 14,
                border: neon.accent.opacity(0.35)
            )
        }
    }
}

// MARK: - WS-H.3: Post-pair readiness checklist
//
// Compact checklist shown in the agent picker (and Settings > Box Health)
// after pairing. Informational, never blocking. "Sign in" rows deep-link
// the existing AgentLoginSheet. The user can proceed to start a session
// at any point.

extension ConduitUI {
    /// Compact checklist of per-agent + infra readiness. Shown after pairing
    /// and on the box-health surface. Never blocking.
    struct ReadinessChecklist: View {
        let items: [ReadinessCheckItem]
        /// Called when the user taps "Sign in" on a not-signed-in row.
        let onSignIn: (String) -> Void

        @Environment(\.neonTheme) private var neon

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items) { item in
                    readinessRow(item)
                }
            }
        }

        private func readinessRow(_ item: ReadinessCheckItem) -> some View {
            HStack(spacing: 10) {
                statusIcon(item)
                Text(item.label)
                    .font(neon.sans(13).weight(.medium))
                    .foregroundStyle(item.status == .ok ? neon.text : neon.textDim)
                Spacer(minLength: 0)
                actionLabel(item)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .neonCardSurface(
                neon,
                fill: rowFill(item),
                cornerRadius: 12,
                border: rowBorder(item)
            )
        }

        @ViewBuilder
        private func actionLabel(_ item: ReadinessCheckItem) -> some View {
            switch item.status {
            case .ok:
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(neon.green)
            case .notSignedIn:
                if let provider = item.loginProvider, !provider.isEmpty {
                    Button {
                        onSignIn(provider)
                    } label: {
                        Text("Sign in")
                            .font(neon.sans(11.5).weight(.semibold))
                            .foregroundStyle(neon.accentText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(neon.accent))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("not signed in")
                        .font(neon.mono(10.5))
                        .foregroundStyle(neon.textFaint)
                }
            case .notInstalled:
                if item.autoInstalls {
                    Text("installs on first use")
                        .font(neon.mono(10.5))
                        .foregroundStyle(neon.textFaint)
                } else {
                    Text("not installed")
                        .font(neon.mono(10.5))
                        .foregroundStyle(neon.textFaint)
                }
            case .absent:
                Text("missing")
                    .font(neon.mono(10.5))
                    .foregroundStyle(neon.textFaint)
            }
        }

        private func statusIcon(_ item: ReadinessCheckItem) -> some View {
            let (name, color): (String, Color) = switch item.status {
            case .ok:           ("checkmark.circle.fill", neon.green)
            case .notSignedIn:  ("exclamationmark.circle", neon.accent)
            case .notInstalled: item.autoInstalls
                                    ? ("arrow.down.circle", neon.textDim)
                                    : ("xmark.circle",      neon.red)
            case .absent:       ("exclamationmark.triangle", neon.accent)
            }
            return Image(systemName: name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 20)
        }

        private func rowFill(_ item: ReadinessCheckItem) -> Color {
            switch item.status {
            case .ok:           return neon.surface
            case .notSignedIn:  return neon.accent.opacity(neon.dark ? 0.07 : 0.05)
            case .notInstalled: return item.autoInstalls
                                    ? neon.surface
                                    : neon.red.opacity(neon.dark ? 0.07 : 0.05)
            case .absent:       return neon.accent.opacity(neon.dark ? 0.07 : 0.05)
            }
        }

        private func rowBorder(_ item: ReadinessCheckItem) -> Color {
            switch item.status {
            case .ok:           return neon.border
            case .notSignedIn:  return neon.accent.opacity(0.3)
            case .notInstalled: return item.autoInstalls
                                    ? neon.border
                                    : neon.red.opacity(0.3)
            case .absent:       return neon.accent.opacity(0.3)
            }
        }
    }
}
