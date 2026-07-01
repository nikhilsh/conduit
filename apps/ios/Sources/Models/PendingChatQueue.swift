import Foundation

/// One user chat message awaiting delivery to the agent.
///
/// The shell appends an optimistic transcript echo (a `local-\u{2026}`
/// `ConversationItem`) the instant the user hits send, then enqueues the
/// same text here. The queue survives backgrounding and process death
/// (persisted per-session), so a message typed during a reconnect window --
/// or sent the moment the user backgrounds the app -- is no longer lost.
///
/// `localID` ties the queue entry to its transcript echo: when delivery
/// succeeds the shell flips that echo from `pending` -> `done`; when it
/// ultimately fails it flips to `failed` with a retry affordance. Mirrors
/// Android `PendingChat`.
///
/// `kind` distinguishes the entry's delivery context:
///   - `normal`      = today's optimistic fire-and-deliver (NO turn active). UNCHANGED.
///   - `queuedTurn`  = held because a turn is active; flush on turn-complete (claude;
///                     also codex if not steered).
///   - `steering`    = codex entry currently being injected into the running turn.
///   - `retrying`    = a steer/send attempt failed; show "Retrying", offer the Steer button.
struct PendingChat: Codable, Equatable {
    /// The `local-\u{2026}` id of the optimistic transcript echo this entry backs.
    let localID: String
    /// The raw message text to deliver (already slash-command-filtered).
    let message: String
    /// Broker-clock-anchored timestamp string of the echo (for ordering).
    let ts: String
    /// Delivery attempts made so far. Drives the give-up -> `failed` decision.
    var attempts: Int = 0
    /// Set once the entry has exhausted retries and is surfaced as failed.
    /// A failed entry stays in the queue (so the user can retry) but is NOT
    /// auto-flushed again until the user explicitly retries it.
    var failed: Bool = false
    /// True once the WS write returned success but the BROKER has not yet
    /// acked receipt (task K). A `sent` entry stays in the queue — only a
    /// broker `chat_ack` (markDelivered) removes it — so a write that
    /// "succeeded" locally yet never flushed (app killed mid-send) is still
    /// re-attempted on the next flush. The broker dedups resends by
    /// client_msg_id (== localID), so the agent never sees a double. The
    /// bubble stays faded while `sent` and only goes solid on the ack.
    var sent: Bool = false
    /// Delivery context for this entry (spec: status enum).
    var kind: EntryKind = .normal

    enum EntryKind: String, Codable, Equatable {
        /// Normal optimistic fire-and-deliver (no active turn). Unchanged from #479.
        case normal
        /// Held because a turn is active; flush on turn-complete.
        case queuedTurn
        /// Codex entry currently being injected into the running turn via steer.
        case steering
        /// A steer/send attempt failed; offer the Steer button again.
        case retrying
    }
}

/// Pure, dependency-free state machine for the optimistic-send pending
/// queue. Holds NO transport and NO clock -- the shell injects delivery and
/// persistence -- so the queue/flush/ack/failure transitions are unit-
/// testable without a live WS. Mirrors Android `PendingChatQueue`.
///
/// State lives in `bySession`. The shell drives it with these moves:
///   1. `enqueue`              -- on send, register the message as pending.
///   2. `enqueueForActiveTurn` -- on send-while-turn-active, mark as queuedTurn.
///   3. `flushable(for:)`      -- when ready (connected + agent live), ask which
///                               entries to (re)attempt; the shell delivers each.
///   4. `flushOnTurnComplete`  -- on turn-end, return ONE queuedTurn entry.
///   5. `markDelivered`        -- the WS write succeeded -> drop the entry (ack).
///   6. `markAttemptFailed`    -- the WS write threw -> bump attempts; past the
///                               cap the entry becomes `failed` (surfaced with retry).
///   7. `markSteering`         -- set kind to .steering for a codex steer in-flight.
///   8. `markRetrying`         -- a steer failed; set kind to .retrying for re-offer.
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

    /// Register a freshly-sent message as pending with kind `.normal`.
    /// Idempotent on `localID`.
    mutating func enqueue(sessionID: String, localID: String, message: String, ts: String) {
        var list = bySession[sessionID] ?? []
        guard !list.contains(where: { $0.localID == localID }) else { return }
        list.append(PendingChat(localID: localID, message: message, ts: ts, kind: .normal))
        bySession[sessionID] = list
    }

    /// Register a freshly-sent message as pending with kind `.queuedTurn` (turn was
    /// active when the user hit send). Idempotent on `localID`.
    mutating func enqueueForActiveTurn(sessionID: String, localID: String, message: String, ts: String) {
        var list = bySession[sessionID] ?? []
        guard !list.contains(where: { $0.localID == localID }) else { return }
        list.append(PendingChat(localID: localID, message: message, ts: ts, kind: .queuedTurn))
        bySession[sessionID] = list
    }

    /// Entries the shell should (re)attempt now: `normal` entries not yet
    /// `failed`. `.queuedTurn`, `.steering`, and `.retrying` entries are
    /// NOT returned here -- they are flushed via `flushOnTurnComplete` or
    /// re-steered explicitly. This preserves #479: a `normal` entry still
    /// flushes on connect/foreground/reconnect exactly as before.
    func flushable(for sessionID: String) -> [PendingChat] {
        (bySession[sessionID] ?? []).filter { $0.kind == .normal && !$0.failed }
    }

    /// Queued-turn entries visible in the "Queued Next" panel: all entries
    /// whose kind is `.queuedTurn`, `.steering`, or `.retrying`.
    func queuedTurnEntries(for sessionID: String) -> [PendingChat] {
        (bySession[sessionID] ?? []).filter {
            $0.kind == .queuedTurn || $0.kind == .steering || $0.kind == .retrying
        }
    }

    /// On turn-complete: return the OLDEST `.queuedTurn` or `.retrying`
    /// entry for the session (not a `.steering` one -- that is already
    /// in-flight). Returns nil when there is nothing queued. The caller
    /// delivers the returned entry via the normal send path; remaining
    /// entries stay queued for the NEXT turn-complete (natural serialization).
    func flushOnTurnComplete(sessionID: String) -> PendingChat? {
        (bySession[sessionID] ?? []).first {
            $0.kind == .queuedTurn || $0.kind == .retrying
        }
    }

    /// The WS write for `localID` returned success but the broker has NOT yet
    /// acked (task K). Mark the entry `sent` (bubble stays faded) and KEEP it
    /// in the queue so an un-acked send is re-attempted on the next flush.
    /// Idempotent. A no-op if the entry is already gone (acked).
    mutating func markSent(sessionID: String, localID: String) {
        guard var list = bySession[sessionID],
              let idx = list.firstIndex(where: { $0.localID == localID }) else { return }
        list[idx].sent = true
        bySession[sessionID] = list
    }

    /// Called when an assistant reply arrives for a session, proving the broker
    /// received the user's prior message(s). Removes all non-failed `.normal`
    /// entries and returns their localIDs so the shell can flip each echo to `done`.
    /// A `chat_ack` arriving later no-ops (entry already gone). `.queuedTurn` and
    /// steer entries are NOT touched -- they may not have been delivered yet.
    ///
    /// WHY we no longer require `sent==true`: `markSent` runs async after the WS
    /// write succeeds. On the first message of a session the broker can reply
    /// (firing an AskUserQuestion turn) before `markSent` completes, leaving the
    /// entry still `sent=false`. Requiring `sent` would skip that entry and leave
    /// the bubble faded forever -- no later reply arrives to retry. An assistant
    /// reply is itself proof the broker received the prior user message(s); we do
    /// not need the local WS-write flag to confirm it. The broker dedups any
    /// resend by client_msg_id, so clearing without `sent` cannot cause a
    /// double-send. `failed` entries are preserved (user must explicitly retry);
    /// `.queuedTurn`/`.steering`/`.retrying` entries are preserved (they may be
    /// genuinely undelivered).
    mutating func drainSentNormal(sessionID: String) -> [String] {
        guard var list = bySession[sessionID] else { return [] }
        let drained = list.filter { !$0.failed && $0.kind == .normal }.map { $0.localID }
        list.removeAll { !$0.failed && $0.kind == .normal }
        if list.isEmpty { bySession[sessionID] = nil } else { bySession[sessionID] = list }
        return drained
    }

    /// The BROKER acked receipt of `localID` (chat_ack) -- drop it from the
    /// queue. The shell flips the transcript echo to `done` (solid bubble).
    /// This is the ONLY durable-delivery signal; a bare WS-write success goes
    /// through `markSent` and leaves the entry queued.
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

    /// Mark a codex entry as in-flight steer (kind -> `.steering`).
    mutating func markSteering(sessionID: String, localID: String) {
        guard var list = bySession[sessionID],
              let idx = list.firstIndex(where: { $0.localID == localID }) else { return }
        list[idx].kind = .steering
        bySession[sessionID] = list
    }

    /// A steer attempt failed -- revert to `.retrying` so the panel shows
    /// "Retrying" and offers the Steer button again.
    mutating func markRetrying(sessionID: String, localID: String) {
        guard var list = bySession[sessionID],
              let idx = list.firstIndex(where: { $0.localID == localID }) else { return }
        list[idx].kind = .retrying
        bySession[sessionID] = list
    }

    /// User tapped retry on a failed entry -- clear the failed flag and reset
    /// attempts so the next `flushable` picks it up again.
    mutating func retry(sessionID: String, localID: String) {
        guard var list = bySession[sessionID],
              let idx = list.firstIndex(where: { $0.localID == localID }) else { return }
        list[idx].failed = false
        list[idx].attempts = 0
        list[idx].sent = false
        bySession[sessionID] = list
    }

    /// Drop an entire session's queue (session deleted / forgotten).
    mutating func clear(sessionID: String) {
        bySession[sessionID] = nil
    }
}
