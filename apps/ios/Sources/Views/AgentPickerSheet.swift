import SwiftUI

/// Shared "pick an agent" sheet. Used in two places:
/// - **+** toolbar button on `ProjectListView` (start a new session).
/// - Auto-presented after a deep-link / QR pair so the user lands
///   directly on agent choice instead of an empty session list.
///
/// Buttons are big and tinted with the per-agent accent so the
/// affordance matches the chat-tab tint after creation.
struct AgentPickerSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    /// Optional context label (e.g. host that was just paired) shown
    /// in the sheet header. nil hides it.
    var headerNote: String?

    var body: some View {
        NavigationStack {
            ZStack {
                SweKittyTheme.backgroundGradient(for: colorScheme).ignoresSafeArea()
                VStack(spacing: 16) {
                    header
                    agentButton(
                        kind: "claude",
                        label: "Claude",
                        subtitle: "Anthropic — copper accent, headstrong",
                        tint: SweKittyTheme.claudeAccent
                    )
                    agentButton(
                        kind: "codex",
                        label: "Codex",
                        subtitle: "OpenAI — green accent, codex",
                        tint: SweKittyTheme.codexAccent
                    )
                    if !store.harness.canIssueCommands {
                        Text("Connect to a harness first — open Settings to pair.")
                            .font(.footnote)
                            .foregroundStyle(SweKittyTheme.textMuted)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .tint(SweKittyTheme.accentStrong)
    }

    @ViewBuilder
    private var header: some View {
        if let note = headerNote, !note.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Paired with")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textSecondary)
                Text(note)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .glassRoundedRect()
        }
    }

    private func agentButton(kind: String, label: String, subtitle: String, tint: Color) -> some View {
        Button {
            store.createSession(assistant: kind)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                AgentAvatar(assistant: kind, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(SweKittyTheme.textPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(SweKittyTheme.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .glassRect(cornerRadius: SweKittyTheme.cardCornerRadius, tint: tint.opacity(0.20))
        }
        .buttonStyle(.plain)
        .disabled(!store.harness.canIssueCommands)
        .opacity(store.harness.canIssueCommands ? 1.0 : 0.55)
    }
}
