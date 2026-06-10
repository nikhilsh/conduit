package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Android mirror of `apps/ios/Tests/ConduitTests/SessionStoreTests.swift`
 * StripPendingSentinelTests. The HTTP `fetchConversation` replay bypasses the
 * core classifier (which strips the pending-input sentinel on the live path),
 * so without [stripPendingSentinel] the sentinel line both shows as raw chat
 * text AND its role+content fingerprint differs from the live, stripped card —
 * leaving a duplicate card body under the real card on reattach.
 */
class StripPendingSentinelTest {

    private val sentinel = "[[conduit:needs-input]]"

    @Test fun dropsTheSentinelLine() {
        val raw = "$sentinel\nAllow codex to run this command?\n\nls -la\nin /root\n\n1. Approve\n2. Deny"
        val stripped = stripPendingSentinel(raw)
        assertFalse(stripped.contains(sentinel))
        assertTrue(stripped.startsWith("Allow codex to run this command?"))
        assertTrue(stripped.contains("1. Approve"))
        assertTrue(stripped.contains("2. Deny"))
    }

    @Test fun noSentinelIsUnchanged() {
        val raw = "just a normal assistant message\nwith two lines"
        assertEquals(raw, stripPendingSentinel(raw))
    }

    @Test fun strippedFingerprintMatchesLiveCard() {
        val liveBody = "Allow codex to run this command?\n\nls\nin /root\n\n1. Approve\n2. Deny"
        val pastRaw = "$sentinel\n$liveBody"
        assertEquals(liveBody, stripPendingSentinel(pastRaw))
    }
}
