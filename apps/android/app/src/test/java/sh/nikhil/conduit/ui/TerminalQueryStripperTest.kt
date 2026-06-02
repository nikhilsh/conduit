package sh.nikhil.conduit.ui

import org.junit.Assert.assertArrayEquals
import org.junit.Test

/**
 * Pins [TerminalQueryStripper]: the agent's DA/DSR/OSC-colour *query*
 * sequences must be dropped before they reach Termux's emulator (else it
 * auto-answers them and the local-PTY echo loops the replies back as
 * garbage — `^[[?64;…c`, `^[]10;rgb:…`), while every other byte (SGR,
 * cursor moves, OSC titles/colour-sets, text) passes through untouched.
 * Sequences split across feed deltas must still be caught.
 */
class TerminalQueryStripperTest {

    private val esc = "\u001b"
    private val bel = "\u0007"
    private val st = "\u001b\\" // ESC \
    private fun b(s: String) = s.toByteArray(Charsets.US_ASCII)
    private fun strip(s: String) = TerminalQueryStripper().strip(b(s))

    // ── queries that get dropped ──

    @Test fun dropsDa1() = assertArrayEquals(b(""), strip("$esc[c"))
    @Test fun dropsDa1WithZero() = assertArrayEquals(b(""), strip("$esc[0c"))
    @Test fun dropsDa2() = assertArrayEquals(b(""), strip("$esc[>c"))
    @Test fun dropsDa2WithZero() = assertArrayEquals(b(""), strip("$esc[>0c"))
    @Test fun dropsXtversion() = assertArrayEquals(b(""), strip("$esc[>q"))
    @Test fun dropsDsr5() = assertArrayEquals(b(""), strip("$esc[5n"))
    @Test fun dropsDsr6() = assertArrayEquals(b(""), strip("$esc[6n"))
    @Test fun dropsOsc10QueryBel() = assertArrayEquals(b(""), strip("$esc]10;?$bel"))
    @Test fun dropsOsc11QuerySt() = assertArrayEquals(b(""), strip("$esc]11;?$st"))
    @Test fun dropsOsc12Query() = assertArrayEquals(b(""), strip("$esc]12;?$bel"))

    @Test fun dropsTheExactBugReportQueries() {
        // The four queries whose auto-answers produced the on-screen garbage.
        assertArrayEquals(b(""), strip("$esc[c$esc[>c$esc]10;?$bel$esc]11;?$st"))
    }

    // ── everything else passes through byte-for-byte ──

    @Test fun keepsSgr() = assertArrayEquals(b("$esc[31mhi$esc[0m"), strip("$esc[31mhi$esc[0m"))
    @Test fun keepsCursorMoves() = assertArrayEquals(b("$esc[2J$esc[H"), strip("$esc[2J$esc[H"))
    @Test fun keepsOscTitle() = assertArrayEquals(b("$esc]0;my title$bel"), strip("$esc]0;my title$bel"))
    @Test fun keepsOscColorSet() =
        assertArrayEquals(b("$esc]11;rgb:0000/0000/0000$st"), strip("$esc]11;rgb:0000/0000/0000$st"))
    @Test fun keepsDsrResponseForm() = assertArrayEquals(b("$esc[0n"), strip("$esc[0n")) // 0n is a reply, not a query
    @Test fun keepsPlainText() = assertArrayEquals(b("hello world\r\n"), strip("hello world\r\n"))

    @Test fun stripsQueryFromSurroundingText() =
        assertArrayEquals(b("helloworld"), strip("hello$esc[cworld"))

    // ── split across feed deltas (carry state) ──

    @Test fun dropsQuerySplitAcrossDeltas() {
        val s = TerminalQueryStripper()
        assertArrayEquals(b(""), s.strip(b("$esc[")))   // held in carry
        assertArrayEquals(b(""), s.strip(b("c")))        // completed → dropped
    }

    @Test fun keepsSgrSplitAcrossDeltas() {
        val s = TerminalQueryStripper()
        assertArrayEquals(b(""), s.strip(b("$esc[3")))      // held
        assertArrayEquals(b("$esc[31mhi"), s.strip(b("1mhi"))) // completes as SGR → emitted
    }

    @Test fun loneTrailingEscIsCarried() {
        val s = TerminalQueryStripper()
        assertArrayEquals(b(""), s.strip(b(esc)))    // lone ESC held
        assertArrayEquals(b(""), s.strip(b("[c")))    // completes the DA1 → dropped
    }

    @Test fun resetClearsCarry() {
        val s = TerminalQueryStripper()
        assertArrayEquals(b(""), s.strip(b("$esc[")))  // held
        s.reset()
        assertArrayEquals(b("X"), s.strip(b("X")))       // stale carry forgotten
    }
}
