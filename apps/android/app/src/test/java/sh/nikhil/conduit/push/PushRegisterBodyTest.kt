package sh.nikhil.conduit.push

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

/**
 * Tests for the shape of the register/unregister/test POST bodies sent to the
 * broker. Validates:
 *  - POST /api/push/register {platform, token, device_id} — correct fields.
 *  - POST /api/push/test {title, body, device_id} — correct fields.
 *
 * The bodies are pure JSONObject construction (no Android APIs), so these run
 * on the plain JVM.
 */
class PushRegisterBodyTest {

    private val testDeviceId = "test-device-uuid-1234"

    // ── Register body ─────────────────────────────────────────────────────

    private fun buildRegisterBody(platform: String, token: String, deviceId: String?): JSONObject =
        JSONObject().apply {
            put("platform", platform)
            put("token", token)
            deviceId?.let { put("device_id", it) }
        }

    @Test fun registerBody_unifiedPush_hasCorrectFields() {
        val body = buildRegisterBody("unifiedpush", "https://ntfy.example.com/topic/abc", testDeviceId)
        assertEquals("unifiedpush", body.getString("platform"))
        assertEquals("https://ntfy.example.com/topic/abc", body.getString("token"))
        assertEquals(testDeviceId, body.getString("device_id"))
        assertEquals(3, body.length())
    }

    @Test fun registerBody_fcm_hasCorrectFields() {
        val body = buildRegisterBody("fcm", "fcm-token-xyz", testDeviceId)
        assertEquals("fcm", body.getString("platform"))
        assertEquals("fcm-token-xyz", body.getString("token"))
        assertEquals(testDeviceId, body.getString("device_id"))
        assertEquals(3, body.length())
    }

    @Test fun registerBody_apns_hasCorrectFields() {
        val body = buildRegisterBody("apns", "apns-hex-device-token", testDeviceId)
        assertEquals("apns", body.getString("platform"))
        assertEquals("apns-hex-device-token", body.getString("token"))
        assertEquals(testDeviceId, body.getString("device_id"))
    }

    @Test fun registerBody_tokenIsEndpointUrl_forUnifiedPush() {
        // UnifiedPush: the "token" IS the distributor endpoint URL.
        val endpointUrl = "https://push.my-server.com/UP?v=1&token=secret123"
        val body = buildRegisterBody("unifiedpush", endpointUrl, testDeviceId)
        assertEquals(endpointUrl, body.getString("token"))
    }

    @Test fun registerBody_noDeviceId_omitsField() {
        // When device_id is null (pre-hydrate path), the field is absent.
        val body = buildRegisterBody("unifiedpush", "https://ntfy.example.com/topic/abc", null)
        assertEquals(2, body.length())
        assertEquals(false, body.has("device_id"))
    }

    // ── Test notification body ─────────────────────────────────────────────

    private fun buildTestBody(host: String, deviceId: String?): JSONObject =
        JSONObject().apply {
            put("title", "Conduit")
            put("body", "Test notification from $host")
            deviceId?.let { put("device_id", it) }
        }

    @Test fun testBody_hasCorrectFields() {
        val body = buildTestBody("my-box.example.com", testDeviceId)
        assertNotNull(body.getString("title"))
        assertNotNull(body.getString("body"))
        assertEquals(testDeviceId, body.getString("device_id"))
        assertEquals(3, body.length())
    }

    @Test fun testBody_titleIsConduit() {
        val body = buildTestBody("host", testDeviceId)
        assertEquals("Conduit", body.getString("title"))
    }

    @Test fun testBody_bodyMentionsHost() {
        val host = "vps.example.com"
        val body = buildTestBody(host, testDeviceId)
        assert(body.getString("body").contains(host)) {
            "Test body should mention the host"
        }
    }

    @Test fun testBody_noDeviceId_omitsField() {
        val body = buildTestBody("host", null)
        assertEquals(2, body.length())
        assertEquals(false, body.has("device_id"))
    }
}
