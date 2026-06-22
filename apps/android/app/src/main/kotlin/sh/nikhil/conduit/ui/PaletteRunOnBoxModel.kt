package sh.nikhil.conduit.ui

/**
 * Pure decision model for the command palette "Run on box" action.
 *
 * Encapsulates the three-way branch so the logic can be unit-tested without
 * a Compose runtime or SessionStore. Mirrors iOS ConduitHomeView's inline
 * onRunOnBox block (PR #719).
 *
 * Outcomes:
 *  - [Outcome.NoOp]       -- empty / blank text -> silently ignored.
 *  - [Outcome.SeedSession]-- non-empty text + connected box -> open agent
 *                            picker seeded with the text as the first message.
 *  - [Outcome.AddBox]     -- non-empty text + not connected -> route to
 *                            pair-a-box so the user can connect first.
 */
object PaletteRunOnBoxModel {

    sealed class Outcome {
        /** Blank input -- nothing to do. */
        object NoOp : Outcome()
        /** Show the agent picker with [prompt] pre-filled as the seed text. */
        data class SeedSession(val prompt: String) : Outcome()
        /** Not connected -- route to add-server / pair-a-box instead. */
        object AddBox : Outcome()
    }

    /**
     * Decide what to do when the user submits [text] via the palette
     * "Run on box" row.
     *
     * @param text      The raw typed string (may be blank).
     * @param connected True when the harness is Live or Linked (can issue commands).
     */
    fun decide(text: String, connected: Boolean): Outcome {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return Outcome.NoOp
        return if (connected) Outcome.SeedSession(trimmed) else Outcome.AddBox
    }
}
