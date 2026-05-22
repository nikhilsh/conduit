import Foundation
import Observation

/// Per-item streaming state for the in-progress assistant turn.
///
/// `ConversationItem.id` is a `String` (UniFFI shape — see
/// `core/generated/swe_kitty_core.swift`), so all keys here are
/// strings. The state machine is intentionally small:
///
///   `.idle`              — no chunks seen, or post-`reset`.
///   `.streaming(buffer)` — at least one chunk delivered, terminal
///                          chunk not yet observed.
///   `.complete`          — terminal chunk seen; buffer is dropped
///                          because the persisted `ConversationItem`
///                          on `SessionStore` is the source of truth
///                          once streaming ends.
///
/// The buffer holds the *accumulated* content, not the latest delta:
/// callers `update(... content:)` with whatever the broker has
/// produced so far, which keeps the renderer side idempotent (re-feeds
/// of the same chunk don't double-append).
enum RenderState: Equatable, Sendable {
    case idle
    case streaming(buffer: String)
    case complete
}

/// Pure-data state machine driving the streaming-render path
/// (litter audit A.5). Owns no views and emits no side-effects beyond
/// updating its own observable storage, so it can be exercised by
/// unit tests without spinning up a SwiftUI host.
///
/// `@MainActor` because the consumer is SwiftUI; `@Observable` so that
/// `renderState(for:)` reads from views trigger re-render on change.
@Observable
@MainActor
final class StreamingRendererCoordinator {

    /// Process-wide singleton. The view layer reaches for `.shared`
    /// directly rather than receiving an injected coordinator so that
    /// `SessionStore.ingestChat` (off in the model layer) and
    /// `ConversationMarkdownBlock` (deep in the view tree) reference
    /// the same state machine without threading the dependency through
    /// every intervening type. Tests still construct fresh instances
    /// via `init()` — the singleton is convenience, not a hard
    /// requirement.
    static let shared = StreamingRendererCoordinator()

    /// Per-id state. Items not present here are `.idle` by definition;
    /// we don't materialise an entry until `update` is called so the
    /// dictionary stays bounded by *in-flight* turns, not total history.
    private var states: [String: RenderState] = [:]

    init() {}

    /// Feed an accumulated content snapshot for `itemID`.
    ///
    /// - Parameters:
    ///   - itemID: `ConversationItem.id`.
    ///   - content: The full accumulated assistant text seen so far.
    ///   - isComplete: `true` on the terminal chunk; flips the state
    ///     to `.complete` and discards the buffer (the persisted
    ///     `ConversationItem` carries the final string).
    ///
    /// Semantics:
    ///   - `update(..., isComplete: false)` on a `.complete` item is a
    ///     no-op. The terminal transition is one-way until `reset`.
    ///   - `update(..., isComplete: true)` is *always* honoured, even
    ///     from `.idle`, so a single-shot completion (no streaming
    ///     deltas) still lands in `.complete`.
    func update(itemID: String, content: String, isComplete: Bool) {
        if isComplete {
            states[itemID] = .complete
            return
        }
        switch states[itemID] ?? .idle {
        case .complete:
            // Late delta after completion — ignore. The persisted
            // item is the source of truth and we don't want to
            // rewind the UI back to a streaming pill.
            return
        case .idle, .streaming:
            states[itemID] = .streaming(buffer: content)
        }
    }

    /// Render-time accessor. Defaults to `.idle` for unknown ids so
    /// the view doesn't have to special-case "not started yet".
    func renderState(for itemID: String) -> RenderState {
        states[itemID] ?? .idle
    }

    /// Drop all tracked state for `itemID`. Used when the
    /// `SessionStore` evicts a conversation (e.g. session deleted) so
    /// the coordinator doesn't leak entries across sessions.
    func reset(itemID: String) {
        states.removeValue(forKey: itemID)
    }
}
