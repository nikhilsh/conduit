package sh.nikhil.conduit.push

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Unit tests for push-notification payload parsing logic.
 *
 * Mirrors the parsing done in [ConduitUnifiedPushReceiver.onMessage].
 * Tests run on the plain JVM (no Android framework needed — org.json is
 * available via `testImplementation("org.json:json:…")` in build.gradle.kts).
 */
class PushPayloadTest {

    // ── Payload parsing helpers ───────────────────────────────────────────

    /** Parses a raw UP message byte array into the three fields the receiver uses. */
    private data class ParsedPayload(
        val title: String,
        val body: String,
        val sessionId: String?,
    )

    private fun parsePayload(raw: String): ParsedPayload {
        val json = JSONObject(raw)
        val title = json.optString("title", "Conduit")
            .takeIf { it.isNotBlank() } ?: "Conduit"
        val body = json.optString("body", "A session needs your attention")
            .takeIf { it.isNotBlank() } ?: "A session needs your attention"
        val sessionId = json.optString("session_id", "").takeIf { it.isNotBlank() }
        return ParsedPayload(title, body, sessionId)
    }

    // ── Tests ─────────────────────────────────────────────────────────────

    @Test fun fullPayload_allFieldsParsed() {
        val raw = JSONObject().apply {
            put("title", "Conduit")
            put("body", "Turn complete")
            put("session_id", "abc-123")
        }.toString()
        val parsed = parsePayload(raw)
        assertEquals("Conduit", parsed.title)
        assertEquals("Turn complete", parsed.body)
        assertEquals("abc-123", parsed.sessionId)
    }

    @Test fun contentFreePayload_onlySessionId_usesDefaults() {
        // The broker sends content-free payloads in privacy mode (default).
        val raw = JSONObject().apply {
            put("session_id", "sess-456")
        }.toString()
        val parsed = parsePayload(raw)
        assertEquals("Conduit", parsed.title)
        assertEquals("A session needs your attention", parsed.body)
        assertEquals("sess-456", parsed.sessionId)
    }

    @Test fun emptyPayload_returnsDefaults() {
        val raw = "{}"
        val parsed = parsePayload(raw)
        assertEquals("Conduit", parsed.title)
        assertEquals("A session needs your attention", parsed.body)
        assertNull(parsed.sessionId)
    }

    @Test fun blankTitle_fallsBackToDefault() {
        val raw = JSONObject().apply {
            put("title", "   ")
            put("body", "something happened")
            put("session_id", "x")
        }.toString()
        val parsed = parsePayload(raw)
        assertEquals("Conduit", parsed.title)
    }

    @Test fun blankSessionId_treatedAsNull() {
        val raw = JSONObject().apply {
            put("session_id", "")
        }.toString()
        val parsed = parsePayload(raw)
        assertNull(parsed.sessionId)
    }

    @Test fun sessionIdWithSpecialChars_preserved() {
        val id = "session/with-dashes_and.dots"
        val raw = JSONObject().apply { put("session_id", id) }.toString()
        assertEquals(id, parsePayload(raw).sessionId)
    }
}
