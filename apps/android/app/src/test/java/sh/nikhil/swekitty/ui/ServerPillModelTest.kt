package sh.nikhil.swekitty.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.nikhil.swekitty.Endpoint
import sh.nikhil.swekitty.HarnessState
import sh.nikhil.swekitty.SavedServer

/**
 * `android-discovery` — Android mirror of iOS `ServerPillModelTests`
 * shipped in PR #47, with the URL-only equality fix from PR #59 baked in.
 * Pure JUnit (no Robolectric) — [ServerPillModel] is a pure data class,
 * which is exactly why the iOS surface lifted it out of the view body in
 * the first place. See `ServerPill.kt` for the rendering side.
 */
class ServerPillModelTest {

    private fun savedServer(
        id: String = "id-1",
        name: String = "harness",
        url: String = "ws://192.168.1.20:8080",
        token: String = "t1",
        isDefault: Boolean = true,
    ) = SavedServer(
        id = id,
        name = name,
        endpoint = Endpoint(url = url, token = token),
        isDefault = isDefault,
    )

    // ---------- caption formatting ----------

    @Test
    fun savedCaptionIsBareHostPort() {
        // The surrounding "Saved servers" section header already implies
        // "saved" — the caption shouldn't repeat that affordance.
        val model = ServerPillModel(
            id = "saved:1", kind = ServerPillModel.Kind.Saved,
            name = "studio", host = "192.168.1.20", port = 8080,
            status = ServerPillModel.Status.Live, isActive = true, version = null,
        )
        assertEquals("192.168.1.20:8080", model.caption)
    }

    @Test
    fun discoveredCaptionUsesPrefix() {
        // "discovered ·" prefix is the visual cue that distinguishes a
        // transient mDNS row from a curated saved server when they sit
        // side by side in the pill strip. The middle dot is a U+00B7
        // (mirroring iOS) — pin the exact bytes so a future copy edit
        // can't quietly swap it for a hyphen.
        val model = ServerPillModel(
            id = "discovered:abc", kind = ServerPillModel.Kind.Discovered,
            name = "harness-on-laptop", host = "10.0.0.5", port = 9000,
            status = ServerPillModel.Status.Idle, isActive = false, version = "0.4.2",
        )
        assertEquals("discovered · 10.0.0.5:9000", model.caption)
    }

    // ---------- duplicate-host collapse (fix-server-pill-duplicate-host) ----------

    @Test
    fun pillCollapsesToSingleLineWhenNameMatchesCaption() {
        // PR #47 polish bug: when the user saves a server without a
        // custom label, SessionStore seeds `name` with displayHost
        // ("host:port") — which made the pill render the same string
        // on both lines. Collapse to host-only on line 1 + null
        // subtitle so the view drops the second Text.
        val m = ServerPillModel.fromSaved(
            savedServer(name = "192.168.1.20:8080", url = "ws://192.168.1.20:8080"),
            Endpoint("ws://192.168.1.20:8080", "t1"),
            HarnessState.Live,
        )
        assertNull(m.subtitle)
        assertEquals("192.168.1.20", m.displayName)
    }

    @Test
    fun pillCollapsesWhenNameIsEmpty() {
        // Defensive: an empty stored name shouldn't render an empty
        // bold line + host:port below. Fall back to host on line 1.
        val m = ServerPillModel.fromSaved(
            savedServer(name = "", url = "ws://192.168.1.20:8080"),
            Endpoint("ws://192.168.1.20:8080", "t1"),
            HarnessState.Live,
        )
        assertNull(m.subtitle)
        assertEquals("192.168.1.20", m.displayName)
    }

    @Test
    fun pillShowsBothLinesWhenUserSetCustomName() {
        // Happy path — the user picked "Studio" so line 1 stays
        // "Studio" and subtitle surfaces the host:port underneath.
        val m = ServerPillModel.fromSaved(
            savedServer(name = "Studio", url = "ws://192.168.1.20:8080"),
            Endpoint("ws://192.168.1.20:8080", "t1"),
            HarnessState.Live,
        )
        assertEquals("Studio", m.displayName)
        assertEquals("192.168.1.20:8080", m.subtitle)
    }

    // ---------- status mapping (saved → harness) ----------

    @Test
    fun statusMapsLiveToLive() {
        val m = ServerPillModel.fromSaved(savedServer(), Endpoint("ws://192.168.1.20:8080", "t1"), HarnessState.Live)
        assertEquals(ServerPillModel.Status.Live, m.status)
        assertTrue(m.isActive)
    }

    @Test
    fun statusMapsLinkedToLive() {
        // Linked = handshake done, no traffic yet. The pill still reads
        // as "live" because the harness is reachable; the harness-state
        // distinction between Linked / Live only matters for the badge.
        val m = ServerPillModel.fromSaved(savedServer(), Endpoint("ws://192.168.1.20:8080", "t1"), HarnessState.Linked)
        assertEquals(ServerPillModel.Status.Live, m.status)
    }

    @Test
    fun statusMapsConnectingToConnecting() {
        val m = ServerPillModel.fromSaved(savedServer(), Endpoint("ws://192.168.1.20:8080", "t1"), HarnessState.Connecting)
        assertEquals(ServerPillModel.Status.Connecting, m.status)
    }

    @Test
    fun statusMapsReconnectingToConnecting() {
        val m = ServerPillModel.fromSaved(
            savedServer(),
            Endpoint("ws://192.168.1.20:8080", "t1"),
            HarnessState.Reconnecting(attempt = 2u, maxAttempts = 5u),
        )
        assertEquals(ServerPillModel.Status.Connecting, m.status)
    }

    @Test
    fun statusMapsFailedToFailed() {
        val m = ServerPillModel.fromSaved(
            savedServer(),
            Endpoint("ws://192.168.1.20:8080", "t1"),
            HarnessState.Failed("nope"),
        )
        assertEquals(ServerPillModel.Status.Failed, m.status)
    }

    @Test
    fun statusForInactiveSavedIsIdle() {
        // A saved server that *isn't* the current endpoint always reads
        // as idle — the harness state belongs to whatever endpoint is
        // selected, not to every row in the strip.
        val m = ServerPillModel.fromSaved(
            savedServer(url = "ws://other:9999"),
            Endpoint("ws://192.168.1.20:8080", "t1"),
            HarnessState.Live,
        )
        assertEquals(ServerPillModel.Status.Idle, m.status)
        assertFalse(m.isActive)
    }

    // ---------- URL-only equality (PR #59 parity) ----------

    @Test
    fun activeFlagIgnoresToken() {
        // Identity = URL only. iOS PR #59 fixed a regression where a
        // re-pair (fresh token, same URL) flipped isActive false and
        // every row briefly read as idle. The token is a per-device
        // secret — two clients on the same URL with different tokens
        // are still the same advertiser.
        val server = savedServer(url = "ws://192.168.1.20:8080", token = "OLD_TOKEN")
        val current = Endpoint(url = "ws://192.168.1.20:8080", token = "FRESH_TOKEN")
        val m = ServerPillModel.fromSaved(server, current, HarnessState.Live)
        assertTrue("URL match should drive isActive regardless of token drift", m.isActive)
    }

    @Test
    fun activeFlagDistinguishesDifferentUrls() {
        // Negative case for the above — two saved servers with the same
        // token (e.g. two harnesses configured manually with a static
        // token) must still resolve isActive against URL.
        val server = savedServer(url = "ws://host-a:8080", token = "shared")
        val current = Endpoint(url = "ws://host-b:8080", token = "shared")
        val m = ServerPillModel.fromSaved(server, current, HarnessState.Live)
        assertFalse(m.isActive)
    }

    // ---------- accessibility label ----------

    @Test
    fun accessibilityLabelPrefixIsSavedServer() {
        // TalkBack prefix lives in the contract — a future caption
        // rewrite (the visible "discovered ·" prefix) must not bleed
        // into the screen-reader string.
        val m = ServerPillModel(
            id = "saved:1", kind = ServerPillModel.Kind.Saved,
            name = "studio", host = "10.0.0.5", port = 8080,
            status = ServerPillModel.Status.Live, isActive = true, version = null,
        )
        assertEquals("Saved server studio, 10.0.0.5:8080, status live", m.accessibilityLabel)
    }

    @Test
    fun accessibilityLabelPrefixIsNearbyServer() {
        val m = ServerPillModel(
            id = "discovered:abc", kind = ServerPillModel.Kind.Discovered,
            name = "harness", host = "10.0.0.5", port = 9000,
            status = ServerPillModel.Status.Idle, isActive = false, version = null,
        )
        assertEquals("Nearby server harness, 10.0.0.5:9000, status idle", m.accessibilityLabel)
    }

    // ---------- id namespacing ----------

    @Test
    fun savedAndDiscoveredIdsAreNamespaced() {
        // The LazyRow key must stay unique even when a saved server and
        // its mDNS twin coexist on screen — prefixing with the kind is
        // the simplest scheme that survives a name collision.
        val saved = ServerPillModel.fromSaved(
            savedServer(id = "abc"),
            Endpoint("ws://192.168.1.20:8080", "t1"),
            HarnessState.Live,
        )
        val discovered = ServerPillModel.fromDiscovered(
            id = "abc", name = "harness", host = "10.0.0.5", port = 9000,
            version = null, isActive = false,
        )
        assertEquals("saved:abc", saved.id)
        assertEquals("discovered:abc", discovered.id)
    }

    // ---------- splitHostPort helper ----------

    @Test
    fun splitHostPortParsesWsUrl() {
        val parts = ServerPillModel.splitHostPort("ws://192.168.1.20:8080")
        assertEquals("192.168.1.20" to 8080, parts)
    }

    @Test
    fun splitHostPortReturnsNullWithoutPort() {
        // A malformed URL falls back to displayHost + 0 inside
        // fromSaved — the helper itself returns null so the fallback
        // can be decided at the call site.
        assertNull(ServerPillModel.splitHostPort("ws://no-port-here"))
    }

    // ---------- version surfacing ----------

    @Test
    fun discoveredCarriesVersionTag() {
        // Saved entries don't ship a version (the field is null by
        // construction), but discovered rows surface txt["v"] when
        // the advertiser supplied one.
        val d = ServerPillModel.fromDiscovered(
            id = "abc", name = "harness", host = "10.0.0.5", port = 9000,
            version = "0.4.2", isActive = false,
        )
        assertEquals("0.4.2", d.version)
        val s = ServerPillModel.fromSaved(
            savedServer(),
            Endpoint("ws://192.168.1.20:8080", "t1"),
            HarnessState.Live,
        )
        assertNull(s.version)
    }
}
