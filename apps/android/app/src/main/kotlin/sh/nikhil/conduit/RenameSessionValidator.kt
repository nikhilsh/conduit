package sh.nikhil.conduit

/**
 * Pure-data validator for session display-name renames. Kotlin mirror of
 * `apps/ios/Sources/Shared/RenameSessionValidator.swift` so both platforms
 * enforce the same allow-list: `^[A-Za-z0-9 _-]{1,32}$` after trimming
 * surrounding whitespace. Mirrors the broker-side rule from PR #82
 * (`rename_session`) so the client rejects the same inputs the harness
 * would reject -- the user finds out at the field, not after a round-trip.
 */
object RenameSessionValidator {
    /** Human-readable hint shown beneath the field. */
    const val HELP_TEXT = "Letters, numbers, space, underscore, hyphen. 1-32 chars."

    /** Regex applied to the *trimmed* draft. */
    private val PATTERN = Regex("^[A-Za-z0-9 _-]{1,32}$")

    /** True iff the trimmed draft matches the allow-list. */
    fun isValid(raw: String): Boolean {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return false
        if (trimmed.length > 32) return false
        return PATTERN.matches(trimmed)
    }
}
