import SwiftUI

/// Modal rename sheet — opened from the SessionInfoView name row (pencil)
/// and from a long-press on the ProjectView nav title. Replaces the prior
/// inline `.alert` rename affordance with a proper sheet so the validator
/// errors have room to render under the field.
///
/// Validation is delegated to `RenameSessionValidator.isValid(_:)` so the
/// rule lives once (pure data, unit-tested) rather than being copy-pasted
/// across the call sites. Save is disabled until the trimmed draft passes.
struct RenameSessionSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let sessionID: String
    /// Pre-filled with the current display name so the user edits rather
    /// than retypes; cleared if the caller passes an empty initial value.
    /// Uses an explicit init below because `@State` defaults capture the
    /// initial value once — passing a fresh draft on each presentation
    /// requires us to seed the underlying storage.
    @State private var draft: String

    init(sessionID: String, draft: String) {
        self.sessionID = sessionID
        self._draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SweKittyTheme.backgroundGradient(for: colorScheme)
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 16) {
                    Text("Choose a label for this session. The broker name stays the same — this rename is local to your device.")
                        .font(.footnote)
                        .foregroundStyle(SweKittyTheme.textMuted)

                    TextField("Name", text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: SweKittyTheme.smallCornerRadius, style: .continuous)
                                .fill(SweKittyTheme.surface.opacity(0.85))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: SweKittyTheme.smallCornerRadius, style: .continuous)
                                .strokeBorder(SweKittyTheme.border.opacity(0.35), lineWidth: 1)
                        )

                    if !trimmedDraft.isEmpty && !RenameSessionValidator.isValid(draft) {
                        Text(RenameSessionValidator.helpText)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text(RenameSessionValidator.helpText)
                            .font(.caption)
                            .foregroundStyle(SweKittyTheme.textMuted)
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .navigationTitle("Rename session")
            .navigationBarTitleDisplayMode(.inline)
            .tint(SweKittyTheme.accentStrong)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.renameSession(sessionID: sessionID, to: trimmedDraft)
                        dismiss()
                    }
                    .disabled(!RenameSessionValidator.isValid(draft))
                }
            }
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Pure-data validator for session display names. Single source of truth
/// for the rename rule so the sheet, future call sites, and the unit
/// tests can't drift. Mirrors the broker-side allow-list from PR #82:
/// `^[A-Za-z0-9 _-]{1,32}$` after trimming surrounding whitespace.
enum RenameSessionValidator {
    /// Human-readable hint shown beneath the field. Kept here so the
    /// help text and the regex live together.
    static let helpText = "Letters, numbers, space, underscore, hyphen. 1–32 chars."

    /// Regex pattern applied to the *trimmed* draft. Trimming happens
    /// inside `isValid(_:)` so callers don't have to remember.
    static let pattern = "^[A-Za-z0-9 _-]{1,32}$"

    /// True iff the trimmed draft matches the allow-list. Empty /
    /// whitespace-only / oversized / non-ASCII drafts all return false.
    static func isValid(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.count > 32 { return false }
        // NSRegularExpression because Swift's stdlib regex literal needs
        // iOS 16+ — the project still targets iOS 15 widgets in places,
        // so we stay on the older API for safety.
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return re.firstMatch(in: trimmed, options: [], range: range) != nil
    }
}
