package sh.nikhil.swekitty.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.swe_kitty_core.ProjectSession

/**
 * Pure-data plumbing test for [TermuxSessionConfig.from]. Locks the
 * Stage 1 defaults that the Compose factory feeds into
 * `com.termux.terminal.TerminalSession`'s JNI subprocess call. We
 * can't exercise the actual `TerminalView` mount from a JVM unit test
 * — Termux's emulator calls into native code via JNI which Robolectric
 * doesn't fake — so this is the bulk of what's testable below the
 * instrumentation boundary.
 *
 * If Stage 2 changes the shell path or the env list, this test fails
 * and the new contract gets re-codified here; that is the point.
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
    fun `default shell path is the always-available system sh`() {
        val cfg = TermuxSessionConfig.from(fakeSession())
        // `/system/bin/sh` exists on every Android API since 1; this
        // is the Stage 1 mount-only default and must not regress to a
        // path that requires the Termux app to be installed.
        assertEquals("/system/bin/sh", cfg.shellPath)
        assertEquals("/", cfg.cwd)
    }

    @Test
    fun `env carries TERM=xterm-256color for the emulator handshake`() {
        val cfg = TermuxSessionConfig.from(fakeSession())
        // Termux's TerminalEmulator dispatches a different code path
        // for xterm-256color than for vt100; pinning this keeps the
        // Stage 1 banner ANSI-safe and matches what the broker side
        // assumes on the WebTerminal path.
        assertTrue(
            "env should include TERM=xterm-256color, got=${cfg.env.toList()}",
            cfg.env.any { it == "TERM=xterm-256color" },
        )
    }

    @Test
    fun `argv first element matches the shell path`() {
        val cfg = TermuxSessionConfig.from(fakeSession())
        // POSIX convention: argv[0] is the program name. Termux's JNI
        // createSubprocess uses argv as-is, so the shell needs to see
        // its own path or it'll log "argv[0]=null" on some devices.
        assertEquals(cfg.shellPath, cfg.args.firstOrNull())
    }

    @Test
    fun `from is pure - session id does not affect the config`() {
        // Stage 1 disconnects the Termux session from broker bytes.
        // Stage 2 will start routing through session.id; the test
        // that locks that wiring lives in the broker-bridge layer,
        // not here. For now, two distinct sessions yield identical
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
}
