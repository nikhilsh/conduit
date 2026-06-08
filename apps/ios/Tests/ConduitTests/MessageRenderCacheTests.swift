import Testing
import Foundation
@testable import Conduit

/// Pure-data tests for the LRU render cache (upstream audit A.5).
/// Covers the eviction policy contract and the `invalidate` API that
/// the (not-yet-landed) `ConversationView` integration will call when
/// an item is reset. Locked in here so the next PR can be reviewed
/// against a known-good cache implementation.
@Suite("MessageRenderCache")
@MainActor
struct MessageRenderCacheTests {

    @Test func missReturnsNil() {
        let cache = MessageRenderCache()
        #expect(cache.get(itemID: "a", revision: 0) == nil)
    }

    @Test func setThenGetRoundTrips() {
        let cache = MessageRenderCache()
        let value = AttributedString("hello")
        cache.set(itemID: "a", revision: 0, value: value)
        #expect(cache.get(itemID: "a", revision: 0) == value)
    }

    @Test func differentRevisionsAreSeparateEntries() {
        // Streaming revisions stack up: rev N gets evicted only when
        // the cap forces it, not when rev N+1 lands. This lets the
        // view layer hop between revisions (e.g. on a scroll-back)
        // without re-rendering from source.
        let cache = MessageRenderCache()
        cache.set(itemID: "a", revision: 0, value: AttributedString("v0"))
        cache.set(itemID: "a", revision: 1, value: AttributedString("v1"))

        #expect(cache.get(itemID: "a", revision: 0) == AttributedString("v0"))
        #expect(cache.get(itemID: "a", revision: 1) == AttributedString("v1"))
        #expect(cache.count == 2)
    }

    @Test func overwriteUpdatesValueInPlace() {
        let cache = MessageRenderCache()
        cache.set(itemID: "a", revision: 0, value: AttributedString("first"))
        cache.set(itemID: "a", revision: 0, value: AttributedString("second"))
        #expect(cache.get(itemID: "a", revision: 0) == AttributedString("second"))
        #expect(cache.count == 1)
    }

    @Test func evictionDropsLeastRecentlyUsed() {
        let cache = MessageRenderCache(capacity: 3)
        cache.set(itemID: "a", revision: 0, value: AttributedString("A"))
        cache.set(itemID: "b", revision: 0, value: AttributedString("B"))
        cache.set(itemID: "c", revision: 0, value: AttributedString("C"))

        // Touch A so B becomes the LRU.
        _ = cache.get(itemID: "a", revision: 0)

        cache.set(itemID: "d", revision: 0, value: AttributedString("D"))

        #expect(cache.get(itemID: "b", revision: 0) == nil)
        #expect(cache.get(itemID: "a", revision: 0) == AttributedString("A"))
        #expect(cache.get(itemID: "c", revision: 0) == AttributedString("C"))
        #expect(cache.get(itemID: "d", revision: 0) == AttributedString("D"))
        #expect(cache.count == 3)
    }

    @Test func evictionWithoutReadsIsInsertionOrder() {
        let cache = MessageRenderCache(capacity: 2)
        cache.set(itemID: "a", revision: 0, value: AttributedString("A"))
        cache.set(itemID: "b", revision: 0, value: AttributedString("B"))
        cache.set(itemID: "c", revision: 0, value: AttributedString("C"))

        #expect(cache.get(itemID: "a", revision: 0) == nil)
        #expect(cache.get(itemID: "b", revision: 0) == AttributedString("B"))
        #expect(cache.get(itemID: "c", revision: 0) == AttributedString("C"))
    }

    @Test func overwriteMovesEntryToMostRecentlyUsed() {
        // Streaming buffers overwrite the same `(id, revision)` slot
        // on rapid re-renders. Each overwrite must reset the LRU
        // clock so the active item isn't evicted out from under us.
        let cache = MessageRenderCache(capacity: 2)
        cache.set(itemID: "a", revision: 0, value: AttributedString("A"))
        cache.set(itemID: "b", revision: 0, value: AttributedString("B"))
        cache.set(itemID: "a", revision: 0, value: AttributedString("A2"))
        cache.set(itemID: "c", revision: 0, value: AttributedString("C"))

        #expect(cache.get(itemID: "b", revision: 0) == nil)
        #expect(cache.get(itemID: "a", revision: 0) == AttributedString("A2"))
        #expect(cache.get(itemID: "c", revision: 0) == AttributedString("C"))
    }

    @Test func invalidateDropsAllRevisionsOfID() {
        let cache = MessageRenderCache()
        cache.set(itemID: "a", revision: 0, value: AttributedString("a0"))
        cache.set(itemID: "a", revision: 1, value: AttributedString("a1"))
        cache.set(itemID: "a", revision: 2, value: AttributedString("a2"))
        cache.set(itemID: "b", revision: 0, value: AttributedString("b0"))

        cache.invalidate(itemID: "a")

        #expect(cache.get(itemID: "a", revision: 0) == nil)
        #expect(cache.get(itemID: "a", revision: 1) == nil)
        #expect(cache.get(itemID: "a", revision: 2) == nil)
        #expect(cache.get(itemID: "b", revision: 0) == AttributedString("b0"))
        #expect(cache.count == 1)
    }

    @Test func invalidateUnknownIDIsNoOp() {
        let cache = MessageRenderCache()
        cache.set(itemID: "a", revision: 0, value: AttributedString("A"))
        cache.invalidate(itemID: "never-seen")
        #expect(cache.get(itemID: "a", revision: 0) == AttributedString("A"))
        #expect(cache.count == 1)
    }

    @Test func defaultCapacityIs200() {
        // Locks in the cap chosen for the production wiring — see
        // the comment block on `MessageRenderCache` for the sizing
        // rationale. If we change the cap, this assertion forces the
        // doc comment to be updated alongside it.
        let cache = MessageRenderCache()
        #expect(cache.capacity == 1200)
    }

    @Test func capacityIsRespectedUnderLoad() {
        let cache = MessageRenderCache(capacity: 5)
        for i in 0..<20 {
            cache.set(itemID: "id-\(i)", revision: 0, value: AttributedString("v\(i)"))
        }
        #expect(cache.count == 5)
        // Only the last 5 inserts survive (no reads in between, so
        // strict insertion order = LRU order).
        for i in 0..<15 {
            #expect(cache.get(itemID: "id-\(i)", revision: 0) == nil)
        }
        for i in 15..<20 {
            #expect(cache.get(itemID: "id-\(i)", revision: 0) == AttributedString("v\(i)"))
        }
    }
}
