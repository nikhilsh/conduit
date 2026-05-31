package sh.nikhil.conduit.auth

import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Android mirror of the iOS Swift Testing suite for
 * `AgentLoginLoopbackServer.parseRequestLine(_:expectedPath:)`.
 *
 * Same scenario set as iOS — the two parsers MUST agree, because a
 * platform-specific drift in what counts as a "callback we accept"
 * shows up as a one-platform OAuth flow that silently times out.
 *
 * Robolectric is required because `Uri.parse` (used by the parser
 * for percent-decoding) is part of the Android framework.
 */
@RunWith(RobolectricTestRunner::class)
class AgentLoginLoopbackParserTest {

    private val path = "/auth/callback"

    @Test
    fun parses_codeFromBareQuery() {
        val res = AgentLoginLoopbackServer.parseRequestLine(
            "GET /auth/callback?code=abc HTTP/1.1",
            expectedPath = path,
        )
        assertEquals("code=abc", res?.rawQueryString)
        assertEquals("abc", res?.code)
        assertEquals("", res?.errorReason)
    }

    @Test
    fun parses_codeAndStateAndExtraParams() {
        val res = AgentLoginLoopbackServer.parseRequestLine(
            "GET /auth/callback?code=xyz&state=abc&scope=read HTTP/1.1",
            expectedPath = path,
        )
        assertEquals("code=xyz&state=abc&scope=read", res?.rawQueryString)
        assertEquals("xyz", res?.code)
    }

    @Test
    fun parses_providerError() {
        val res = AgentLoginLoopbackServer.parseRequestLine(
            "GET /auth/callback?error=access_denied HTTP/1.1",
            expectedPath = path,
        )
        assertEquals("access_denied", res?.errorReason)
        assertEquals("", res?.code)
    }

    @Test
    fun rejects_nonMatchingPath() {
        val res = AgentLoginLoopbackServer.parseRequestLine(
            "GET /something/else?code=abc HTTP/1.1",
            expectedPath = path,
        )
        assertNull(res)
    }

    @Test
    fun rejects_nonGetMethod() {
        val res = AgentLoginLoopbackServer.parseRequestLine(
            "POST /auth/callback?code=abc HTTP/1.1",
            expectedPath = path,
        )
        assertNull(res)
    }

    @Test
    fun rejects_malformedRequestLine() {
        assertNull(AgentLoginLoopbackServer.parseRequestLine("", expectedPath = path))
        assertNull(AgentLoginLoopbackServer.parseRequestLine("not an http line", expectedPath = path))
    }

    @Test
    fun handles_emptyQuery() {
        val res = AgentLoginLoopbackServer.parseRequestLine(
            "GET /auth/callback HTTP/1.1",
            expectedPath = path,
        )
        // No query → emits an empty CallbackResult; coordinator
        // upgrades this to `fail("no authorization code")`.
        assertEquals("", res?.rawQueryString)
        assertEquals("", res?.code)
        assertEquals("", res?.errorReason)
    }

    @Test
    fun handles_percentEncodedCode() {
        val res = AgentLoginLoopbackServer.parseRequestLine(
            "GET /auth/callback?code=a%2Bb%3Dc HTTP/1.1",
            expectedPath = path,
        )
        // `Uri.getQueryParameter` decodes — we get the raw bytes back.
        assertEquals("a+b=c", res?.code)
        // Raw query string preserves the encoding for round-trip
        // forwarding to the broker (where the CLI does its own decode).
        assertEquals("code=a%2Bb%3Dc", res?.rawQueryString)
    }

    @Test
    fun custom_expectedPath() {
        val res = AgentLoginLoopbackServer.parseRequestLine(
            "GET /alt/route?code=abc HTTP/1.1",
            expectedPath = "/alt/route",
        )
        assertEquals("abc", res?.code)
    }
}
