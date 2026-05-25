package sh.nikhil.swekitty.ui

import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.text.AnnotatedString

/**
 * Thread-safe LRU cache for parsed markdown (`AnnotatedString`),
 * Android mirror of iOS `MessageRenderCache` (task #38).
 *
 * The chat list re-parses markdown into an [AnnotatedString] on every
 * recycle: a recycled `LazyColumn` row whose `remember(text, ...)` key
 * changed recomputes [LitterMarkdownHeadingScaler.scaledAnnotated]
 * from scratch (0px → final height), which is the judder source during
 * scrollback and streaming. Hoisting a process-shaped cache above the
 * list lets recycled rows render straight from cache.
 *
 * Why bound at ~200:
 *   - Each entry is one [AnnotatedString] (a few KB of span runs on a
 *     typical reply). 200 × ~4 KB ≈ <1 MB resident — well below the
 *     LazyColumn's own text overhead on a long thread.
 *   - A conversation rarely keeps more than ~100 rendered messages on
 *     screen; the cap gives 2× headroom for streaming intermediate
 *     revisions of in-flight turns.
 *
 * Eviction policy: classic LRU. [get] moves the entry to most-recently
 * used; [put] inserts/overwrites at MRU and evicts the least-recently
 * used once over the cap. Backed by `LinkedHashMap(accessOrder=true)`
 * whose `removeEldestEntry` override does the eviction. All access is
 * `@Synchronized` because the cache is reachable from recomposition on
 * the main thread and (defensively) any background prewarm.
 */
class ParsedMarkdownCache(val capacity: Int = DEFAULT_CAPACITY) {

    init {
        require(capacity > 0) { "ParsedMarkdownCache capacity must be positive" }
    }

    /**
     * Composite cache key. `revision` is an opaque value the caller
     * folds from everything that affects the parsed output (content +
     * body point size + font choice). Same `(id, revision)` ⇒
     * guaranteed-identical output — the invariant the cache relies on.
     */
    data class Key(val id: String, val revision: Int)

    private val map = object : LinkedHashMap<Key, AnnotatedString>(
        16,
        0.75f,
        /* accessOrder = */ true,
    ) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Key, AnnotatedString>?): Boolean =
            size > capacity
    }

    /** Cache hit (and LRU touch), or `null` on miss. */
    @Synchronized
    fun get(id: String, revision: Int): AnnotatedString? = map[Key(id, revision)]

    /** Insert or overwrite; evicts the LRU entry past the cap. */
    @Synchronized
    fun put(id: String, revision: Int, value: AnnotatedString) {
        map[Key(id, revision)] = value
    }

    /**
     * Get the cached value or compute, store, and return it. The
     * single call site used by the view layer — keeps the
     * lookup/parse/store dance in one place.
     */
    @Synchronized
    fun getOrPut(id: String, revision: Int, compute: () -> AnnotatedString): AnnotatedString {
        val key = Key(id, revision)
        map[key]?.let { return it }
        val value = compute()
        map[key] = value
        return value
    }

    /** Drop every revision for [id] (e.g. on item reset / eviction). */
    @Synchronized
    fun invalidate(id: String) {
        map.keys.removeAll { it.id == id }
    }

    /** Current resident count. Test hook. */
    @get:Synchronized
    val count: Int
        get() = map.size

    companion object {
        const val DEFAULT_CAPACITY = 200
    }
}

/**
 * CompositionLocal carrying the chat's [ParsedMarkdownCache]. Hoisted
 * once at the chat surface (above the `LazyColumn`) so every recycled
 * row sees the same cache. Defaults to a throwaway instance so a
 * preview / stray composable still renders (just without cross-row
 * reuse) rather than crashing.
 */
val LocalParsedMarkdownCache = staticCompositionLocalOf { ParsedMarkdownCache() }
