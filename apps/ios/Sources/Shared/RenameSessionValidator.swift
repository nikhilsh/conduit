import Foundation

/// Pure-data validator for session display names. Single source of truth
/// for the rename rule so the sheet, future call sites, and the unit
/// tests can't drift. Mirrors the broker-side allow-list from PR #82:
/// `^[A-Za-z0-9 _-]{1,32}$` after trimming surrounding whitespace.
///
/// Extracted out of the legacy `RenameSessionSheet.swift` so the
/// `LitterRenameSessionSheet` can call into the same rule. Behaviour
/// pinned by `RenameSessionValidatorTests`.
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
