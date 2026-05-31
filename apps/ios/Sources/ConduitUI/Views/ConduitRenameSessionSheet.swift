import SwiftUI

// MARK: - ConduitRenameSessionSheet
//
// Native ConduitUI rename-session sheet. Replaces the legacy
// `RenameSessionSheet`. Validation is delegated to
// `RenameSessionValidator.isValid(_:)` (extracted to `Shared/` so the
// rule lives once across both trees + tests).
//
// Visual style:
//   - small-caps section label
//   - .ultraThinMaterial card around the text field
//   - footnote-sized hint, danger color when invalid

extension ConduitUI {
    struct RenameSessionSheet: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.dismiss) private var dismiss

        let session: ProjectSession

        @State private var draft: String

        init(session: ProjectSession, initialDraft: String) {
            self.session = session
            self._draft = State(initialValue: initialDraft)
        }

        var body: some View {
            NavigationStack {
                ZStack {
                    ConduitUI.Palette.surface.color.ignoresSafeArea()
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Choose a label for this session. The broker name stays the same — this rename is local to your device.")
                            .font(.caption2)
                            .foregroundStyle(ConduitUI.Palette.textMuted.color)

                        sectionLabel("Name")
                        TextField("Name", text: $draft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .conduitGlassRoundedRect(cornerRadius: 14)

                        Text(RenameSessionValidator.helpText)
                            .font(.caption2)
                            .foregroundStyle(hintColor)

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .navigationTitle("Rename session")
                .navigationBarTitleDisplayMode(.inline)
                .neonAccentTint()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            store.renameSession(sessionID: session.id, to: trimmedDraft)
                            dismiss()
                        }
                        .disabled(!RenameSessionValidator.isValid(draft))
                    }
                }
            }
            .appearanceColorScheme()
        }

        private var trimmedDraft: String {
            draft.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private var hintColor: Color {
            if !trimmedDraft.isEmpty && !RenameSessionValidator.isValid(draft) {
                return ConduitUI.Palette.danger.color
            }
            return ConduitUI.Palette.textMuted.color
        }

        private func sectionLabel(_ text: String) -> some View {
            Text(text.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(ConduitUI.Palette.textMuted.color)
        }
    }
}
