package sh.nikhil.conduit

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the single allow-list rule for session display-name renames.
 * Kotlin mirror of `RenameSessionValidatorTests.swift`.
 */
class RenameSessionValidatorTest {

    // MARK: Rejected inputs

    @Test fun rejectsEmptyString() {
        assertFalse(RenameSessionValidator.isValid(""))
    }

    @Test fun rejectsWhitespaceOnly() {
        assertFalse(RenameSessionValidator.isValid("   "))
        assertFalse(RenameSessionValidator.isValid("\t\t"))
        assertFalse(RenameSessionValidator.isValid("\n \n"))
    }

    @Test fun rejectsLongerThan32() {
        val thirtyThree = "a".repeat(33)
        assertFalse(RenameSessionValidator.isValid(thirtyThree))
    }

    @Test fun rejectsForwardSlash() {
        assertFalse(RenameSessionValidator.isValid("my/session"))
    }

    @Test fun rejectsNewline() {
        assertFalse(RenameSessionValidator.isValid("foo\nbar"))
    }

    @Test fun rejectsUnicode() {
        assertFalse(RenameSessionValidator.isValid("café"))
        assertFalse(RenameSessionValidator.isValid("rocket 🚀"))
        assertFalse(RenameSessionValidator.isValid("日本語"))
    }

    @Test fun rejectsOtherPunctuation() {
        for (bad in listOf(",", ".", "(", ")", ":", ";", "?", "!", "*")) {
            assertFalse(RenameSessionValidator.isValid("name$bad"))
        }
    }

    // MARK: Accepted inputs

    @Test fun acceptsSimpleAscii() {
        assertTrue(RenameSessionValidator.isValid("project"))
        assertTrue(RenameSessionValidator.isValid("Project Alpha"))
    }

    @Test fun acceptsDigitsAndSeparators() {
        assertTrue(RenameSessionValidator.isValid("issue_123"))
        assertTrue(RenameSessionValidator.isValid("bug-fix-2026"))
        assertTrue(RenameSessionValidator.isValid("v1_0"))
    }

    @Test fun acceptsExactly32Chars() {
        val thirtyTwo = "a".repeat(32)
        assertTrue(RenameSessionValidator.isValid(thirtyTwo))
    }

    @Test fun trimsSurroundingWhitespaceBeforeChecking() {
        assertTrue(RenameSessionValidator.isValid("  hello  "))
        assertTrue(RenameSessionValidator.isValid("\thello\n"))
    }

    @Test fun helpTextIsNonEmpty() {
        assertTrue(RenameSessionValidator.HELP_TEXT.isNotEmpty())
    }
}
