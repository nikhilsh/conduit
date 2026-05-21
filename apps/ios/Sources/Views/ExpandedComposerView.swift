import SwiftUI

/// Fullscreen multi-line editor for long messages. Triggered from
/// the composer's expand button; sits over the chat behind a
/// `.fullScreenCover` so the keyboard takes the full height instead
/// of competing with the chat history.
///
/// Behaviour mirrors litter's ExpandedComposerView: top bar with
/// Cancel + Send, a single large TextEditor in the body, and a draft
/// binding that flows back to ChatTab so closing without sending
/// doesn't lose what was typed.
struct ExpandedComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Binding var draft: String
    let placeholder: String
    let accentTint: Color
    /// Triggered by the top-bar Send button. Caller is responsible
    /// for dispatching the actual sendChat + clearing the draft;
    /// this view just relays.
    let onSend: () -> Void

    @FocusState private var editorFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                SweKittyTheme.backgroundGradient(for: colorScheme).ignoresSafeArea()

                if draft.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(SweKittyTheme.textMuted)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $draft)
                    .focused($editorFocused)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            .navigationTitle("Compose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onSend()
                        dismiss()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(SweKittyTheme.textOnAccent)
                            .frame(width: 30, height: 30)
                            .background(accentTint)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send")
                }
            }
            .onAppear {
                // Defer focus so the present animation completes
                // before the keyboard slides up — without this the
                // sheet jitters on iOS 26 because the keyboard
                // animation collides with the cover transition.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    editorFocused = true
                }
            }
        }
    }
}
