package sh.nikhil.conduit.ui

import android.webkit.WebView
import io.mockk.mockk
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * First Android test suite — drives the JSON-bridge parser from PR #17.
 *
 * Why this one first (per docs/TESTING-STRATEGY.md):
 *  1. Pure-ish function (parses JSON, dispatches callbacks) — no
 *     compose-test ceremony, no Robolectric activity boot.
 *  2. The int-vs-double resize coercion is exactly the class of bug
 *     nobody catches without a test (WebView's `evaluateJavascript`
 *     can hand back numeric values typed either way depending on the
 *     android.webkit implementation).
 *  3. Codifies the contract between terminal.js and the Kotlin side,
 *     which we now ship to both iOS and Android off the same bundle.
 *
 * Runs under Robolectric only because the file imports android.webkit
 * for `WebView` — the test never actually touches the WebView, it's
 * passed as a MockK stub.
 */
@RunWith(RobolectricTestRunner::class)
class TerminalBridgeTest {

    // ---------- ready ----------

    @Test
    fun readyMessageFlipsStateAndFlushesPending() {
        val state = WebTerminalState()
        val bridge = TerminalBridge(
            state = state,
            webView = mockk(relaxed = true),
            onInput = {},
            onResize = { _, _ -> },
        )

        // Pre-condition: ready is false, pending list grows when
        // feed is called before ready.
        assertTrue(!state.ready)

        bridge.postMessage("""{"type":"ready"}""")

        // Post-condition: ready is true. Pending flush is fire-and-
        // forget but should not throw.
        assertTrue(state.ready)
    }

    // ---------- input ----------

    @Test
    fun inputMessageDeliversUtf8BytesToCallback() {
        var seen: ByteArray? = null
        val bridge = makeBridge(onInput = { seen = it })

        bridge.postMessage("""{"type":"input","data":"hello"}""")

        assertArrayEquals("hello".toByteArray(Charsets.UTF_8), seen)
    }

    @Test
    fun inputMessageHandlesMultibyteCharacters() {
        var seen: ByteArray? = null
        val bridge = makeBridge(onInput = { seen = it })

        // Han character + emoji — both multi-byte in UTF-8.
        bridge.postMessage("""{"type":"input","data":"漢🐱"}""")

        assertArrayEquals("漢🐱".toByteArray(Charsets.UTF_8), seen)
    }

    @Test
    fun inputMessageWithEmptyDataIsDropped() {
        var calls = 0
        val bridge = makeBridge(onInput = { calls++ })

        bridge.postMessage("""{"type":"input","data":""}""")

        assertEquals(0, calls)
    }

    // ---------- resize (the load-bearing one) ----------

    @Test
    fun resizeWithIntegerColsAndRows() {
        var seen: Pair<Int, Int>? = null
        val bridge = makeBridge(onResize = { rows, cols -> seen = rows to cols })

        bridge.postMessage("""{"type":"resize","cols":120,"rows":40}""")

        assertEquals(40 to 120, seen)
    }

    @Test
    fun resizeWithDoubleColsAndRowsCoercesToInt() {
        // xterm.js's fit addon sometimes posts integers as JS numbers
        // that serialize as JSON doubles (`120.0`). org.json's
        // JSONObject.optInt floors them, so the bridge must still
        // produce a clean (rows, cols) pair.
        var seen: Pair<Int, Int>? = null
        val bridge = makeBridge(onResize = { rows, cols -> seen = rows to cols })

        bridge.postMessage("""{"type":"resize","cols":120.0,"rows":40.0}""")

        assertEquals(40 to 120, seen)
    }

    @Test
    fun resizeWithMissingFieldsDoesNotCall() {
        var calls = 0
        val bridge = makeBridge(onResize = { _, _ -> calls++ })

        bridge.postMessage("""{"type":"resize"}""")
        bridge.postMessage("""{"type":"resize","cols":120}""")

        assertEquals(0, calls)
    }

    @Test
    fun resizeWithNonPositiveDimensionsIsRejected() {
        var calls = 0
        val bridge = makeBridge(onResize = { _, _ -> calls++ })

        bridge.postMessage("""{"type":"resize","cols":0,"rows":0}""")
        bridge.postMessage("""{"type":"resize","cols":-10,"rows":40}""")

        assertEquals(0, calls)
    }

    // ---------- malformed input ----------

    @Test
    fun malformedJsonIsSwallowedSilently() {
        // The bridge must not crash the WebView interface on bad
        // input — JS could in theory post anything. Survival = pass.
        val bridge = makeBridge()
        bridge.postMessage("not json")
        bridge.postMessage("{}")
        bridge.postMessage("""{"type":"unknown"}""")
        // No assertion needed — the test passes if no exception is thrown.
    }

    // ---------- helpers ----------

    private fun makeBridge(
        onInput: (ByteArray) -> Unit = {},
        onResize: (Int, Int) -> Unit = { _, _ -> },
    ): TerminalBridge = TerminalBridge(
        state = WebTerminalState(),
        webView = mockk<WebView>(relaxed = true),
        onInput = onInput,
        onResize = onResize,
    )
}
