import SwiftUI

/// LRU cache for syntax-highlighted code blocks, keyed by
/// `(content hash, normalized language id, isDark)`. Backs
/// `SyntaxHighlightedCodeBlock`: HighlightSwift's `CodeText` re-runs
/// highlight.js on EVERY body evaluation, and with per-row `.equatable()`
/// in the chat list that fires whenever a `LazyVStack` row recycles back
/// into view (scroll away/back) or the theme/font changes. In a long chat
/// that's a sustained highlight.js storm off the main allocator. This cache
/// lets an identical (content + resolved language + color scheme) render
/// reuse a precomputed `AttributedString` + card background `Color` instead
/// of re-highlighting.
///
/// NOTE: this is a perf change with a *visual* surface — the cached render
/// reproduces `.codeTextStyle(.card).codeTextColors(.theme(.atomOne))` by
/// hand (see `SyntaxHighlightedCodeBlock`). It needs on-device visual
/// verification to confirm the cached path is pixel-identical to the live
/// `CodeText` path.
///
/// Mirrors `MessageRenderCache`: classic LRU with a parallel `[Key]` order
/// array (cheap at this n; avoids an `OrderedDictionary` dependency), reads
/// move to MRU, writes insert/overwrite at MRU and evict the LRU entry once
/// the dictionary exceeds the cap.
@MainActor
final class SyntaxHighlightCache {

    /// Composite key. `contentHash` is the `Hasher`-derived hash of the
    /// code payload rather than the string itself, so we don't pin a copy
    /// of every distinct code block as a dictionary key — collisions are
    /// astronomically unlikely for the payload sizes we cache, and a
    /// collision only costs a one-off re-highlight, never a wrong render
    /// (the language + isDark are part of the key too). `language` is the
    /// already-normalized highlight.js id; `isDark` captures which half of
    /// the auto-light/dark `.atomOne` theme produced the colors.
    struct Key: Hashable, Sendable {
        let contentHash: Int
        let language: String
        let isDark: Bool

        init(content: String, language: String, isDark: Bool) {
            self.contentHash = content.hashValue
            self.language = language
            self.isDark = isDark
        }
    }

    /// A highlighted render: the `AttributedString` from the engine plus
    /// the card background `Color` (`HighlightResult.backgroundColor`) so
    /// the cached path can rebuild the `.card` chrome without a second
    /// highlight pass.
    struct Entry: Sendable {
        let text: AttributedString
        let background: Color
    }

    /// Upper bound on resident entries. Exposed so tests can verify the
    /// constant without reaching into private state.
    let capacity: Int

    /// Ordered storage: insertion order = LRU order, least-recently-used
    /// at `startIndex`, most recently used at `endIndex - 1`.
    private var storage: [Key: Entry] = [:]
    private var order: [Key] = []

    /// Process-wide cache. Same rationale as `MessageRenderCache.shared`:
    /// the consumer is the `SyntaxHighlightedCodeBlock` SwiftUI view, which
    /// can't easily receive non-`@Observable` dependencies through
    /// `.environment`, so the cache is reached via singleton instead. Tests
    /// can still construct independent instances with `init(capacity:)`.
    static let shared = SyntaxHighlightCache()

    init(capacity: Int = 1200) {
        precondition(capacity > 0, "SyntaxHighlightCache capacity must be positive")
        self.capacity = capacity
        self.storage.reserveCapacity(capacity)
        self.order.reserveCapacity(capacity)
    }

    /// Cache hit, with LRU bookkeeping. Returns `nil` on miss; the caller
    /// runs the async highlight and calls `set`.
    func get(content: String, language: String, isDark: Bool) -> Entry? {
        let key = Key(content: content, language: language, isDark: isDark)
        guard let value = storage[key] else { return nil }
        touch(key)
        return value
    }

    /// Insert or overwrite. Evicts the LRU entry when the cap is exceeded.
    func set(content: String, language: String, isDark: Bool, value: Entry) {
        let key = Key(content: content, language: language, isDark: isDark)
        if storage[key] != nil {
            storage[key] = value
            touch(key)
            return
        }
        storage[key] = value
        order.append(key)
        if order.count > capacity {
            let evicted = order.removeFirst()
            storage.removeValue(forKey: evicted)
        }
    }

    /// Current resident count. Test hook; the production view layer never
    /// needs this.
    var count: Int { order.count }

    // MARK: - Private

    private func touch(_ key: Key) {
        // Move-to-back. Iterating the order array is cheap and avoids the
        // bookkeeping cost of a linked list.
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
        }
        order.append(key)
    }
}
