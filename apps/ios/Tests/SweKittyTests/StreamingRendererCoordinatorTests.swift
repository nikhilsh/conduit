import Testing
@testable import SweKitty

/// Pure-data tests for the streaming render coordinator (litter audit
/// A.5). The state machine is intentionally tiny so the tests can
/// codify the full transition table — no SwiftUI host, no broker, no
/// async — and the next PR (the `ConversationView` integration) can
/// be reviewed against a known-good behavioural contract.
@Suite("StreamingRendererCoordinator")
@MainActor
struct StreamingRendererCoordinatorTests {

    @Test func unknownItemDefaultsToIdle() {
        let coord = StreamingRendererCoordinator()
        #expect(coord.renderState(for: "missing") == .idle)
    }

    @Test func incrementalChunksAccumulateIntoStreaming() {
        let coord = StreamingRendererCoordinator()
        coord.update(itemID: "a", content: "Hel", isComplete: false)
        #expect(coord.renderState(for: "a") == .streaming(buffer: "Hel"))

        coord.update(itemID: "a", content: "Hello", isComplete: false)
        #expect(coord.renderState(for: "a") == .streaming(buffer: "Hello"))
    }

    @Test func terminalChunkTransitionsToComplete() {
        let coord = StreamingRendererCoordinator()
        coord.update(itemID: "a", content: "partial", isComplete: false)
        coord.update(itemID: "a", content: "partial done", isComplete: true)
        #expect(coord.renderState(for: "a") == .complete)
    }

    @Test func singleShotCompletionSkipsStreaming() {
        // Server-side single-message replies don't emit deltas — they
        // arrive whole with `isComplete: true`. The coordinator must
        // still land in `.complete` so the view doesn't sit on `.idle`.
        let coord = StreamingRendererCoordinator()
        coord.update(itemID: "a", content: "all at once", isComplete: true)
        #expect(coord.renderState(for: "a") == .complete)
    }

    @Test func lateDeltaAfterCompletionIsIgnored() {
        let coord = StreamingRendererCoordinator()
        coord.update(itemID: "a", content: "x", isComplete: true)
        coord.update(itemID: "a", content: "y", isComplete: false)
        #expect(coord.renderState(for: "a") == .complete)
    }

    @Test func multipleItemsTrackedIndependently() {
        let coord = StreamingRendererCoordinator()
        coord.update(itemID: "a", content: "A", isComplete: false)
        coord.update(itemID: "b", content: "B-final", isComplete: true)
        coord.update(itemID: "c", content: "C", isComplete: false)

        #expect(coord.renderState(for: "a") == .streaming(buffer: "A"))
        #expect(coord.renderState(for: "b") == .complete)
        #expect(coord.renderState(for: "c") == .streaming(buffer: "C"))
    }

    @Test func resetReturnsItemToIdle() {
        let coord = StreamingRendererCoordinator()
        coord.update(itemID: "a", content: "hello", isComplete: false)
        coord.reset(itemID: "a")
        #expect(coord.renderState(for: "a") == .idle)
    }

    @Test func resetIsScopedToTheGivenID() {
        let coord = StreamingRendererCoordinator()
        coord.update(itemID: "a", content: "A", isComplete: false)
        coord.update(itemID: "b", content: "B", isComplete: false)
        coord.reset(itemID: "a")
        #expect(coord.renderState(for: "a") == .idle)
        #expect(coord.renderState(for: "b") == .streaming(buffer: "B"))
    }

    @Test func resetOfUnknownIDIsNoOp() {
        let coord = StreamingRendererCoordinator()
        coord.reset(itemID: "never-seen")
        #expect(coord.renderState(for: "never-seen") == .idle)
    }

    @Test func updateAfterResetStartsFreshStreaming() {
        // After eviction the same id may be reused (e.g. retry on a
        // dropped turn). The coordinator must not retain `.complete`
        // residue from the old run.
        let coord = StreamingRendererCoordinator()
        coord.update(itemID: "a", content: "done", isComplete: true)
        coord.reset(itemID: "a")
        coord.update(itemID: "a", content: "new", isComplete: false)
        #expect(coord.renderState(for: "a") == .streaming(buffer: "new"))
    }

    @Test func observingCompleteShapedEventYieldsCompleteImmediately() {
        // Wire-up regression guard for the `ios-streaming-wire` PR:
        // when `SessionStore.ingestChat` lands a fully-formed assistant
        // turn (no streaming deltas, just `isComplete: true`), a view
        // observing `renderState(for:)` must see `.complete` on its
        // very first read — i.e. the coordinator must not park the
        // entry in `.streaming` first and then transition.
        let coord = StreamingRendererCoordinator()
        coord.update(itemID: "wire", content: "full message", isComplete: true)
        #expect(coord.renderState(for: "wire") == .complete)
    }

    @Test func emptyContentChunkIsStillStreaming() {
        // Brokers occasionally emit a zero-length opener delta to
        // signal "assistant has started typing". Treat it as
        // streaming with an empty buffer so the view can show a
        // typing pill immediately.
        let coord = StreamingRendererCoordinator()
        coord.update(itemID: "a", content: "", isComplete: false)
        #expect(coord.renderState(for: "a") == .streaming(buffer: ""))
    }
}
