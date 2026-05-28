import SwiftUI

/// TOFU sheet shown the first time we see a host's SSH fingerprint, or
/// when an already-trusted host's fingerprint changes. Persist the
/// decision in `SshHostKeyTrustStore` if the user accepts.
struct HostKeyPromptSheet: View {
    let prompt: HostKeyPrompt
    let resolve: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            ZStack {
                SweKittyTheme.backgroundGradient(for: colorScheme)
                    .ignoresSafeArea()
                VStack(alignment: .leading, spacing: 18) {
                    Text("First time connecting to")
                        .font(.subheadline)
                        .foregroundStyle(SweKittyTheme.textSecondary)
                    Text("\(prompt.host):\(prompt.port)")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(SweKittyTheme.textBody)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Host Key Fingerprint")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SweKittyTheme.textSecondary)
                        Text(prompt.fingerprint)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(SweKittyTheme.textBody)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassRoundedRect()
                    }

                    Text("Verify this fingerprint against the server's `ssh-keyscan` output before trusting. If it doesn't match, something is intercepting your connection.")
                        .font(.footnote)
                        .foregroundStyle(SweKittyTheme.textSecondary)

                    Spacer()

                    VStack(spacing: 10) {
                        Button {
                            resolve(true)
                            dismiss()
                        } label: {
                            Label("Trust and Continue", systemImage: "checkmark.shield")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(SweKittyTheme.textPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .glassCapsule(interactive: true, tint: SweKittyTheme.success.opacity(0.55))
                        }
                        .buttonStyle(.plain)

                        Button {
                            resolve(false)
                            dismiss()
                        } label: {
                            Label("Reject", systemImage: "xmark.shield")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(SweKittyTheme.textPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .glassCapsule(interactive: true, tint: SweKittyTheme.danger.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Verify Host Key")
            .navigationBarTitleDisplayMode(.inline)
        }
        .appearanceColorScheme()
    }
}
