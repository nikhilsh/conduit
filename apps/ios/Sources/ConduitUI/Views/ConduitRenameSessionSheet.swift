import SwiftUI

// MARK: - ConduitRenameSessionSheet
//
// Native ConduitUI rename-session sheet. Replaces the legacy
// `RenameSessionSheet`. Validation is delegated to
// `RenameSessionValidator.isValid(_:)` (extracted to `Shared/` so the
// rule lives once across both trees + tests).
//
// Recomposed onto the neon-theme idiom shared by the other redesigned
// sheets (SessionInfoView, AgentLoginSheet, FoundSessionsSheet):
//   - GlassAppBackground canvas, not a flat Palette.surface fill.
//   - A trailing close "X" replaces the old Cancel/Save toolbar text
//     buttons -- Cancel is "just dismiss", Save lives as the pill CTA.
//   - A neon card surface around the field, small-caps section label.
//   - A pill-style primary Save CTA pinned to the bottom via
//     safeAreaInset (mirrors AgentLoginSheet's bottom "Done" bar).

extension ConduitUI {
    struct RenameSessionSheet: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        let session: ProjectSession

        @State private var draft: String
        @FocusState private var fieldFocused: Bool

        init(session: ProjectSession, initialDraft: String) {
            self.session = session
            self._draft = State(initialValue: initialDraft)
        }

        var body: some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Choose a label for this session. The broker name stays the same \u{2014} this rename is local to your device.")
                            .font(neon.sans(12.5))
                            .foregroundStyle(neon.textFaint)

                        nameCard

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                }
                .navigationTitle("Rename session")
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
                        .accessibilityLabel("Close")
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    saveBar
                }
            }
            .neonAccentTint()
            .appearanceColorScheme()
            .onAppear { fieldFocused = true }
        }

        private var nameCard: some View {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Name")
                TextField("Name", text: $draft)
                    .font(neon.sans(15))
                    .foregroundStyle(neon.text)
                    .tint(neon.accent)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .focused($fieldFocused)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(neon.surface2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(showsError ? neon.red.opacity(0.6) : neon.borderStrong, lineWidth: 1)
                            )
                    )
                Text(RenameSessionValidator.helpText)
                    .font(neon.mono(11))
                    .foregroundStyle(showsError ? neon.red : neon.textFaint)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
        }

        private var saveBar: some View {
            VStack(spacing: 0) {
                Rectangle().fill(neon.border).frame(height: 1)
                ConduitUI.ActionButton("Save", variant: .primary) {
                    save()
                }
                .disabled(!isValid)
                .opacity(isValid ? 1 : 0.45)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .background(neon.bg.ignoresSafeArea(edges: .bottom))
        }

        private var trimmedDraft: String {
            draft.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private var isValid: Bool {
            RenameSessionValidator.isValid(draft)
        }

        private var showsError: Bool {
            !trimmedDraft.isEmpty && !isValid
        }

        private func save() {
            guard isValid else { return }
            Telemetry.breadcrumb("session", "rename saved", data: ["session_id": session.id])
            store.renameSession(sessionID: session.id, to: trimmedDraft)
            dismiss()
        }

        private func sectionLabel(_ text: String) -> some View {
            Text(text.uppercased())
                .font(neon.mono(11).weight(.bold))
                .tracking(0.6)
                .foregroundStyle(neon.textFaint)
        }
    }
}
