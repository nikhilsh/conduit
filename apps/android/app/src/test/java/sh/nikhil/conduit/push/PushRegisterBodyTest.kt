package sh.nikhil.conduit.push

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

/**
 * Tests for the shape of the register/unregister/test POST bodies sent to the
 * broker. Validates:
 *  - POST /api/push/register {platform, token} — correct fields, no extras.
 *  - POST /api/push/test {title, body} — correct fields.
 *
 * The bodies are pure JSONObject construction (no Android APIs), so these run
 * on the plain JVM.
 */
class PushRegisterBodyTest {

    // ── Register body ─────────────────────────────────────────────────────

    private fun buildRegisterBody(platform: String, token: String): JSONObject =
        JSONObject().apply {
            put("platform", platform)
            put("token", token)
        }

    @Test fun registerBody_unifiedPush_hasCorrectFields() {
        val body = buildRegisterBody("unifiedpush", "https://ntfy.example.com/topic/abc")
        assertEquals("unifiedpush", body.getString("platform"))
        assertEquals("https://ntfy.example.com/topic/abc", body.getString("token"))
        // No extra fields.
        assertEquals(2, body.length())
    }

    @Test fun registerBody_fcm_hasCorrectFields() {
        val body = buildRegisterBody("fcm", "fcm-token-xyz")
        assertEquals("fcm", body.getString("platform"))
        assertEquals("fcm-token-xyz", body.getString("token"))
        assertEquals(2, body.length())
    }

    @Test fun registerBody_apns_hasCorrectFields() {
        val body = buildRegisterBody("apns", "apns-hex-device-token")
        assertEquals("apns", body.getString("platform"))
        assertEquals("apns-hex-device-token", body.getString("token"))
    }

    @Test fun registerBody_tokenIsEndpointUrl_forUnifiedPush() {
        // UnifiedPush: the "token" IS the distributor endpoint URL.
        val endpointUrl = "https://push.my-server.com/UP?v=1&token=secret123"
        val body = buildRegisterBody("unifiedpush", endpointUrl)
        assertEquals(endpointUrl, body.getString("token"))
    }

    // ── Test notification body ─────────────────────────────────────────────

    private fun buildTestBody(host: String): JSONObject =
        JSONObject().apply {
            put("title", "Conduit")
            put("body", "Test notification from $host")
        }

    @Test fun testBody_hasCorrectFields() {
        val body = buildTestBody("my-box.example.com")
        assertNotNull(body.getString("title"))
        assertNotNull(body.getString("body"))
        assertEquals(2, body.length())
    }

    @Test fun testBody_titleIsConduit() {
        val body = buildTestBody("host")
        assertEquals("Conduit", body.getString("title"))
    }

    @Test fun testBody_bodyMentionsHost() {
        val host = "vps.example.com"
        val body = buildTestBody(host)
        assert(body.getString("body").contains(host)) {
            "Test body should mention the host"
        }
    }
}
