package sh.nikhil.conduit.ui

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the Android terminal accessory-bar key table against the iOS
 * `TerminalAccessoryBar.keys` array (task #40). Pure JUnit — asserts on
 * the [TerminalAccessoryBarModel] data so the iOS↔Android byte parity
 * and the press-and-hold repeat set can't silently drift without a
 * Compose host.
 */
class TerminalAccessoryBarModelTest {

    @Test
    fun keyOrderAndLabelsMatchIos() {
        val labels = TerminalAccessoryBarModel.keys.map { it.label }
        assertEquals(
            listOf(
                "esc", "tab", "⌫", "↑", "↓", "←", "→",
                "home", "end", "pgup", "pgdn",
                "^C", "^D", "^Z", "^L", "^R", "^U", "^W", "^A", "^E",
                "|", "/", "\\", "~", "-",
            ),
            labels,
        )
    }

    @Test
    fun controlChordsEmitC0Bytes() {
        fun bytesFor(label: String): ByteArray =
            TerminalAccessoryBarModel.keys.first { it.label == label }.bytes

        // The four chords added in task #40 plus the original set.
        assertArrayEquals(byteArrayOf(0x03), bytesFor("^C"))
        assertArrayEquals(byteArrayOf(0x04), bytesFor("^D"))
        assertArrayEquals(byteArrayOf(0x1A), bytesFor("^Z"))
        assertArrayEquals(byteArrayOf(0x0C), bytesFor("^L"))
        assertArrayEquals(byteArrayOf(0x12), bytesFor("^R"))
        assertArrayEquals(byteArrayOf(0x15), bytesFor("^U"))
        assertArrayEquals(byteArrayOf(0x17), bytesFor("^W"))
        assertArrayEquals(byteArrayOf(0x01), bytesFor("^A"))
        assertArrayEquals(byteArrayOf(0x05), bytesFor("^E"))
    }

    @Test
    fun arrowsAndBackspaceEmitXtermSequences() {
        fun bytesFor(label: String): ByteArray =
            TerminalAccessoryBarModel.keys.first { it.label == label }.bytes

        assertArrayEquals(byteArrayOf(0x7F), bytesFor("⌫"))
        assertArrayEquals(byteArrayOf(0x1B, 0x5B, 0x41), bytesFor("↑"))
        assertArrayEquals(byteArrayOf(0x1B, 0x5B, 0x42), bytesFor("↓"))
        assertArrayEquals(byteArrayOf(0x1B, 0x5B, 0x44), bytesFor("←"))
        assertArrayEquals(byteArrayOf(0x1B, 0x5B, 0x43), bytesFor("→"))
    }

    @Test
    fun navigationKeysEmitXtermSequences() {
        fun bytesFor(label: String): ByteArray =
            TerminalAccessoryBarModel.keys.first { it.label == label }.bytes

        // Home ESC[H, End ESC[F, PgUp ESC[5~, PgDn ESC[6~ — must match iOS.
        assertArrayEquals(byteArrayOf(0x1B, 0x5B, 0x48), bytesFor("home"))
        assertArrayEquals(byteArrayOf(0x1B, 0x5B, 0x46), bytesFor("end"))
        assertArrayEquals(byteArrayOf(0x1B, 0x5B, 0x35, 0x7E), bytesFor("pgup"))
        assertArrayEquals(byteArrayOf(0x1B, 0x5B, 0x36, 0x7E), bytesFor("pgdn"))
    }

    @Test
    fun onlyBackspaceAndArrowsAutoRepeat() {
        val repeating = TerminalAccessoryBarModel.keys.filter { it.repeats }.map { it.label }.toSet()
        assertEquals(setOf("⌫", "↑", "↓", "←", "→"), repeating)
        // Control chords and symbols must not auto-repeat — a held ^C
        // should fire once, not spam SIGINT.
        assertFalse(TerminalAccessoryBarModel.keys.first { it.label == "^C" }.repeats)
        assertFalse(TerminalAccessoryBarModel.keys.first { it.label == "esc" }.repeats)
    }

    @Test
    fun repeatTimingsMatchIos() {
        // iOS: repeatInitialDelay 0.4s, repeatInterval 0.1s.
        assertEquals(400L, TerminalAccessoryBarModel.REPEAT_INITIAL_DELAY_MS)
        assertEquals(100L, TerminalAccessoryBarModel.REPEAT_INTERVAL_MS)
    }

    @Test
    fun multiGlyphLabelsAreWide() {
        val wide = TerminalAccessoryBarModel.keys.filter { it.wide }.map { it.label }.toSet()
        assertEquals(setOf("esc", "tab", "home", "end", "pgup", "pgdn"), wide)
        assertTrue(TerminalAccessoryBarModel.keys.first { it.label == "^C" }.wide.not())
    }
}
