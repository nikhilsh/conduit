import Foundation
import Observation
import UIKit

/// App-wide feature flags + experiment assignment (design handoff §2/§3).
///
/// Persisted to `UserDefaults.standard`, injected at the app root, and read
/// by:
///   - the **new-session** sheet — agent cards / effort dial / launch line
///     (§3), each an independent flag so they can ship piecemeal;
///   - the **chat shell** — the `chat-shell-v2` A/B (§2), where the resolved
///     arm decides Breathe (A) vs Signature (B).
///
/// A staff Debug menu (`ConduitDebugMenuView`) can force any value and shows
/// the computed bucket/hash/exposure state. The Settings → Labs control
/// (`ConduitLabsView`) exposes the user-facing A/B/Auto conversation-style
/// override.
@Observable
final class FeatureFlags {

    // MARK: - Chat arms (§2)

    /// The two chat-shell arms. `a` = "Breathe" (today's chat, de-cramped);
    /// `b` = "Signature" (the conduit-spine lane). The rawValue is the
    /// stable bucket id logged to telemetry.
    enum ChatArm: String, CaseIterable, Identifiable {
        case a
        case b
        var id: String { rawValue }
        /// Human label for the Debug menu / Labs control.
        var label: String { self == .a ? "Breathe (A)" : "Signature (B)" }
    }

    /// User/staff conversation-style override (Settings → Labs, `01-ab`).
    /// `auto` uses the assigned bucket; `a`/`b` are a manual LOCAL override
    /// for dogfooding that never changes the logged bucket (§2 acceptance).
    enum ChatStylePreference: String, CaseIterable, Identifiable {
        case auto
        case a
        case b
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: return "Auto"
            case .a:    return "A"
            case .b:    return "B"
            }
        }
    }

    private enum Keys {
        static let newSessionAgentCards = "conduit.flags.newSession.agentCards"
        static let newSessionEffortDial = "conduit.flags.newSession.effortDial"
        static let newSessionLaunchLine = "conduit.flags.newSession.launchLine"
        static let chatStylePreference = "conduit.flags.chat.stylePreference"
        static let chatExperimentKilled = "conduit.flags.chat.experimentKilled"
        static let chatAssignedArm = "conduit.flags.chat.assignedArm"
        static let chatStableID = "conduit.flags.chat.stableID"
        static let chatExposureLogged = "conduit.flags.chat.exposureLogged"
        static let newSessionLastEffort = "conduit.flags.newSession.lastEffort"
        static let onboardingSeenWelcome = "conduit.flags.onboarding.seenWelcome"
        static let onboardingFurthestStep = "conduit.flags.onboarding.furthestStep"
        static let onboardingGuide = "conduit.flags.onboarding.guide"
        static let replyHaptics = "conduit.flags.chat.replyHaptics"
        static let sshTunnelTransport = "conduit.flags.transport.sshTunnel"
        static let showSubagentPanel = "conduit.flags.debug.showSubagentPanel"
        static let concurrentMultiBox = "conduit.flags.transport.concurrentMultiBox"
    }

    // MARK: - Concurrent multi-box (connection-critical) — default OFF

    /// Be connected to MULTIPLE boxes at once, with every connected box's
    /// sessions live in the aggregated Active list simultaneously (first cut,
    /// iOS-only). When ON, `SessionStore` keeps a per-box `BoxConnection`
    /// (its own `ConduitClient` + delegate) and routes every session-scoped
    /// operation to the connection that OWNS that session (looked up via the
    /// existing `sessionBox[sessionID]` stamp); new sessions default to the
    /// selected/primary box.
    ///
    /// When OFF (the default), `SessionStore` runs EXACTLY today's
    /// single-connection path — one `client`, one `endpoint`; the per-box
    /// registry stays empty so every route resolves to that single client.
    /// Flipping this OFF is an instant, byte-equivalent rollback.
    var concurrentMultiBox: Bool {
        didSet { defaults.set(concurrentMultiBox, forKey: Keys.concurrentMultiBox) }
    }

    /// Static read for non-`@Observable` call sites (`SessionStore`, which
    /// isn't handed the `FeatureFlags` object). Mirrors the instance default
    /// (OFF) so the two never diverge.
    static func concurrentMultiBoxEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Keys.concurrentMultiBox) as? Bool ?? false
    }

    // MARK: - SSH tunnel transport (connection-critical) — default ON

    /// Route SSH-paired boxes through the held `SshTunnel` (core #451): the
    /// bootstrap keeps the SSH session alive and the WS/HTTP client dials
    /// `ws://127.0.0.1:<tunnel.localPort>`, so the bearer token never leaves
    /// the SSH-encrypted channel and the box needs no public broker port.
    ///
    /// When OFF, the SSH-bootstrap flow falls back to the legacy
    /// `sshBootstrap(...)` call, which spawns a fire-and-forget tunnel and
    /// (historically) dialed the same loopback port without a held handle.
    /// Token-paired boxes (`conduit://` QR pairing) are UNAFFECTED either
    /// way — only the SSH-bootstrap path consults this flag.
    var sshTunnelTransport: Bool {
        didSet { defaults.set(sshTunnelTransport, forKey: Keys.sshTunnelTransport) }
    }

    /// Static read of the SSH-tunnel flag for non-`@Observable` call sites
    /// (e.g. `SessionStore`, which isn't handed the `FeatureFlags` object).
    /// Mirrors the instance default (ON) so the two never diverge.
    static func sshTunnelTransportEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Keys.sshTunnelTransport) as? Bool ?? true
    }

    // MARK: - Subagent panel (debug) — default OFF

    /// Show the "Agents" section in the session Information tab (DEBUG only).
    /// When ON, the Information tab renders the live subagent roster delivered
    /// via the `view:"agents"` view_event. Default OFF — never clutters chat.
    var showSubagentPanel: Bool {
        didSet { defaults.set(showSubagentPanel, forKey: Keys.showSubagentPanel) }
    }

    // MARK: - New-session flags (§3) — default ON (this is the shipping design)

    /// Agent picker renders as side-by-side **cards** that tint the sheet
    /// (`new-session.agent-cards`).
    var newSessionAgentCards: Bool {
        didSet { defaults.set(newSessionAgentCards, forKey: Keys.newSessionAgentCards) }
    }
    /// Reasoning-effort picker renders as the 3-stop **dial**
    /// (`new-session.effort-dial`).
    var newSessionEffortDial: Bool {
        didSet { defaults.set(newSessionEffortDial, forKey: Keys.newSessionEffortDial) }
    }
    /// Live mono **launch line** above Start (`will run claude · medium · …`).
    var newSessionLaunchLine: Bool {
        didSet { defaults.set(newSessionLaunchLine, forKey: Keys.newSessionLaunchLine) }
    }

    // MARK: - Chat reply haptics — default ON

    /// Play a tasteful haptic tap when an agent reply **starts** (light
    /// impact) and **finishes** (success notification). ChatGPT-style but
    /// without the continuous buzz-while-generating. Default ON; surfaced in
    /// Settings → Conversation. See `ReplyHaptics.swift`.
    var replyHaptics: Bool {
        didSet { defaults.set(replyHaptics, forKey: Keys.replyHaptics) }
    }

    /// Last reasoning-effort the user picked on the effort dial (§3
    /// acceptance: "persists the last choice"). Empty until first use, in
    /// which case the sheet falls back to the agent's default. Stored as the
    /// raw API value (`low`/`medium`/`high`).
    var newSessionLastEffort: String {
        didSet { defaults.set(newSessionLastEffort, forKey: Keys.newSessionLastEffort) }
    }

    // MARK: - Onboarding state (§5)

    /// Whether the marketing **Welcome** screen has been shown on this
    /// device. Its ONLY job (per `ONBOARDING.md`) is to decide whether
    /// Welcome appears again — all other gating is driven from live broker
    /// state, never from this flag.
    var onboardingSeenWelcome: Bool {
        didSet { defaults.set(onboardingSeenWelcome, forKey: Keys.onboardingSeenWelcome) }
    }
    /// Furthest onboarding step reached (0 Welcome · 1 Install · 2 Pair · 3
    /// Done) so a quit mid-setup resumes at the furthest incomplete step.
    var onboardingFurthestStep: Int {
        didSet { defaults.set(onboardingFurthestStep, forKey: Keys.onboardingFurthestStep) }
    }
    /// "Guide me" (true) vs "I know my way" (false) — scales the hand-holding.
    var onboardingGuide: Bool {
        didSet { defaults.set(onboardingGuide, forKey: Keys.onboardingGuide) }
    }

    // MARK: - Chat A/B state (§2)

    /// User/staff override. Persisted. `auto` defers to the assigned bucket.
    var chatStylePreference: ChatStylePreference {
        didSet { defaults.set(chatStylePreference.rawValue, forKey: Keys.chatStylePreference) }
    }

    /// Kill-switch (§2 guardrail). When true, EVERYONE falls back to arm A
    /// regardless of bucket or local override. Staff-flippable in Debug.
    var chatExperimentKilled: Bool {
        didSet { defaults.set(chatExperimentKilled, forKey: Keys.chatExperimentKilled) }
    }

    /// The deterministically-assigned bucket for this install. Computed once
    /// from a stable id and **persisted** — never re-bucketed on the same
    /// install (§2 acceptance: a bucketed user sees a stable arm).
    private(set) var chatAssignedArm: ChatArm

    /// Stable per-device id the bucket hashes over. Conduit has no accounts,
    /// so this is a device-local id (the vendor id, persisted) — never an
    /// account id.
    let chatStableID: String

    /// Whether the one-per-install exposure event has been logged.
    private var chatExposureLogged: Bool {
        didSet { defaults.set(chatExposureLogged, forKey: Keys.chatExposureLogged) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        self.newSessionAgentCards = defaults.object(forKey: Keys.newSessionAgentCards) as? Bool ?? true
        self.newSessionEffortDial = defaults.object(forKey: Keys.newSessionEffortDial) as? Bool ?? true
        self.newSessionLaunchLine = defaults.object(forKey: Keys.newSessionLaunchLine) as? Bool ?? true
        self.newSessionLastEffort = defaults.string(forKey: Keys.newSessionLastEffort) ?? ""

        self.onboardingSeenWelcome = defaults.object(forKey: Keys.onboardingSeenWelcome) as? Bool ?? false
        self.onboardingFurthestStep = defaults.object(forKey: Keys.onboardingFurthestStep) as? Int ?? 0
        self.onboardingGuide = defaults.object(forKey: Keys.onboardingGuide) as? Bool ?? true

        self.replyHaptics = defaults.object(forKey: Keys.replyHaptics) as? Bool ?? true
        self.sshTunnelTransport = defaults.object(forKey: Keys.sshTunnelTransport) as? Bool ?? true
        self.showSubagentPanel = defaults.object(forKey: Keys.showSubagentPanel) as? Bool ?? false
        self.concurrentMultiBox = defaults.object(forKey: Keys.concurrentMultiBox) as? Bool ?? false

        self.chatStylePreference = (defaults.string(forKey: Keys.chatStylePreference)
            .flatMap(ChatStylePreference.init(rawValue:))) ?? .auto
        self.chatExperimentKilled = defaults.object(forKey: Keys.chatExperimentKilled) as? Bool ?? false
        self.chatExposureLogged = defaults.object(forKey: Keys.chatExposureLogged) as? Bool ?? false

        // Stable DEVICE id (no accounts): reuse the persisted one, else seed
        // from the vendor id (stable per install), else a fresh UUID. Persist
        // so the bucket never moves even if `identifierForVendor` later changes.
        let stableID: String
        if let stored = defaults.string(forKey: Keys.chatStableID) {
            stableID = stored
        } else {
            let seed = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            defaults.set(seed, forKey: Keys.chatStableID)
            stableID = seed
        }
        self.chatStableID = stableID

        // Assignment is computed once and persisted. If a value is already
        // stored, honour it verbatim (never re-bucket the same install).
        if let stored = defaults.string(forKey: Keys.chatAssignedArm),
           let arm = ChatArm(rawValue: stored) {
            self.chatAssignedArm = arm
        } else {
            let arm = Self.bucket(for: stableID)
            defaults.set(arm.rawValue, forKey: Keys.chatAssignedArm)
            self.chatAssignedArm = arm
        }
    }

    // MARK: - Resolution

    /// The arm the chat shell should actually render right now (§2):
    ///   - kill-switch on → always **A** (safe evolution);
    ///   - local override `a`/`b` → that arm (does NOT change the bucket);
    ///   - `auto` → the persisted assigned bucket.
    var resolvedChatArm: ChatArm {
        if chatExperimentKilled { return .a }
        switch chatStylePreference {
        case .a:    return .a
        case .b:    return .b
        case .auto: return chatAssignedArm
        }
    }

    /// The 32-bit hash the bucket is derived from — surfaced in Debug so a
    /// tester can sanity-check the assignment.
    var chatBucketHash: UInt32 { Self.fnv1a(chatStableID) }

    /// Log the `chat-shell-v2` exposure event exactly once per install, the
    /// first time the chat shell mounts for a bucketed user (§2). Logs the
    /// assigned bucket + resolved arm + whether an override is active.
    /// Idempotent — safe to call on every chat mount.
    func logChatExposureIfNeeded() {
        guard !chatExposureLogged else { return }
        chatExposureLogged = true
        Telemetry.debug("experiment", "chat-shell-v2 exposure", data: [
            "experiment": "chat-shell-v2",
            "assigned": chatAssignedArm.rawValue,
            "resolved": resolvedChatArm.rawValue,
            "preference": chatStylePreference.rawValue,
            "killed": String(chatExperimentKilled),
            "hash": String(chatBucketHash),
        ])
    }

    // MARK: - Onboarding routing (§5)

    /// Where launch routing should send the user.
    ///
    /// **Conduit has no accounts / sign-in** — trust is established
    /// device-to-broker through the pairing handshake, and the pairing key
    /// lives on THIS device. So there is no `signedIn` concept and no cloud
    /// "my machines" list: routing is gated purely on device-local state.
    /// An auth wall must never precede onboarding.
    enum OnboardingRoute: Equatable {
        case none       // Home (offline banner handled elsewhere when unreachable)
        case full       // Welcome → Install → Pair (no broker paired on this device)
    }

    /// First-matching-rule-wins launch routing. Pure + testable. Signals are
    /// device-local only:
    ///   - `pairedBrokers` — count of brokers this device holds a key for
    ///   - `brokerReachable` — at least one paired broker online right now
    ///
    /// Rules:
    ///   1. `pairedBrokers == 0`        → **full** onboarding (Welcome shows
    ///      only if `!seenWelcome`, else enter at Install — see
    ///      `onboardingInitialStep`).
    ///   2. paired but `!brokerReachable` → **none** (Home + "broker offline"
    ///      banner; let it wake — never re-onboard).
    ///   3. paired and reachable          → **none** (Home / Sessions).
    ///
    /// The old "existing account, new device → pair-only" fast-path is gone:
    /// without accounts a brand-new device starts fresh and pairs the brokers
    /// it will talk to (the accepted tradeoff).
    static func onboardingRoute(
        pairedBrokers: Int,
        brokerReachable: Bool
    ) -> OnboardingRoute {
        pairedBrokers == 0 ? .full : .none
    }

    /// The step the wizard should open on, honouring resume and the once-ever
    /// Welcome: full route enters at Welcome only if it hasn't been seen, else
    /// at the furthest incomplete step (min Install).
    func onboardingInitialStep(for route: OnboardingRoute) -> Int {
        switch route {
        case .none:
            return OnboardingStep.done.rawValue
        case .full:
            let floor = onboardingSeenWelcome ? OnboardingStep.install.rawValue : OnboardingStep.welcome.rawValue
            return max(floor, min(onboardingFurthestStep, OnboardingStep.pair.rawValue))
        }
    }

    /// Onboarding step indices — shared by the routing math and the wizard.
    enum OnboardingStep: Int { case welcome = 0, install = 1, pair = 2, done = 3 }

    // MARK: - Deterministic bucketing

    /// 50/50 bucket from a stable id: low bit of an FNV-1a hash. Deterministic
    /// and stable across launches (unlike Swift's per-process-seeded
    /// `hashValue`), so the same id always lands in the same arm.
    static func bucket(for id: String) -> ChatArm {
        (fnv1a(id) & 1) == 0 ? .a : .b
    }

    /// FNV-1a 32-bit over the UTF-8 bytes. Small, dependency-free, stable.
    static func fnv1a(_ s: String) -> UInt32 {
        var hash: UInt32 = 0x811c_9dc5
        for byte in s.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
    }
}
