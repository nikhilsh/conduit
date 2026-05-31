package sh.nikhil.conduit.ui

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.conduit_core.ProjectSession

/**
 * Pure-data plumbing test for [TermuxSessionConfig.from] + the
 * Stage 2 byte-feed reducer ([computeFeed]). Locks the Stage 2
 * defaults that the Compose factory feeds into
 * `com.termux.terminal.TerminalSession`'s JNI subprocess call. We
 * can't exercise the actual `TerminalView` mount from a JVM unit
 * test — Termux's emulator calls into native code via JNI which
 * Robolectric doesn't fake — so this is the bulk of what's testable
 * below the instrumentation boundary.
 *
 * If a future stage changes the shell path or the env list, this
 * test fails and the new contract gets re-codified here; that is
 * the point.
 */
class TermuxSessionConfigTest {

    private fun fakeSession(id: String = "s-1"): ProjectSession =
        ProjectSession(
            id = id,
            name = "fake",
            assistant = "claude",
            branch = null,
            preview = null,
            reasoningEffort = null,
            cwd = null,
            startedAt = null,
            lastActivityAt = null,
            displayName = null,
        )

    @Test
    fun `default shell path is the always-available system sleep`() {
        val cfg = TermuxSessionConfig.from(fakeSession())
        // Stage 2 switched from /system/bin/sh to /system/bin/sleep
        // so the local PTY stays silent — the broker is the source
        // of truth for terminal output. Both binaries exist on
        // every Android API since 1; sleep just doesn't produce a
        // shell prompt that would race the broker bytes.
        assertEquals("/system/bin/sleep", cfg.shellPath)
        assertEquals("/", cfg.cwd)
    }

    @Test
    fun `argv carries sleep with a 32-bit-max-seconds timeout`() {
        val cfg = TermuxSessionConfig.from(fakeSession())
        // 2147483647 (INT_MAX seconds, ~68 years) — long enough that
        // the local subprocess never wakes up during a session, but
        // small enough to fit in the busybox/toybox sleep arg parser.
        assertArrayEquals(
            arrayOf("/system/bin/sleep", "2147483647"),
            cfg.args,
        )
    }

    @Test
    fun `env carries TERM=xterm-256color for the emulator handshake`() {
        val cfg = TermuxSessionConfig.from(fakeSession())
        // Termux's TerminalEmulator dispatches a different code path
        // for xterm-256color than for vt100; pinning this matches
        // what the broker side assumes on the WebTerminal path.
        assertTrue(
            "env should include TERM=xterm-256color, got=${cfg.env.toList()}",
            cfg.env.any { it == "TERM=xterm-256color" },
        )
    }

    @Test
    fun `from is pure - session id does not affect the config`() {
        // The local subprocess is just a JNI backstop; the broker
        // session id lives in the [TermuxTerminalView] closure, not
        // in the config. Two distinct sessions yield identical
        // configs — proves no accidental leakage.
        val a = TermuxSessionConfig.from(fakeSession("session-a"))
        val b = TermuxSessionConfig.from(fakeSession("session-b"))
        assertEquals(a, b)
    }

    @Test
    fun `equals tells apart different shell paths`() {
        // Sanity check on the hand-rolled equals/hashCode (we override
        // them because `data class` with array fields falls back to
        // reference equality on those arrays — explicitly not what we
        // want for assertions in this file).
        val a = TermuxSessionConfig.from(fakeSession())
        val b = a.copy(shellPath = "/system/bin/bogus")
        assertNotEquals(a, b)
    }

    // --- Stage 2: byte-feed reducer ---------------------------------

    @Test
    fun `computeFeed - growing buffer ships only the delta`() {
        val buf = byteArrayOf(0x68, 0x65, 0x6C, 0x6C, 0x6F) // "hello"
        val decision = computeFeed(buf, lastFedByteCount = 3)
        assertFalse("no reset on grow", decision.reset)
        // Only the tail bytes (positions 3..5) are forwarded.
        assertArrayEquals(byteArrayOf(0x6C, 0x6F), decision.bytes)
        assertEquals(5, decision.newCursor)
    }

    @Test
    fun `computeFeed - equal buffer is a no-op`() {
        val buf = byteArrayOf(1, 2, 3)
        val decision = computeFeed(buf, lastFedByteCount = 3)
        assertFalse(decision.reset)
        assertEquals(0, decision.bytes.size)
        assertEquals(3, decision.newCursor)
    }

    @Test
    fun `computeFeed - shrunk buffer signals snapshot replay`() {
        // Snapshot replace: the broker pushed a fresh
        // gunzipped snapshot that's smaller than what we'd already
        // fed. Mirror WebTerminal's `resetAndFeed` shape — reset the
        // emulator and replay the whole buffer.
        val buf = byteArrayOf(1, 2)
        val decision = computeFeed(buf, lastFedByteCount = 5)
        assertTrue("reset on shrink", decision.reset)
        assertArrayEquals(byteArrayOf(1, 2), decision.bytes)
        assertEquals(2, decision.newCursor)
    }

    @Test
    fun `computeFeed - empty initial buffer is a no-op`() {
        // First mount before any broker bytes have arrived. Cursor
        // stays at 0 so the first real chunk is still seen as a
        // grow, not a reset.
        val decision = computeFeed(ByteArray(0), lastFedByteCount = 0)
        assertFalse(decision.reset)
        assertEquals(0, decision.bytes.size)
        assertEquals(0, decision.newCursor)
    }
}
