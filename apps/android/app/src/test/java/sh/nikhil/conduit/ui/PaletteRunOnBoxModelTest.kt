package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [PaletteRunOnBoxModel] -- pure JVM, no Compose runtime needed.
 *
 * Covers:
 *  - empty/blank text -> NoOp (never starts a session)
 *  - non-empty text + connected -> SeedSession with trimmed prompt
 *  - non-empty text + disconnected -> AddBox
 *  - whitespace-only input -> NoOp
 *  - leading/trailing whitespace is trimmed in SeedSession.prompt
 */
class PaletteRunOnBoxModelTest {

    @Test
    fun emptyText_connected_isNoOp() {
        val result = PaletteRunOnBoxModel.decide("", connected = true)
        assertTrue(result is PaletteRunOnBoxModel.Outcome.NoOp)
    }

    @Test
    fun emptyText_disconnected_isNoOp() {
        val result = PaletteRunOnBoxModel.decide("", connected = false)
        assertTrue(result is PaletteRunOnBoxModel.Outcome.NoOp)
    }

    @Test
    fun whitespaceOnly_connected_isNoOp() {
        val result = PaletteRunOnBoxModel.decide("   ", connected = true)
        assertTrue(result is PaletteRunOnBoxModel.Outcome.NoOp)
    }

    @Test
    fun whitespaceOnly_disconnected_isNoOp() {
        val result = PaletteRunOnBoxModel.decide("\t\n", connected = false)
        assertTrue(result is PaletteRunOnBoxModel.Outcome.NoOp)
    }

    @Test
    fun nonEmptyText_connected_isSeedSession() {
        val result = PaletteRunOnBoxModel.decide("refactor the auth module", connected = true)
        assertTrue(result is PaletteRunOnBoxModel.Outcome.SeedSession)
        assertEquals("refactor the auth module", (result as PaletteRunOnBoxModel.Outcome.SeedSession).prompt)
    }

    @Test
    fun nonEmptyText_connected_promptIsTrimmed() {
        val result = PaletteRunOnBoxModel.decide("  fix the bug  ", connected = true)
        assertTrue(result is PaletteRunOnBoxModel.Outcome.SeedSession)
        assertEquals("fix the bug", (result as PaletteRunOnBoxModel.Outcome.SeedSession).prompt)
    }

    @Test
    fun nonEmptyText_disconnected_isAddBox() {
        val result = PaletteRunOnBoxModel.decide("run tests", connected = false)
        assertTrue(result is PaletteRunOnBoxModel.Outcome.AddBox)
    }

    @Test
    fun singleChar_connected_isSeedSession() {
        val result = PaletteRunOnBoxModel.decide("x", connected = true)
        assertTrue(result is PaletteRunOnBoxModel.Outcome.SeedSession)
        assertEquals("x", (result as PaletteRunOnBoxModel.Outcome.SeedSession).prompt)
    }
}
