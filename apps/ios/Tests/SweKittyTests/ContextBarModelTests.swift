import Testing
import Foundation
@testable import SweKitty

/// Pure-data tests for `PinnedContext` and the `SessionStore` pin /
/// unpin API. ContextChipView + ContextBarView are thin SwiftUI
/// adapters over this model — we exercise the model so the chip's
/// rendering can be derived purely from data in snapshot tests later.
@Suite("ContextBar.model")
@MainActor
struct ContextBarModelTests {

    @Test func pinnedContextIconReflectsKind() {
        #expect(PinnedContext(kind: .file, label: "f.swift", payload: "/a/f.swift").iconName == "doc.text")
        #expect(PinnedContext(kind: .url, label: "host", payload: "https://x").iconName == "link")
        #expect(PinnedContext(kind: .snippet, label: "snip", payload: "...").iconName == "text.quote")
    }

    @Test func pinContextAppendsToSessionList() {
        let store = SessionStore()
        let sid = "test-pin-\(UUID().uuidString)"
        let ctx = PinnedContext(kind: .file, label: "ChatTab.swift", payload: "/path/ChatTab.swift")

        store.pinContext(ctx, for: sid)

        #expect(store.pinnedContexts[sid]?.count == 1)
        #expect(store.pinnedContexts[sid]?.first?.label == "ChatTab.swift")
    }

    @Test func pinContextPreservesInsertionOrder() {
        let store = SessionStore()
        let sid = "test-order-\(UUID().uuidString)"
        let first = PinnedContext(kind: .file, label: "a", payload: "1")
        let second = PinnedContext(kind: .url, label: "b", payload: "2")
        let third = PinnedContext(kind: .snippet, label: "c", payload: "3")

        store.pinContext(first, for: sid)
        store.pinContext(second, for: sid)
        store.pinContext(third, for: sid)

        #expect(store.pinnedContexts[sid]?.map(\.label) == ["a", "b", "c"])
    }

    @Test func pinContextDeduplicatesIdenticalPayloads() {
        // Dragging the same file in twice should be idempotent.
        // The id differs across the two PinnedContext structs but
        // (kind, payload) is what `pinContext` uses for equality.
        let store = SessionStore()
        let sid = "test-dedupe-\(UUID().uuidString)"
        store.pinContext(PinnedContext(kind: .file, label: "x", payload: "/p"), for: sid)
        store.pinContext(PinnedContext(kind: .file, label: "x", payload: "/p"), for: sid)
        #expect(store.pinnedContexts[sid]?.count == 1)
    }

    @Test func pinContextDistinguishesByKindEvenForSamePayload() {
        let store = SessionStore()
        let sid = "test-distinct-\(UUID().uuidString)"
        store.pinContext(PinnedContext(kind: .file, label: "x", payload: "shared"), for: sid)
        store.pinContext(PinnedContext(kind: .snippet, label: "x", payload: "shared"), for: sid)
        // Same payload but different kinds → both are kept.
        #expect(store.pinnedContexts[sid]?.count == 2)
    }

    @Test func unpinContextRemovesById() {
        let store = SessionStore()
        let sid = "test-unpin-\(UUID().uuidString)"
        let a = PinnedContext(kind: .file, label: "a", payload: "1")
        let b = PinnedContext(kind: .url, label: "b", payload: "2")
        store.pinContext(a, for: sid)
        store.pinContext(b, for: sid)

        store.unpinContext(a.id, from: sid)

        #expect(store.pinnedContexts[sid]?.map(\.label) == ["b"])
    }

    @Test func unpinContextClearsKeyWhenListEmpties() {
        // When the last chip goes away the map drops the session
        // key entirely. ContextBarView relies on this to render
        // `EmptyView` cleanly without an explicit isEmpty check on
        // the optional.
        let store = SessionStore()
        let sid = "test-empty-\(UUID().uuidString)"
        let ctx = PinnedContext(kind: .file, label: "only", payload: "/only")
        store.pinContext(ctx, for: sid)
        store.unpinContext(ctx.id, from: sid)
        #expect(store.pinnedContexts[sid] == nil)
    }

    @Test func unpinContextOnEmptySessionIsNoOp() {
        let store = SessionStore()
        let sid = "test-noop-\(UUID().uuidString)"
        // Just shouldn't crash.
        store.unpinContext(UUID(), from: sid)
        #expect(store.pinnedContexts[sid] == nil)
    }

    @Test func pinnedContextsAreIsolatedPerSession() {
        let store = SessionStore()
        let s1 = "test-iso-1-\(UUID().uuidString)"
        let s2 = "test-iso-2-\(UUID().uuidString)"
        store.pinContext(PinnedContext(kind: .file, label: "a", payload: "1"), for: s1)
        store.pinContext(PinnedContext(kind: .file, label: "b", payload: "2"), for: s2)
        #expect(store.pinnedContexts[s1]?.map(\.label) == ["a"])
        #expect(store.pinnedContexts[s2]?.map(\.label) == ["b"])
    }
}
