package sh.nikhil.conduit

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [SessionStore.BoxFeatures] parsing from the broker
 * `/api/capabilities` response.
 *
 * Pure JSONObject construction -- no Android APIs, runs on plain JVM.
 *
 * Covers:
 *  - ntfy_url present -> ntfyUrl field populated
 *  - ntfy_url absent (older broker) -> ntfyUrl null, no regression
 *  - ntfy_url empty string -> ntfyUrl null (treated as absent)
 *  - ntfy_url blank string -> ntfyUrl null
 *  - other flags (host_metrics, shell_sessions, push) parse correctly
 *    alongside ntfy_url
 */
class BoxFeaturesParseTest {

    /**
     * Mirrors the parse logic in [SessionStore.fetchBoxFeatures] without
     * touching the network or Android APIs.
     */
    private fun parseFeatures(json: String): SessionStore.BoxFeatures? {
        return runCatching {
            val features = JSONObject(json).optJSONObject("features")
            val rawNtfyUrl = features?.optString("ntfy_url", null)
            SessionStore.BoxFeatures(
                hostMetrics = features?.optBoolean("host_metrics", false) ?: false,
                shellSessions = features?.optBoolean("shell_sessions", false) ?: false,
                push = features?.optBoolean("push", false) ?: false,
                ntfyUrl = if (rawNtfyUrl.isNullOrBlank()) null else rawNtfyUrl,
            )
        }.getOrNull()
    }

    // ── ntfy_url field ────────────────────────────────────────────────────

    @Test fun ntfyUrl_present_parsesCorrectly() {
        val json = """{"features":{"host_metrics":true,"shell_sessions":true,"push":true,"ntfy_url":"https://ntfy.example.com"}}"""
        val result = parseFeatures(json)
        assertEquals("https://ntfy.example.com", result?.ntfyUrl)
    }

    @Test fun ntfyUrl_absent_isNull() {
        // Older broker that doesn't include the key -- must not break.
        val json = """{"features":{"host_metrics":true,"shell_sessions":true,"push":true}}"""
        val result = parseFeatures(json)
        assertNull(result?.ntfyUrl)
    }

    @Test fun ntfyUrl_emptyString_isNull() {
        // Broker sends the key but with an empty value -> treat as absent.
        val json = """{"features":{"host_metrics":true,"push":true,"ntfy_url":""}}"""
        val result = parseFeatures(json)
        assertNull(result?.ntfyUrl)
    }

    @Test fun ntfyUrl_blankString_isNull() {
        // Broker sends whitespace-only -> treat as absent.
        val json = """{"features":{"push":true,"ntfy_url":"   "}}"""
        val result = parseFeatures(json)
        assertNull(result?.ntfyUrl)
    }

    // ── Other flags unaffected ─────────────────────────────────────────────

    @Test fun allFlags_parseCorrectly_withNtfyUrl() {
        val json = """{"features":{"host_metrics":true,"shell_sessions":false,"push":true,"ntfy_url":"https://push.mybox.com"}}"""
        val result = parseFeatures(json)
        assertTrue(result!!.hostMetrics)
        assertFalse(result.shellSessions)
        assertTrue(result.push)
        assertEquals("https://push.mybox.com", result.ntfyUrl)
    }

    @Test fun allFlags_parseCorrectly_withoutNtfyUrl() {
        val json = """{"features":{"host_metrics":false,"shell_sessions":true,"push":false}}"""
        val result = parseFeatures(json)
        assertFalse(result!!.hostMetrics)
        assertTrue(result.shellSessions)
        assertFalse(result.push)
        assertNull(result.ntfyUrl)
    }

    @Test fun featuresObjectMissing_returnsNonNullWithDefaults() {
        // capabilities response that has no "features" key at all.
        val json = """{"version":"1.2.3"}"""
        val result = parseFeatures(json)
        // The parse should succeed (not throw), defaulting all booleans to false.
        assertFalse(result!!.hostMetrics)
        assertFalse(result.shellSessions)
        assertFalse(result.push)
        assertNull(result.ntfyUrl)
    }

    @Test fun ntfyUrl_preservesTrailingPathAndPort() {
        val url = "https://my-vps.example.com:2586"
        val json = """{"features":{"push":true,"ntfy_url":"$url"}}"""
        val result = parseFeatures(json)
        assertEquals(url, result?.ntfyUrl)
    }
}
