import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

// `TurnActivityAttributes` (the `ActivityAttributes`-conforming type
// passed to `Activity<…>.request`) lives in `TurnActivityAttributes.swift`
// so the widget extension target can compile the same declaration
// without dragging in this controller class. See that file's header
// for the cross-target rationale.

/// Bridges the `TurnActivityModel` state machine to ActivityKit.
///
/// Responsibilities:
///   - own a `TurnActivityModel` per session,
///   - subscribe to `SessionStore` changes (selected session + latest
///     conversation item) and feed them into the model,
///   - translate the model's `TurnActivityEffect`s into
///     `Activity.request` / `Activity.update` / `Activity.end` calls,
///   - persist the active `Activity.id` keyed by sessionID so we keep at
///     most one Live Activity per session even across re-binds.
///
/// **Architecture note**: the lock-screen + Dynamic Island UI lives in
/// the `ConduitWidgets` app-extension target (`apps/ios/Widgets/`). The
/// extension and this controller share the `TurnActivityAttributes` type
/// declaration (compiled into both targets — see `apps/ios/project.yml`)
/// so the system can route `Activity.request(...)` payloads to the right
/// widget.
@MainActor
public final class TurnLiveActivityController {
    /// Singleton shared with `ConduitApp` — there's exactly one active-turn
    /// surface per device, so a global is the right shape.
    public static let shared = TurnLiveActivityController()

    /// Per-session state machine. Most installs see one entry (the active
    /// session) but we keep a dictionary so concurrent sessions on iPad
    /// don't trample each other.
    private var models: [String: TurnActivityModel] = [:]

    /// `Activity.id` keyed by sessionID. Used to enforce a single
    /// concurrent activity per session: if a `.start` effect arrives
    /// while an entry exists, we end the prior activity first.
    private var activeActivityIDs: [String: String] = [:]

    /// Last-seen conversation item id per session so re-emitting the same
    /// item (idempotent stream refresh) doesn't produce duplicate updates.
    private var lastSeenItemID: [String: String] = [:]

    /// Last-seen lifecycle phase per session for the session-exit signal.
    private var lastSeenPhase: [String: String] = [:]

    /// The broker endpoint to use for Live Activity push-token registration.
    /// Set by the bridge (which owns the store) whenever it evaluates,
    /// so the controller always has the current base URL + bearer token.
    public var registrationEndpoint: StoredEndpoint?

    private init() {}

    /// Drive the controller from a `SessionStore` snapshot. Idempotent —
    /// safe to call on every store change.
    ///
    /// `conversationItem` is the most recent typed item the store is
    /// holding for the session, projected into the pure-data shape so
    /// this signature doesn't drag in the UniFFI types and break the
    /// build when ActivityKit isn't available.
    public func ingest(
        sessionID: String,
        agentName: String,
        latestItem: TurnActivityItem?,
        sessionPhase: String?
    ) {
        var model = models[sessionID, default: TurnActivityModel()]

        // Session-level exits end the activity even if the conversation
        // item stream hasn't surfaced an `.exit` row yet.
        if let phase = sessionPhase {
            let prev = lastSeenPhase[sessionID]
            lastSeenPhase[sessionID] = phase
            if phase.hasPrefix("exited") && prev != phase {
                let effect = model.sessionExited()
                apply(effect: effect, sessionID: sessionID)
                models[sessionID] = model
                return
            }
        }

        guard let item = latestItem else {
            models[sessionID] = model
            return
        }

        if lastSeenItemID[sessionID] == item.id {
            // Same item we already processed — only run the idle tick so a
            // long pause after the last tool still closes the activity.
            let effect = model.tick(now: Date())
            apply(effect: effect, sessionID: sessionID)
            models[sessionID] = model
            return
        }
        lastSeenItemID[sessionID] = item.id

        let effect = model.apply(item: item, sessionID: sessionID, agentName: agentName)
        apply(effect: effect, sessionID: sessionID)
        models[sessionID] = model
    }

    /// Single-item entry point used by `TurnLiveActivityBridge`. The
    /// bridge has already classified the item as a tool/command/exit;
    /// here we hand it straight to the per-session state machine and
    /// let it decide whether to start, update, or end. The richer
    /// `ingest(sessionID:agentName:latestItem:sessionPhase:)` path is
    /// kept for the older "view-layer fire-and-forget" call sites that
    /// already feed a phase signal alongside the latest item.
    public func observe(
        item: TurnActivityItem, in sessionID: String, agentName: String, sessionName: String = ""
    ) {
        var model = models[sessionID, default: TurnActivityModel()]
        if lastSeenItemID[sessionID] == item.id {
            // Idempotent re-emit. Tick so an idle close still fires.
            let effect = model.tick(now: Date())
            apply(effect: effect, sessionID: sessionID)
            models[sessionID] = model
            return
        }
        lastSeenItemID[sessionID] = item.id
        let effect = model.apply(
            item: item, sessionID: sessionID, agentName: agentName, sessionName: sessionName
        )
        apply(effect: effect, sessionID: sessionID)
        models[sessionID] = model
    }

    /// External "session was reaped" signal (user tapped Exit, or the
    /// harness reported `onExit`). Ends the activity without waiting for
    /// the idle timeout. `summary` becomes the done-state closing line.
    public func sessionExited(sessionID: String, summary: String? = nil) {
        guard var model = models[sessionID] else { return }
        let effect = model.sessionExited(summary: summary)
        apply(effect: effect, sessionID: sessionID)
        models[sessionID] = model
    }

    /// Re-push every live activity's current content with a fresh
    /// `syncedAt` + `staleDate`. Round-3 §2: called on every scrap of
    /// execution time the app gets (foreground, scene-phase changes, the
    /// "Tap to refresh" deep link) so the lock-screen card's freshness
    /// stamp reflects reality.
    public func refreshAll() {
        for (sessionID, model) in models {
            guard model.isActive, let state = model.contentState else { continue }
            updateActivity(state: state, sessionID: sessionID)
        }
        // Every refresh is also a hygiene pass: anything on the lock
        // screen this controller doesn't own is an orphan from a prior
        // app run and will never update again — end it.
        reapOrphanActivities()
    }

    /// Periodic tick — called from a timer in the app or driven by the
    /// store's @Observable change feed. Closes activities that have been
    /// idle past their timeout.
    public func tickAll(now: Date = Date()) {
        for (sessionID, var model) in models {
            let effect = model.tick(now: now)
            apply(effect: effect, sessionID: sessionID)
            models[sessionID] = model
        }
    }

    // MARK: - Effect application

    private func apply(effect: TurnActivityEffect, sessionID: String) {
        switch effect {
        case .noop:
            return
        case let .start(attributes, state):
            startActivity(attributes: attributes, state: state, sessionID: sessionID)
        case let .update(state):
            updateActivity(state: state, sessionID: sessionID)
        case let .end(state):
            endActivity(state: state, sessionID: sessionID)
        }
    }

    /// How long a pushed snapshot stays "fresh". Past this, iOS marks the
    /// activity stale (`context.isStale`) and the widget dims + swaps its
    /// CTA to "Tap to refresh" (round-3 §2). 9 min sits in the spec's
    /// 8–10 min window.
    public static let staleInterval: TimeInterval = 9 * 60

    /// Stamp a snapshot at push time: `syncedAt` = now is the honesty
    /// stamp the widget renders ("synced just now / Nm ago").
    private static func stamped(_ state: TurnActivityContentState) -> TurnActivityContentState {
        var s = state
        s.syncedAt = Date()
        return s
    }

    private func startActivity(
        attributes: TurnActivityAttributesData,
        state: TurnActivityContentState,
        sessionID: String
    ) {
        #if canImport(ActivityKit)
        // Defensive: if a previous activity is still alive (e.g. app was
        // backgrounded mid-turn and a stale handle leaked), tear it down
        // before requesting a new one. Mirrors Conduit's behaviour.
        if let priorID = activeActivityIDs[sessionID] {
            Task { await Self.terminateActivity(id: priorID) }
            activeActivityIDs[sessionID] = nil
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Telemetry.breadcrumb("live_activity", "start skipped: activities disabled")
            return
        }

        let attrs = TurnActivityAttributes(from: attributes)
        let content = TurnActivityAttributes.ContentState(from: Self.stamped(state))
        // Capture registration endpoint at start time so the push-token
        // task closure below can post without racing a later endpoint change.
        let endpoint = registrationEndpoint
        do {
            let activity = try Activity<TurnActivityAttributes>.request(
                attributes: attrs,
                content: ActivityContent(
                    state: content,
                    staleDate: Date().addingTimeInterval(Self.staleInterval)
                ),
                pushType: .token
            )
            activeActivityIDs[sessionID] = activity.id
            Telemetry.breadcrumb("push_la", "activity started with pushType .token",
                data: ["session": sessionID, "activityID": activity.id])

            // Consume push token updates for the lifetime of this activity.
            // Each token from the system must be registered with the broker
            // so it can target this specific Live Activity via APNs.
            Task { @MainActor in
                for await tokenData in activity.pushTokenUpdates {
                    let hex = tokenData.apnsTokenHex
                    Telemetry.breadcrumb("push_la", "LA push token received",
                        data: ["session": sessionID, "hexLen": "\(hex.count)"])
                    guard let ep = endpoint else {
                        Telemetry.breadcrumb("push_la", "LA push token: no endpoint, skipping",
                            data: ["session": sessionID])
                        continue
                    }
                    PushNotificationManager.shared.registerLAToken(
                        hex: hex, sessionID: sessionID, endpoint: ep
                    )
                }
            }
        } catch {
            // `Activity.request` throws on: simulators without a Mac host
            // recent enough, Live Activities disabled in Settings, or a
            // mismatch between the host + widget `ActivityAttributes`
            // shape. The controller stays functional and the next turn's
            // effect will retry -- but capture it so a release build that
            // silently shows no Live Activity is diagnosable from Sentry
            // (e.g. the widget extension isn't embedded in the IPA).
            Telemetry.capture(error: error, message: "Live Activity request failed", tags: ["flow": "liveactivity"], extras: ["session": sessionID])
        }
        #endif
    }

    private func updateActivity(state: TurnActivityContentState, sessionID: String) {
        #if canImport(ActivityKit)
        guard let activityID = activeActivityIDs[sessionID] else { return }
        let content = TurnActivityAttributes.ContentState(from: Self.stamped(state))
        Task {
            for activity in Activity<TurnActivityAttributes>.activities where activity.id == activityID {
                await activity.update(ActivityContent(
                    state: content,
                    staleDate: Date().addingTimeInterval(Self.staleInterval)
                ))
            }
        }
        #endif
    }

    /// How long a finished (done) card stays on the lock screen before
    /// auto-dismissing. The system default keeps ended activities up to
    /// FOUR hours — which read as "Live Activities don't make sense,
    /// that was so long ago" once a few sessions had finished (device
    /// feedback, round 4). 15 min is long enough to glance, short
    /// enough to never describe ancient history.
    public static let doneLingerInterval: TimeInterval = 15 * 60

    private func endActivity(state: TurnActivityContentState, sessionID: String) {
        #if canImport(ActivityKit)
        guard let activityID = activeActivityIDs[sessionID] else { return }
        activeActivityIDs[sessionID] = nil
        let content = TurnActivityAttributes.ContentState(from: Self.stamped(state))
        Task {
            for activity in Activity<TurnActivityAttributes>.activities where activity.id == activityID {
                // Final (done) content never goes stale — it's a finished
                // fact, not a live claim — but it must not linger for
                // hours either.
                await activity.end(
                    ActivityContent(state: content, staleDate: nil),
                    dismissalPolicy: .after(Date().addingTimeInterval(Self.doneLingerInterval))
                )
            }
        }
        Telemetry.breadcrumb("live_activity", "ended", data: ["session": sessionID])
        #endif
    }

    /// End every system activity this controller doesn't own. After an
    /// app relaunch the controller's `activeActivityIDs` is empty, so
    /// activities from the previous run are ORPHANS — nothing will ever
    /// update or end them, and they pile up on the lock screen showing
    /// hours-old "running"/"done" states (device feedback, round 4).
    /// Called at launch and from `refreshAll()` (every scene change);
    /// live turns re-request their activity as events flow, so reaping
    /// is always safe.
    public func reapOrphanActivities() {
        #if canImport(ActivityKit)
        let owned = Set(activeActivityIDs.values)
        Task {
            for activity in Activity<TurnActivityAttributes>.activities
            where !owned.contains(activity.id) {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        Telemetry.breadcrumb("live_activity", "reaped orphans")
        #endif
    }

    #if canImport(ActivityKit)
    private static func terminateActivity(id: String) async {
        for activity in Activity<TurnActivityAttributes>.activities where activity.id == id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
    #endif
}

/// Adapter helpers that convert the UniFFI-shaped `ConversationItem` into
/// the pure-data `TurnActivityItem` the model accepts. Kept in a separate
/// type so the model file stays decoupled from the Rust-core types and
/// the test target doesn't have to pull in any FFI.
public enum TurnLiveActivityMapping {
    /// Find the most recent item that should drive the activity: prefer
    /// a running tool/command, fall back to an exit so the controller
    /// can close the activity, then otherwise the newest tool/command
    /// regardless of status.
    public static func latestRelevantItem(from items: [ConversationItem]) -> TurnActivityItem? {
        guard !items.isEmpty else { return nil }
        // Scan newest → oldest. We surface the freshest tool/command so a
        // chat-only tail (assistant messages after the last tool) doesn't
        // re-open the activity.
        for raw in items.reversed() {
            if let mapped = TurnLiveActivityMapping.map(raw),
               mapped.kind == .tool || mapped.kind == .command || mapped.kind == .exit
                || mapped.kind == .pendingInput {
                return mapped
            }
        }
        return nil
    }

    static func map(_ item: ConversationItem) -> TurnActivityItem? {
        let kind: TurnActivityItem.Kind
        switch item.kind {
        case "tool":          kind = .tool
        case "command":       kind = .command
        case "message":       kind = .message
        case "exit":          kind = .exit
        case "pending_input": kind = .pendingInput
        default:              kind = .other
        }
        let timestamp = TurnLiveActivityMapping.parseTimestamp(item.ts) ?? Date()
        var interruptKind: TurnInterruptKind?
        var prompt: String?
        var optionCount = 0
        if kind == .pendingInput {
            // Handoff Part B: distinguish an n-way question (choice) from a
            // binary tool gate (permission) so the lock screen can show the
            // honest CTA. The data is heuristic — the core surfaces the same
            // `pending_input` kind for both — but `content` + `pendingOptions`
            // carry enough to classify.
            let classified = classifyPending(
                content: item.content,
                options: item.pendingOptions,
                command: item.command
            )
            interruptKind = classified.kind
            prompt = classified.prompt
            optionCount = item.pendingOptions.count
        }
        return TurnActivityItem(
            id: item.id,
            kind: kind,
            toolName: item.toolName,
            command: item.command,
            status: item.status,
            exitCode: item.exitCode,
            timestamp: timestamp,
            interruptKind: interruptKind,
            prompt: prompt,
            optionCount: optionCount
        )
    }

    /// Sentinel the Rust core prepends to a pending-input message
    /// (`core/src/conversation.rs`); stripped before display.
    private static let pendingSentinel = "[[conduit:needs-input]]"

    /// Classify a `pending_input` item as a binary permission gate or an
    /// n-way choice, and extract a concise prompt. Heuristic, biased toward
    /// `.choice` (the safe default — choice always opens the app to answer,
    /// so a mis-classified permission still resolves correctly; the inverse
    /// would offer a background Approve on a multiple-choice question, the
    /// exact bug Part B fixes).
    static func classifyPending(
        content: String, options: [String], command: String?
    ) -> (kind: TurnInterruptKind, prompt: String) {
        let prompt = pendingPrompt(content: content, command: command)
        let lower = content.lowercased()

        // Codex tool-approval prompts ("[A]pprove / [E]dit / [R]eject").
        if lower.contains("[a]pprove") || lower.contains("approve / edit / reject") {
            return (.permission, prompt)
        }

        // A small option set that reads as a yes/no decision is a
        // permission gate; user-authored options (named choices) are not.
        let gateWords: Set<String> = [
            "approve", "approved", "deny", "denied", "yes", "no", "allow",
            "disallow", "reject", "run", "skip", "cancel", "confirm", "ok",
        ]
        let normalized = options.map {
            $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !options.isEmpty, options.count <= 3,
           normalized.allSatisfy({ opt in gateWords.contains(where: { opt == $0 || opt.hasPrefix($0 + " ") }) }) {
            return (.permission, prompt)
        }

        // No explicit options + a yes/no-shaped ask ("Run …?", "Allow …?",
        // "… permission …?") is a permission gate.
        if options.count <= 2, lower.contains("?"),
           lower.contains("run ") || lower.contains("allow ") || lower.contains("permission") {
            return (.permission, prompt)
        }

        return (.choice, prompt)
    }

    /// Concise one-line prompt for the card: sentinel stripped, first
    /// non-empty line, capped. Falls back to the command, then a generic
    /// label.
    static func pendingPrompt(content: String, command: String?) -> String {
        let stripped = content.replacingOccurrences(of: pendingSentinel, with: "")
        let firstLine = stripped
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })
        if let firstLine, !firstLine.isEmpty {
            return String(firstLine.prefix(140))
        }
        if let command, !command.isEmpty { return command }
        return "Needs your input"
    }

    /// Parse the ISO-8601 timestamps the Rust core emits. Falls back to
    /// `nil` so the controller can default to `Date()` rather than
    /// blocking the lifecycle on a malformed string.
    // Cached formatters — `ISO8601DateFormatter()` is expensive to allocate and
    // this parses every conversation item; building two formatters per call
    // showed up as a CFDateFormatter CPU hang in Sentry (CONDUIT-IOS-15). Reuse
    // shared instances (ISO8601 date parsing is thread-safe once configured).
    private static let isoWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseTimestamp(_ raw: String) -> Date? {
        // The harness emits timestamps both with and without fractional seconds.
        if let d = isoWithFractional.date(from: raw) { return d }
        return isoPlain.date(from: raw)
    }
}

#if DEBUG
extension TurnLiveActivityController {
    /// Test-only inspection of the per-session model.
    func _debugModel(sessionID: String) -> TurnActivityModel? {
        models[sessionID]
    }
}
#endif
