import Foundation

/// One user chat message awaiting delivery to the agent.
///
/// The shell appends an optimistic transcript echo (a `local-…`
/// `ConversationItem`) the instant the user hits send, then enqueues the
/// same text here. The queue survives backgrounding and process death
/// (persisted per-session), so a message typed during a reconnect window —
/// or sent the moment the user backgrounds the app — is no longer lost.
///
/// `localID` ties the queue entry to its transcript echo: when delivery
/// succeeds the shell flips that echo from `pending` → `done`; when it
/// ultimately fails it flips to `failed` with a retry affordance. Mirrors
/// Android `PendingChat`.
struct PendingChat: Codable, Equatable {
    /// The `local-…` id of the optimistic transcript echo this entry backs.
    let localID: String
    /// The raw message text to deliver (already slash-command-filtered).
    let message: String
    /// Broker-clock-anchored timestamp string of the echo (for ordering).
    let ts: String
    /// Delivery attempts made so far. Drives the give-up → `failed` decision.
    var attempts: Int = 0
    /// Set once the entry has exhausted retries and is surfaced as failed.
    /// A failed entry stays in the queue (so the user can retry) but is NOT
    /// auto-flushed again until the user explicitly retries it.
    var failed: Bool = false
}

/// Pure, dependency-free state machine for the optimistic-send pending
/// queue. Holds NO transport and NO clock — the shell injects delivery and
/// persistence — so the queue/flush/ack/failure transitions are unit-
/// testable without a live WS. Mirrors Android `PendingChatQueue`.
///
/// State lives in `bySession`. The shell drives it with four moves:
///   1. `enqueue`  — on send, register the message as pending.
///   2. `flushable(for:)` — when ready (connected + agent live), ask which
///      entries to (re)attempt; the shell delivers each and reports back.
///   3. `markDelivered` — the WS write succeeded → drop the entry (ack).
///   4. `markAttemptFailed` — the WS write threw → bump attempts; past the
///      cap the entry becomes `failed` (surfaced with retry).
struct PendingChatQueue: Equatable {
    /// Give up after this many delivery attempts and surface the entry as
    /// failed. Three covers a transient reconnect blip without spamming the
    /// agent if the box is genuinely unreachable.
    static let maxAttempts = 3

    private(set) var bySession: [String: [PendingChat]] = [:]

    init(bySession: [String: [PendingChat]] = [:]) {
        self.bySession = bySession
    }

    /// All entries for a session in insertion order (oldest first).
    func entries(for sessionID: String) -> [PendingChat] {
        bySession[sessionID] ?? []
    }

    /// True when `localID` is still pending (not yet delivered). Drives the
    /// transcript echo's `pending`/`failed` indicator.
    func isPending(_ localID: String, in sessionID: String) -> Bool {
        (bySession[sessionID] ?? []).contains { $0.localID == localID }
    }

    /// True when `localID` is pending AND has exhausted retries.
    func isFailed(_ localID: String, in sessionID: String) -> Bool {
        (bySession[sessionID] ?? []).contains { $0.localID == localID && $0.failed }
    }

    /// Register a freshly-sent message as pending. Idempotent on `localID`.
    mutating func enqueue(sessionID: String, localID: String, message: String, ts: String) {
        var list = bySession[sessionID] ?? []
        guard !list.contains(where: { $0.localID == localID }) else { return }
        list.append(PendingChat(localID: localID, message: message, ts: ts))
        bySession[sessionID] = list
    }

    /// Entries the shell should (re)attempt now: everything not yet marked
    /// `failed`. A `failed` entry waits for an explicit `retry` before it
    /// re-enters the flush set, so an unreachable box doesn't hammer the
    /// agent on every foreground.
    func flushable(for sessionID: String) -> [PendingChat] {
        (bySession[sessionID] ?? []).filter { !$0.failed }
    }

    /// The WS write for `localID` succeeded — drop it from the queue (ack).
    /// The shell flips the transcript echo to `done`.
    mutating func markDelivered(sessionID: String, localID: String) {
        guard var list = bySession[sessionID] else { return }
        list.removeAll { $0.localID == localID }
        if list.isEmpty { bySession[sessionID] = nil } else { bySession[sessionID] = list }
    }

    /// A delivery attempt for `localID` threw. Bump its attempt count; once
    /// it reaches `maxAttempts` the entry becomes `failed` (the shell flips
    /// the echo to `failed` + shows retry). Returns true if the entry just
    /// crossed into the failed state, so the caller can capture telemetry.
    @discardableResult
    mutating func markAttemptFailed(sessionID: String, localID: String) -> Bool {
        guard var list = bySession[sessionID],
              let idx = list.firstIndex(where: { $0.localID == localID }) else { return false }
        list[idx].attempts += 1
        let crossed = !list[idx].failed && list[idx].attempts >= Self.maxAttempts
        if crossed { list[idx].failed = true }
        bySession[sessionID] = list
        return crossed
    }

    /// User tapped retry on a failed entry — clear the failed flag and reset
    /// attempts so the next `flushable` picks it up again.
    mutating func retry(sessionID: String, localID: String) {
        guard var list = bySession[sessionID],
              let idx = list.firstIndex(where: { $0.localID == localID }) else { return }
        list[idx].failed = false
        list[idx].attempts = 0
        bySession[sessionID] = list
    }

    /// Drop an entire session's queue (session deleted / forgotten).
    mutating func clear(sessionID: String) {
        bySession[sessionID] = nil
    }
}
