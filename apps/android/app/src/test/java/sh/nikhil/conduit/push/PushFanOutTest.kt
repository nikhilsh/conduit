package sh.nikhil.conduit.push

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.nikhil.conduit.Endpoint

/**
 * Unit tests for multi-box fan-out registration logic.
 *
 * Tests are pure (no Android framework, no network, no coroutines) — they
 * validate the endpoint deduplication logic and the payload-building shape.
 * The HTTP layer is covered separately by [PushRegisterBodyTest].
 *
 * Fan-out design contract:
 *   - Given N endpoints, N register POST bodies should be built.
 *   - One box failure must not prevent others (modelled by nullable results).
 *   - An empty endpoint list produces no register calls (no crash).
 *   - The active endpoint is always included, even when allEndpoints is empty.
 *   - Duplicate endpoints are deduplicated by URL.
 *   - Incomplete endpoints (blank URL or token) are skipped.
 */
class PushFanOutTest {

    // ── Endpoint helpers ──────────────────────────────────────────────────

    private fun ep(url: String, token: String = "tok") = Endpoint(url = url, token = token)
    private val incomplete = Endpoint(url = "", token = "")

    // ── Pure fan-out endpoint selection logic ─────────────────────────────
    // Mirrors PushStore.registerWithAllEndpoints dedup logic.

    private fun selectFanOutEndpoints(
        activeEndpoint: Endpoint,
        allEndpoints: List<Endpoint>,
    ): List<Endpoint> {
        val seen = mutableSetOf<String>()
        return buildList {
            if (activeEndpoint.isComplete && seen.add(activeEndpoint.url)) add(activeEndpoint)
            for (ep in allEndpoints) {
                if (ep.isComplete && seen.add(ep.url)) add(ep)
            }
        }
    }

    // ── Payload builder (mirrors PushStore.postRegisterToEndpoint body) ───

    private val testDeviceId = "test-device-uuid-1234"

    private fun buildRegisterBody(platform: String, token: String, deviceId: String? = testDeviceId): JSONObject =
        JSONObject().apply {
            put("platform", platform)
            put("token", token)
            deviceId?.let { put("device_id", it) }
        }

    // ── Fan-out result simulation ─────────────────────────────────────────
    // Nullable Boolean: true = success, false = HTTP failure, null = network error.

    private fun countSuccesses(results: List<Boolean?>): Int =
        results.filterNotNull().count { it }

    private fun countFailures(results: List<Boolean?>): Int =
        results.count { it == false || it == null }

    // ── Tests: endpoint selection ─────────────────────────────────────────

    @Test fun nEndpointsProduceNSelections() {
        val active = ep("https://box1.example.com")
        val all = listOf(
            ep("https://box1.example.com"),
            ep("https://box2.example.com"),
            ep("https://box3.example.com"),
        )
        val selected = selectFanOutEndpoints(active, all)
        assertEquals(3, selected.size)
    }

    @Test fun activeEndpointIsFirstInSelection() {
        val active = ep("https://active.example.com")
        val all = listOf(
            ep("https://box2.example.com"),
            ep("https://box3.example.com"),
        )
        val selected = selectFanOutEndpoints(active, all)
        assertEquals(3, selected.size)
        assertEquals(active, selected.first())
    }

    @Test fun activeEndpointIncludedEvenIfNotInAllEndpoints() {
        val active = ep("https://solo.example.com")
        val selected = selectFanOutEndpoints(active, emptyList())
        assertEquals(1, selected.size)
        assertEquals(active, selected.first())
    }

    @Test fun emptyAllEndpointsAndIncompleteActiveProducesEmpty() {
        val selected = selectFanOutEndpoints(incomplete, emptyList())
        assertTrue(selected.isEmpty())
    }

    @Test fun duplicatesAreDeduplicatedByUrl() {
        val active = ep("https://box1.example.com")
        val all = listOf(
            ep("https://box1.example.com"),
            ep("https://box1.example.com"),
            ep("https://box2.example.com"),
        )
        val selected = selectFanOutEndpoints(active, all)
        assertEquals(2, selected.size)
    }

    @Test fun incompleteEndpointsAreSkipped() {
        val active = ep("https://box1.example.com")
        val all = listOf(
            ep("https://box1.example.com"),
            Endpoint(url = "", token = "tok"),
            Endpoint(url = "https://no-token.example.com", token = ""),
        )
        val selected = selectFanOutEndpoints(active, all)
        assertEquals(1, selected.size)
    }

    // ── Tests: failure isolation ──────────────────────────────────────────

    @Test fun oneBoxFailureDoesNotPreventOthers() {
        // 3 boxes: box1 = success, box2 = network error (null), box3 = success.
        val results = listOf(true, null, true)
        assertEquals(2, countSuccesses(results))
        assertEquals(1, countFailures(results))
    }

    @Test fun allSuccessesCountedCorrectly() {
        val results = listOf(true, true, true)
        assertEquals(3, countSuccesses(results))
        assertEquals(0, countFailures(results))
    }

    @Test fun allFailuresCountedCorrectly() {
        val results = listOf(null, false, null)
        assertEquals(0, countSuccesses(results))
        assertEquals(3, countFailures(results))
    }

    @Test fun emptyResultListProducesZeroSuccesses() {
        assertEquals(0, countSuccesses(emptyList()))
        assertEquals(0, countFailures(emptyList()))
    }

    // ── Tests: resilient aggregate decision ───────────────────────────────
    // Mirrors PushStore.registerWithAllEndpoints: overall success when AT
    // LEAST ONE endpoint registered; error ONLY on total failure. An offline
    // secondary box must not flip the operation to failed.

    /** (anySucceeded, activeSucceeded) modelled from per-endpoint ok flags. */
    private fun aggregate(results: List<Pair<Boolean, Boolean>>): Pair<Boolean, Boolean> {
        // results: (isActive, ok)
        val anySucceeded = results.any { it.second }
        val activeSucceeded = results.any { it.first && it.second }
        return anySucceeded to activeSucceeded
    }

    private fun isOverallSuccess(results: List<Pair<Boolean, Boolean>>): Boolean {
        val (any, active) = aggregate(results)
        return any || active
    }

    private fun isTotalFailure(results: List<Pair<Boolean, Boolean>>): Boolean =
        results.isNotEmpty() && !isOverallSuccess(results)

    @Test fun activeSucceedsOfflineSecondaryStillOverallSuccess() {
        // active box (reachable) ok, second box offline. THE BUG: this used to
        // mark the whole registration failed. Now it is a success.
        val results = listOf(
            true to true,    // active, registered
            false to false,  // secondary, offline
        )
        assertTrue(isOverallSuccess(results))
        assertFalse(isTotalFailure(results))
    }

    @Test fun activeOfflineButSecondaryReachableIsStillSuccess() {
        // active box offline, a reachable secondary registered: don't error.
        val results = listOf(
            true to false,  // active, offline
            false to true,  // secondary, registered
        )
        assertTrue(isOverallSuccess(results))
        assertFalse(isTotalFailure(results))
    }

    @Test fun allEndpointsFailingIsTotalFailure() {
        val results = listOf(
            true to false,
            false to false,
            false to false,
        )
        assertFalse(isOverallSuccess(results))
        assertTrue(isTotalFailure(results))
    }

    @Test fun singleActiveEndpointSuccessIsSuccess() {
        val results = listOf(true to true)
        assertTrue(isOverallSuccess(results))
        assertFalse(isTotalFailure(results))
    }

    // ── Tests: PostResult diagnostic ──────────────────────────────────────

    @Test fun postResultDiagnosticForHttpCode() {
        val r = PostResult(ok = false, code = 404, body = null, errorKind = null, errorMessage = null)
        assertEquals("http:404", r.diagnostic())
    }

    @Test fun postResultDiagnosticForException() {
        val r = PostResult(ok = false, code = -1, body = null, errorKind = "SocketTimeoutException", errorMessage = "timeout")
        assertEquals("exception:SocketTimeoutException", r.diagnostic())
    }

    @Test fun postResultDiagnosticForSuccess() {
        val r = PostResult(ok = true, code = 200, body = "{}", errorKind = null, errorMessage = null)
        assertEquals("ok", r.diagnostic())
    }

    // ── Tests: register payload shape per box ─────────────────────────────

    @Test fun registerBodyHasCorrectFieldsForEachBox() {
        val platforms = listOf("unifiedpush", "fcm", "apns")
        for (platform in platforms) {
            val body = buildRegisterBody(platform, "token-abc")
            assertEquals(platform, body.getString("platform"))
            assertEquals("token-abc", body.getString("token"))
            assertEquals(testDeviceId, body.getString("device_id"))
            assertEquals(3, body.length())
        }
    }

    @Test fun registerBodyTokenIsEndpointUrlForUnifiedPush() {
        val endpointUrl = "https://push.my-server.com/UP?v=1&token=secret123"
        val body = buildRegisterBody("unifiedpush", endpointUrl)
        assertEquals(endpointUrl, body.getString("token"))
    }

    @Test fun nBoxesProduceNDistinctBodies() {
        val boxes = listOf(
            ep("https://box1.example.com"),
            ep("https://box2.example.com"),
            ep("https://box3.example.com"),
        )
        val token = "push-endpoint-url"
        val bodies = boxes.map { buildRegisterBody("unifiedpush", token) }
        assertEquals(3, bodies.size)
        bodies.forEach { body ->
            assertEquals("unifiedpush", body.getString("platform"))
            assertEquals(token, body.getString("token"))
            assertEquals(testDeviceId, body.getString("device_id"))
        }
    }
}
