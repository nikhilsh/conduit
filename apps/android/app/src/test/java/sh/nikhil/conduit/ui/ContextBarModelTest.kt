package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.nikhil.conduit.PinnedContext
import sh.nikhil.conduit.PinnedContextKind
import sh.nikhil.conduit.PinnedContextReducer

/**
 * Pure-data assertions for the pinned-context model that backs the
 * ContextBar above the composer. Mirror of iOS
 * `ContextBarModelTests`. Exercises [PinnedContextReducer] directly
 * so the tests run under plain JUnit — no Robolectric, no
 * ViewModel instantiation.
 */
class ContextBarModelTest {

    private fun ctx(
        kind: PinnedContextKind,
        label: String,
        payload: String,
        id: String = "$kind:$payload",
    ): PinnedContext = PinnedContext(id = id, kind = kind, label = label, payload = payload)

    @Test fun pin_appendsToEmptySession() {
        val initial = emptyMap<String, List<PinnedContext>>()
        val c = ctx(PinnedContextKind.File, "README.md", "/repo/README.md")
        val next = PinnedContextReducer.pin(initial, "S1", c)
        assertEquals(listOf(c), next["S1"])
    }

    @Test fun pin_preservesInsertionOrder() {
        var m = emptyMap<String, List<PinnedContext>>()
        val a = ctx(PinnedContextKind.File, "a.kt", "/a.kt")
        val b = ctx(PinnedContextKind.Url, "anthropic.com", "https://anthropic.com")
        val c = ctx(PinnedContextKind.Snippet, "fn main", "fn main() {}")
        m = PinnedContextReducer.pin(m, "S1", a)
        m = PinnedContextReducer.pin(m, "S1", b)
        m = PinnedContextReducer.pin(m, "S1", c)
        assertEquals(listOf(a, b, c), m["S1"])
    }

    @Test fun pin_dedupesOnKindAndPayload_ignoringId() {
        // iOS guards against the same file being dragged in twice — the
        // (kind, payload) tuple is the canonical identity. A second pin
        // with a different `id` but the same payload must be a no-op.
        val first = ctx(PinnedContextKind.File, "README", "/repo/README.md", id = "first")
        val dup = ctx(PinnedContextKind.File, "README (copy)", "/repo/README.md", id = "second")
        var m = emptyMap<String, List<PinnedContext>>()
        m = PinnedContextReducer.pin(m, "S1", first)
        m = PinnedContextReducer.pin(m, "S1", dup)
        assertEquals(1, m["S1"]?.size)
        // The original entry survives — dedupe is "first wins", not
        // "last wins". Matches iOS reference semantics.
        assertEquals("first", m["S1"]?.first()?.id)
    }

    @Test fun pin_doesNotDedupeAcrossKinds() {
        // Same payload but a URL vs. a Snippet — those are distinct
        // chips. The dedupe rule keys on BOTH kind and payload.
        val asUrl = ctx(PinnedContextKind.Url, "snippet.io", "https://snippet.io")
        val asSnippet = ctx(PinnedContextKind.Snippet, "snippet.io quote", "https://snippet.io")
        var m = emptyMap<String, List<PinnedContext>>()
        m = PinnedContextReducer.pin(m, "S1", asUrl)
        m = PinnedContextReducer.pin(m, "S1", asSnippet)
        assertEquals(2, m["S1"]?.size)
    }

    @Test fun unpin_removesById_andKeepsSiblings() {
        val a = ctx(PinnedContextKind.File, "a.kt", "/a.kt", id = "A")
        val b = ctx(PinnedContextKind.File, "b.kt", "/b.kt", id = "B")
        var m = emptyMap<String, List<PinnedContext>>()
        m = PinnedContextReducer.pin(m, "S1", a)
        m = PinnedContextReducer.pin(m, "S1", b)
        m = PinnedContextReducer.unpin(m, "S1", "A")
        assertEquals(listOf(b), m["S1"])
    }

    @Test fun unpin_lastEntry_dropsSessionKey() {
        // When the final entry is removed, the session key disappears
        // so observers see absence (`null`) rather than an empty list.
        // iOS uses `removeValue(forKey:)` for the same reason.
        val a = ctx(PinnedContextKind.File, "a.kt", "/a.kt", id = "A")
        var m = emptyMap<String, List<PinnedContext>>()
        m = PinnedContextReducer.pin(m, "S1", a)
        m = PinnedContextReducer.unpin(m, "S1", "A")
        assertNull(m["S1"])
        assertFalse(m.containsKey("S1"))
    }

    @Test fun unpin_unknownId_isNoOp() {
        val a = ctx(PinnedContextKind.File, "a.kt", "/a.kt", id = "A")
        var m = emptyMap<String, List<PinnedContext>>()
        m = PinnedContextReducer.pin(m, "S1", a)
        val before = m
        m = PinnedContextReducer.unpin(m, "S1", "does-not-exist")
        assertEquals(before, m)
    }

    @Test fun unpin_unknownSession_isNoOp() {
        // Tapping an unpin on a session that never had any chips is
        // safe — we don't synthesize an empty entry.
        val m = PinnedContextReducer.unpin(emptyMap(), "ghost-session", "A")
        assertTrue(m.isEmpty())
    }

    @Test fun perSessionIsolation_pinDoesNotLeakAcrossSessions() {
        // Per-session isolation is the load-bearing rule — pinning a
        // context onto S1 must NOT show up on S2. ChatPage reads
        // `pinnedContexts[session.id]`; cross-session leakage would
        // attach the wrong file to the wrong agent.
        val onS1 = ctx(PinnedContextKind.File, "s1-only.kt", "/s1.kt", id = "S1-A")
        val onS2 = ctx(PinnedContextKind.File, "s2-only.kt", "/s2.kt", id = "S2-A")
        var m = emptyMap<String, List<PinnedContext>>()
        m = PinnedContextReducer.pin(m, "S1", onS1)
        m = PinnedContextReducer.pin(m, "S2", onS2)
        assertEquals(listOf(onS1), m["S1"])
        assertEquals(listOf(onS2), m["S2"])

        // Unpin on S1 must NOT touch S2's list.
        m = PinnedContextReducer.unpin(m, "S1", "S1-A")
        assertNull(m["S1"])
        assertEquals(listOf(onS2), m["S2"])
    }

    @Test fun perSessionIsolation_sameContextOnTwoSessions_isAllowed() {
        // The dedupe rule is scoped to a single session — pinning the
        // same payload onto two sessions is fine, and the reducer
        // doesn't silently de-dupe across keys.
        val payload = ctx(PinnedContextKind.File, "shared.kt", "/shared.kt", id = "X")
        var m = emptyMap<String, List<PinnedContext>>()
        m = PinnedContextReducer.pin(m, "S1", payload)
        m = PinnedContextReducer.pin(m, "S2", payload)
        assertEquals(listOf(payload), m["S1"])
        assertEquals(listOf(payload), m["S2"])
    }
}
