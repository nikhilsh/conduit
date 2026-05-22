import Foundation

/// LRU cache for rendered `AttributedString` instances keyed by
/// `(itemID, revision)`. Backs the streaming-render path (litter
/// audit A.5): markdown → `AttributedString` conversion is the hot
/// allocator in the chat list, and re-rendering every visible row on
/// each chunk dominated a frame budget in Instruments traces.
///
/// Why bound at 200:
///   - Each entry is one `AttributedString`; on a typical assistant
///     reply that's a few KB of attribute runs. 200 × ~4 KB ≈ <1 MB
///     resident, which is well below the SwiftUI list's own
///     attributed-text overhead on a long thread.
///   - Conversations rarely keep more than ~100 rendered messages on
///     screen at once; the cap gives 2× headroom for streaming
///     intermediate revisions of in-flight turns.
///
/// Eviction policy: classic LRU. Reads (`get`) move the entry to the
/// most-recently-used position; writes (`set`) either overwrite (and
/// move to MRU) or insert at MRU, evicting the least-recently-used
/// entry once the dictionary exceeds the cap. We use a parallel
/// `[Key]` order array rather than `OrderedDictionary` so we don't
/// take a new dependency for ~200 entries.
@MainActor
final class MessageRenderCache {

    /// Composite key. `revision` is an opaque monotonically-increasing
    /// counter assigned by the caller (typically the chunk index on
    /// the streaming side, or a static value once the message is
    /// finalized). Same `(id, revision)` ⇒ guaranteed-identical
    /// rendered output, which is the invariant the cache relies on.
    struct Key: Hashable, Sendable {
        let itemID: String
        let revision: Int
    }

    /// Upper bound on resident entries. Exposed so tests can verify
    /// the constant without reaching into private state.
    let capacity: Int

    /// Ordered storage: insertion order = LRU order, with the
    /// least-recently-used entry at `startIndex` and the most
    /// recently used at `endIndex - 1`. We re-key on each touch by
    /// removing + re-inserting, which is O(n) on the order array but
    /// acceptable at n ≤ 200.
    private var storage: [Key: AttributedString] = [:]
    private var order: [Key] = []

    /// Process-wide cache. Same rationale as
    /// `StreamingRendererCoordinator.shared`: the consumer is the
    /// `ConversationMarkdownBlock` SwiftUI view, which can't easily
    /// receive non-`@Observable` dependencies through `.environment`,
    /// so the cache is reached via singleton instead. Tests can still
    /// construct independent instances with `init(capacity:)`.
    static let shared = MessageRenderCache()

    init(capacity: Int = 200) {
        precondition(capacity > 0, "MessageRenderCache capacity must be positive")
        self.capacity = capacity
        self.storage.reserveCapacity(capacity)
        self.order.reserveCapacity(capacity)
    }

    /// Cache hit, with LRU bookkeeping. Returns `nil` on miss; the
    /// caller is responsible for rendering and calling `set`.
    func get(itemID: String, revision: Int) -> AttributedString? {
        let key = Key(itemID: itemID, revision: revision)
        guard let value = storage[key] else { return nil }
        touch(key)
        return value
    }

    /// Insert or overwrite. Evicts the LRU entry when the cap is
    /// exceeded. Overwriting an existing key moves it to MRU — this
    /// matters for streaming, where the same `(id, revision)` may be
    /// rewritten if a downstream re-render races a buffer flush.
    func set(itemID: String, revision: Int, value: AttributedString) {
        let key = Key(itemID: itemID, revision: revision)
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

    /// Drop every revision for `itemID`. Called from
    /// `StreamingRendererCoordinator.reset` (and on session eviction)
    /// so stale entries don't pin memory once an item is gone.
    func invalidate(itemID: String) {
        let stale = order.filter { $0.itemID == itemID }
        guard !stale.isEmpty else { return }
        for key in stale { storage.removeValue(forKey: key) }
        order.removeAll { $0.itemID == itemID }
    }

    /// Current resident count. Test hook; the production view layer
    /// never needs this.
    var count: Int { order.count }

    // MARK: - Private

    private func touch(_ key: Key) {
        // Move-to-back. Iterating a 200-element array is cheap and
        // avoids the bookkeeping cost of a linked list.
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
        }
        order.append(key)
    }
}
