import Testing
import Foundation
@testable import SweKitty

/// Pins the single allow-list rule for session display-name renames:
/// `^[A-Za-z0-9 _-]{1,32}$` after trimming surrounding whitespace.
///
/// Mirrors the broker-side validation shipped in PR #82 (`rename_session`)
/// so the iOS client rejects the same inputs the harness would reject —
/// the user finds out at the field, not after a round-trip.
@Suite("RenameSessionValidator — pure-data rename rule")
struct RenameSessionValidatorTests {

    // MARK: - Rejected inputs

    @Test func rejectsEmptyString() {
        #expect(!RenameSessionValidator.isValid(""))
    }

    @Test func rejectsWhitespaceOnly() {
        // Trimming runs inside `isValid` so a wall of spaces collapses
        // to empty and fails. Tabs + newlines included for safety.
        #expect(!RenameSessionValidator.isValid("   "))
        #expect(!RenameSessionValidator.isValid("\t\t"))
        #expect(!RenameSessionValidator.isValid("\n \n"))
    }

    @Test func rejectsLongerThan32() {
        // 33 chars — one over the cap. Mirrors the broker `{1,32}` bound.
        let thirtyThree = String(repeating: "a", count: 33)
        #expect(!RenameSessionValidator.isValid(thirtyThree))
    }

    @Test func rejectsForwardSlash() {
        // `/` would be interpreted as a path separator in the broker
        // log path; the allow-list excludes it on purpose.
        #expect(!RenameSessionValidator.isValid("my/session"))
    }

    @Test func rejectsNewline() {
        // A newline in the middle of the name is not the same as
        // surrounding whitespace — it can't be trimmed away, and the
        // regex doesn't match `\n`. Defends against paste-bombs from
        // the system keyboard.
        #expect(!RenameSessionValidator.isValid("foo\nbar"))
    }

    @Test func rejectsUnicode() {
        // The allow-list is ASCII-only (matches broker). Emoji and
        // non-ASCII letters fail.
        #expect(!RenameSessionValidator.isValid("café"))
        #expect(!RenameSessionValidator.isValid("rocket 🚀"))
        #expect(!RenameSessionValidator.isValid("日本語"))
    }

    @Test func rejectsOtherPunctuation() {
        // Anything outside `[A-Za-z0-9 _-]` is rejected — guard against
        // accidental allow-list creep (commas, dots, parens, etc.).
        for bad in [",", ".", "(", ")", ":", ";", "?", "!", "*"] {
            #expect(!RenameSessionValidator.isValid("name\(bad)"))
        }
    }

    // MARK: - Accepted inputs

    @Test func acceptsSimpleAscii() {
        #expect(RenameSessionValidator.isValid("project"))
        #expect(RenameSessionValidator.isValid("Project Alpha"))
    }

    @Test func acceptsDigitsAndSeparators() {
        // Underscore and hyphen are the two allowed punctuation chars.
        #expect(RenameSessionValidator.isValid("issue_123"))
        #expect(RenameSessionValidator.isValid("bug-fix-2026"))
        #expect(RenameSessionValidator.isValid("v1_0"))
    }

    @Test func acceptsExactly32Chars() {
        // Boundary: 32 is the inclusive upper bound. 33 fails (above).
        let thirtyTwo = String(repeating: "a", count: 32)
        #expect(RenameSessionValidator.isValid(thirtyTwo))
    }

    @Test func trimsSurroundingWhitespaceBeforeChecking() {
        // Leading/trailing whitespace doesn't disqualify — we trim
        // first, then validate the remainder. This matches what the
        // sheet sends to `store.renameSession`.
        #expect(RenameSessionValidator.isValid("  hello  "))
        #expect(RenameSessionValidator.isValid("\thello\n"))
    }

    @Test func helpTextIsNonEmpty() {
        // The sheet renders `helpText` as the field hint and the
        // error label — defend that it isn't accidentally cleared.
        #expect(!RenameSessionValidator.helpText.isEmpty)
    }
}
