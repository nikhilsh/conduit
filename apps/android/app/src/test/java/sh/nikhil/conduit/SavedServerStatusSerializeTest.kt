package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.json.JSONArray
import org.json.JSONObject

/**
 * Verifies the [SavedServerStatus] serialisation round-trip used in
 * [SessionStore.persistSavedServers] and [SessionStore.decodeSavedServers]
 * without requiring the Android SDK (pure JVM).
 *
 * The test mirrors the encode/decode logic inline so it stays in the
 * unit-test classpath and does not depend on SessionStore internals.
 */
class SavedServerStatusSerializeTest {

    // ---- minimal codec mirroring SessionStore encode/decode ----

    private fun encode(status: SavedServerStatus?): JSONObject {
        val o = JSONObject()
        when (status) {
            is SavedServerStatus.Ready -> o.put("status", "ready")
            is SavedServerStatus.Failed -> {
                val so = JSONObject()
                so.put("state", "failed")
                so.put("reason", status.reason)
                o.put("status", so)
            }
            null -> { /* key omitted */ }
        }
        return o
    }

    private fun decode(o: JSONObject): SavedServerStatus? {
        val st = o.opt("status")
        return when {
            st == null -> null
            st is String && st == "ready" -> SavedServerStatus.Ready
            st is JSONObject -> {
                val state = st.optString("state", "")
                if (state == "failed") SavedServerStatus.Failed(st.optString("reason", ""))
                else null
            }
            else -> null
        }
    }

    @Test fun nullStatusRoundTrip() {
        assertNull(decode(encode(null)))
    }

    @Test fun readyStatusRoundTrip() {
        assertEquals(SavedServerStatus.Ready, decode(encode(SavedServerStatus.Ready)))
    }

    @Test fun failedStatusRoundTrip() {
        val original = SavedServerStatus.Failed("Couldn't reach the host: connection refused")
        val decoded = decode(encode(original)) as? SavedServerStatus.Failed
        assertEquals(original.reason, decoded?.reason)
    }

    @Test fun missingKeyDecodesNull() {
        // Old JSON without a "status" key must decode as null (backward compat).
        val o = JSONObject()
        o.put("id", "abc")
        o.put("name", "old-box")
        assertNull(decode(o))
    }

    @Test fun unknownStateDecodesNull() {
        val o = JSONObject()
        val st = JSONObject()
        st.put("state", "unknown-future-state")
        o.put("status", st)
        assertNull(decode(o))
    }
}
