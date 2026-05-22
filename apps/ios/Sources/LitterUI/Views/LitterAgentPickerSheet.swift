import SwiftUI

// MARK: - LitterAgentPickerSheet
//
// Native LitterUI agent-picker sheet. Replaces the legacy
// `AgentPickerSheet`. Visual choices:
//   - small-caps "PAIRED WITH" / "INITIAL PROMPT" / "AGENT" section
//     labels (11pt mono, brand-tinted)
//   - .ultraThinMaterial cards via `litterGlassRoundedRect`
//   - per-agent accent on the avatar circle only; row text stays in
//     `textPrimary` so the buttons read as a list not a rainbow
//
// Used in two places:
//   - "+" button on `LitterHomeView` (new session).
//   - Auto-presented after a deep-link pair so the user lands on
//     "pick Claude/Codex" instead of an empty session list.

extension LitterUI {
    struct AgentPickerSheet: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.dismiss) private var dismiss

        /// Optional context label (e.g. host that was just paired) shown
        /// in the sheet header. nil hides it.
        var headerNote: String? = nil

        /// Optional pre-populated prompt (typically a voice transcript).
        /// When set, tapping an agent creates the session with this
        /// prompt seeded as its first chat message.
        var initialPrompt: String? = nil

        var body: some View {
            NavigationStack {
                ZStack {
                    LitterUI.Palette.surface.color.ignoresSafeArea()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            header
                            if let prompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !prompt.isEmpty {
                                promptPreview(prompt)
                            }
                            sectionLabel("Agent")
                            agentRow(
                                kind: "claude",
                                label: "Claude",
                                subtitle: "Anthropic — copper accent"
                            )
                            agentRow(
                                kind: "codex",
                                label: "Codex",
                                subtitle: "OpenAI — green accent"
                            )
                            if !store.harness.canIssueCommands {
                                Text("Connect to a harness first — open Settings to pair.")
                                    .font(.footnote)
                                    .foregroundStyle(LitterUI.Palette.textMuted.color)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.top, 4)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                    }
                    .scrollIndicators(.hidden)
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
            .tint(LitterUI.Palette.brand.color)
        }

        // MARK: - Subviews

        @ViewBuilder
        private var header: some View {
            if let note = headerNote, !note.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("Paired with")
                    Text(note)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LitterUI.Palette.textPrimary.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .litterGlassRoundedRect(cornerRadius: 14)
            }
        }

        private func promptPreview(_ prompt: String) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Initial prompt")
                Text(prompt)
                    .font(.footnote)
                    .foregroundStyle(LitterUI.Palette.textPrimary.color)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .litterGlassRoundedRect(cornerRadius: 14)
            .accessibilityIdentifier("LitterAgentPickerSheet.initialPrompt")
        }

        private func sectionLabel(_ text: String) -> some View {
            Text(text.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(LitterUI.Palette.textMuted.color)
        }

        private func agentRow(kind: String, label: String, subtitle: String) -> some View {
            let canIssue = store.harness.canIssueCommands
            let tint = SweKittyTheme.accent(forAgent: kind)
            return Button {
                store.createSession(assistant: kind, initialPrompt: initialPrompt)
                dismiss()
            } label: {
                HStack(spacing: 14) {
                    AgentAvatar(assistant: kind, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(LitterUI.Palette.textPrimary.color)
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(LitterUI.Palette.textMuted.color)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LitterUI.Palette.textMuted.color)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .litterGlassRoundedRect(cornerRadius: 14, tint: tint.opacity(0.18))
            }
            .buttonStyle(.plain)
            .disabled(!canIssue)
            .opacity(canIssue ? 1.0 : 0.55)
        }
    }
}
