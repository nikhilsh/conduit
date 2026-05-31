package sh.nikhil.conduit.ui

import androidx.compose.ui.text.AnnotatedString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-data tests for the parsed-markdown LRU (task #38). Android
 * mirror of iOS `MessageRenderCacheTests` — same eviction contract,
 * same default cap, same invalidate semantics, so the two platforms
 * stay aligned. Runs under plain JUnit (`AnnotatedString` is pure-JVM).
 */
class ParsedMarkdownCacheTest {

    private fun s(v: String) = AnnotatedString(v)

    @Test fun missReturnsNull() {
        val cache = ParsedMarkdownCache()
        assertNull(cache.get("a", 0))
    }

    @Test fun putThenGetRoundTrips() {
        val cache = ParsedMarkdownCache()
        cache.put("a", 0, s("hello"))
        assertEquals(s("hello"), cache.get("a", 0))
    }

    @Test fun differentRevisionsAreSeparateEntries() {
        val cache = ParsedMarkdownCache()
        cache.put("a", 0, s("v0"))
        cache.put("a", 1, s("v1"))
        assertEquals(s("v0"), cache.get("a", 0))
        assertEquals(s("v1"), cache.get("a", 1))
        assertEquals(2, cache.count)
    }

    @Test fun overwriteUpdatesValueInPlace() {
        val cache = ParsedMarkdownCache()
        cache.put("a", 0, s("first"))
        cache.put("a", 0, s("second"))
        assertEquals(s("second"), cache.get("a", 0))
        assertEquals(1, cache.count)
    }

    @Test fun getOrPutComputesOnceThenServesFromCache() {
        val cache = ParsedMarkdownCache()
        var computes = 0
        val a = cache.getOrPut("a", 0) { computes++; s("X") }
        val b = cache.getOrPut("a", 0) { computes++; s("X") }
        assertEquals(s("X"), a)
        assertEquals(s("X"), b)
        assertEquals("compute runs exactly once for a hit", 1, computes)
    }

    @Test fun evictionDropsLeastRecentlyUsed() {
        val cache = ParsedMarkdownCache(capacity = 3)
        cache.put("a", 0, s("A"))
        cache.put("b", 0, s("B"))
        cache.put("c", 0, s("C"))
        // Touch A so B becomes the LRU.
        cache.get("a", 0)
        cache.put("d", 0, s("D"))
        assertNull(cache.get("b", 0))
        assertEquals(s("A"), cache.get("a", 0))
        assertEquals(s("C"), cache.get("c", 0))
        assertEquals(s("D"), cache.get("d", 0))
        assertEquals(3, cache.count)
    }

    @Test fun evictionWithoutReadsIsInsertionOrder() {
        val cache = ParsedMarkdownCache(capacity = 2)
        cache.put("a", 0, s("A"))
        cache.put("b", 0, s("B"))
        cache.put("c", 0, s("C"))
        assertNull(cache.get("a", 0))
        assertEquals(s("B"), cache.get("b", 0))
        assertEquals(s("C"), cache.get("c", 0))
    }

    @Test fun getOrPutHitMovesEntryToMostRecentlyUsed() {
        val cache = ParsedMarkdownCache(capacity = 2)
        cache.put("a", 0, s("A"))
        cache.put("b", 0, s("B"))
        // Access A (hit) → A is now MRU, B is LRU.
        cache.getOrPut("a", 0) { s("ignored") }
        cache.put("c", 0, s("C"))
        assertNull(cache.get("b", 0))
        assertEquals(s("A"), cache.get("a", 0))
        assertEquals(s("C"), cache.get("c", 0))
    }

    @Test fun invalidateDropsAllRevisionsOfId() {
        val cache = ParsedMarkdownCache()
        cache.put("a", 0, s("a0"))
        cache.put("a", 1, s("a1"))
        cache.put("a", 2, s("a2"))
        cache.put("b", 0, s("b0"))
        cache.invalidate("a")
        assertNull(cache.get("a", 0))
        assertNull(cache.get("a", 1))
        assertNull(cache.get("a", 2))
        assertEquals(s("b0"), cache.get("b", 0))
        assertEquals(1, cache.count)
    }

    @Test fun invalidateUnknownIdIsNoOp() {
        val cache = ParsedMarkdownCache()
        cache.put("a", 0, s("A"))
        cache.invalidate("never-seen")
        assertEquals(s("A"), cache.get("a", 0))
        assertEquals(1, cache.count)
    }

    @Test fun defaultCapacityIs200() {
        // Locks in the cap chosen for the production wiring; matches the
        // iOS `MessageRenderCache` default so the two stay aligned.
        assertEquals(200, ParsedMarkdownCache().capacity)
        assertEquals(200, ParsedMarkdownCache.DEFAULT_CAPACITY)
    }

    @Test fun capacityIsRespectedUnderLoad() {
        val cache = ParsedMarkdownCache(capacity = 5)
        for (i in 0 until 20) cache.put("id-$i", 0, s("v$i"))
        assertEquals(5, cache.count)
        for (i in 0 until 15) assertNull(cache.get("id-$i", 0))
        for (i in 15 until 20) assertNotNull(cache.get("id-$i", 0))
    }

    @Test fun rejectsNonPositiveCapacity() {
        try {
            ParsedMarkdownCache(capacity = 0)
            throw AssertionError("expected IllegalArgumentException")
        } catch (_: IllegalArgumentException) {
            // expected
        }
    }

    // --- markdownRevision (the cache-key fold) ---

    @Test fun revisionIsStableForSameInputs() {
        val a = markdownRevision("hello", 16f, sh.nikhil.conduit.AppearanceStore.FontFamily.System)
        val b = markdownRevision("hello", 16f, sh.nikhil.conduit.AppearanceStore.FontFamily.System)
        assertEquals(a, b)
    }

    @Test fun revisionVariesWithContent() {
        val a = markdownRevision("hello", 16f, sh.nikhil.conduit.AppearanceStore.FontFamily.System)
        val b = markdownRevision("world", 16f, sh.nikhil.conduit.AppearanceStore.FontFamily.System)
        assertTrue(a != b)
    }

    @Test fun revisionVariesWithBodyPointSize() {
        val a = markdownRevision("hello", 16f, sh.nikhil.conduit.AppearanceStore.FontFamily.System)
        val b = markdownRevision("hello", 22f, sh.nikhil.conduit.AppearanceStore.FontFamily.System)
        assertTrue(a != b)
    }

    @Test fun revisionVariesWithFontChoice() {
        val a = markdownRevision("hello", 16f, sh.nikhil.conduit.AppearanceStore.FontFamily.System)
        val b = markdownRevision("hello", 16f, sh.nikhil.conduit.AppearanceStore.FontFamily.Monospaced)
        assertTrue(a != b)
    }
}
