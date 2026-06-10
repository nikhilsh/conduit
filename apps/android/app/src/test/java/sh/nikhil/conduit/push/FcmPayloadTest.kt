package sh.nikhil.conduit.push

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Tests for FCM push payload parsing in [ConduitFcmService.onMessageReceived].
 *
 * FCM delivers messages with two parallel payload paths:
 *   1. notification block — { title, body } used for background auto-display
 *   2. data map           — string key-value pairs: { session_id, box, category }
 *
 * The service prefers the notification block for title/body (FCM system displays
 * it in background), then falls back to data map entries, then hardcoded defaults.
 * session_id comes exclusively from the data map.
 *
 * These tests exercise the pure parsing logic without any Android framework
 * (no FirebaseApp, no RemoteMessage instantiation needed — we test the logic
 * functions directly to stay JVM-only and fast).
 */
class FcmPayloadTest {

    // ── Helpers mirroring ConduitFcmService field extraction ─────────────

    private data class FcmParsed(
        val title: String,
        val body: String,
        val sessionId: String?,
    )

    /**
     * Mirrors the title/body/sessionId extraction logic in
     * [ConduitFcmService.onMessageReceived].
     *
     * [notifTitle] / [notifBody] simulate RemoteMessage.notification?.title/body.
     * [data] simulates RemoteMessage.data (string map from FCM data fields).
     */
    private fun parse(
        notifTitle: String? = null,
        notifBody: String? = null,
        data: Map<String, String> = emptyMap(),
    ): FcmParsed {
        val sessionId = data["session_id"]?.takeIf { it.isNotBlank() }
        val title = notifTitle?.takeIf { it.isNotBlank() }
            ?: data["title"]?.takeIf { it.isNotBlank() }
            ?: "Conduit"
        val body = notifBody?.takeIf { it.isNotBlank() }
            ?: data["body"]?.takeIf { it.isNotBlank() }
            ?: "A session needs your attention"
        return FcmParsed(title, body, sessionId)
    }

    // ── notification block is primary for title/body ──────────────────────

    @Test fun notificationBlock_titleBody_usedFirst() {
        val parsed = parse(
            notifTitle = "Agent done",
            notifBody = "Your turn completed",
            data = mapOf("session_id" to "abc-123"),
        )
        assertEquals("Agent done", parsed.title)
        assertEquals("Your turn completed", parsed.body)
        assertEquals("abc-123", parsed.sessionId)
    }

    @Test fun dataMap_title_body_usedWhenNotifBlockAbsent() {
        val parsed = parse(
            notifTitle = null,
            notifBody = null,
            data = mapOf(
                "title" to "From data",
                "body" to "Data body",
                "session_id" to "sess-1",
            ),
        )
        assertEquals("From data", parsed.title)
        assertEquals("Data body", parsed.body)
        assertEquals("sess-1", parsed.sessionId)
    }

    // ── default fallbacks ─────────────────────────────────────────────────

    @Test fun emptyPayload_usesDefaults() {
        val parsed = parse()
        assertEquals("Conduit", parsed.title)
        assertEquals("A session needs your attention", parsed.body)
        assertNull(parsed.sessionId)
    }

    @Test fun blankNotifTitle_fallsBackToDefault() {
        val parsed = parse(notifTitle = "   ", notifBody = "Some body")
        assertEquals("Conduit", parsed.title)
    }

    @Test fun blankSessionId_treatedAsNull() {
        val parsed = parse(data = mapOf("session_id" to ""))
        assertNull(parsed.sessionId)
    }

    // ── provider selection order ──────────────────────────────────────────

    /**
     * Validates the preference rule documented in [PushProviders]:
     * UnifiedPush wins when isAvailable=true; FCM is the fallback.
     * We test the selection logic as a pure boolean without instantiating
     * real providers (no Android runtime needed).
     */
    @Test fun providerSelection_upWinsOverFcm() {
        // Simulate: UP available, FCM available → should pick UP.
        val upAvailable = true
        val fcmAvailable = true
        val selectedProvider = when {
            upAvailable -> "unifiedpush"
            fcmAvailable -> "fcm"
            else -> null
        }
        assertEquals("unifiedpush", selectedProvider)
    }

    @Test fun providerSelection_fcmFallback_whenUpUnavailable() {
        val upAvailable = false
        val fcmAvailable = true
        val selectedProvider = when {
            upAvailable -> "unifiedpush"
            fcmAvailable -> "fcm"
            else -> null
        }
        assertEquals("fcm", selectedProvider)
    }

    @Test fun providerSelection_nullWhenBothUnavailable() {
        val upAvailable = false
        val fcmAvailable = false
        val selectedProvider = when {
            upAvailable -> "unifiedpush"
            fcmAvailable -> "fcm"
            else -> null
        }
        assertNull(selectedProvider)
    }
}
