import Foundation
import Observation
import UIKit

// MARK: - Conversation timestamp ordering
//
// Mirror of Android `tsEpochMillis` / `List.sortedByConversationTs`. Chat
// items are ordered by their RFC3339 `ts`, but a raw String compare mis-sorts
// when timestamps carry different offsets (`+09:00` vs `Z`) or fractional
// precision, and an empty `ts` (a live, not-yet-persisted item) has no natural
// place. Parse to epoch seconds instead; empty/unparseable sorts as the NEWEST
// so an in-flight reply stays BELOW the user echo that triggered it (device
// bug: agent reply rendered above the user's prompt).
//
// Normalization: the broker stamps user-prompt transcript entries with Go's
// time.RFC3339Nano (nanosecond precision, 1-9 fractional digits, trailing
// zeros trimmed). iOS ISO8601DateFormatter only handles exactly 3 fractional
// digits (withFractionalSeconds) or zero. Everything else parses as nil and
// was sorting to .greatestFiniteMagnitude (newest slot), placing the user
// answer BELOW the agent reply. Fix: normalize the fractional-seconds
// component to exactly 3 digits before handing to the formatter.
// Android's Instant.parse handles nanoseconds natively, so Android is fine.
private let conduitTsFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let conduitTsPlain = ISO8601DateFormatter()

// Matches the fractional-seconds group immediately before the timezone
// designator in an RFC3339 string: e.g. ".123456789" in
// "2026-07-02T14:49:00.123456789Z" or ".5" in "...T10:00:00.5+09:00".
// The timezone portion is captured (group 2) so we can reassemble the string.
private let conduitTsFractionalRegex: NSRegularExpression = {
    // Pattern: literal dot, one-or-more digits (group 1), then the tz (group 2).
    // Timezone is Z or +/-HH:MM (RFC3339 only allows these two forms).
    // Raw string: \. = literal dot in regex; \d = digit class; [+-] = char class.
    try! NSRegularExpression(pattern: #"\.(\d+)(Z|[+-]\d{2}:\d{2})$"#)
}()

/// Normalizes fractional seconds to exactly 3 digits (truncating or
/// zero-padding) so ISO8601DateFormatter withFractionalSeconds can parse
/// RFC3339 strings with any number of fractional digits (1-9).
/// Returns the original string unchanged if there are no fractional seconds.
private func conduitNormalizeFractionalSeconds(_ ts: String) -> String {
    let nsTs = ts as NSString
    let range = NSRange(location: 0, length: nsTs.length)
    guard let match = conduitTsFractionalRegex.firstMatch(in: ts, range: range) else {
        return ts // no fractional component — return as-is for plain formatter
    }
    let fracRange = match.range(at: 1)
    let tzRange = match.range(at: 2)
    guard fracRange.location != NSNotFound, tzRange.location != NSNotFound else {
        return ts
    }
    let frac = nsTs.substring(with: fracRange) // e.g. "123456789" or "5"
    let tz = nsTs.substring(with: tzRange)     // e.g. "Z" or "+09:00"

    // Truncate to 3 digits or pad with trailing zeros to reach 3.
    let normalized: String
    if frac.count >= 3 {
        normalized = String(frac.prefix(3))
    } else {
        normalized = frac + String(repeating: "0", count: 3 - frac.count)
    }

    // Reassemble: everything before the "." + "." + normalized + timezone.
    let dotPos = match.range(at: 0).location // start of whole match (the ".")
    let prefix = nsTs.substring(to: dotPos)
    return "\(prefix).\(normalized)\(tz)"
}

// Thread-safe memoization cache for conduitConversationTsEpoch.
// The same ts strings re-appear on every refresh (every streamed delta
// re-merges the full transcript). Caching collapses repeated ICU parses
// (~50 us each) to a dictionary lookup, eliminating the main-thread hang
// reported in Sentry (App Hang up to 12 s, sortedByConversationTs / ICU).
// Called from both the @MainActor and Task.detached, hence the lock.
// The lock also serialises access to conduitTsFractional / conduitTsPlain,
// which (like all NSFormatter subclasses) are not safe for concurrent use.
private let conduitTsEpochCacheLock = NSLock()
private var conduitTsEpochCache: [String: Double] = [:]

func conduitConversationTsEpoch(_ ts: String) -> Double {
    if ts.isEmpty { return .greatestFiniteMagnitude }
    conduitTsEpochCacheLock.lock()
    defer { conduitTsEpochCacheLock.unlock() }
    if let cached = conduitTsEpochCache[ts] { return cached }
    // Normalize fractional seconds to exactly 3 digits so the fractional
    // formatter can handle Go's RFC3339Nano output (1-9 variable digits).
    let normalized = conduitNormalizeFractionalSeconds(ts)
    let epoch: Double
    if let d = conduitTsFractional.date(from: normalized) {
        epoch = d.timeIntervalSince1970
    } else if let d = conduitTsPlain.date(from: normalized) {
        epoch = d.timeIntervalSince1970
    } else {
        epoch = .greatestFiniteMagnitude
    }
    conduitTsEpochCache[ts] = epoch
    return epoch
}

/// A fractional-precision RFC3339 string for the supplied epoch — used to
/// stamp the optimistic user echo one tick past the newest known item.
func conduitConversationTsString(epoch: Double) -> String {
    conduitTsFractional.string(from: Date(timeIntervalSince1970: epoch))
}

extension Array {
    /// Stable chronological sort by an epoch-normalized `ts` accessor. Equal
    /// keys preserve arrival order (mirrors Android's index tie-break).
    ///
    /// Uses a decorate-sort-undecorate (Schwartzian) transform so
    /// `conduitConversationTsEpoch` (ISO8601 parse) runs O(n) rather than
    /// O(n log n). With 100+ items this was the top hang source: date parsing
    /// fired on every comparator call inside the sort.
    func sortedByConversationTs(_ ts: (Element) -> String) -> [Element] {
        let decorated = enumerated().map { (offset: $0.offset, element: $0.element, epoch: conduitConversationTsEpoch(ts($0.element))) }
        return decorated.sorted { a, b in
            a.epoch != b.epoch ? a.epoch < b.epoch : a.offset < b.offset
        }.map { $0.element }
    }
}

/// Harness reachability state. The Rust `connect()` just stores a delegate
/// — it doesn't actually prove the server is reachable — so we keep a
/// separate `.linked` (handshake done, not yet verified) and `.live`
/// (at least one round-trip succeeded). Session creation flips us into
/// `.live` on the first success.
///
/// `.reconnecting` is driven by the Rust core's per-session reconnect
/// worker: a transient drop becomes "Reconnecting (2/5)…" rather than
/// "Offline" and recovers automatically.
enum HarnessState: Equatable {
    case disconnected
    case connecting
    case linked
    case live
    case reconnecting(attempt: UInt32, maxAttempts: UInt32)
    case failed(String)

    /// Short label suitable for a status badge.
    var badgeLabel: String {
        switch self {
        case .disconnected:                       return "Disconnected"
        case .connecting:                         return "Connecting…"
        case .linked:                             return "Paired"
        case .live:                               return "Live"
        case .reconnecting(let a, let m):         return "Reconnecting (\(a)/\(m))…"
        case .failed:                             return "Offline"
        }
    }

    /// Long error description for the failed state, if any.
    var failureReason: String? {
        if case let .failed(reason) = self { return reason }
        return nil
    }

    /// True once the app has actually proven the harness can answer.
    var isReachable: Bool {
        switch self {
        case .linked, .live: return true
        default: return false
        }
    }

    /// True once the user can issue commands (create sessions, etc).
    /// Keep allowing commands while reconnecting — the outbound channel
    /// queues messages until the new socket is in place, so the user
    /// can keep typing through a blip.
    var canIssueCommands: Bool {
        switch self {
        case .linked, .live, .reconnecting: return true
        default: return false
        }
    }
}

/// Per-session lifecycle, distinct from the overall harness state.
/// Driven by both client API calls and incoming `SessionStatus` deltas.
enum SessionLifecycle: Equatable {
    case creating
    case live
    case exited(Int32)
    case failed(String)
}

struct StoredEndpoint: Equatable {
    var url: String
    var token: String

    static let empty = StoredEndpoint(url: "", token: "")

    var isComplete: Bool { !url.isEmpty && !token.isEmpty }

    /// Sanitized host display (strips ws[s]:// and trailing slash).
    var displayHost: String {
        var s = url
        for prefix in ["wss://", "ws://", "https://", "http://"] {
            if s.lowercased().hasPrefix(prefix) {
                s.removeFirst(prefix.count)
                break
            }
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? "(no endpoint)" : s
    }

    /// HTTP(S) base for resolving relative paths the server sends back
    /// (`/preview/<uuid>/`, `/memory/sessions/<uuid>.html`). The ws/wss
    /// URL we store is converted scheme-only; host + port are preserved.
    var httpBaseURL: URL? {
        guard var components = URLComponents(string: url) else { return nil }
        switch components.scheme?.lowercased() {
        case "ws":   components.scheme = "http"
        case "wss":  components.scheme = "https"
        case "http", "https": break
        default: return nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

/// One-shot UI cue triggered after a pairing completes.
/// `Identifiable` so it can drive `.sheet(item:)` cleanly — when the
/// sheet dismisses, the binding clears this back to nil and stale
/// pairings don't re-trigger the sheet on next launch.
struct PendingAgentPick: Identifiable, Equatable {
    let id: UUID = UUID()
    let hostNote: String
}

/// Non-secret SSH coordinates for a saved server. Stored alongside the
/// SavedServer so self-heal can look up the credential without asking the user.
/// The secret itself lives in SshCredentialStore (Keychain-backed).
struct SshEndpointRef: Codable, Equatable {
    var host: String
    var port: UInt16
    var username: String
}

/// Optional status field on a saved server. nil (absent in older persisted
/// blobs) decodes as nil and is treated as .ready everywhere.
enum SavedServerStatus: Codable, Equatable {
    case ready
    case failed(reason: String)
}

struct SavedServer: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var endpoint: StoredEndpoint
    var isDefault: Bool
    /// Non-secret SSH coordinates, present when this server was paired via SSH.
    /// nil for token-paired (conduit://) boxes. Populated by connectViaSSH so
    /// self-heal can rebuild SshCredentials without user input.
    var ssh: SshEndpointRef?
    /// Bootstrap status. nil means .ready (backward-compatible: old blobs
    /// that lack this field decode to nil and are treated as ready).
    var status: SavedServerStatus?
}

struct RemoteDirectoryEntry: Codable, Equatable, Identifiable {
    var name: String
    var path: String
    var is_dir: Bool
    var id: String { path }
}

struct RemoteDirectoryListing: Codable, Equatable {
    var path: String
    var parent: String
    var entries: [RemoteDirectoryEntry]
}

/// Wire shape of `GET /api/fs/harness-status?path=` — whether a directory
/// already carries an agent harness (CLAUDE.md / AGENTS.md). Powers the
/// "Set up agent harness" chip (Part B); `fs/list` is dirs-only so it can't
/// surface these files.
struct RemoteHarnessStatus: Codable, Equatable {
    var has_claude_md: Bool
    var has_agents_md: Bool
    var has_harness: Bool
}

/// Wire shape of `GET /api/session/conversation/<id>` (broker PR #196).
/// The persisted transcript is a flat list of role/content/ts/files
/// rows — the same `conversation.jsonl` the broker replays into a live
/// WS, exposed read-only over HTTP for exited sessions.
struct RemoteConversationFile: Codable, Equatable {
    var path: String
    var rev: String?
}

struct RemoteConversationItem: Codable, Equatable {
    var role: String
    var content: String
    var ts: String?
    var files: [RemoteConversationFile]?
}

struct RemoteConversation: Codable, Equatable {
    var items: [RemoteConversationItem]
}

/// Extended paginated response shape for
/// `GET /api/session/conversation/<id>?tail=N` and
/// `GET /api/session/conversation/<id>?before_ts=T&limit=N`.
/// Old brokers omit `has_more_before` and `oldest_ts` — they decode to
/// `false` / `0` so pagination never fires against an un-redeployed broker.
struct RemoteConversationPage: Codable {
    var items: [RemoteConversationItem]
    /// `false` means start of history reached; missing field on old brokers
    /// decodes as `false`.
    var hasMoreBefore: Bool
    /// Epoch-millisecond timestamp of items[0]; 0 if items is empty.
    var oldestTs: Int64

    enum CodingKeys: String, CodingKey {
        case items
        case hasMoreBefore = "has_more_before"
        case oldestTs = "oldest_ts"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([RemoteConversationItem].self, forKey: .items)
        hasMoreBefore = (try? c.decode(Bool.self, forKey: .hasMoreBefore)) ?? false
        oldestTs = (try? c.decode(Int64.self, forKey: .oldestTs)) ?? 0
    }
}

/// Wire shape of `GET /api/sessions` — the broker's authoritative
/// in-memory live-session set. Mirrors `broker/internal/session.LiveSessionInfo`.
/// A reconnecting client reconciles against this: only `running` rows
/// belong in the ACTIVE list; saved sessions absent here have died and
/// fall through to History. `started_at` / `last_activity_at` are the
/// broker's REAL timestamps (preserved across recovery), so the home list
/// shows true "created / last active" times rather than the reattach moment.
struct LiveSessionInfo: Codable, Equatable {
    var id: String
    var assistant: String
    var phase: String
    var health: String
    var running: Bool
    // Recoverable: true when opening the session yields an interactive agent —
    // either it is live now, or it is a cold on-disk session the broker would
    // respawn cleanly on /ws open. Drives Resume on otherwise read-only rows.
    // Optional for back-compat with brokers that don't send the field.
    var recoverable: Bool?
    var rows: UInt16
    var cols: UInt16
    var viewers: Int
    var title: String?
    var cwd: String?
    var startedAt: String?
    var lastActivityAt: String?

    enum CodingKeys: String, CodingKey {
        case id, assistant, phase, health, running, recoverable, rows, cols, viewers, title, cwd
        case startedAt = "started_at"
        case lastActivityAt = "last_activity_at"
    }
}

struct LiveSessionsResponse: Codable, Equatable {
    var sessions: [LiveSessionInfo]
    // Cold on-disk sessions that are not live now but would respawn cleanly on
    // open. Absent on older brokers (nil → no Resume offered, read-only as before).
    var recoverable: [LiveSessionInfo]?
}

/// Raised by `fetchConversation` when the broker has no persisted
/// transcript for the session — either the session predates the #196
/// redeploy (the `conversation.jsonl` was never written) or the id is
/// unknown. The viewer renders a friendly "no saved transcript" state
/// for this case instead of a generic error.
struct ConversationNotFoundError: LocalizedError {
    var errorDescription: String? { "No saved transcript for this session." }
}

extension StoredEndpoint: Codable {}

// MARK: - AgentDescriptor (WS-3.1)
//
// Per-assistant capability descriptor from `GET /api/capabilities` `agents`
// map (broker PR #440). Mirrors `broker/internal/session.AgentDescriptor`.
// All fields are optional-with-defaults so older brokers that omit them
// silently fall back to today's hardcoded behaviour.

struct AgentDescriptorSupports: Decodable, Equatable {
    /// Whether `/compact` is available for this agent.
    var compact: Bool
    /// Whether `/clear` (in-session context reset) is available. Optional:
    /// `nil` means the broker is too old to state it, so callers fall back to
    /// `compact` as a proxy (any backend with compact almost certainly also
    /// clears). Distinct from `compact` because a backend can support one
    /// without the other (broker `BackendCapabilities.Clear`, PR #844).
    var clear: Bool?
    /// Whether `ask_user_question` is supported.
    var askUserQuestion: Bool
    /// Whether the reasoning-effort dial / picker should be shown.
    var effort: Bool
    /// Whether plan-mode (`--permission-mode plan`) is available.
    var planMode: Bool
    /// Whether the account-usage / limits card has a data source.
    var usage: Bool
    /// Whether `turn/steer` injection is available (codex app-server only).
    /// When true the "Queued Next" panel shows the "Steer" button and the
    /// send button becomes the steer glyph while a turn is active.
    /// Default false so older brokers and claude sessions are unaffected.
    var steer: Bool

    enum CodingKeys: String, CodingKey {
        case compact
        case clear
        case askUserQuestion = "ask_user_question"
        case effort
        case planMode = "plan_mode"
        case usage
        case steer
    }

    init(
        compact: Bool = false,
        clear: Bool? = nil,
        askUserQuestion: Bool = false,
        effort: Bool = true,
        planMode: Bool = false,
        usage: Bool = false,
        steer: Bool = false
    ) {
        self.compact = compact
        self.clear = clear
        self.askUserQuestion = askUserQuestion
        self.effort = effort
        self.planMode = planMode
        self.usage = usage
        self.steer = steer
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        compact         = try c.decodeIfPresent(Bool.self, forKey: .compact)         ?? false
        clear           = try c.decodeIfPresent(Bool.self, forKey: .clear)
        askUserQuestion = try c.decodeIfPresent(Bool.self, forKey: .askUserQuestion) ?? false
        effort          = try c.decodeIfPresent(Bool.self, forKey: .effort)          ?? true
        planMode        = try c.decodeIfPresent(Bool.self, forKey: .planMode)        ?? false
        usage           = try c.decodeIfPresent(Bool.self, forKey: .usage)           ?? false
        steer           = try c.decodeIfPresent(Bool.self, forKey: .steer)           ?? false
    }
}

struct AgentDescriptor: Decodable, Equatable {
    /// Human-readable name ("Claude", "Codex"). May differ from the
    /// registry key ("claude") used throughout the app.
    var displayName: String
    /// OAuth provider key ("anthropic" / "openai" / ""). Empty = no
    /// provider-based login for this agent.
    var loginProvider: String
    var supports: AgentDescriptorSupports
    /// Model list embedded in the descriptor (same as the top-level
    /// `models[name]` list; may be empty for agents with no catalog).
    var models: [ConduitUI.AgentModel]

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case loginProvider = "login_provider"
        case supports
        case models
    }

    init(
        displayName: String = "",
        loginProvider: String = "",
        supports: AgentDescriptorSupports = AgentDescriptorSupports(),
        models: [ConduitUI.AgentModel] = []
    ) {
        self.displayName = displayName
        self.loginProvider = loginProvider
        self.supports = supports
        self.models = models
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName   = try c.decodeIfPresent(String.self,                     forKey: .displayName)   ?? ""
        loginProvider = try c.decodeIfPresent(String.self,                     forKey: .loginProvider) ?? ""
        supports      = try c.decodeIfPresent(AgentDescriptorSupports.self,    forKey: .supports)      ?? AgentDescriptorSupports()
        models        = try c.decodeIfPresent([ConduitUI.AgentModel].self,      forKey: .models)        ?? []
    }
}

// MARK: - BrokerReadiness (WS-H.1 consumer)
//
// Parsed from the `readiness` block in `GET /api/capabilities` (broker #450).
// All fields are optional so an older broker that omits the block produces
// a nil readiness value — every consumer treats nil as "unknown, no nag".

/// Per-agent readiness state reported by the broker.
struct AgentReadiness: Decodable, Equatable {
    /// The CLI binary is present on the box.
    var cliPresent: Bool
    /// The agent is signed in (credential file exists or env-key set).
    var signedIn: Bool
    /// Seconds until the credential expires; nil = permanent (API key) or unknown.
    var authExpiresInS: Int?
    /// How the credential is held: "env" (API key on box), "box" (signed in on box), or "app" (pushed from Conduit app).
    var credentialSource: String?

    enum CodingKeys: String, CodingKey {
        case cliPresent        = "cli_present"
        case signedIn          = "signed_in"
        case authExpiresInS    = "auth_expires_in_s"
        case credentialSource  = "credential_source"
    }

    init(cliPresent: Bool = false, signedIn: Bool = false, authExpiresInS: Int? = nil, credentialSource: String? = nil) {
        self.cliPresent       = cliPresent
        self.signedIn         = signedIn
        self.authExpiresInS   = authExpiresInS
        self.credentialSource = credentialSource
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cliPresent        = try c.decodeIfPresent(Bool.self,   forKey: .cliPresent)      ?? false
        signedIn          = try c.decodeIfPresent(Bool.self,   forKey: .signedIn)        ?? false
        authExpiresInS    = try c.decodeIfPresent(Int.self,    forKey: .authExpiresInS)
        credentialSource  = try c.decodeIfPresent(String.self, forKey: .credentialSource)
    }
}

/// Top-level readiness block from `/api/capabilities`.
struct BrokerReadiness: Decodable, Equatable {
    /// Broker build tag ("v0.0.120") or "dev" for hand-built boxes.
    var brokerVersion: String
    /// Node.js found at broker startup.
    var nodePresent: Bool
    /// tmux found on the broker host.
    var tmuxPresent: Bool
    /// git found on the broker host (agents need git to clone/commit).
    var gitPresent: Bool
    /// Per-agent readiness, keyed by the agent name ("claude", "codex", …).
    var agents: [String: AgentReadiness]

    enum CodingKeys: String, CodingKey {
        case brokerVersion = "broker_version"
        case nodePresent   = "node_present"
        case tmuxPresent   = "tmux_present"
        case gitPresent    = "git_present"
        case agents
    }

    init(
        brokerVersion: String = "dev",
        nodePresent: Bool = true,
        tmuxPresent: Bool = true,
        gitPresent: Bool = true,
        agents: [String: AgentReadiness] = [:]
    ) {
        self.brokerVersion = brokerVersion
        self.nodePresent   = nodePresent
        self.tmuxPresent   = tmuxPresent
        self.gitPresent    = gitPresent
        self.agents        = agents
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        brokerVersion = try c.decodeIfPresent(String.self,                     forKey: .brokerVersion) ?? "dev"
        nodePresent   = try c.decodeIfPresent(Bool.self,                       forKey: .nodePresent)   ?? true
        tmuxPresent   = try c.decodeIfPresent(Bool.self,                       forKey: .tmuxPresent)   ?? true
        gitPresent    = try c.decodeIfPresent(Bool.self,                       forKey: .gitPresent)    ?? true
        agents        = try c.decodeIfPresent([String: AgentReadiness].self,   forKey: .agents)        ?? [:]
    }
}

// MARK: - Broker-version comparison (WS-H.2)
//
// The broker stamps its build with the release tag ("v0.0.120"). The app
// compares against its own marketing version (BuildInfo.marketingVersion).
// "dev" / unparseable versions are treated as Unknown so hand-built boxes
// are never nagged.

/// Result of comparing the broker's reported version to the app minimum.
enum BrokerVersionStatus: Equatable {
    /// Version string is "dev" or otherwise unparseable — no nag.
    case unknown
    /// Broker is at or above the minimum expected version.
    case current
    /// Broker is older than the minimum expected version.
    case updateAvailable(brokerVersion: String)
}

/// Compare `brokerVersion` against `minimumVersion`.
/// Both are expected in "vMAJOR.MINOR.PATCH" form; anything else → `.unknown`.
/// "dev" or empty → `.unknown`. Visible for testing.
func brokerVersionStatus(brokerVersion: String, minimumVersion: String) -> BrokerVersionStatus {
    func parse(_ v: String) -> (Int, Int, Int)? {
        let s = v.hasPrefix("v") ? String(v.dropFirst()) : v
        let parts = s.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }
    guard
        !brokerVersion.isEmpty,
        brokerVersion != "dev",
        let bv = parse(brokerVersion),
        let mv = parse(minimumVersion)
    else { return .unknown }
    if bv < mv { return .updateAvailable(brokerVersion: brokerVersion) }
    return .current
}

// MARK: - Broker-update decision (session-safe gate)

/// What the app should do when it detects a stale broker.
enum BrokerUpdateDecision: Equatable {
    /// Not stale, or versions are unparseable — do nothing.
    case none
    /// Stale + zero live sessions + SSH paired: silent auto-update is safe.
    case silentUpdate
    /// Stale + live sessions exist + SSH paired: must warn the user first.
    case deferAndWarn
    /// Stale + token-paired box: no auto-update path; show the copy-install banner.
    case showCopyBanner
}

/// Pure, testable decision: given the staleness, live-session count, and
/// pairing type, return what the broker-update gate should do.
/// Both apps use the same logic; "dev"/unparseable versions return `.none`.
func brokerUpdateDecision(
    isStale: Bool,
    liveCount: Int,
    isSshPaired: Bool
) -> BrokerUpdateDecision {
    guard isStale else { return .none }
    guard isSshPaired else { return .showCopyBanner }
    return liveCount == 0 ? .silentUpdate : .deferAndWarn
}

/// Payload attached to `pendingBrokerUpdate` when the silent auto-update is
/// deferred because there are live sessions on the box.
struct PendingBrokerUpdate: Equatable {
    let boxID: String
    let brokerVersion: String
    let liveCount: Int
}

// MARK: - Readiness checklist item (WS-H.3)

/// One row in the post-pair readiness checklist.
struct ReadinessCheckItem: Equatable, Identifiable {
    enum Status: Equatable {
        case ok
        case notSignedIn
        case notInstalled
        case absent   // node / tmux / git missing — NOT auto-installed
    }
    let id: String          // agent key or "node" / "tmux" / "git"
    let label: String       // "Claude", "Codex", "node", "tmux", "git"
    let status: Status
    /// OAuth provider for sign-in deep-link (nil for non-agent rows).
    let loginProvider: String?
    /// True when the conduit broker will install this automatically on first
    /// session start (i.e. agent CLIs). False for infra tools (git, node,
    /// tmux) that the user must install themselves.
    var autoInstalls: Bool = false
    /// How the credential is held when signed in: "env", "box", or "app". Nil when not signed in or unknown.
    var credentialSource: String? = nil
}

/// Derive the ordered checklist from a `BrokerReadiness` block plus the live
/// agent descriptor map so display names are broker-accurate.
/// Agent rows come first (sorted by key), then infra rows (node, tmux) only
/// when absent. Visible for testing.
func readinessCheckItems(
    readiness: BrokerReadiness,
    descriptors: [String: AgentDescriptor]
) -> [ReadinessCheckItem] {
    var items: [ReadinessCheckItem] = []
    for key in readiness.agents.keys.sorted() {
        let ar = readiness.agents[key]!
        let displayName = descriptors[key]?.displayName.isEmpty == false
            ? descriptors[key]!.displayName
            : key.prefix(1).uppercased() + key.dropFirst()
        let provider = descriptors[key]?.loginProvider
        let status: ReadinessCheckItem.Status
        if !ar.cliPresent {
            status = .notInstalled
        } else if !ar.signedIn {
            status = .notSignedIn
        } else {
            status = .ok
        }
        items.append(ReadinessCheckItem(
            id: key,
            label: displayName,
            status: status,
            loginProvider: provider?.isEmpty == false ? provider : nil,
            autoInstalls: true,
            credentialSource: ar.credentialSource
        ))
    }
    // Infra rows — only flag when absent (they are subtle secondary rows).
    // node is intentionally omitted: it is a terminal-scrollback sidecar and
    // does not block running any agent.
    if !readiness.tmuxPresent {
        items.append(ReadinessCheckItem(id: "tmux", label: "tmux", status: .absent, loginProvider: nil))
    }
    if !readiness.gitPresent {
        items.append(ReadinessCheckItem(id: "git", label: "git", status: .absent, loginProvider: nil))
    }
    return items
}

/// UI-level status for the SSH-bootstrap flow. Independent of `HarnessState`
/// because bootstrap runs *before* we have an endpoint to connect to: the
/// progress line ("Starting harness…") lives in the SSH login sheet, not
/// the main pairing status.
enum SshBootstrapState: Equatable {
    case idle
    case running(message: String)
    case failed(reason: String)
}

/// Outstanding TOFU prompt presented to the user mid-bootstrap. The bridge
/// blocks on the user's tap before letting the SSH handshake continue.
struct HostKeyPrompt: Identifiable, Equatable {
    let id = UUID()
    let host: String
    let port: UInt16
    let fingerprint: String
}

/// One pinned context (file, URL, or snippet) that the composer
/// surfaces as a chip above the text field. The payload is what the
/// next `sendChat` should fold into the outgoing message; `label` is
/// the short string the chip renders. Identifiable so chip rows can
/// animate inserts/removes cleanly with `ForEach`.
struct PinnedContext: Identifiable, Equatable {
    enum Kind: String, Equatable, Codable {
        case file
        case url
        case snippet
    }
    let id: UUID
    let kind: Kind
    let label: String
    let payload: String

    init(id: UUID = UUID(), kind: Kind, label: String, payload: String) {
        self.id = id
        self.kind = kind
        self.label = label
        self.payload = payload
    }

    /// SF Symbol used by the chip view. Centralized here so chip
    /// rendering is data-driven and the model is easy to test.
    var iconName: String {
        switch kind {
        case .file:    return "doc.text"
        case .url:     return "link"
        case .snippet: return "text.quote"
        }
    }
}

/// AI-generated quick replies for a session (task #233). `replies` are
/// the short tap-able strings the broker's one-shot model produced;
/// `forMessageID` ties them to the assistant message they were generated
/// for, so a stale set (from a turn the user has since moved past) can be
/// dropped. Parsed from the broker's `view:"quick_replies"` view_event.
struct AIQuickReplies: Equatable {
    var replies: [String]
    var forMessageID: String

    /// Decode the core's flattened `on_view_event` payload: `replies` is a
    /// JSON-array string, `for_message_id` is plain. Returns nil when the
    /// payload has no usable replies (the caller then clears the chips).
    static func from(payload: [String: String]) -> AIQuickReplies? {
        guard
            let raw = payload["replies"],
            let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        let cleaned = decoded
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        return AIQuickReplies(
            replies: Array(cleaned.prefix(4)),
            forMessageID: payload["for_message_id"] ?? ""
        )
    }
}

/// One subagent entry in the live roster delivered via `view:"agents"` view_event.
/// JSON keys match the broker contract exactly (spec: subagent-panel-spec.md).
struct SubagentEntry: Equatable, Identifiable {
    var id: String { taskId }
    var taskId: String
    var name: String
    var description: String
    var status: String          // "working" | "done" | "failed"
    var lastTool: String
    var tokens: Int
    var toolUses: Int
    var durationMs: Int
    var startedAt: String
    var endedAt: String

    /// Decode a single agent object from the JSON array in the view_event payload.
    static func from(json: [String: Any]) -> SubagentEntry? {
        guard let taskId = json["task_id"] as? String, !taskId.isEmpty else { return nil }
        return SubagentEntry(
            taskId:      taskId,
            name:        json["name"]        as? String ?? "",
            description: json["description"] as? String ?? "",
            status:      json["status"]      as? String ?? "working",
            lastTool:    json["last_tool"]   as? String ?? "",
            tokens:      json["tokens"]      as? Int    ?? 0,
            toolUses:    json["tool_uses"]   as? Int    ?? 0,
            durationMs:  json["duration_ms"] as? Int    ?? 0,
            startedAt:   json["started_at"]  as? String ?? "",
            endedAt:     json["ended_at"]    as? String ?? ""
        )
    }

    /// Decode the full roster from the core's flattened `on_view_event` payload.
    /// The payload carries a single key "agents" whose value is a JSON-array string.
    static func roster(from payload: [String: String]) -> [SubagentEntry]? {
        guard
            let raw = payload["agents"],
            let data = raw.data(using: .utf8),
            let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return arr.compactMap { SubagentEntry.from(json: $0) }
    }
}

/// One live connection to a single box, owned by `SessionStore` when the
/// `concurrentMultiBox` flag is ON.
///
/// Each connected box gets its OWN `BoxConnection`: an independent
/// `ConduitClient` (per-instance in Rust — its own endpoint/token/handle map
/// and delegate, verified no global/singleton client state in
/// `core/src/lib.rs`), and its own `StoreDelegate` (stamped with `boxID` so
/// the box-scoped `onDisconnected` lands on THIS holder, not the global
/// harness). For SSH-paired boxes it also holds the `SshTunnel`, but those are
/// deferred in this first cut (see `connectBox`). Tearing one down never
/// touches another.
///
/// Sessions reconcile into the shared `SessionStore` maps keyed by session id
/// (so the existing ingest/render paths are unchanged); the existing
/// `SessionStore.sessionBox[sessionID] = server.id` stamp is what lets
/// op-routing find the owning connection again.
///
/// This type only exists on the multi-box path. The single-box path keeps
/// using `SessionStore.client` / `.endpoint` / `.sshTunnel` untouched.
@MainActor
final class BoxConnection {
    let server: SavedServer
    var client: ConduitClient
    var delegate: StoreDelegate
    /// Held SSH tunnel for an SSH-bootstrapped box (core #451), or nil for a
    /// token-paired box. Owned here so disconnecting one box releases only
    /// its own russh session / loopback listener. (SSH boxes are deferred this
    /// cut, so this is always nil for now — kept as the documented seam.)
    var tunnel: SshTunnel?
    /// This box's own harness state (the global `SessionStore.harness`
    /// continues to mirror the PRIMARY box so today's single-box banner is
    /// unchanged).
    var harness: HarnessState = .connecting

    var endpoint: StoredEndpoint { server.endpoint }

    init(server: SavedServer, client: ConduitClient, delegate: StoreDelegate, tunnel: SshTunnel? = nil) {
        self.server = server
        self.client = client
        self.delegate = delegate
        self.tunnel = tunnel
    }

    /// Stop the WS client and release any held tunnel. Idempotent.
    func teardown() {
        client.disconnect()
        if let tunnel {
            Telemetry.breadcrumb("ssh_tunnel", "multibox tunnel stop", data: ["local_port": "\(tunnel.localPort())"])
            tunnel.stop()
        }
        tunnel = nil
    }
}

@Observable
@MainActor
final class SessionStore {
    /// Persisted endpoint in the keychain so pairings survive app reinstalls.
    var endpoint: StoredEndpoint {
        didSet {
            Self.persist(endpoint)
            refreshRecentDirectories()
        }
    }

    // MARK: - Demo mode
    /// True when the user activated the in-app demo (no real server needed).
    /// Persisted so a relaunch stays in demo until the user exits.
    var isDemoMode: Bool {
        get { UserDefaults.standard.bool(forKey: "conduit.isDemoMode") }
        set { UserDefaults.standard.set(newValue, forKey: "conduit.isDemoMode") }
    }

    func activateDemo() {
        isDemoMode = true
        // Seed the store so real Usage / Recap / Activity screens light up.
        sessions = DemoData.sessions
        for session in DemoData.sessions {
            conversationLog[session.id] = DemoData.conversationBySession[session.id] ?? []
            statusBySession[session.id] = DemoData.statusBySession[session.id]
            sessionLifecycle[session.id] = .live
        }
        Telemetry.breadcrumb("demo", "activated", data: ["sessions": "\(DemoData.sessions.count)"])
    }

    func deactivateDemo() {
        isDemoMode = false
        // Remove all demo entries so no residue leaks into a real session.
        let demoIDs = Set(DemoData.sessions.map { $0.id })
        sessions = sessions.filter { !demoIDs.contains($0.id) }
        for id in demoIDs {
            conversationLog.removeValue(forKey: id)
            statusBySession.removeValue(forKey: id)
            sessionLifecycle.removeValue(forKey: id)
        }
        Telemetry.breadcrumb("demo", "deactivated")
    }

    var harness: HarnessState = .disconnected

    /// Display-only harness: applies the "assume connected" grace window so the
    /// "Reconnecting..." banner is suppressed for ~4s after app foreground. The
    /// real `harness` is always used for functional gating (send gates, etc.).
    var visibleHarness: HarnessState {
        guard suppressGraceReconnecting, case .reconnecting = harness else { return harness }
        return lastReachableHarness
    }

    var sessions: [ProjectSession] = []
    var selectedSessionID: String?
    /// Sessions whose WS worker has been parked via pause_session(). Cleared
    /// on foreground so nudgeNetworkChange() reconnects them automatically.
    private var pausedSessionIDs: Set<String> = []
    var savedServers: [SavedServer] = []
    var recentDirectories: [String] = []

    /// Display name of the currently-connected box, or nil when none is
    /// paired. Used by the agent-account rows to label per-box readiness
    /// ("Ready on <box>"). Prefers the SavedServer name (the real identity,
    /// e.g. "root@host" for SSH-tunneled boxes whose endpoint is a loopback),
    /// falling back to the endpoint's display host for token-only pairings.
    var connectedBoxName: String? {
        guard endpoint.isComplete else { return nil }
        if let matched = savedServers.first(where: { $0.endpoint == endpoint }) {
            return matched.name
        }
        return endpoint.displayHost
    }

    /// SSH-bootstrap progress. Observed by the SSH login sheet.
    var sshBootstrapState: SshBootstrapState = .idle

    /// Live SSH tunnel for an SSH-bootstrapped session (core #451). Held for
    /// the session's lifetime so the russh session — and therefore the
    /// loopback port-forward the WS dials — stays up. Dropping this would
    /// tear the SSH session down and kill the tunnel, so it is `stop()`ed and
    /// released only on disconnect / re-bootstrap. `nil` for token-paired
    /// (`conduit://`) boxes and when the SSH-tunnel flag is off (legacy path).
    private var sshTunnel: SshTunnel?

    /// True once the held tunnel has reported `isAlive() == false` (the SSH
    /// session died: network flap, server reboot, idle kill, iOS suspend).
    /// Drives a "connection to your server was lost — reconnect" affordance.
    /// Reset whenever a fresh tunnel is established. Token-paired boxes never
    /// set this (no tunnel).
    var sshTunnelLost: Bool = false

    /// Background liveness watcher for the held tunnel. Polls `isAlive()` and,
    /// on first `false`, triggers self-heal. Cancelled when the tunnel is
    /// replaced or stopped.
    private var sshTunnelWatcher: Task<Void, Never>?

    /// Single-flight guard for SSH self-heal. Prevents the liveness watcher
    /// and any concurrent reconnect path from both firing at once.
    private var isReconnecting: Bool = false

    /// Active TOFU prompt. ConduitApp observes this and presents a sheet.
    var pendingHostKey: HostKeyPrompt?

    /// Resolver for the active TOFU prompt. Wired up by the bridge; consumed
    /// by the SwiftUI sheet's Accept/Reject buttons.
    private var hostKeyResolver: ((Bool) -> Void)?

    /// Banner-style error for the most recent session-creation failure.
    /// Cleared automatically the next time the user tries again.
    var sessionCreationError: String?

    /// Sheet-independent error surfaced after the SSH bootstrap fails.
    /// Persists even when the SSH login sheet is dismissed so the user
    /// can see what went wrong from the main screen. Cleared when a new
    /// bootstrap attempt starts.
    var sshBootstrapError: String?

    /// True while the SSH login / add-box sheet is presented. The root
    /// TOFU alert in ConduitApp gates on this so the alert is not
    /// presented over the sheet (which would dismiss the sheet).
    var sshLoginSheetActive: Bool = false

    /// Per-session lifecycle. Sessions whose entry is `.creating` appear
    /// in the list as placeholders even before the server reports them.
    var sessionLifecycle: [String: SessionLifecycle] = [:]

    /// Latest SessionStatus seen for each session — drives the health badge + agent badge.
    var statusBySession: [String: SessionStatus] = [:]

    /// Append-only terminal scrollback per session. TerminalTab observes this and
    /// re-feeds the WKTerminalView on appear / after reconnect.
    var terminalBuffer: [String: Data] = [:]

    /// Session ids whose `terminalBuffer` changed since the last disk flush.
    /// Drives the coalesced write-through in `scheduleTerminalPersist`.
    private var terminalPersistDirty: Set<String> = []
    /// At most one debounced flush in flight at a time.
    private var terminalPersistScheduled = false

    /// Per-session xterm.js serialized render state, captured by
    /// `WKTerminalView.dismantleUIView` (tab switch / background) and
    /// replayed by the next attach so the user doesn't see an empty
    /// terminal waiting for live PTY bytes. ANSI string from
    /// `SerializeAddon.serialize()`. In-memory only; cross-launch
    /// persistence would need disk write-through.
    var terminalSnapshot: [String: String] = [:]

    /// Chat log per session, oldest first.
    var chatLog: [String: [ChatEvent]] = [:]
    /// Typed conversation timeline per session, oldest first.
    var conversationLog: [String: [ConversationItem]] = [:]

    /// True while the initial session reconcile is in flight (connect →
    /// `GET /api/sessions` → join). Lets the home list show a loading state
    /// instead of flashing "No sessions yet" before the broker's live set
    /// lands. Flipped false at every exit of `reconcileLiveSessions`.
    var isLoadingSessions: Bool = false

    /// Persisted past chat hydrated from the broker's `conversation.jsonl`
    /// (`GET /api/session/conversation/<id>`) when a live session is
    /// REATTACHED on launch — the broker replays only the terminal snapshot
    /// over the WS, not the chat, so without this a reattached session's
    /// prior conversation would be blank until the next turn. Kept as a
    /// sticky base that `refreshConversation` always merges under the live
    /// (Rust-core) items, so a new turn can't wipe the restored history.
    private var hydratedChat: [String: [ConversationItem]] = [:]

    // MARK: - Backward-pagination state

    /// Whether more history pages exist BEFORE the oldest currently-loaded
    /// item for a session. `false` = start of transcript reached OR old
    /// broker (no `has_more_before` field). Keyed by sessionID.
    /// Exposed for `ChatView` to gate the "load older" trigger.
    var hasMoreHistoryBySession: [String: Bool] = [:]

    /// Oldest epoch-millisecond timestamp loaded so far per session.
    /// Passed as `before_ts` to the next `fetchOlderConversation` call.
    private var oldestLoadedTsBySession: [String: Int64] = [:]

    /// True while a `fetchOlderConversation` network request is in flight
    /// for the given session. Prevents overlapping fetches.
    var isLoadingOlderBySession: [String: Bool] = [:]

    /// AI-generated quick replies per session (task #233). The broker
    /// emits a `view:"quick_replies"` view_event when an assistant turn
    /// completes; the chat composer renders these as tap-able chips,
    /// replacing the old client-side heuristic. Cleared when the user
    /// sends or a fresh assistant turn arrives.
    var quickReplies: [String: AIQuickReplies] = [:]

    /// Credential source per session. Populated when the broker emits a
    /// `view:"credential_source"` view_event indicating which credential
    /// path was used. Value is "box" (box-local login) or "app_forwarded"
    /// (the box is not logged in; the app credential is being forwarded).
    /// The chat view shows a subtle inline banner for "app_forwarded".
    var credentialSource: [String: String] = [:]

    // In-memory streaming overlay: partial assistant content being streamed
    // for the current turn, keyed by sessionID. Cleared when the final
    // on_chat_event arrives (the permanent message is then in the Rust store).
    // Old brokers never send chat_streaming events so this stays empty.
    var streamingMessage: [String: String] = [:]

    // The `turn_ts` of the currently-streaming turn per sessionID, set by
    // ingestChatStreaming and used by ingestChat to distinguish a final
    // current-turn message from a broker-replayed older transcript entry.
    // Replayed entries have a ts < streamingTurnTs and must NOT clear
    // the live streaming state. Cleared alongside streamingMessage.
    var streamingTurnTs: [String: String] = [:]

    // Current turn phase per session, sourced from the broker's turn_phase
    // view_event. Values: "writing" (streaming text), "working" (tool calls),
    // "" (thinking/waiting). Nil = no phase info from broker yet.
    var turnPhaseBySession: [String: String] = [:]

    // Accumulated thinking/reasoning text for the current turn per sessionID,
    // sourced from the broker's thinking_streaming view_event (Claude only).
    // Ephemeral: cleared alongside streamingMessage when the turn ends.
    // Never persisted into the transcript or conversationLog.
    var thinkingBySession: [String: String] = [:]

    /// IDs of `pending_input` conversation items that have been resolved via
    /// an out-of-band path (ConduitApprovalsView, lock-screen intent) and
    /// should render as ANSWERED in the inline chat card immediately —
    /// without waiting for a broker echo that may arrive seconds later.
    /// The ChatView merges this into its local `answeredPendingIDs` check.
    /// Cleared lazily when a WS echo replaces the item with status "done".
    var resolvedPendingInputIDs: Set<String> = []

    /// Fingerprints of pending-input cards the user has answered in this app
    /// launch, keyed by sessionID then fingerprint -> answer text. Persists
    /// across view dismissals (unlike ConduitChatView's @State). Reset on
    /// app restart — the HTTP transcript covers the restart path via the
    /// persisted resolution marker the broker writes into the transcript.
    private var answeredPendingBySession: [String: [String: String]] = [:]

    func markPendingInputAnswered(sessionID: String, fingerprint: String, answer: String) {
        answeredPendingBySession[sessionID, default: [:]][fingerprint] = answer
        Telemetry.breadcrumb("chat", "pending_input_answered_stored",
            data: ["sessionID": sessionID, "hasAnswer": answer.isEmpty ? "false" : "true"])
    }

    func isPendingInputAnswered(sessionID: String, fingerprint: String) -> Bool {
        answeredPendingBySession[sessionID]?[fingerprint] != nil
    }

    func answeredTextForPendingInput(sessionID: String, fingerprint: String) -> String? {
        let t = answeredPendingBySession[sessionID]?[fingerprint]
        return (t?.isEmpty == false) ? t : nil
    }

    /// Live subagent roster per session. Populated by `view:"agents"` view_events
    /// emitted by the broker on every task_started/task_progress/task_notification
    /// frame. Full snapshot — newest arrived last. Displayed in the Information
    /// tab Agents section (DEBUG-gated via FeatureFlags.showSubagentPanel).
    var subagentRosters: [String: [SubagentEntry]] = [:]

    /// Manually pinned context per session — rendered above the
    /// composer as removable chips. PR ios-composer-parity introduces
    /// the data model and the manual `pinContext` API; a follow-up PR
    /// wires drag-from-Files and snippet-from-message into it.
    var pinnedContexts: [String: [PinnedContext]] = [:]

    /// Last-known preview info per session (nil until the agent reports one).
    var preview: [String: PreviewInfo] = [:]

    /// Per-session connection health from the Rust reconnect worker.
    /// Exposed for UI affordances that want session-scoped state instead
    /// of the aggregated harness state.
    var connectionHealthBySession: [String: ConnectionHealth] = [:]

    /// Per-session agent-auth-failure flag, keyed by session id. Set when a
    /// session's chat surfaces the claude/codex 401 ("API Error: 401" /
    /// "Invalid authentication credentials" / "Failed to authenticate") as
    /// plain assistant/result text — the broker emits no typed signal this
    /// round (docs/PLAN-credential-propagate.md §D; the typed
    /// `agent_auth_required` view_event is a deferred follow-up). The value
    /// is the provider attributed to the session so the chat banner can
    /// offer "Sign in on this box". Cleared when a fresh user turn is sent
    /// (see `sendChat`) so a successful retry drops the affordance.
    var agentAuthFailure: [String: OAuthProvider] = [:]

    /// Set when a fresh pairing (deep link, QR scan, etc.) completes;
    /// drives the `AgentPickerSheet` so the user lands directly on
    /// "pick Claude or Codex" instead of an empty session list. UI
    /// resets this to nil when the sheet dismisses.
    var pendingAgentPick: PendingAgentPick?

    /// Local rename map — keyed by session id, value is the user-supplied
    /// display name. Persists in `UserDefaults` so a rename survives
    /// relaunch even though the Rust core doesn't know about it.
    var displayNames: [String: String] = SessionStore.loadDisplayNames() {
        didSet { SessionStore.persistDisplayNames(displayNames) }
    }

    /// Model alias each session was created/forked with (`--model` override),
    /// keyed by session id. The broker doesn't report a live model string, so
    /// this client-side record is the only honest source for the title menu's
    /// identity header. Absent for sessions that inherited the agent default
    /// (the UI says "default model") — never fabricated.
    var modelBySession: [String: String] = [:]

    /// Box (SavedServer.id) each session was last reconciled from.
    /// Populated in `reconcileLiveSessions` on every broker live-set
    /// fetch; keyed by session id. Survives box switches — entries are
    /// only added/updated, never wiped on disconnect. Used to:
    ///   1. Group sessions under their originating box on the home list.
    ///   2. Gate `attemptDeliver` so a message is never routed into the
    ///      wrong broker (root cause of ConduitError: UnknownSession).
    var sessionBox: [String: String] = SessionStore.loadSessionBox() {
        didSet { SessionStore.persistSessionBox(sessionBox) }
    }

    /// Broker AI-generated session titles (task: ai-session-titles) — keyed
    /// by session id, value is the short title the broker minted from the
    /// conversation's purpose, delivered as a `view:"session_title"`
    /// view_event. SEPARATE from `displayNames` (manual rename) so a manual
    /// rename always wins in `displayName(for:)`; the AI title sits just
    /// below it, above the first-message fallback. Persisted in
    /// `UserDefaults` so a history row shows the AI name even before the
    /// broker re-emits it on attach.
    var brokerTitles: [String: String] = SessionStore.loadBrokerTitles() {
        didSet { SessionStore.persistBrokerTitles(brokerTitles) }
    }

    /// Per-session optimistic-send queue: messages the user has sent that
    /// haven't been acked by a successful WS write yet. Persisted to
    /// `UserDefaults` so a backgrounding-mid-send (or a kill/relaunch) never
    /// silently drops a typed message — the device-reported "sent then
    /// backgrounded → never delivered" bug. Flushed on connect / foreground /
    /// reconnect. The transcript echo reads `pendingChats` to draw the
    /// clock / "failed" indicator. Mirror of Android `_pendingChats`.
    var pendingChats: PendingChatQueue = SessionStore.loadPendingChats() {
        didSet { SessionStore.persistPendingChats(pendingChats) }
    }

    /// Per-box set of found-session IDs the user has hidden via the overflow
    /// menu. Persisted so hidden sessions stay hidden across launches.
    /// Keyed by SavedServer.id; value is the set of `external_id` strings.
    var hiddenFoundSessions: [String: Set<String>] = SessionStore.loadHiddenFoundSessions() {
        didSet { SessionStore.persistHiddenFoundSessions(hiddenFoundSessions) }
    }

    private var client: ConduitClient?
    private var delegate: StoreDelegate?

    /// Monotonic counter incremented each time a new ConduitClient is created
    /// in `connect()`. StoreDelegate stamps itself with the value at creation
    /// time; any callback whose stamp no longer matches the live counter is from
    /// a stale old client and is silently dropped. This prevents the old client's
    /// queued `onDisconnected` (fired AFTER `connect()` created a new client and
    /// reached `.linked`) from clobbering the new harness state with `.failed`.
    fileprivate var clientGeneration: UInt64 = 0

    // MARK: - Concurrent multi-box registry (flag `concurrentMultiBox`, OFF)

    /// Live per-box connections, keyed by `SavedServer.id`. Empty on the
    /// single-box path; populated only when the flag is ON and the user
    /// connects boxes. Each holder owns its own client + delegate.
    var boxConnections: [String: BoxConnection] = [:]

    /// The box new sessions default to / the "primary" box (Settings
    /// CONNECTION becomes "which box new sessions land on"). nil falls back to
    /// the first connected box. Only consulted on the multi-box path.
    var primaryBoxID: String?

    private var foregroundObserver: NSObjectProtocol?
    private var networkReachableObserver: NSObjectProtocol?
    private var networkInterfaceObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?

    // MARK: - Foreground refresh + grace-window state (Changes 1-4)

    /// Timestamp of the most recent app-foreground event. Set by the
    /// willEnterForegroundNotification handler; read by ingestConnectionHealth
    /// to decide whether to activate the "assume connected" grace window.
    private var foregroundedAt: Date?

    /// When true, `visibleHarness` returns `lastReachableHarness` instead of
    /// the actual `.reconnecting` state, suppressing the "Reconnecting..." banner
    /// during a ~4s post-foreground grace window. Cleared when `.connected` arrives
    /// or the timer fires.
    var suppressGraceReconnecting: Bool = false

    /// Last harness state that was `.live` or `.linked`; returned by
    /// `visibleHarness` during the grace window so the connected UI stays visible.
    private var lastReachableHarness: HarnessState = .linked

    /// Active grace-window timer; cancelled on `.connected`.
    private var graceWindowTask: Task<Void, Never>?

    /// Sessions that had hydrated content at foreground time. Drained by
    /// ingestConnectionHealth(.connected) to fire a forced post-replay re-read
    /// (bypasses PR #871 empty-log gate -- calls refreshConversationOffMain
    /// directly, not through refreshSessions).
    private var sessionsNeedingPostConnectRefresh: Set<String> = []

    /// Shadow-write target: the shared Rust reducer (`core::store::SessionStoreCore`).
    /// In this PR the Swift maps above are still the read source of truth;
    /// every `ingest*` also folds the same event into `rustStore`, and a
    /// debug-build assertion in each ingest path verifies the two stay in
    /// sync. Flip `useRustStore` to false to bypass entirely if a later
    /// reducer change ships a regression — kill switch for safe rollout.
    /// PR follow-ups: (1) swap reads onto rustStore, (2) drop the Swift
    /// maps, (3) port the same shadow-write into Android `SessionStore.kt`.
    private let useRustStore = true
    let rustStore = SessionStoreCore()
    /// Serial queue for fire-and-forget Rust shadow-writes. Serial so a
    /// `rustApplyQueue.sync {}` barrier in tests drains all pending writes.
    let rustApplyQueue = DispatchQueue(label: "sh.nikhil.conduit.rust-apply", qos: .utility)

    /// View-layer coordinator wired in by `ConduitApp` so `ingestChat`
    /// can hand each terminal-shaped chat event to the streaming
    /// renderer. Optional because tests instantiate `SessionStore`
    /// without a SwiftUI host — the coordinator is then `nil` and the
    /// ingest path stays a no-op for the renderer side. ChatEvent has
    /// no id field; we synthesize a deterministic per-event key from
    /// (role, ts, content-hash) so the same event re-fed yields the
    /// same key (idempotent with the coordinator's update semantics).
    var streamingCoordinator: StreamingRendererCoordinator?

    /// Active per-user agent OAuth v2 coordinator. Set by the
    /// `ConduitAgentLoginSheet` when the user taps "Login with …";
    /// inbound `agent_login_url` / `agent_login_complete` /
    /// `agent_login_failed` view_events are routed here so the
    /// coordinator's state machine can advance regardless of which
    /// screen owns the sheet. Cleared on `succeeded` / `failed` /
    /// `cancelled` so a second login attempt picks up a fresh
    /// coordinator instance. See `docs/PLAN-AGENT-OAUTH.md` "Approach
    /// v2" and the comment block on `AgentLoginCoordinator`.
    var activeLoginCoordinator: AgentLoginCoordinator?

    init() {
        self.endpoint = Self.loadPersisted()
        self.savedServers = Self.loadSavedServers()
        self.recentDirectories = []
        if endpoint.isComplete && !savedServers.contains(where: { $0.endpoint == endpoint }) {
            upsertSavedServer(name: endpoint.displayHost, endpoint: endpoint, makeDefault: true)
        }
        refreshRecentDirectories()
        installNetworkAndLifecycleHooks()
    }

    // No deinit cleanup: SessionStore lives for the app's lifetime
    // (owned by ConduitApp's @State), so the NotificationCenter
    // observers are released only at process exit — and Swift 6 actor
    // isolation forbids touching MainActor state from a nonisolated
    // deinit anyway. The path monitor itself now lives on
    // NetworkReachabilityObserver (also app-scoped).

    /// Tell every per-session worker in the Rust core that the network
    /// path probably changed. The worker drops its current socket and
    /// re-enters the reconnect loop instead of waiting for TCP to
    /// surface the failure.
    private func nudgeNetworkChange() {
        client?.notifyNetworkChange()
        // Multi-box: nudge every connected box's reconnect worker too.
        for conn in boxConnections.values { conn.client.notifyNetworkChange() }
    }

    /// Park the WS worker for one session (it's left the foreground UI).
    /// The worker closes its socket and waits for a nudge to reconnect.
    func pauseSession(_ sessionID: String) {
        guard !pausedSessionIDs.contains(sessionID),
              let c = clientForSession(sessionID) else { return }
        pausedSessionIDs.insert(sessionID)
        try? c.pauseSession(sessionId: sessionID)
        Telemetry.breadcrumb("ws", "session paused", data: ["session": sessionID])
    }

    /// Re-arm a paused session (it's returned to the foreground UI).
    /// No-ops if the session was never paused to avoid dropping active connections.
    func resumeSession(_ sessionID: String) {
        guard pausedSessionIDs.contains(sessionID),
              let c = clientForSession(sessionID) else { return }
        pausedSessionIDs.remove(sessionID)
        try? c.resumeSession(sessionId: sessionID)
        Telemetry.breadcrumb("ws", "session resumed", data: ["session": sessionID])
    }

    /// Pause every joined session (called on app background).
    private func pauseAllSessions() {
        for s in sessions { pauseSession(s.id) }
    }

    /// Clear the paused-ID set after foreground nudge re-arms all workers.
    private func clearPausedSessions() {
        pausedSessionIDs.removeAll()
    }

    private func installNetworkAndLifecycleHooks() {
        // Three notification observers all want to call the
        // MainActor-isolated [nudgeNetworkChange]. We pass `queue: .main`
        // so the closures actually run on the main thread at runtime,
        // but the closure's static type is `@Sendable` nonisolated —
        // Swift can't prove the actor match from `queue:` alone, so we
        // tell it explicitly with `MainActor.assumeIsolated`. This is
        // safe by construction: the `OperationQueue.main` dispatch is
        // what makes the assumption true.
        let nudge: @Sendable () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                self?.nudgeNetworkChange()
            }
        }

        // App returns to foreground after a long suspend — sockets may
        // be silently dead even though our state thinks they're live.
        // Besides nudging the reconnect worker, re-pull every session's
        // conversation: a reply that landed while we were suspended only
        // exists in the broker's conversation.jsonl (live events aren't
        // replayed on re-attach), so without this the transcript stays
        // stale and the typing indicator spins forever — the "says
        // connected but never replies" bug.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Record foreground timestamp for the grace window (Change 4).
                self?.foregroundedAt = Date()
                Telemetry.breadcrumb("session", "foreground_refresh_start")
                // Clear the paused set BEFORE nudgeNetworkChange so all
                // sessions reconnect cleanly (nudge wakes parked workers).
                self?.clearPausedSessions()
                self?.nudgeNetworkChange()
                self?.refreshSessions()
                // Foregrounding may have re-armed a socket that died while
                // suspended -- flush any message the user sent right before
                // they backgrounded the app (the lost-send bug).
                self?.flushPendingChats()
                // Change 1: proactive HTTP fetch for the currently-open session.
                // Runs in parallel with the WS redial so the transcript is fresh
                // before the replay lands.
                if let sid = self?.selectedSessionID {
                    Task { @MainActor [weak self] in
                        await self?.foregroundRefreshConversation(sid)
                    }
                }
                // Change 2: reconcile live sessions on foreground. Guard against
                // an in-flight reconcile (isLoadingSessions already tracks this).
                if self?.isLoadingSessions == false {
                    self?.reconcileLiveSessions()
                } else {
                    Telemetry.breadcrumb("session", "fg_reconcile_skipped_in_flight")
                }
                // Change 3: mark sessions with hydrated content for a
                // forced post-connect re-read once WS replay has settled.
                self?.markSessionsForPostConnectRefresh()
            }
        }

        // App is about to background — flush any dirty terminal scrollback to
        // disk NOW so a subsequent kill (or our own crash) still leaves the
        // last-known terminal on disk for an instant cold-launch restore.
        // Also pause all WS workers: N idle heartbeat loops burn the CPU and
        // drain the battery while the app is in the background.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushTerminalPersist()
                self?.pauseAllSessions()
            }
        }

        // Path-level reachability is owned by NetworkReachabilityObserver
        // (instantiated at app launch by ConduitApp). We just listen for
        // the coarse `unsatisfied→satisfied` and `interface-changed`
        // edges and nudge the Rust core into immediate reconnect. The
        // old inline `NWPathMonitor` lived here; A.9 hoisted it so the
        // state machine is independently testable.
        networkReachableObserver = NotificationCenter.default.addObserver(
            forName: .networkBecameReachable,
            object: nil,
            queue: .main
        ) { _ in nudge() }
        networkInterfaceObserver = NotificationCenter.default.addObserver(
            forName: .networkInterfaceChanged,
            object: nil,
            queue: .main
        ) { _ in nudge() }
    }

    // MARK: - Convenience derived state

    /// Sessions plus any in-flight placeholders, sorted with placeholders first.
    var visibleSessions: [VisibleSession] {
        let real = sessions.map { VisibleSession.real($0) }
        let placeholderIDs = sessionLifecycle
            .filter { entry in entry.value == .creating && !sessions.contains(where: { s in s.id == entry.key }) }
            .keys
            .sorted()
        let placeholders = placeholderIDs.map { VisibleSession.creating($0) }
        return placeholders + real
    }

    // MARK: - Connection

    func connect() {
        guard endpoint.isComplete else {
            harness = .failed("Set an endpoint and token in Settings.")
            return
        }
        harness = .connecting
        clientGeneration &+= 1
        let generation = clientGeneration
        let newClient = ConduitClient(endpoint: endpoint.url, bearerToken: endpoint.token)
        let newDelegate = StoreDelegate(store: self, generation: generation)
        self.client = newClient
        self.delegate = newDelegate
        Task {
            do {
                try await newClient.connect(delegate: newDelegate)
                self.harness = .linked
                Telemetry.breadcrumb("onboarding", "endpoint_connected",
                    data: ["host": self.endpoint.displayHost,
                           "first_server": "\(self.savedServers.count == 1)"])
                // Auto-propagate device-stored agent credentials to THIS box
                // over HTTP so a box added after sign-in (or one that lost its
                // `.enc`) gets the credential before its first session — the
                // "signed in but 401 on another box" fix
                // (docs/PLAN-credential-propagate.md §A). Best-effort; the
                // helper never throws. This single-box path also covers
                // reconnect() and selectSavedServer(), which both route here.
                let connectedEndpoint = self.endpoint
                Task { await self.propagateStoredAgentCredentials(to: connectedEndpoint) }
                // Refresh capabilities so we have the broker's reported version
                // post-connect; refreshModelCatalog() runs the stale-broker
                // auto-update check (Fix: broker auto-update on reconnect).
                Task { await self.refreshModelCatalog() }
                self.refreshSessions()
                // Connection is live again — re-deliver any messages queued
                // while we were disconnected (reconnect window / backgrounded
                // mid-send / killed before the WS flushed).
                self.flushPendingChats()
                // Reconcile against the broker's authoritative live set:
                // reattach only genuinely-running agents (so they resume
                // after a cold launch / app termination) and demote any
                // saved `.live` row the broker no longer has to History.
                // The broker — not our stale local flags — decides what's
                // alive (the keep-alive model). See `reconcileLiveSessions`.
                self.reconcileLiveSessions()
            } catch {
                let detail = Self.describe(error)
                self.harness = .failed(detail)
                Telemetry.capture(
                    error: error,
                    message: "iOS harness connect failed",
                    tags: ["surface": "ios", "phase": "connect"],
                    extras: ["endpoint": self.endpoint.displayHost, "detail": detail]
                )
            }
        }
    }

    func disconnect() {
        disconnectClient()
        // Tear down any held SSH tunnel so we never leak the russh session /
        // loopback listener. No-op for token-paired boxes (tunnel is nil).
        teardownSshTunnel()
    }

    /// Tear down only the WS client, leaving any held SSH tunnel intact. Used
    /// by `reconnect()` so a WS-only blip on an SSH-tunneled box re-dials the
    /// SAME live loopback port instead of killing (and leaking) the russh
    /// session it depends on.
    private func disconnectClient() {
        client?.disconnect()
        client = nil
        delegate = nil
        harness = .disconnected
    }

    // MARK: - Concurrent multi-box (flag `concurrentMultiBox`)

    /// True only when the flag is ON. Single point of truth.
    var multiBoxEnabled: Bool { FeatureFlags.concurrentMultiBoxEnabled() }

    /// THE op-routing seam. Returns the `ConduitClient` a session-scoped
    /// operation must use:
    ///   - flag ON + the session is stamped (via the existing `sessionBox`) to
    ///     a CONNECTED box → that box's client (so the op reaches the broker
    ///     that OWNS the session, never a different one — the load-bearing
    ///     correctness invariant);
    ///   - otherwise → the single global `client` (the flag-OFF path and the
    ///     safe fallback for an unstamped / not-yet-connected session).
    ///
    /// On the flag-OFF path `boxConnections` is always empty, so this is
    /// unconditionally `self.client` — byte-equivalent to the prior code.
    func clientForSession(_ sessionID: String) -> ConduitClient? {
        if multiBoxEnabled,
           let boxID = sessionBox[sessionID],
           let conn = boxConnections[boxID] {
            return conn.client
        }
        return client
    }

    /// The box new sessions / box-targeted ops default to on the multi-box
    /// path: the explicit `primaryBoxID` if it's connected, else the first
    /// connected box, else nil.
    var primaryBoxConnection: BoxConnection? {
        guard multiBoxEnabled else { return nil }
        if let id = primaryBoxID, let conn = boxConnections[id] { return conn }
        return boxConnections.values.first
    }

    /// Whether a given saved box currently has a live multi-box connection.
    func isBoxConnected(_ serverID: String) -> Bool {
        boxConnections[serverID] != nil
    }

    /// True for an SSH-tunnel loopback endpoint (`ws://127.0.0.1:…` /
    /// `ws://localhost:…`). Such a box can only be reached through its held
    /// tunnel, so the multi-box registry (which dials directly) defers it.
    static func isLoopbackEndpoint(_ endpoint: StoredEndpoint) -> Bool {
        let host = endpoint.url.lowercased()
        return host.contains("127.0.0.1") || host.contains("://localhost")
    }

    /// Connect ONE saved box WITHOUT tearing down any other connected box.
    /// Token-paired boxes dial directly; SSH-paired (loopback) boxes are
    /// deferred this cut (skipped below). Idempotent — a second call for an
    /// already-connected box just promotes it to primary. Multi-box only.
    func connectBox(_ serverID: String) {
        guard multiBoxEnabled else { return }
        guard let server = savedServers.first(where: { $0.id == serverID }) else { return }
        if boxConnections[serverID] != nil {
            primaryBoxID = serverID
            return
        }
        guard server.endpoint.isComplete else {
            Telemetry.breadcrumb("multibox", "connect skipped (incomplete endpoint)", data: ["box": server.name])
            return
        }
        // First-cut scope: only token-paired (directly-dialable) boxes join the
        // multi-box registry. An SSH-paired box's endpoint is a
        // `ws://127.0.0.1:<port>` loopback bound to a tunnel the single-box
        // path holds — an independent per-box tunnel is deferred. Skip rather
        // than dial a dead loopback port. (See PR notes.)
        if Self.isLoopbackEndpoint(server.endpoint) {
            Telemetry.breadcrumb("multibox", "connect skipped (ssh/loopback box deferred)", data: ["box": server.name])
            return
        }
        let newClient = ConduitClient(endpoint: server.endpoint.url, bearerToken: server.endpoint.token)
        let newDelegate = StoreDelegate(store: self, boxID: serverID)
        let conn = BoxConnection(server: server, client: newClient, delegate: newDelegate)
        boxConnections[serverID] = conn
        if primaryBoxID == nil { primaryBoxID = serverID }
        Telemetry.breadcrumb("multibox", "connect box", data: [
            "box": server.name,
            "host": server.endpoint.displayHost,
            "total_connected": "\(boxConnections.count)",
        ])
        Task {
            do {
                try await newClient.connect(delegate: newDelegate)
                conn.harness = .linked
                // Auto-propagate device-stored agent credentials to THIS box
                // (using its own endpoint/token) so a freshly-connected box
                // gets the credential before its first session — §A of
                // docs/PLAN-credential-propagate.md. Best-effort; never blocks
                // or fails the connect.
                await self.propagateStoredAgentCredentials(to: server.endpoint)
                self.refreshSessions()
                // Reattach this box's genuinely-running sessions so they stream
                // live (the broker only replays over the WS on join).
                await self.reattachBoxLiveSessions(conn)
                self.flushPendingChats()
            } catch {
                let detail = Self.describe(error)
                conn.harness = .failed(detail)
                Telemetry.capture(
                    error: error,
                    message: "iOS multibox connect failed",
                    tags: ["surface": "ios", "phase": "multibox_connect"],
                    extras: ["box": server.name, "host": server.endpoint.displayHost, "detail": detail]
                )
            }
        }
    }

    /// Disconnect ONE box, leaving every other connected box untouched. Drops
    /// the holder (releasing its client), and re-aggregates the visible list.
    /// The `sessionBox` stamps are LEFT intact (they persist across box
    /// switches by design — the rows just become dimmed history for that box).
    func disconnectBox(_ serverID: String) {
        guard let conn = boxConnections[serverID] else { return }
        Telemetry.breadcrumb("multibox", "disconnect box", data: ["box": conn.server.name])
        conn.teardown()
        boxConnections[serverID] = nil
        if primaryBoxID == serverID {
            primaryBoxID = boxConnections.keys.first
        }
        refreshSessions()
    }

    /// Tear down EVERY multi-box connection (hard reset / flag flipped OFF).
    /// Single-box `client`/`endpoint` are left intact.
    func disconnectAllBoxes() {
        for (_, conn) in boxConnections { conn.teardown() }
        boxConnections.removeAll()
        primaryBoxID = nil
    }

    /// Reattach a box's genuinely-running sessions over its own client so they
    /// stream live (the broker replays the snapshot only on `joinSession`).
    /// Per-box analogue of the single-box `reconcileLiveSessions` reattach,
    /// scoped to this box's endpoint + client; best-effort.
    private func reattachBoxLiveSessions(_ conn: BoxConnection) async {
        guard let data = await getJSON(endpoint: conn.endpoint, path: "/api/sessions"),
              let decoded = try? JSONDecoder().decode(LiveSessionsResponse.self, from: data)
        else { return }
        let running = decoded.sessions.filter { $0.running }
        for info in running where !SavedSessionsStore.shared.isTombstoned(id: info.id) {
            sessionBox[info.id] = conn.server.id
            if sessionLifecycle[info.id] == nil {
                sessionLifecycle[info.id] = .creating
            }
            hydrateTerminalBuffer(info.id)
            try? await conn.client.joinSession(sessionId: info.id, assistant: info.assistant)
            let sid = info.id
            Task { @MainActor in await self.hydrateChatConversation(sid) }
        }
        refreshSessions()
    }

    /// A box's WS dropped — update only THAT box's harness, never the global
    /// banner. Mirrors the auth/disconnect classification of the single-box
    /// `ingestDisconnected`, scoped to the holder.
    func ingestBoxDisconnected(boxID: String, reason: String) {
        guard let conn = boxConnections[boxID] else { return }
        let lower = reason.lowercased()
        if lower.contains("auth") || lower.contains("401") || lower.contains("unauthorized") {
            conn.harness = .failed("Pairing expired for \(conn.server.name).")
        } else {
            conn.harness = .failed("Disconnected: \(reason)")
        }
        Telemetry.breadcrumb("multibox", "box disconnected", data: [
            "box": conn.server.name,
            "reason": Self.connectionReasonCode(from: reason),
        ])
    }

    // MARK: - SSH tunnel lifecycle (core #451)

    /// Install a freshly-bootstrapped tunnel (or clear to the legacy path when
    /// `nil`) and start the liveness watcher. Always stops the prior tunnel
    /// first so a re-bootstrap never leaks the old russh session.
    private func adoptSshTunnel(_ tunnel: SshTunnel?) {
        teardownSshTunnel()
        sshTunnel = tunnel
        sshTunnelLost = false
        guard tunnel != nil else { return }
        startSshTunnelWatcher()
    }

    /// Stop + release the held tunnel and cancel its watcher. Idempotent.
    private func teardownSshTunnel() {
        sshTunnelWatcher?.cancel()
        sshTunnelWatcher = nil
        if let tunnel = sshTunnel {
            Telemetry.breadcrumb("ssh_tunnel", "tunnel stop", data: ["local_port": "\(tunnel.localPort())"])
            tunnel.stop()
        }
        sshTunnel = nil
    }

    /// Poll the held tunnel's `isAlive()` on a slow cadence. On the first
    /// `false` (SSH session died) hand off to `attemptSshSelfHeal()` which
    /// retries with exponential backoff before falling back to `.failed`.
    private func startSshTunnelWatcher() {
        sshTunnelWatcher = Task { [weak self] in
            // ~3s cadence: cheap, non-blocking `is_closed()` check. The WS
            // reconnect worker usually notices the dead loopback dial first;
            // this is the authoritative SSH-level signal.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                guard let self, let tunnel = self.sshTunnel else { return }
                if !tunnel.isAlive() {
                    Telemetry.breadcrumb("ssh_tunnel", "tunnel lost", data: [
                        "local_port": "\(tunnel.localPort())",
                    ])
                    Telemetry.capture(
                        error: NSError(domain: "ios.ssh_tunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "tunnel lost"]),
                        message: "iOS SSH tunnel lost",
                        tags: ["surface": "ios", "phase": "ssh_tunnel"],
                        extras: ["local_port": "\(tunnel.localPort())"]
                    )
                    self.attemptSshSelfHeal()
                    return
                }
            }
        }
    }

    /// Exponential-backoff self-heal for a dropped SSH tunnel. Looks up the
    /// persisted credential for the current server (stored unconditionally on
    /// every successful bootstrap), re-runs connectViaSSH, and retries up to
    /// maxAttempts times before surfacing the terminal .failed state.
    ///
    /// Single-flight: isReconnecting prevents the liveness watcher and
    /// reconnect() from both firing concurrently.
    private func attemptSshSelfHeal() {
        guard !isReconnecting else {
            Telemetry.breadcrumb("ssh_tunnel", "self-heal skipped (already reconnecting)")
            return
        }

        // Require a saved SSH ref on the current server — token-paired boxes
        // have no SSH ref and should never trigger self-heal.
        let sshRef = savedServers.first(where: { $0.endpoint == endpoint })?.ssh
        guard let ref = sshRef else {
            Telemetry.breadcrumb("ssh_tunnel", "self-heal aborted — no ssh ref for current server")
            sshTunnelLost = true
            harness = .failed("Connection to your server was lost. Reconnect to continue.")
            return
        }

        isReconnecting = true
        sshBootstrapState = .running(message: "Reconnecting\u{2026}")

        Task { [weak self] in
            defer { self?.isReconnecting = false }

            let maxAttempts = 6
            var delaySecs: UInt64 = 2

            for attempt in 1...maxAttempts {
                guard let self else { return }
                if Task.isCancelled { return }

                Telemetry.breadcrumb("ssh_tunnel", "self-heal attempt", data: [
                    "attempt": "\(attempt)",
                    "host": ref.host,
                ])

                // Look up the persisted credential — saved unconditionally on
                // every successful bootstrap so this should always succeed.
                guard let saved = SshCredentialStore.find(host: ref.host, port: ref.port, username: ref.username) else {
                    Telemetry.breadcrumb("ssh_tunnel", "self-heal aborted — no saved credential", data: [
                        "host": ref.host, "attempt": "\(attempt)",
                    ])
                    break
                }

                let auth: SshAuth
                switch saved.kind {
                case .password:
                    auth = .password(password: saved.secret)
                case .privateKey:
                    auth = .privateKey(keyPem: saved.secret, passphrase: saved.passphrase)
                }
                let credentials = SshCredentials(
                    host: ref.host,
                    port: ref.port,
                    username: ref.username,
                    auth: auth
                )

                // connectViaSSH is already the full re-bootstrap path: it
                // disconnects, re-runs the tunnel, calls adoptSshTunnel, and
                // connects. We don't call it directly (it has its own
                // single-flight guard) — instead replicate the core logic
                // inline so self-heal bypasses the duplicate-guard check.
                let hostKeyBridge = SshHostKeyBridge(store: self, host: ref.host, port: ref.port)
                let progressBridge = SshProgressBridge(store: self, host: ref.host)

                do {
                    let preToken = UUID().uuidString
                    let useTunnel = FeatureFlags.sshTunnelTransportEnabled()
                    let result: SshBootstrapResult
                    var tunnel: SshTunnel?

                    if useTunnel {
                        Telemetry.breadcrumb("ssh_tunnel", "self-heal bootstrap start", data: ["host": ref.host])
                        let bootstrap = try await sshBootstrapTunneled(
                            credentials: credentials,
                            preAllocatedToken: preToken,
                            anthropicApiKey: "",
                            openaiApiKey: "",
                            imageRef: nil,
                            appVersion: BuildInfo.marketingVersion,
                            hostKeyDelegate: hostKeyBridge,
                            progressDelegate: progressBridge
                        )
                        result = bootstrap.result
                        tunnel = bootstrap.tunnel
                    } else {
                        result = try await sshBootstrap(
                            credentials: credentials,
                            preAllocatedToken: preToken,
                            anthropicApiKey: "",
                            openaiApiKey: "",
                            imageRef: nil,
                            appVersion: BuildInfo.marketingVersion,
                            hostKeyDelegate: hostKeyBridge,
                            progressDelegate: progressBridge
                        )
                    }

                    // Success: swap in the new endpoint/tunnel and reconnect.
                    let newEndpoint = StoredEndpoint(
                        url: "ws://127.0.0.1:\(result.localPort)",
                        token: result.token
                    )
                    // Update the saved server entry that owns this SSH ref to
                    // point to the new loopback port, and mark it default.
                    var next = self.savedServers
                    if let idx = next.firstIndex(where: { $0.ssh == ref }) {
                        next[idx].endpoint = newEndpoint
                        next[idx].isDefault = true
                        for i in next.indices where i != idx { next[i].isDefault = false }
                    } else {
                        for i in next.indices { next[i].isDefault = false }
                        next.append(SavedServer(
                            id: UUID().uuidString,
                            name: "\(ref.username)@\(ref.host)",
                            endpoint: newEndpoint,
                            isDefault: true,
                            ssh: ref
                        ))
                    }
                    self.savedServers = next
                    Self.persistSavedServers(next)
                    self.endpoint = newEndpoint
                    self.disconnect()
                    self.adoptSshTunnel(tunnel)
                    self.connect()
                    self.sshBootstrapState = .idle
                    self.sshTunnelLost = false
                    Telemetry.breadcrumb("ssh_tunnel", "self-heal succeeded", data: [
                        "attempt": "\(attempt)", "host": ref.host,
                    ])
                    return
                } catch {
                    Telemetry.breadcrumb("ssh_tunnel", "self-heal attempt failed", data: [
                        "attempt": "\(attempt)", "host": ref.host, "error": "\(error)",
                    ])
                }

                if attempt < maxAttempts {
                    if Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: delaySecs * 1_000_000_000)
                    delaySecs = min(delaySecs * 2, 30)
                }
            }

            // Exhausted all attempts — surface terminal failure.
            guard let self else { return }
            Telemetry.capture(
                error: NSError(domain: "ios.ssh_tunnel", code: 2, userInfo: [NSLocalizedDescriptionKey: "self-heal exhausted"]),
                message: "iOS SSH self-heal exhausted",
                tags: ["surface": "ios", "phase": "ssh_self_heal"],
                extras: ["host": ref.host, "attempts": "\(maxAttempts)"]
            )
            self.sshTunnelLost = true
            self.sshBootstrapState = .idle
            self.harness = .failed("Connection to your server was lost. Reconnect to continue.")
        }
    }

    /// Re-establish the link using the currently stored endpoint.
    ///
    /// If an SSH tunnel is held AND still alive, this is a WS-only restart:
    /// the tunnel is preserved so we re-dial the same live loopback port.
    /// If the tunnel is nil/dead AND the current server has an SSH ref,
    /// route through attemptSshSelfHeal (full re-bootstrap with backoff).
    /// Otherwise (token-paired box) do a plain disconnect+reconnect.
    func reconnect() {
        if let tunnel = sshTunnel, tunnel.isAlive() {
            disconnectClient()
            connect()
        } else if savedServers.first(where: { $0.endpoint == endpoint })?.ssh != nil {
            // Dead or nil tunnel on an SSH-paired server — self-heal it.
            attemptSshSelfHeal()
        } else {
            disconnect()
            connect()
        }
    }

    func listDirectories(path: String?) async throws -> RemoteDirectoryListing {
        // Proactive fast-fail: if the SSH tunnel is definitively dead, kick off
        // self-heal immediately rather than letting the network call hit a
        // refused loopback port and produce a cryptic error.
        if let tunnel = sshTunnel, !tunnel.isAlive(),
           savedServers.first(where: { $0.endpoint == endpoint })?.ssh != nil {
            Telemetry.breadcrumb("fs", "listDirectories — SSH tunnel dead, triggering self-heal",
                data: ["path": path ?? "/"])
            reconnect()
            throw NSError(domain: "SessionStore", code: 103,
                userInfo: [NSLocalizedDescriptionKey: "Lost connection to this box. Reconnecting\u{2026}"])
        }
        guard let base = endpoint.httpBaseURL else {
            throw NSError(domain: "SessionStore", code: 100, userInfo: [NSLocalizedDescriptionKey: "Invalid endpoint URL"])
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/api/fs/list"
        if let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            components?.queryItems = [URLQueryItem(name: "path", value: path)]
        }
        guard let url = components?.url else {
            throw NSError(domain: "SessionStore", code: 101, userInfo: [NSLocalizedDescriptionKey: "Failed to build directory URL"])
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "SessionStore", code: 102, userInfo: [NSLocalizedDescriptionKey: "Directory listing failed"])
        }
        return try JSONDecoder().decode(RemoteDirectoryListing.self, from: data)
    }

    /// Whether a directory already has an agent harness (CLAUDE.md / AGENTS.md).
    /// Returns nil on any failure so callers default to NOT nagging (the chip
    /// only shows on a definite has_harness=false). Best-effort; never throws.
    func harnessStatus(path: String?) async -> RemoteHarnessStatus? {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let base = endpoint.httpBaseURL else { return nil }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/api/fs/harness-status"
        components?.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = components?.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let status = try? JSONDecoder().decode(RemoteHarnessStatus.self, from: data)
        else { return nil }
        return status
    }

    /// The curated bootstrap prompt seeded when the user taps "Set up agent
    /// harness" (Part B). Audits the repo and writes a CLAUDE.md + AGENTS.md
    /// with VERIFIED gate commands, asking before committing.
    static let harnessBootstrapPrompt =
        "Audit this repository and set up its agent harness. Identify the real "
        + "build, test, and lint commands by inspecting the project (do not guess) "
        + "and verify each one actually runs. Then write a concise CLAUDE.md and "
        + "AGENTS.md documenting those verified gate commands and the project "
        + "layout, and propose sensible CI gates. Ask me before committing anything."

    /// Host health snapshot from `GET /api/host/metrics` (broker v0.0.111+).
    /// Percentages are 0–100; see broker/internal/hostmetrics.
    struct HostMetrics: Decodable {
        let cpuPct: Double
        let memPct: Double
        let diskPct: Double
        let load1: Double?
        let uptimeSecs: Int64?

        enum CodingKeys: String, CodingKey {
            case cpuPct = "cpu_pct"
            case memPct = "mem_pct"
            case diskPct = "disk_pct"
            case load1
            case uptimeSecs = "uptime_secs"
        }
    }

    /// What the Box health screen needs to know about a box's broker.
    /// `nil` fields on failure paths collapse to "hide the affordance".
    struct BoxFeatures {
        var hostMetrics: Bool
        var shellSessions: Bool
        /// Broker advertises `session_discovery` -- enumerate sessions started
        /// outside Conduit. Default false so the feature ships dark on older
        /// brokers (mirrors the host_metrics / shell_sessions pattern).
        var sessionDiscovery: Bool
        /// Broker advertises `session_fork` -- fork a session onto a new worktree.
        /// Kept separate so discovery can ship before fork is ready.
        var sessionFork: Bool
        /// Broker advertises `session_watch` -- incremental transcript polling
        /// for a live running session. Default false so Watch ships dark on
        /// older brokers that do not yet expose this capability.
        var sessionWatch: Bool
    }

    /// Per-assistant model catalogs discovered by the broker live from the
    /// agent CLIs (capabilities "models", broker modelcatalog.go). Empty
    /// until the first successful fetch — the pickers then fall back to the
    /// static `ConduitUI.ForkOptions` lists. Kept across failures so a flaky
    /// refresh never downgrades an already-populated picker.
    private(set) var modelCatalog: [String: [ConduitUI.AgentModel]] = [:]

    /// Per-assistant capability descriptors from the broker (WS-3.1,
    /// `agents` key in `GET /api/capabilities`). Empty until the first
    /// successful fetch — consumers fall back to static defaults when absent
    /// so behaviour is pixel-identical to today on older brokers.
    /// Shape mirrors `broker/internal/session.AgentDescriptor`.
    private(set) var agentDescriptors: [String: AgentDescriptor] = [:]

    /// Broker readiness block from `GET /api/capabilities` (WS-H.1, broker
    /// #450). Nil until the first successful fetch or on older brokers that
    /// omit the block — every WS-H.2/H.3 consumer treats nil as "unknown".
    private(set) var brokerReadiness: BrokerReadiness?

    /// Whether the broker supports the pipeline gate preview + handoff-edit
    /// flow (`GET /api/capabilities` -> `"pipeline_gate_preview": true`).
    /// False on old brokers that omit the key; consumers render the
    /// pre-existing generic gate card when false.
    private(set) var pipelineGatePreview: Bool = false

    /// Whether the broker supports pipeline resume-from-failed
    /// (`GET /api/capabilities` -> `"pipeline_resume": true`).
    /// False on old brokers; the "Retry step" affordance hides when false.
    private(set) var pipelineResume: Bool = false
    /// Broker advertises transactional mid-session agent switching.
    /// False on older brokers, which keeps the switch affordance hidden.
    private(set) var switchAgentSupported: Bool = false

    /// Whether the broker supports pipeline templates
    /// (`GET /api/capabilities` -> `"pipeline_templates": true`).
    /// False on old brokers; Save/Load template affordances hide when false.
    private(set) var pipelineTemplates: Bool = false

    /// Whether the broker supports fanout-as-a-step
    /// (`GET /api/capabilities` -> `"pipeline_fanout": true`).
    /// False on old brokers; the fan-out toggle in the builder and the
    /// pick panel in the monitor hide when false.
    private(set) var pipelineFanout: Bool = false

    /// Single-flight + at-most-once-per-(box,version) guard for the
    /// post-connect broker auto-update (Fix: broker auto-update on reconnect).
    /// `reconnect()`/`selectSavedServer()` short-circuit to a WS-only bounce
    /// when the SSH tunnel is still alive, so the bootstrap script's
    /// `_update_broker_if_stale` never re-runs. We detect a stale broker from
    /// the reported `broker_version` and trigger ONE re-bootstrap. The set of
    /// already-attempted "boxID@version" keys stops it from looping (after the
    /// update the broker reports the app version -> compare equal -> no-op).
    private var brokerUpdateAttempted: Set<String> = []
    private var brokerUpdateInFlight = false

    /// Non-nil when the silent auto-update was deferred because the box has
    /// live sessions. The UI shows a warning banner and the user must confirm.
    var pendingBrokerUpdate: PendingBrokerUpdate?

    /// Session IDs to auto-resume after the broker restarts. Keyed by boxID.
    /// Populated at confirm-time (before the restart); consumed in
    /// `reattachBoxLiveSessions` once `recoverableSessionIDs` is populated.
    private var pendingResume: [String: Set<String>] = [:]

    /// Refresh both `modelCatalog` and `agentDescriptors` from the active
    /// endpoint's capabilities. ONE request; old brokers (no `agents` key)
    /// are a silent no-op for the descriptor path only.
    func refreshModelCatalog() async {
        struct Envelope: Decodable {
            struct Features: Decodable {
                let switchAgent: Bool?
                enum CodingKeys: String, CodingKey {
                    case switchAgent = "switch_agent"
                }
            }
            let models: [String: [ConduitUI.AgentModel]]?
            let agents: [String: AgentDescriptor]?
            let readiness: BrokerReadiness?
            let features: Features?
            let pipeline_gate_preview: Bool?
            let pipeline_resume: Bool?
            let pipeline_templates: Bool?
            let pipeline_fanout: Bool?
        }
        Telemetry.breadcrumb(
            "model_catalog", "refresh start",
            data: ["host": endpoint.displayHost])
        guard let data = await getJSON(endpoint: endpoint, path: "/api/capabilities"),
              let caps = try? JSONDecoder().decode(Envelope.self, from: data)
        else {
            Telemetry.breadcrumb(
                "model_catalog", "capabilities fetch/decode failed",
                data: ["host": endpoint.displayHost])
            return
        }
        if let models = caps.models, !models.isEmpty {
            modelCatalog = models
            Telemetry.breadcrumb("onboarding", OnboardingStep.capabilitiesFetched,
                data: ["host": endpoint.displayHost,
                       "agents": models.keys.sorted().joined(separator: ",")])
            Telemetry.breadcrumb(
                "model_catalog", "refreshed",
                data: [
                    "assistants": models.keys.sorted().joined(separator: ","),
                    "counts": models.map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ","),
                ])
        } else {
            Telemetry.breadcrumb(
                "model_catalog", "no models in capabilities (old broker or discovery pending)",
                data: ["host": endpoint.displayHost])
        }
        if let agents = caps.agents, !agents.isEmpty {
            agentDescriptors = agents
            Telemetry.breadcrumb(
                "agent_descriptors", "refreshed",
                data: ["agents": agents.keys.sorted().joined(separator: ",")])
        } else {
            Telemetry.breadcrumb(
                "agent_descriptors", "no agents in capabilities (old broker)",
                data: ["host": endpoint.displayHost])
        }
        switchAgentSupported = caps.features?.switchAgent ?? false
        // pipeline_gate_preview capability: top-level boolean, default false on old brokers.
        pipelineGatePreview = caps.pipeline_gate_preview ?? false
        // pipeline_resume: resume-from-failed; default false on old brokers.
        pipelineResume = caps.pipeline_resume ?? false
        // pipeline_templates: save/load templates; default false on old brokers.
        pipelineTemplates = caps.pipeline_templates ?? false
        // pipeline_fanout: fanout-as-a-step; default false on old brokers.
        pipelineFanout = caps.pipeline_fanout ?? false

        // WS-H.1: parse the readiness block; nil on old brokers → consumers treat as unknown.
        if let r = caps.readiness {
            brokerReadiness = r
            Telemetry.breadcrumb(
                "broker_readiness", "refreshed",
                data: [
                    "version": r.brokerVersion,
                    "node": r.nodePresent ? "1" : "0",
                    "tmux": r.tmuxPresent ? "1" : "0",
                    "git": r.gitPresent ? "1" : "0",
                    "agents": r.agents.keys.sorted().joined(separator: ","),
                ])
            // Fix: broker auto-update on reconnect. The WS-only reconnect
            // fast-path never re-runs the bootstrap script, so a box left on
            // an old broker stays stale. Now that we have the broker's
            // reported version, trigger a one-shot re-bootstrap when it's
            // behind the app (single-flight + at-most-once per box@version).
            updateBrokerIfStale(brokerVersion: r.brokerVersion)
        } else {
            Telemetry.breadcrumb(
                "broker_readiness", "no readiness block (old broker)",
                data: ["host": endpoint.displayHost])
        }
    }

    /// Session-safe broker auto-update gate.
    ///
    /// When the connected box is an SSH box whose broker reports a version
    /// OLDER than the app:
    ///   - If there are no live sessions: silent update (safe; nothing to lose).
    ///   - If there are live sessions: defer — set `pendingBrokerUpdate` so the
    ///     UI can warn the user and let them confirm.
    ///
    /// Gating (so it never loops):
    ///   - only SSH boxes (token-paired boxes have no bootstrap path);
    ///   - `brokerVersion` must parse as semver and be strictly < the app's;
    ///   - at-most-once per (boxID, brokerVersion) per launch;
    ///   - single-flight while a re-bootstrap is in flight.
    func updateBrokerIfStale(brokerVersion: String) {
        let appVersion = BuildInfo.marketingVersion
        // Only SSH-paired boxes have a re-bootstrap path; token boxes don't.
        guard let server = savedServers.first(where: { $0.endpoint == endpoint }),
              server.ssh != nil else { return }
        let boxID = server.id

        let status = brokerVersionStatus(brokerVersion: brokerVersion, minimumVersion: appVersion)
        guard case .updateAvailable = status else { return }

        let key = "\(boxID)@\(brokerVersion)"
        guard !brokerUpdateInFlight, !brokerUpdateAttempted.contains(key) else {
            Telemetry.breadcrumb("broker_update", "skip (already attempted or in flight)", data: [
                "box": boxID, "installed": brokerVersion, "expected": appVersion,
                "in_flight": "\(brokerUpdateInFlight)",
            ])
            return
        }
        brokerUpdateAttempted.insert(key)

        let liveCount = liveSessionCount(forBox: boxID)
        let decision = brokerUpdateDecision(
            isStale: true,
            liveCount: liveCount,
            isSshPaired: true
        )

        switch decision {
        case .silentUpdate:
            Telemetry.breadcrumb("broker_update", "stale detected — silent update (no live sessions)", data: [
                "box": boxID, "installed": brokerVersion, "expected": appVersion,
            ])
            brokerUpdateInFlight = true
            attemptSshSelfHeal()
            brokerUpdateInFlight = false

        case .deferAndWarn:
            Telemetry.breadcrumb("broker_update", "deferred (live sessions)", data: [
                "box": boxID, "installed": brokerVersion, "expected": appVersion,
                "live_count": "\(liveCount)",
            ])
            pendingBrokerUpdate = PendingBrokerUpdate(
                boxID: boxID,
                brokerVersion: brokerVersion,
                liveCount: liveCount
            )

        default:
            break
        }
    }

    /// Called by the UI after the user confirms the "end N sessions to update"
    /// alert. Snapshots live session IDs for auto-resume, then triggers the
    /// SSH self-heal that restarts the broker.
    func confirmAndUpdateBroker() {
        guard let pending = pendingBrokerUpdate else { return }
        let boxID = pending.boxID

        // Snapshot live session IDs for this box so we can auto-resume them
        // after the broker restarts and reconnects.
        let liveIDs = sessions.compactMap { s -> String? in
            guard sessionBox[s.id] == boxID else { return nil }
            switch sessionLifecycle[s.id] {
            case .exited, .failed: return nil
            default: return s.id
            }
        }
        if !liveIDs.isEmpty {
            pendingResume[boxID] = Set(liveIDs)
            Telemetry.breadcrumb("broker_update", "auto_resume scheduled", data: [
                "box": boxID, "count": "\(liveIDs.count)",
            ])
        }

        Telemetry.breadcrumb("broker_update", "update confirmed by user", data: [
            "box": boxID, "installed": pending.brokerVersion,
        ])
        pendingBrokerUpdate = nil
        brokerUpdateInFlight = true
        attemptSshSelfHeal()
        brokerUpdateInFlight = false
    }

    /// Probe `GET /api/capabilities` on a specific saved endpoint (works
    /// for non-active boxes too — plain authed GET, no WS needed).
    /// Returns nil on any failure (old broker, unreachable, 401): the
    /// caller hides the dependent affordances rather than erroring.
    func fetchBoxFeatures(endpoint: StoredEndpoint) async -> BoxFeatures? {
        struct CapsEnvelope: Decodable {
            struct Features: Decodable {
                let hostMetrics: Bool?
                let shellSessions: Bool?
                let sessionDiscovery: Bool?
                let sessionFork: Bool?
                let sessionWatch: Bool?
                enum CodingKeys: String, CodingKey {
                    case hostMetrics = "host_metrics"
                    case shellSessions = "shell_sessions"
                    case sessionDiscovery = "session_discovery"
                    case sessionFork = "session_fork"
                    case sessionWatch = "session_watch"
                }
            }
            let features: Features?
        }
        guard let data = await getJSON(endpoint: endpoint, path: "/api/capabilities"),
              let caps = try? JSONDecoder().decode(CapsEnvelope.self, from: data)
        else {
            Telemetry.breadcrumb("box_health", "capabilities probe failed", data: ["host": endpoint.displayHost])
            return nil
        }
        return BoxFeatures(
            hostMetrics: caps.features?.hostMetrics ?? false,
            shellSessions: caps.features?.shellSessions ?? false,
            sessionDiscovery: caps.features?.sessionDiscovery ?? false,
            sessionFork: caps.features?.sessionFork ?? false,
            sessionWatch: caps.features?.sessionWatch ?? false
        )
    }

    /// Fetch live CPU/MEM/DISK for a box. nil = box doesn't report metrics
    /// (old broker 404, non-Linux 503, unreachable) → hide the health
    /// section (honest-state rule).
    func fetchHostMetrics(endpoint: StoredEndpoint) async -> HostMetrics? {
        guard let data = await getJSON(endpoint: endpoint, path: "/api/host/metrics"),
              let metrics = try? JSONDecoder().decode(HostMetrics.self, from: data)
        else {
            Telemetry.breadcrumb("box_health", "metrics fetch failed", data: ["host": endpoint.displayHost])
            return nil
        }
        Telemetry.breadcrumb("box_health", "metrics fetched", data: [
            "cpu": String(format: "%.0f", metrics.cpuPct),
            "mem": String(format: "%.0f", metrics.memPct),
            "disk": String(format: "%.0f", metrics.diskPct),
        ])
        return metrics
    }

    // MARK: - Found Sessions (session_discovery capability)

    /// A session found on the box that was NOT started by Conduit.
    struct FoundSession: Identifiable, Equatable {
        let id: String          // == externalID, used as Identifiable.id
        let externalID: String
        let agent: String
        let title: String
        let cwd: String
        let gitBranch: String?
        let turnCount: Int
        let lastActivityAt: Date
        var isRunning: Bool
    }

    /// Fetch paged discovered sessions from `GET /api/sessions/discovered`.
    /// Returns nil on any failure (box offline, capability absent).
    func fetchDiscoveredSessions(
        endpoint: StoredEndpoint,
        q: String = "",
        agent: String = "",
        cursor: String = ""
    ) async -> (sessions: [FoundSession], nextCursor: String, totalOnDisk: Int)? {
        struct Item: Decodable {
            let agent: String
            let external_id: String
            let title: String
            let cwd: String
            let git_branch: String?
            let turn_count: Int
            let last_activity_at: Int64
            let is_running: Bool
        }
        struct Response: Decodable {
            let sessions: [Item]
            let next_cursor: String
            let total_on_disk: Int
        }

        var items: [URLQueryItem] = []
        if !q.isEmpty { items.append(URLQueryItem(name: "q", value: q)) }
        if !agent.isEmpty { items.append(URLQueryItem(name: "agent", value: agent)) }
        if !cursor.isEmpty { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        var comps = URLComponents()
        comps.queryItems = items.isEmpty ? nil : items
        let query = comps.query.map { "?\($0)" } ?? ""

        Telemetry.breadcrumb("found_sessions", "discover start",
            data: ["host": endpoint.displayHost, "q": q])
        guard let data = await getJSON(endpoint: endpoint, path: "/api/sessions/discovered\(query)"),
              let resp = try? JSONDecoder().decode(Response.self, from: data)
        else {
            Telemetry.breadcrumb("found_sessions", "discover failed",
                data: ["host": endpoint.displayHost])
            return nil
        }
        let sessions = resp.sessions.map { item in
            FoundSession(
                id: item.external_id,
                externalID: item.external_id,
                agent: item.agent,
                title: item.title,
                cwd: item.cwd,
                gitBranch: item.git_branch,
                turnCount: item.turn_count,
                lastActivityAt: Date(timeIntervalSince1970: Double(item.last_activity_at) / 1000.0),
                isRunning: item.is_running
            )
        }
        Telemetry.breadcrumb("found_sessions", "discover loaded",
            data: ["host": endpoint.displayHost, "count": "\(sessions.count)",
                   "total": "\(resp.total_on_disk)"])
        return (sessions: sessions, nextCursor: resp.next_cursor, totalOnDisk: resp.total_on_disk)
    }

    /// Fetch read-only transcript for a found session via
    /// `GET /api/sessions/discovered/transcript`. Returns nil on failure.
    func fetchDiscoveredTranscript(
        endpoint: StoredEndpoint,
        agent: String,
        externalID: String
    ) async -> [ConversationItem]? {
        struct Entry: Decodable {
            let role: String
            let content: String
            let ts: String?
        }
        struct Response: Decodable {
            let items: [Entry]
        }

        let path = "/api/sessions/discovered/transcript?agent=\(agent)&external_id=\(externalID)"
        Telemetry.breadcrumb("found_sessions", "transcript fetch",
            data: ["agent": agent, "id": externalID])
        guard let data = await getJSON(endpoint: endpoint, path: path),
              let resp = try? JSONDecoder().decode(Response.self, from: data)
        else {
            Telemetry.breadcrumb("found_sessions", "transcript failed",
                data: ["agent": agent, "id": externalID])
            return nil
        }
        let items = resp.items.enumerated().map { (idx, entry) in
            let role = entry.role.lowercased()
            let kind = role == "tool" ? "tool" : "message"
            return ConversationItem(
                id: "found-\(externalID)-\(idx)",
                role: role,
                kind: kind,
                status: "done",
                content: entry.content,
                ts: entry.ts ?? "",
                files: [],
                toolName: nil,
                command: nil,
                exitCode: nil,
                durationMs: nil,
                diffSummary: nil,
                pendingOptions: [],
                sourceAgent: nil,
                targetAgent: nil,
                taskText: nil,
                resultSummary: nil,
                planSteps: []
            )
        }
        Telemetry.breadcrumb("found_sessions", "transcript loaded",
            data: ["count": "\(items.count)", "id": externalID])
        return items
    }

    /// Fetch incremental transcript items newer than `sinceMs` (Unix epoch ms).
    /// Used by `FoundWatchView` to tail a running session without re-fetching
    /// the full transcript on every poll tick.
    /// Returns `(items: [ConversationItem], latestTs: Int64)` on success, nil on failure.
    func fetchDiscoveredTranscriptSince(
        endpoint: StoredEndpoint,
        agent: String,
        externalID: String,
        sinceMs: Int64
    ) async -> (items: [ConversationItem], latestTs: Int64)? {
        struct Entry: Decodable {
            let role: String
            let content: String
            let ts: String?
        }
        struct Response: Decodable {
            let items: [Entry]
            let latest_ts: Int64
        }

        let path = "/api/sessions/discovered/transcript?agent=\(agent)&external_id=\(externalID)&since_ts=\(sinceMs)"
        guard let data = await getJSON(endpoint: endpoint, path: path),
              let resp = try? JSONDecoder().decode(Response.self, from: data)
        else {
            Telemetry.breadcrumb("found_watch", "incremental fetch failed",
                data: ["agent": agent, "id": externalID, "since": "\(sinceMs)"])
            return nil
        }
        let items = resp.items.enumerated().map { (idx, entry) -> ConversationItem in
            let role = entry.role.lowercased()
            let kind = role == "tool" ? "tool" : "message"
            return ConversationItem(
                id: "watch-\(externalID)-\(sinceMs)-\(idx)",
                role: role,
                kind: kind,
                status: "done",
                content: entry.content,
                ts: entry.ts ?? "",
                files: [],
                toolName: nil,
                command: nil,
                exitCode: nil,
                durationMs: nil,
                diffSummary: nil,
                pendingOptions: [],
                sourceAgent: nil,
                targetAgent: nil,
                taskText: nil,
                resultSummary: nil,
                planSteps: []
            )
        }
        Telemetry.breadcrumb("found_watch", "incremental fetch ok",
            data: ["count": "\(items.count)", "id": externalID,
                   "latest_ts": "\(resp.latest_ts)"])
        return (items: items, latestTs: resp.latest_ts)
    }

    /// Adopt a found session (resume or fork) via `POST /api/sessions/adopt`.
    /// On success, opens the new session via the normal selectedSessionID path.
    /// Returns the new session_id on success, nil on failure.
    @discardableResult
    func adoptFound(
        endpoint: StoredEndpoint,
        agent: String,
        externalID: String,
        cwd: String,
        mode: String  // "resume" or "fork"
    ) async -> String? {
        guard let base = endpoint.httpBaseURL else { return nil }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/api/sessions/adopt"
        guard let url = components?.url else { return nil }

        let body: [String: Any] = [
            "agent": agent,
            "external_id": externalID,
            "cwd": cwd,
            "mode": mode,
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        Telemetry.breadcrumb("found_sessions", "adopt start",
            data: ["agent": agent, "id": externalID, "mode": mode])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse
        else {
            Telemetry.breadcrumb("found_sessions", "adopt network error",
                data: ["agent": agent, "id": externalID, "mode": mode])
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            Telemetry.breadcrumb("found_sessions", "adopt non-2xx",
                data: ["agent": agent, "id": externalID, "mode": mode,
                       "status": "\(http.statusCode)"])
            return nil
        }
        struct AdoptResponse: Decodable {
            let session_id: String
        }
        guard let adoptResp = try? JSONDecoder().decode(AdoptResponse.self, from: data) else {
            Telemetry.breadcrumb("found_sessions", "adopt decode error",
                data: ["agent": agent, "id": externalID])
            return nil
        }
        let newSessionID = adoptResp.session_id
        Telemetry.breadcrumb("found_sessions", "adopt success",
            data: ["agent": agent, "id": externalID, "mode": mode,
                   "new_session_id": newSessionID])
        // Join the adopted session over the WebSocket so the resumed agent
        // streams in and chat send works. attachLiveSession handles joinSession,
        // snapshot ingest, lifecycle promotion, and selectedSessionID navigation.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Stamp the owning box FIRST so attachLiveSession's multi-box
            // routing (clientForSession) picks the right connection.
            let boxID = self.savedServers.first(where: { $0.endpoint == endpoint })?.id
            if let boxID { self.sessionBox[newSessionID] = boxID }
            Telemetry.breadcrumb("found_sessions", "adopt attach",
                data: ["new_session_id": newSessionID, "box": boxID ?? "unknown", "mode": mode])
            self.attachLiveSession(sessionID: newSessionID, assistant: agent)
        }
        return newSessionID
    }

    /// Persist a found session as hidden for a given box.
    func hide(foundSessionID: String, onBox boxID: String) {
        var current = hiddenFoundSessions[boxID] ?? []
        current.insert(foundSessionID)
        hiddenFoundSessions[boxID] = current
        Telemetry.breadcrumb("found_sessions", "hide",
            data: ["id": foundSessionID, "box": boxID])
    }

    /// Unhide a previously hidden found session.
    func unhide(foundSessionID: String, onBox boxID: String) {
        hiddenFoundSessions[boxID]?.remove(foundSessionID)
        Telemetry.breadcrumb("found_sessions", "unhide",
            data: ["id": foundSessionID, "box": boxID])
    }

    // MARK: - HiddenFoundSessions persistence

    private static let hiddenFoundSessionsKey = "conduit.foundSessions.hidden"

    static func loadHiddenFoundSessions() -> [String: Set<String>] {
        guard let raw = UserDefaults.standard.data(forKey: hiddenFoundSessionsKey),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: raw)
        else { return [:] }
        return decoded.mapValues { Set($0) }
    }

    static func persistHiddenFoundSessions(_ map: [String: Set<String>]) {
        let serializable = map.mapValues { Array($0) }
        if let data = try? JSONEncoder().encode(serializable) {
            UserDefaults.standard.set(data, forKey: hiddenFoundSessionsKey)
        }
    }

    /// Shared authed-GET against an arbitrary stored endpoint — the
    /// `listDirectories` direct-HTTP pattern, parameterized on endpoint so
    /// Box health can probe boxes that aren't the active connection.
    private func getJSON(endpoint: StoredEndpoint, path: String) async -> Data? {
        guard let base = endpoint.httpBaseURL else { return nil }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        // `path` may include a query string (e.g. "/api/x?q=1"). Assigning
        // the whole string to `components.path` percent-encodes the "?" into
        // "%3F", mangling the URL so it 404s on the broker. Split the query
        // off and set it as a real query component instead.
        if let qIdx = path.firstIndex(of: "?") {
            components?.path = String(path[..<qIdx])
            let rawQuery = String(path[path.index(after: qIdx)...])
            components?.percentEncodedQuery = rawQuery.isEmpty ? nil : rawQuery
        } else {
            components?.path = path
        }
        guard let url = components?.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return data
    }

    /// Fetch a session's persisted transcript read-only over HTTP
    /// (`GET /api/session/conversation/<id>?tail=80`, broker PR #196+#657).
    /// Mirrors `listDirectories`' direct-HTTP + bearer-auth pattern. Used by
    /// the Sessions screen to open an *exited* session — there's no live WS
    /// to replay from, so we read the broker's `conversation.jsonl` instead.
    ///
    /// Returns the BOTTOM-ANCHORED tail (most recent 80 items) and records
    /// pagination state (`hasMoreHistoryBySession`, `oldestLoadedTsBySession`)
    /// so `ChatView` can trigger `fetchOlderConversation` on scroll-up.
    ///
    /// The persisted rows are role/content/ts/files only; we map them into
    /// `ConversationItem` (kind `message` / `tool`, status `done`) so the
    /// existing chat renderer can display them unchanged.
    ///
    /// Throws `ConversationNotFoundError` on 404 — sessions created before
    /// the #196 redeploy never wrote a `conversation.jsonl`.
    func fetchConversation(sessionID: String) async throws -> [ConversationItem] {
        guard let base = endpoint.httpBaseURL else {
            throw NSError(domain: "SessionStore", code: 100, userInfo: [NSLocalizedDescriptionKey: "Invalid endpoint URL"])
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/api/session/conversation/\(sessionID)"
        // Bottom-anchored initial load: request the most recent 80 messages
        // so opening a long session is fast and does not download the entire
        // transcript. `has_more_before` in the response tells us whether
        // there is more history to page in on scroll-up.
        components?.queryItems = [URLQueryItem(name: "tail", value: "80")]
        guard let url = components?.url else {
            throw NSError(domain: "SessionStore", code: 103, userInfo: [NSLocalizedDescriptionKey: "Failed to build conversation URL"])
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "SessionStore", code: 104, userInfo: [NSLocalizedDescriptionKey: "Conversation fetch failed"])
        }
        if http.statusCode == 404 {
            throw ConversationNotFoundError()
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "SessionStore", code: 104, userInfo: [NSLocalizedDescriptionKey: "Conversation fetch failed (\(http.statusCode))"])
        }
        // Try the new paginated shape first; fall back to the legacy flat
        // array so old brokers that haven't shipped #657 still work.
        let items: [RemoteConversationItem]
        var hasMoreBefore = false
        var oldestTs: Int64 = 0
        if let page = try? JSONDecoder().decode(RemoteConversationPage.self, from: data) {
            items = page.items
            hasMoreBefore = page.hasMoreBefore
            oldestTs = page.oldestTs
        } else {
            let legacy = try JSONDecoder().decode(RemoteConversation.self, from: data)
            items = legacy.items
        }
        // Store pagination state so ChatView can trigger further fetches.
        hasMoreHistoryBySession[sessionID] = hasMoreBefore
        if hasMoreBefore { oldestLoadedTsBySession[sessionID] = oldestTs }
        Telemetry.breadcrumb("pagination", "initial load", data: [
            "session": sessionID,
            "count": String(items.count),
            "has_more": String(hasMoreBefore),
            "oldest_ts": String(oldestTs),
        ])
        return items.enumerated().map { index, raw in
            Self.mapRemoteItem(raw, sessionID: sessionID, idPrefix: "saved", index: index)
        }
    }

    /// Fetch a page of messages OLDER than `beforeTs` (epoch milliseconds).
    /// Issues `GET /api/session/conversation/<id>?before_ts=T&limit=80`.
    /// Prepends the returned items into `hydratedChat[sessionID]` (the sticky
    /// base) so `applyRefreshedConversation` / `refreshConversation` keep them
    /// visible after the next live turn. Updates `hasMoreHistoryBySession` and
    /// `oldestLoadedTsBySession` from the response.
    ///
    /// Returns the prepended items on success, empty array if nothing new.
    /// Guards against overlapping fetches via `isLoadingOlderBySession`.
    @discardableResult
    func fetchOlderConversation(sessionID: String) async -> [ConversationItem] {
        guard !(isLoadingOlderBySession[sessionID] ?? false) else { return [] }
        guard hasMoreHistoryBySession[sessionID] == true else { return [] }
        guard let beforeTs = oldestLoadedTsBySession[sessionID], beforeTs > 0 else { return [] }
        guard let base = endpoint.httpBaseURL else { return [] }

        isLoadingOlderBySession[sessionID] = true
        defer { isLoadingOlderBySession[sessionID] = false }

        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/api/session/conversation/\(sessionID)"
        components?.queryItems = [
            URLQueryItem(name: "before_ts", value: String(beforeTs)),
            URLQueryItem(name: "limit", value: "80"),
        ]
        guard let url = components?.url else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            Telemetry.capture(
                error: NSError(domain: "chat_pagination", code: 1,
                               userInfo: [NSLocalizedDescriptionKey: "older-page fetch failed"]),
                message: "chat pagination fetch failed",
                tags: ["surface": "ios", "phase": "pagination"],
                extras: ["session": sessionID, "before_ts": String(beforeTs)]
            )
            return []
        }

        guard let page = try? JSONDecoder().decode(RemoteConversationPage.self, from: data) else {
            Telemetry.capture(
                error: NSError(domain: "chat_pagination", code: 2,
                               userInfo: [NSLocalizedDescriptionKey: "older-page decode failed"]),
                message: "chat pagination decode failed",
                tags: ["surface": "ios", "phase": "pagination"],
                extras: ["session": sessionID]
            )
            return []
        }

        // Items are returned in ascending chronological order; they must be
        // prepended BEFORE the existing hydratedChat base.
        let existingBase = hydratedChat[sessionID] ?? []
        // Offset index by the number of new pages already prepended so ids
        // never collide with `saved-<id>-<index>` items from `fetchConversation`.
        let baseOffset = existingBase.count
        let newItems = page.items.enumerated().map { index, raw in
            Self.mapRemoteItem(raw, sessionID: sessionID, idPrefix: "paged",
                               index: baseOffset + index,
                               extraTag: String(beforeTs))
        }
        if !newItems.isEmpty {
            // Prepend: older items come before the previously-loaded base.
            hydratedChat[sessionID] = newItems + existingBase
            // For reattached live sessions `refreshConversation` re-runs the
            // Rust-core list and merges `hydratedChat` under it. For EXITED
            // sessions (no live client) that path silently no-ops, so we also
            // call `mergeHydrationIntoConversationLog` which directly splices
            // `hydratedChat` into `conversationLog` — the live client path is
            // harmlessly redundant (applyRefreshedConversation does the same
            // merge after the Rust list).
            refreshConversationOffMain(sessionID: sessionID)
            mergeHydrationIntoConversationLog(sessionID: sessionID)
        }

        // Update pagination cursors.
        hasMoreHistoryBySession[sessionID] = page.hasMoreBefore
        if page.hasMoreBefore { oldestLoadedTsBySession[sessionID] = page.oldestTs }

        Telemetry.breadcrumb("pagination", "loaded older page", data: [
            "session": sessionID,
            "fetched": String(newItems.count),
            "has_more": String(page.hasMoreBefore),
            "oldest_ts": String(page.oldestTs),
        ])
        return newItems
    }

    /// Map a raw `RemoteConversationItem` to a `ConversationItem`, stripping
    /// the pending-input sentinel. Shared by `fetchConversation` and
    /// `fetchOlderConversation` to keep id-scheme logic in one place.
    ///
    /// `idPrefix` is `"saved"` for the initial tail load and `"paged"` for
    /// older pages, so ids never collide between loads. `extraTag` (the
    /// before_ts cursor) further namespaces paged-item ids so two back-to-back
    /// page loads don't share an id space even if `index` overlaps.
    nonisolated static func mapRemoteItem(
        _ raw: RemoteConversationItem,
        sessionID: String,
        idPrefix: String,
        index: Int,
        extraTag: String = ""
    ) -> ConversationItem {
        let role = raw.role.lowercased()
        let files = (raw.files ?? []).map {
            ViewEventFile(path: $0.path, rev: $0.rev ?? "")
        }
        // A persisted, RESOLVED pending-input card carries the broker's
        // needs-input sentinel. Classify it as `pending_input` (so it renders
        // as the answered card, not a plain bubble) and parse its options.
        // The HTTP replay bypasses the Rust classifier, so we do here what
        // core does on the live path — plus we KEEP the resolution marker in
        // `content` (strip only the sentinel line) so the card can rehydrate
        // its answered/selected state from the transcript after a reopen.
        let isPending = raw.content.contains(ConduitUI.ChatViewModel.pendingInputSentinel)
        let kind = isPending ? "pending_input" : (role == "tool" ? "tool" : "message")
        if isPending,
           let res = ConduitUI.ChatViewModel.parsePendingResolution(raw.content),
           res.answered {
            // One-time signal that a persisted answered card was rehydrated
            // from the transcript (the fix: answered/selected state now
            // survives close+reopen instead of living only in client @State).
            Telemetry.breadcrumb("approvals", "pending_input rehydrated answered from transcript", data: [
                "session": sessionID,
                "has_answer": String(res.answer != nil),
            ])
        }
        // Strip the pending-input sentinel — see fetchConversation's inline
        // comment for the full rationale. The resolution marker (if any)
        // survives; `parsePendingQuestions` filters it from visible prose.
        let content = Self.stripPendingSentinel(raw.content)
        let pendingOptions = isPending
            ? ConversationRenderer.extractPendingOptions(from: content)
            : []
        let id = extraTag.isEmpty
            ? "\(idPrefix)-\(sessionID)-\(index)"
            : "\(idPrefix)-\(sessionID)-\(extraTag)-\(index)"
        return ConversationItem(
            id: id,
            role: raw.role,
            kind: kind,
            status: "done",
            content: content,
            ts: raw.ts ?? "",
            files: files,
            toolName: nil,
            command: nil,
            exitCode: nil,
            durationMs: nil,
            diffSummary: nil,
            pendingOptions: pendingOptions,
            sourceAgent: nil,
            targetAgent: nil,
            taskText: nil,
            resultSummary: nil,
            planSteps: []
        )
    }

    /// Terminate AND remove a session on the broker over HTTP
    /// (`DELETE /api/session/<id>`). Mirrors `fetchConversation`'s
    /// direct-HTTP + bearer-auth pattern.
    ///
    /// Unlike the WS `exit` control (which only kills the agent process
    /// and leaves the session recoverable on disk — the bug that made
    /// broker sessions accumulate), this endpoint stops the process, kills
    /// the per-session tmux session, drops the session from the broker's
    /// live set, and archives the on-disk dir out of the active list.
    /// Idempotent server-side: a 200 also covers already-gone sessions.
    ///
    /// Works for exited sessions too — there's no live WS handle required,
    /// just the endpoint + bearer token. The conversation transcript stays
    /// reachable via `fetchConversation` (the broker preserves it under
    /// `archived-sessions/<id>`).
    func deleteSession(sessionID: String) async throws {
        guard let base = endpoint.httpBaseURL else {
            throw NSError(domain: "SessionStore", code: 100, userInfo: [NSLocalizedDescriptionKey: "Invalid endpoint URL"])
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/api/session/\(sessionID)"
        guard let url = components?.url else {
            throw NSError(domain: "SessionStore", code: 105, userInfo: [NSLocalizedDescriptionKey: "Failed to build delete URL"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "SessionStore", code: 106, userInfo: [NSLocalizedDescriptionKey: "Session delete failed (\(code))"])
        }
        // Session is gone server-side — drop its cached scrollback so a
        // recycled id can't resurrect a stale terminal on next launch.
        discardPersistedTerminal(sessionID)
    }

    /// Authoritative "what's alive on the broker RIGHT NOW" list
    /// (`GET /api/sessions`). Mirrors `fetchConversation`'s direct-HTTP +
    /// bearer-auth pattern. This is the keep-alive model: the broker is the
    /// source of truth for liveness, so a reconnecting client reconciles
    /// against it instead of blindly trusting locally-saved `.live` flags
    /// (which go stale the moment the broker restarts and the agents die).
    ///
    /// Returns only sessions the broker is keeping in memory — listing
    /// never resurrects a dead/on-disk session. Throws on an older broker
    /// that doesn't serve the endpoint (404) so the caller can fall back
    /// to "show nothing as active" rather than reattaching dead rows.
    /// Session ids the broker reports as recoverable: not live right now but
    /// guaranteed to respawn cleanly on open. Refreshed every `fetchLiveSessions`.
    /// A row in here resumes interactive on tap (broker recovers it on /ws open)
    /// rather than failing closed to a read-only transcript.
    var recoverableSessionIDs: Set<String> = []

    /// True when the broker advertised this id as recoverable in the last
    /// `/api/sessions` fetch.
    func isRecoverable(sessionID: String) -> Bool {
        recoverableSessionIDs.contains(sessionID)
    }

    func fetchLiveSessions() async throws -> [LiveSessionInfo] {
        guard let base = endpoint.httpBaseURL else {
            throw NSError(domain: "SessionStore", code: 100, userInfo: [NSLocalizedDescriptionKey: "Invalid endpoint URL"])
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/api/sessions"
        guard let url = components?.url else {
            throw NSError(domain: "SessionStore", code: 107, userInfo: [NSLocalizedDescriptionKey: "Failed to build sessions URL"])
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "SessionStore", code: 108, userInfo: [NSLocalizedDescriptionKey: "Live sessions fetch failed (\(code))"])
        }
        let decoded = try JSONDecoder().decode(LiveSessionsResponse.self, from: data)
        // Refresh the recoverable set as a side effect of every poll. Live rows
        // are inherently recoverable too, so the set covers both — but the live
        // ones are already reattached, so only the cold ones matter for Resume.
        recoverableSessionIDs = Set((decoded.recoverable ?? []).map { $0.id })
        return decoded.sessions
    }

    // MARK: - Foreground refresh helpers (Changes 1-3)

    /// Proactive HTTP re-fetch for `sessionID`'s conversation on foreground.
    /// Non-idempotent: always updates the sticky `hydratedChat` base so a
    /// suspended-then-resumed app sees fresh transcript before the WS replay
    /// lands. Merges against live FFI state via refreshConversationOffMain
    /// (same rules as hydrateChatConversation). Safe to call in parallel
    /// with the WS redial -- broker reads the conversation.jsonl on disk.
    private func foregroundRefreshConversation(_ sessionID: String) async {
        Telemetry.breadcrumb("session", "fg_refresh_conversation_start",
            data: ["session": sessionID])
        guard let items = try? await fetchConversation(sessionID: sessionID),
              !items.isEmpty else {
            Telemetry.breadcrumb("session", "fg_refresh_conversation_empty",
                data: ["session": sessionID])
            return
        }
        // Refresh the sticky base (non-idempotent -- overwrites the prior base
        // with fresh HTTP content so the merge includes any new turns).
        hydratedChat[sessionID] = items
        refreshConversationOffMain(sessionID: sessionID)
        Telemetry.breadcrumb("session", "fg_refresh_conversation_merged",
            data: ["session": sessionID, "count": "\(items.count)"])
    }

    /// Mark sessions that have hydrated content at foreground time.
    /// ingestConnectionHealth(.connected) drains the set and fires a forced
    /// post-replay re-read (explicit bypass of PR #871's empty-log gate).
    private func markSessionsForPostConnectRefresh() {
        let hydrated = sessions.compactMap { hydratedChat[$0.id] != nil ? $0.id : nil }
        sessionsNeedingPostConnectRefresh = Set(hydrated)
        Telemetry.breadcrumb("session", "fg_marked_post_connect_refresh",
            data: ["count": "\(hydrated.count)"])
    }

    /// Test seam: record a foreground timestamp without touching the network,
    /// so unit tests can verify the grace-window derivation without posting
    /// UIApplication.willEnterForegroundNotification.
    func recordForegroundedAtForTesting(_ date: Date = Date()) {
        foregroundedAt = date
    }

    /// Resume a cold-but-recoverable session: open the live WebSocket so the
    /// broker respawns the agent, instead of dropping to a read-only transcript.
    /// Forces a non-terminal lifecycle first so the recovered `running` status
    /// frame promotes the row to live rather than being swallowed by a stale
    /// terminal `.exited`. If recovery fails the attach path settles it back to
    /// exited and the next open is read-only — a safe fallback.
    func resumeRecoverableSession(sessionID: String, assistant: String) {
        Telemetry.breadcrumb("session", "resume_recoverable", data: [
            "session": sessionID,
            "assistant": assistant,
        ])
        sessionLifecycle[sessionID] = .creating
        attachLiveSession(sessionID: sessionID, assistant: assistant)
    }

    /// Convenience flow: optionally switch endpoint, connect, then create a
    /// new session and move it into `cwd`. Drives the new-session sheet's
    /// box picker (start a session on a box other than the connected one);
    /// model/effort/prompt ride through to `createSession` unchanged.
    func connectAndStart(
        endpoint nextEndpoint: StoredEndpoint? = nil,
        assistant: String,
        cwd: String?,
        reasoningEffort: String? = nil,
        model: String? = nil,
        permissionMode: String? = nil,
        fastMode: Bool? = nil,
        initialPrompt: String? = nil
    ) {
        if let nextEndpoint {
            endpoint = nextEndpoint
            // Preserve a custom server name if the box is already saved —
            // re-upserting under displayHost would clobber the user's label.
            let savedName = savedServers.first(where: { $0.endpoint == nextEndpoint })?.name
            upsertSavedServer(name: savedName ?? nextEndpoint.displayHost, endpoint: nextEndpoint, makeDefault: true)
        }
        Telemetry.breadcrumb("session", "connect+start", data: [
            "host": endpoint.displayHost,
            "assistant": assistant,
            "hasCwd": "\(cwd?.isEmpty == false)",
        ])
        disconnect()
        connect()
        Task { @MainActor in
            do {
                try await waitUntilCommandReady()
                createSession(
                    assistant: assistant,
                    startupCwd: cwd,
                    reasoningEffort: reasoningEffort,
                    model: model,
                    permissionMode: permissionMode,
                    fastMode: fastMode,
                    initialPrompt: initialPrompt
                )
            } catch {
                Telemetry.capture(
                    error: error,
                    message: "connect+start failed",
                    tags: ["surface": "ios", "phase": "connect_and_start"],
                    extras: ["endpoint": self.endpoint.displayHost, "assistant": assistant]
                )
                harness = .failed("Connect/start failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - SSH bootstrap

    /// Drive `sshBootstrap` from the UniFFI surface, pipe the resulting
    /// `local_port` + `token` into our existing pairing flow.
    ///
    /// `serverName` defaults to the human-friendly `user@host` if omitted.
    /// `anthropicApiKey` / `openaiApiKey` are forwarded into the harness'
    /// `docker run -e ...` so first-launch agents work without a follow-up
    /// SSH session — both are optional. The bootstrap script also reads
    /// any host-side env if these are empty.
    func connectViaSSH(
        credentials: SshCredentials,
        serverName: String? = nil,
        anthropicApiKey: String = "",
        openaiApiKey: String = "",
        imageRef: String? = nil
    ) {
        let host = credentials.host
        let port = credentials.port
        let user = credentials.username

        // Single-flight guard — belt-and-suspenders beyond the UI disabledReasons
        // check: if a bootstrap is already in progress, ignore the duplicate tap.
        if case .running = sshBootstrapState {
            Telemetry.breadcrumb("ssh_addbox", "connect ignored (already running)")
            return
        }

        // Clear any prior sheet-independent error so stale messages don't linger.
        sshBootstrapError = nil

        // Breadcrumb before anything else so we can confirm this function was
        // reached even if the Task or bootstrap throws before the first await.
        Telemetry.breadcrumb("ssh_addbox", "connectViaSSH reached", data: [
            "host": host,
            "port": "\(port)",
            "user": user,
        ])
        sshBootstrapState = .running(message: "Connecting to \(user)@\(host):\(port)…")

        Task {
            let preToken = UUID().uuidString
            let hostKeyBridge = SshHostKeyBridge(store: self, host: host, port: port)
            let progressBridge = SshProgressBridge(store: self, host: host)
            do {
                // SSH-tunnel transport (core #451): hold the returned
                // `SshTunnel` for the session's lifetime so the token rides
                // the SSH-encrypted channel and the box needs no public port.
                // Gated behind a flag so the legacy fire-and-forget path stays
                // available as a one-release fallback. Token-paired boxes never
                // reach here — this is the SSH-bootstrap flow only.
                let useTunnel = FeatureFlags.sshTunnelTransportEnabled()
                let result: SshBootstrapResult
                var tunnel: SshTunnel?

                // Helper that runs the actual bootstrap call (factored out so
                // the ECONNRESET-retry logic can call it twice without duplication).
                func runBootstrap() async throws -> (SshBootstrapResult, SshTunnel?) {
                    if useTunnel {
                        Telemetry.breadcrumb("ssh_tunnel", "bootstrap (tunneled) start", data: ["host": host])
                        let bootstrap = try await sshBootstrapTunneled(
                            credentials: credentials,
                            preAllocatedToken: preToken,
                            anthropicApiKey: anthropicApiKey,
                            openaiApiKey: openaiApiKey,
                            imageRef: imageRef,
                            appVersion: BuildInfo.marketingVersion,
                            hostKeyDelegate: hostKeyBridge,
                            progressDelegate: progressBridge
                        )
                        Telemetry.breadcrumb("ssh_tunnel", "tunnel open", data: [
                            "host": host,
                            "local_port": "\(bootstrap.tunnel.localPort())",
                        ])
                        return (bootstrap.result, bootstrap.tunnel)
                    } else {
                        let r = try await sshBootstrap(
                            credentials: credentials,
                            preAllocatedToken: preToken,
                            anthropicApiKey: anthropicApiKey,
                            openaiApiKey: openaiApiKey,
                            imageRef: imageRef,
                            appVersion: BuildInfo.marketingVersion,
                            hostKeyDelegate: hostKeyBridge,
                            progressDelegate: progressBridge
                        )
                        return (r, nil)
                    }
                }

                do {
                    (result, tunnel) = try await runBootstrap()
                } catch let firstErr as SshError where Self.isEconnreset(firstErr) {
                    // ECONNRESET on handshake: sshd RST'd the connection — likely
                    // a concurrent handshake from a previous tap. Wait briefly
                    // and retry once before surfacing the failure.
                    Telemetry.breadcrumb("ssh_addbox", "ECONNRESET on first attempt — retrying once",
                        data: ["host": host])
                    self.sshBootstrapState = .running(message: "Retrying connection…")
                    try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s
                    (result, tunnel) = try await runBootstrap()
                }

                let endpoint = StoredEndpoint(
                    url: "ws://127.0.0.1:\(result.localPort)",
                    token: result.token
                )
                let name = serverName?.isEmpty == false
                    ? serverName!
                    : "\(user)@\(host)"
                let sshRef = SshEndpointRef(host: host, port: port, username: user)
                // Remove any failed-placeholder row for this SSH host that was
                // persisted by a prior failed attempt (placeholder endpoint is
                // "ssh-pending://host:port" and will never match the real endpoint).
                let failedPlaceholderURL = "ssh-pending://\(host):\(port)"
                self.savedServers.removeAll { $0.endpoint.url == failedPlaceholderURL }
                self.endpoint = endpoint
                self.upsertSavedServer(name: name, endpoint: endpoint, sshRef: sshRef, makeDefault: true)
                // Unconditionally persist credentials so self-heal always has
                // them — not gated on the "Remember" checkbox in the login sheet.
                let credToSave: SavedSshCredential = {
                    switch credentials.auth {
                    case .password(let p):
                        return SavedSshCredential(
                            host: credentials.host,
                            port: credentials.port,
                            username: credentials.username,
                            kind: .password,
                            secret: p,
                            passphrase: nil
                        )
                    case .privateKey(let k, let pp):
                        return SavedSshCredential(
                            host: credentials.host,
                            port: credentials.port,
                            username: credentials.username,
                            kind: .privateKey,
                            secret: k,
                            passphrase: pp
                        )
                    }
                }()
                SshCredentialStore.save(credToSave)
                self.disconnect()
                // `disconnect()` stops + releases any prior tunnel; install the
                // new one (if tunneled) and start watching its liveness BEFORE
                // dialing so a drop during connect is observed.
                self.adoptSshTunnel(tunnel)
                self.connect()
                self.sshBootstrapState = .idle
                Telemetry.breadcrumb("onboarding", OnboardingStep.pairingSucceeded,
                    data: ["transport": "ssh", "host": host])
                Telemetry.breadcrumb("ssh_bootstrap", "iOS SSH bootstrap success", data: [
                    "host": host,
                    "remote_port": "\(result.remotePort)",
                    "local_port": "\(result.localPort)",
                    "reused": result.reused ? "1" : "0",
                    "tunneled": useTunnel ? "1" : "0",
                ])
            } catch let err as SshError {
                let detail = Self.describeSsh(err)
                self.sshBootstrapState = .failed(reason: detail)
                // Also persist the error outside the sheet so the user sees it
                // even if they dismissed the SSH login sheet before it finished.
                self.sshBootstrapError = detail
                // Persist a failed SavedServer so the user can Retry from Settings.
                let sshRef = SshEndpointRef(host: host, port: port, username: user)
                self.upsertFailedServer(
                    name: serverName?.isEmpty == false ? serverName! : "\(user)@\(host)",
                    sshRef: sshRef,
                    reason: detail
                )
                Telemetry.breadcrumb("ssh_addbox", "add failed — persisted to Settings", data: [
                    "host": host, "user": user,
                ])
                Telemetry.capture(
                    error: err,
                    message: "iOS SSH bootstrap failed",
                    tags: ["surface": "ios", "phase": "ssh_bootstrap", "code": Self.sshCode(err)],
                    extras: ["host": host, "user": user, "detail": detail]
                )
            } catch {
                let detail = String(describing: error)
                self.sshBootstrapState = .failed(reason: detail)
                self.sshBootstrapError = detail
                // Persist a failed SavedServer so the user can Retry from Settings.
                let sshRef = SshEndpointRef(host: host, port: port, username: user)
                self.upsertFailedServer(
                    name: serverName?.isEmpty == false ? serverName! : "\(user)@\(host)",
                    sshRef: sshRef,
                    reason: detail
                )
                Telemetry.breadcrumb("ssh_addbox", "add failed — persisted to Settings", data: [
                    "host": host, "user": user,
                ])
                Telemetry.capture(
                    error: error,
                    message: "iOS SSH bootstrap failed",
                    tags: ["surface": "ios", "phase": "ssh_bootstrap", "code": "unknown"],
                    extras: ["host": host, "user": user, "detail": detail]
                )
            }
        }
    }

    /// Returns true if the SSH error looks like a TCP connection-reset by
    /// peer — the trigger condition for the one-shot ECONNRESET retry.
    private static func isEconnreset(_ err: SshError) -> Bool {
        switch err {
        case .Handshake(let m):
            let lower = m.lowercased()
            return lower.contains("reset by peer") || lower.contains("os error 54")
                || lower.contains("connection reset")
        default:
            return false
        }
    }

    /// Called from `SshHostKeyBridge` on the main actor when the SSH
    /// handshake hits an unknown fingerprint. The completion runs when
    /// the user accepts/rejects the host-key alert.
    fileprivate func presentHostKeyPrompt(
        host: String,
        port: UInt16,
        fingerprint: String,
        completion: @escaping (Bool) -> Void
    ) {
        Telemetry.breadcrumb(
            "ssh_hostkey", "host key prompt presented",
            data: ["host": host, "fp_prefix": String(fingerprint.prefix(16))]
        )
        hostKeyResolver = completion
        pendingHostKey = HostKeyPrompt(host: host, port: port, fingerprint: fingerprint)
    }

    /// Invoked by the TOFU alert buttons.
    func resolveHostKeyPrompt(accept: Bool) {
        guard let prompt = pendingHostKey else { return }
        Telemetry.breadcrumb(
            "ssh_hostkey", "host key resolved",
            data: ["accept": accept ? "true" : "false"]
        )
        if accept {
            SshHostKeyTrustStore.trust(host: prompt.host, port: prompt.port, fingerprint: prompt.fingerprint)
        }
        pendingHostKey = nil
        let resolver = hostKeyResolver
        hostKeyResolver = nil
        resolver?(accept)
    }

    func clearSshBootstrap() {
        sshBootstrapState = .idle
    }

    func upsertSavedServer(
        name: String,
        endpoint: StoredEndpoint,
        sshRef: SshEndpointRef? = nil,
        makeDefault: Bool,
        status: SavedServerStatus? = nil
    ) {
        var next = savedServers
        if let idx = next.firstIndex(where: { $0.endpoint == endpoint }) {
            next[idx].name = name
            if let ref = sshRef { next[idx].ssh = ref }
            next[idx].status = status
            if makeDefault {
                for i in next.indices { next[i].isDefault = false }
                next[idx].isDefault = true
            }
        } else {
            if makeDefault {
                for i in next.indices { next[i].isDefault = false }
            }
            next.append(
                SavedServer(
                    id: UUID().uuidString,
                    name: name.isEmpty ? endpoint.displayHost : name,
                    endpoint: endpoint,
                    isDefault: makeDefault || next.isEmpty,
                    ssh: sshRef,
                    status: status
                )
            )
        }
        savedServers = next
        Self.persistSavedServers(next)
    }

    /// Persists a failed SSH add attempt so the box appears in Settings
    /// with a Retry affordance. Uses a placeholder endpoint keyed by
    /// host+port so the row is deduplicated correctly on multiple failures.
    func upsertFailedServer(name: String, sshRef: SshEndpointRef, reason: String) {
        // Use a stable fake endpoint keyed by the SSH host+port so repeated
        // failures against the same host deduplicate to the same row.
        let placeholderURL = "ssh-pending://\(sshRef.host):\(sshRef.port)"
        let endpoint = StoredEndpoint(url: placeholderURL, token: "")
        upsertSavedServer(
            name: name,
            endpoint: endpoint,
            sshRef: sshRef,
            makeDefault: false,
            status: .failed(reason: reason)
        )
    }

    func selectSavedServer(_ serverID: String, autoConnect: Bool) {
        guard let server = savedServers.first(where: { $0.id == serverID }) else { return }
        for i in savedServers.indices {
            savedServers[i].isDefault = savedServers[i].id == serverID
        }
        Self.persistSavedServers(savedServers)
        // Bug #1: tapping the active server pill used to call
        // `disconnect()`+`connect()` unconditionally. That tore down
        // the live `ConduitClient` and the subsequent `refreshSessions`
        // observed an empty `list_sessions()` (the fresh Rust client
        // has no `SessionStatus` deltas yet), wiping the visible
        // session list until status frames trickled back in. If the
        // endpoint hasn't actually changed AND we're already linked
        // we just persist the default flag and bail — no need to
        // bounce the socket.
        let endpointChanged = endpoint != server.endpoint
        endpoint = server.endpoint
        if autoConnect {
            if endpointChanged || !harness.isReachable {
                if server.ssh != nil {
                    // SSH box: the persisted endpoint is a loopback ws://127.0.0.1:<port>
                    // that only works while THAT box's russh tunnel is live. Switching
                    // to a different SSH box (or the same one whose tunnel dropped) must
                    // re-bootstrap the tunnel instead of dialing a dead loopback port.
                    // If the held tunnel is already alive AND the endpoint matches we
                    // can skip the bootstrap and just re-dial the WS layer.
                    let tunnelAlive = sshTunnel?.isAlive() == true
                    if tunnelAlive && !endpointChanged {
                        // Tunnel is up, just bounce the WebSocket.
                        disconnect()
                        connect()
                    } else {
                        // No live tunnel for the target box — re-bootstrap.
                        // attemptSshSelfHeal uses self.endpoint (already updated above)
                        // to look up the SSH ref and re-run the full tunnel bootstrap.
                        Telemetry.breadcrumb("ssh_tunnel", "selectSavedServer triggering re-bootstrap", data: [
                            "server": serverID,
                            "endpointChanged": "\(endpointChanged)",
                            "tunnelAlive": "\(tunnelAlive)",
                        ])
                        attemptSshSelfHeal()
                    }
                } else {
                    // Token-paired (conduit://) box — plain disconnect+reconnect.
                    disconnect()
                    connect()
                }
            }
        }
    }

    func removeSavedServer(_ serverID: String) {
        let removedWasCurrent = savedServers.first(where: { $0.id == serverID })?.endpoint == endpoint
        savedServers.removeAll { $0.id == serverID }
        if savedServers.isEmpty {
            endpoint = .empty
            disconnect()
        } else if !savedServers.contains(where: { $0.isDefault }) {
            savedServers[0].isDefault = true
            if removedWasCurrent {
                endpoint = savedServers[0].endpoint
            }
        }
        Self.persistSavedServers(savedServers)
    }

    /// Drop a saved server entirely — removes the row from `savedServers`,
    /// clears any locally-stored display-name override keyed by that id,
    /// and persists both to disk (Keychain + UserDefaults). Idempotent;
    /// safe to call with an unknown id.
    ///
    /// This is the entry point UI affordances (swipe-to-delete in
    /// Settings, "Forget" context-menu on the server pill) call. It
    /// builds on `removeSavedServer` for the savedServers + endpoint
    /// bookkeeping but additionally sweeps the display-name override —
    /// without that step a stale rename for a `SavedServer.id` we just
    /// dropped would linger in UserDefaults forever.
    /// Rename a saved server in-place; persists immediately.
    func renameServer(_ serverID: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = savedServers.firstIndex(where: { $0.id == serverID }) else { return }
        savedServers[idx].name = trimmed
        Self.persistSavedServers(savedServers)
        Telemetry.breadcrumb("boxes", "server renamed", data: ["id": serverID, "name": trimmed])
    }

    func forgetServer(_ id: String) {
        removeSavedServer(id)
        if displayNames[id] != nil {
            displayNames[id] = nil
        }
    }

    // MARK: - Session lifecycle

    func createSession(
        assistant: String,
        branch: String? = nil,
        startupCwd: String? = nil,
        reasoningEffort: String? = nil,
        model: String? = nil,
        permissionMode: String? = nil,
        fastMode: Bool? = nil,
        initialPrompt: String? = nil
    ) {
        // Multi-box: new sessions land on the selected/primary box's
        // connection (and get stamped to it below); single-box uses the one
        // global client unchanged.
        let targetBox = primaryBoxConnection
        guard let client = targetBox?.client ?? client else { return }
        let targetBoxID = targetBox?.server.id
        sessionCreationError = nil
        let pendingID = "pending-\(UUID().uuidString)"
        sessionLifecycle[pendingID] = .creating
        // Log the ACTUAL model slug, not just a bool — codex `--model` is
        // passed to the backend unvalidated, so a bad slug (e.g. a model the
        // backend doesn't know) lets the session spawn fine but fails every
        // turn. Without the slug here, that failure is undiagnosable from
        // Sentry. "inherit" = no override.
        let modelCrumb = (model?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "inherit"
        let effortCrumb = (reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        let permissionModeCrumb = (permissionMode?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "auto"
        Telemetry.breadcrumb("session", "create start", data: ["assistant": assistant, "hasCwd": "\(startupCwd?.isEmpty == false)", "model": modelCrumb, "effort": effortCrumb, "mode": permissionModeCrumb])
        if useRustStore {
            rustStore.applyLifecycle(sessionId: pendingID, lifecycle: .creating)
        }
        Task {
            do {
                // Pass the selected folder as the agent's cwd so the broker
                // spawns the agent *in* it. (Previously this cd'd the PTY
                // shell as a workaround, which only moved the Terminal tab —
                // the headless agent still started in the broker's default
                // .conduit work dir.)
                let trimmedCwd = startupCwd?.trimmingCharacters(in: .whitespacesAndNewlines)
                let startup = (trimmedCwd?.isEmpty == false) ? trimmedCwd : nil
                let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
                let pickedModel = (trimmedModel?.isEmpty == false) ? trimmedModel : nil
                let trimmedEffort = reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines)
                let pickedEffort = (trimmedEffort?.isEmpty == false) ? trimmedEffort : nil
                let trimmedMode = permissionMode?.trimmingCharacters(in: .whitespacesAndNewlines)
                let pickedMode = (trimmedMode?.isEmpty == false) ? trimmedMode : nil
                let id = try await client.createSession(assistant: assistant, branch: branch, reasoningEffort: pickedEffort, model: pickedModel, cwd: startup, permissionMode: pickedMode, fastMode: fastMode, deviceId: DeviceIdentity.deviceID)
                // Multi-box: stamp the new session to its owning box so every
                // later op routes back to the same connection. (Single-box: the
                // existing refreshSessions stamps to the current box.)
                if let targetBoxID { self.sessionBox[id] = targetBoxID }
                Telemetry.breadcrumb("session", "created", data: ["assistant": assistant, "id": id])
                // Funnel: first-ever session creation (no prior sessions on any launch).
                if self.sessions.isEmpty {
                    Telemetry.breadcrumb("onboarding", OnboardingStep.firstSessionCreated,
                        data: ["assistant": assistant, "host": self.endpoint.displayHost])
                }
                // Record the explicit --model override so the title menu's
                // identity header can show the real model (the broker never
                // reports one back). Inherit (nil) stays absent on purpose.
                if let pickedModel {
                    self.modelBySession[id] = pickedModel
                }
                if let startup {
                    self.rememberRecentDirectory(startup)
                }
                self.sessionLifecycle[pendingID] = nil
                self.sessionLifecycle[id] = .live
                if self.useRustStore {
                    self.rustStore.forgetSession(sessionId: pendingID)
                    self.rustStore.applyLifecycle(sessionId: id, lifecycle: .live)
                }
                self.harness = .live
                self.refreshSessions()
                // Persist the new session immediately so it survives a
                // relaunch before any status frame arrives. A fresh broker
                // `listSessions()` is often empty, so `refreshSessions` may
                // not have added the row yet — synthesize a minimal live
                // `ProjectSession` so `recordSavedSession` (which requires a
                // live row) has something to fold into the History index.
                if !self.sessions.contains(where: { $0.id == id }) {
                    self.sessions.insert(
                        ProjectSession(
                            id: id,
                            name: id,
                            assistant: assistant,
                            branch: branch,
                            preview: nil,
                            reasoningEffort: pickedEffort,
                            cwd: startup,
                            startedAt: nil,
                            lastActivityAt: nil,
                            displayName: nil,
                            totalInputTokens: nil,
                            totalOutputTokens: nil,
                            totalCachedTokens: nil,
                            totalCostUsd: nil,
                            contextUsedTokens: nil,
                            contextWindowTokens: nil
                        ),
                        at: 0
                    )
                }
                self.recordSavedSession(forSessionID: id)
                // Seed the first turn (e.g. a voice-dictated prompt). Route it
                // through the same path as a normal composer send: optimistic
                // local echo so the user sees their prompt, slash-command
                // handling, and a *surfaced* (not `try?`-swallowed) WS failure.
                // The old fire-and-forget `try? client.sendChat` here silently
                // dropped the prompt on any transient — the device-reported
                // "talk on home, start a session, prompt never sent".
                if let initialPrompt {
                    let trimmed = initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        Telemetry.breadcrumb("session", "seed prompt", data: ["id": id, "chars": "\(trimmed.count)"])
                        self.sendChat(sessionID: id, message: trimmed)
                    }
                }
                // Defer selecting the new session by one runloop tick.
                // Selecting it flips `ConduitRootView`'s `.id(session.id)`,
                // which tears down the prior detail subtree AND mounts the
                // new one — including `GhosttyTerminalView`, whose attach
                // does synchronous CALayer work (`addSublayer:` +
                // `CATransaction`). Doing the teardown+mount in the SAME
                // CoreAnimation commit that's already flushing the
                // just-dismissed new-session sheet frees a layer mid-flush →
                // `EXC_BAD_ACCESS` in `CA::Transaction::commit` (the
                // post-create crash; localized via the `[session] created`
                // breadcrumb trail). One tick lets the prior commit finish
                // so the terminal mounts in a clean transaction.
                DispatchQueue.main.async { self.selectedSessionID = id }
                // PLAN-AGENT-OAUTH stage 2: now that we have an active
                // session WS (and therefore an authenticated route to
                // the broker), replay any Keychain-stored OAuth
                // credentials. Idempotent on the broker side
                // (last-writer-wins per PLAN §D.1); cheap no-op when
                // the Keychain is empty.
                self.replayStoredAgentCredentials()
            } catch {
                let detail = Self.describe(error)
                Telemetry.capture(error: error, message: "iOS create session failed", tags: ["flow": "session", "assistant": assistant, "model": modelCrumb], extras: ["detail": detail])
                self.sessionLifecycle[pendingID] = .failed(detail)
                if self.useRustStore {
                    self.rustStore.applyLifecycle(
                        sessionId: pendingID,
                        lifecycle: .failedToStart(reason: detail)
                    )
                }
                self.sessionCreationError = detail
                if Self.isAuth(error) {
                    // SSH boxes: token mismatch is recoverable via re-bootstrap.
                    // Token-paired boxes: the pairing QR is genuinely expired.
                    if self.savedServers.first(where: { $0.endpoint == self.endpoint })?.ssh != nil {
                        Telemetry.breadcrumb("session", "auth failure on SSH box — triggering self-heal",
                            data: ["phase": "create_session", "endpoint": self.endpoint.displayHost])
                        self.harness = .reconnecting(attempt: 1, maxAttempts: 3)
                        self.attemptSshSelfHeal()
                    } else {
                        self.harness = .failed("Pairing expired. Scan a new QR code from the server.")
                    }
                } else if Self.isConnectionRefused(error),
                          self.savedServers.first(where: { $0.endpoint == self.endpoint })?.ssh != nil {
                    // Dead SSH tunnel: box shows connected but broker is unreachable.
                    // Drive the same SSH self-heal path so harness ends up .reconnecting.
                    Telemetry.breadcrumb("session", "connection refused on SSH box — triggering self-heal",
                        data: ["phase": "create_session", "endpoint": self.endpoint.displayHost])
                    self.harness = .reconnecting(attempt: 1, maxAttempts: 3)
                    self.attemptSshSelfHeal()
                }
                Telemetry.capture(
                    error: error,
                    message: "iOS create session failed",
                    tags: ["surface": "ios", "phase": "create_session", "assistant": assistant, "model": modelCrumb],
                    extras: ["endpoint": self.endpoint.displayHost, "detail": detail]
                )
                // Sweep the placeholder after a short delay so the user can
                // see *why* without having a stuck row forever.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    self.sessionLifecycle[pendingID] = nil
                    if self.useRustStore {
                        self.rustStore.forgetSession(sessionId: pendingID)
                    }
                }
            }
        }
    }

    func switchAgent(sessionID: String, to assistant: String) {
        guard let client = clientForSession(sessionID) else { return }
        Task {
            do { try await client.switchAgent(sessionId: sessionID, assistant: assistant) }
            catch {
                let detail = Self.describe(error)
                self.sessionLifecycle[sessionID] = .failed("switch_agent: \(detail)")
                if Self.isAuth(error) {
                    if self.savedServers.first(where: { $0.endpoint == self.endpoint })?.ssh != nil {
                        Telemetry.breadcrumb("session", "auth failure on SSH box — triggering self-heal",
                            data: ["phase": "switch_agent", "endpoint": self.endpoint.displayHost])
                        self.harness = .reconnecting(attempt: 1, maxAttempts: 3)
                        self.attemptSshSelfHeal()
                    } else {
                        self.harness = .failed("Pairing expired. Scan a new QR code from the server.")
                    }
                }
                Telemetry.capture(
                    error: error,
                    message: "iOS switch agent failed",
                    tags: ["surface": "ios", "phase": "switch_agent", "assistant": assistant],
                    extras: ["endpoint": self.endpoint.displayHost, "session_id": sessionID, "detail": detail]
                )
            }
        }
    }

    /// Archive a session: END it on the broker (free server resources) but
    /// KEEP it in history as a read-only transcript. This is the home-list
    /// swipe action.
    ///
    /// Two-tier delete model (vs `permanentlyDelete`): archiving drops the
    /// row from the *live* `sessions` list and issues the authoritative
    /// broker DELETE (kills agent + tmux, archives the on-disk dir under
    /// `archived-sessions/<id>`), but it does NOT tombstone the session.
    /// Because the row stays in `SavedSessionsStore`, it keeps appearing in
    /// History — now no longer live, so `isReadOnly` is true and it opens
    /// read-only (#223); the broker preserves `conversation.jsonl`, so
    /// `fetchConversation` still serves the transcript.
    /// Free all per-session in-memory state after archive or permanent delete.
    /// The broker preserves the transcript on disk; History re-fetches it via
    /// HTTP on first open (guarded by `hydratedChat[id] == nil` in
    /// `seedExitedConversation`). Called immediately after `rustStore.forgetSession`.
    private func clearSessionState(_ sessionID: String) {
        chatLog[sessionID] = nil
        conversationLog[sessionID] = nil
        hydratedChat[sessionID] = nil
        terminalBuffer[sessionID] = nil
        terminalSnapshot[sessionID] = nil
        statusBySession[sessionID] = nil
        quickReplies[sessionID] = nil
        credentialSource[sessionID] = nil
        answeredPendingBySession[sessionID] = nil
        subagentRosters[sessionID] = nil
        pinnedContexts[sessionID] = nil
        preview[sessionID] = nil
        connectionHealthBySession[sessionID] = nil
        agentAuthFailure[sessionID] = nil
        hasMoreHistoryBySession[sessionID] = nil
        oldestLoadedTsBySession[sessionID] = nil
        isLoadingOlderBySession[sessionID] = nil
    }

    func archive(sessionID: String) {
        // Optimistic removal so the row disappears immediately. Previously
        // we cleared local state only *after* the async `exitSession` +
        // `refreshSessions` round-trip, so the row lingered until the
        // network call returned — it read as laggy/broken. Prune locally
        // first; `refreshSessions` re-pulls the live list afterward, so a
        // failed teardown self-corrects (the row reappears).
        sessions.removeAll { $0.id == sessionID }
        sessionLifecycle[sessionID] = nil
        if selectedSessionID == sessionID { selectedSessionID = nil }
        if useRustStore { rustStore.forgetSession(sessionId: sessionID) }
        // Free all in-memory chat/state data for this session.
        let convCount = conversationLog[sessionID]?.count ?? 0
        let chatCount = chatLog[sessionID]?.count ?? 0
        clearSessionState(sessionID)
        Telemetry.breadcrumb("memory", "session_state_freed",
            data: ["session": sessionID, "conv": "\(convCount)",
                   "chat": "\(chatCount)", "reason": "archive"])
        // End any Live Activity for this session immediately. The bridge
        // only drives `.end` when it sees an "exited..." phase in a future
        // frame, but archive removes the session from the live list, so the
        // bridge never observes that transition. Call the controller
        // directly so the lock-screen card disappears right away.
        TurnLiveActivityController.shared.sessionExited(sessionID: sessionID)
        Telemetry.breadcrumb("live_activity", "ended on archive", data: ["session": sessionID])
        // NOTE: deliberately NO `SavedSessionsStore.shared.remove(...)` here.
        // Archiving must leave the history row intact so it stays viewable
        // as a read-only transcript. Permanent removal lives in
        // `permanentlyDelete(sessionID:)`, invoked only from History.
        //
        // Mark the persisted History row as exited so it renders "ended"
        // rather than "running". Use the same owner-ID logic as
        // `recordSavedSession` (sessionBox stamp, then active endpoint).
        let ownerID = sessionBox[sessionID] ?? savedHistoryServerID
        SavedSessionsStore.shared.markExited(id: sessionID, serverID: ownerID)
        Telemetry.breadcrumb("session", "archived row marked exited", data: ["session": sessionID, "server": ownerID])
        tearDownOnBroker(sessionID: sessionID, phase: "session_archive")
    }

    /// Permanently delete a session from the app's History. Tombstones the
    /// row (`SavedSessionsStore.remove` → `deletedIDs`) so it leaves
    /// History forever and a later broker re-report can never resurrect it,
    /// and also ends it on the broker (idempotent for already-archived /
    /// exited rows). This is the History-only "Delete permanently" action.
    ///
    /// NOTE: the broker's archived dir on disk is NOT purged here — the
    /// tombstone is purely app-side. Reaping `archived-sessions/<id>` on the
    /// server is a separate future enhancement (no broker endpoint yet).
    func permanentlyDelete(sessionID: String) {
        sessions.removeAll { $0.id == sessionID }
        sessionLifecycle[sessionID] = nil
        if selectedSessionID == sessionID { selectedSessionID = nil }
        pendingChats.clear(sessionID: sessionID)
        if useRustStore { rustStore.forgetSession(sessionId: sessionID) }
        // Free all in-memory chat/state data for this session.
        let convCount = conversationLog[sessionID]?.count ?? 0
        let chatCount = chatLog[sessionID]?.count ?? 0
        clearSessionState(sessionID)
        Telemetry.breadcrumb("memory", "session_state_freed",
            data: ["session": sessionID, "conv": "\(convCount)",
                   "chat": "\(chatCount)", "reason": "delete"])
        // End any Live Activity for this session immediately — same
        // reasoning as archive(sessionID:) above.
        TurnLiveActivityController.shared.sessionExited(sessionID: sessionID)
        Telemetry.breadcrumb("live_activity", "ended on delete", data: ["session": sessionID])
        // Delete is terminal: sweep the persistent "Resume" index AND record
        // the tombstone so a status/list refresh (the broker's tmux can
        // linger, #199) can never re-add the row to History.
        SavedSessionsStore.shared.remove(id: sessionID)
        tearDownOnBroker(sessionID: sessionID, phase: "session_delete")
    }

    /// Shared broker teardown for both archive + permanent-delete: closes
    /// the live WS handle (best-effort checkpoint flush) then issues the
    /// authoritative HTTP DELETE that kills the agent + tmux, drops the
    /// session from the broker's active set, and archives its on-disk dir.
    /// No live WS handle is required, so it also works for exited rows.
    private func tearDownOnBroker(sessionID: String, phase: String) {
        Task {
            // WS `exit` closes the live socket + flushes a checkpoint when
            // a session is attached. Best-effort: an exited session has no
            // live handle, and the HTTP DELETE below is the authoritative
            // teardown either way.
            if let client = self.clientForSession(sessionID) { try? await client.exitSession(sessionId: sessionID) }
            // Authoritative broker-side delete: kills the agent process +
            // tmux, removes the session from the broker's active set, and
            // archives its dir. Without this the broker kept recovering the
            // session on disk and the row reappeared / sessions piled up.
            do {
                try await self.deleteSession(sessionID: sessionID)
            } catch {
                Telemetry.capture(
                    error: error,
                    message: "iOS session teardown failed",
                    tags: ["surface": "ios", "phase": phase],
                    extras: ["endpoint": self.endpoint.displayHost, "session_id": sessionID]
                )
            }
            self.refreshSessions()
        }
    }

    // MARK: - Terminal / chat I/O

    func sendInput(sessionID: String, bytes: Data) {
        guard let client = clientForSession(sessionID) else { return }
        Task { try? await client.sendInput(sessionId: sessionID, data: bytes) }
    }

    /// On-demand /usage: ask the broker to re-fetch the account-level Claude
    /// subscription usage (5-hour + weekly). The fresh numbers arrive on the
    /// next `on_status` callback and land on the session via `apply_status`.
    /// Backs the refresh button in the Session Info account-usage card.
    func refreshAccountUsage(sessionID: String) {
        guard let client = clientForSession(sessionID) else { return }
        Task { try? await client.refreshAccountUsage(sessionId: sessionID) }
    }

    /// Stop the agent's current turn (the composer Stop button) without ending
    /// the session. Fire-and-forget: the broker interrupts the running turn
    /// (claude stream-json interrupt / codex turn-interrupt / codex-exec kill)
    /// and the turn winding down arrives on the normal chat/status stream, which
    /// clears the typing indicator. A no-op broker-side when nothing is running.
    func stopTurn(sessionID: String) {
        guard let client = clientForSession(sessionID) else { return }
        Telemetry.breadcrumb("chat", "stop turn requested", data: ["session": sessionID])
        Task { try? await client.stopTurn(sessionId: sessionID) }
    }

    /// Account-level Claude subscription usage, surfaced ambiently on Home and
    /// in Settings (design handoff §3b). The numbers are per-account, not
    /// per-session, so we just need any Claude session carrying the latest
    /// fetched values. Codex has no equivalent endpoint, so this is Claude-only
    /// by design — the ambient surfaces show Claude and omit Codex rather than
    /// fabricating a number.
    struct AccountUsageSnapshot {
        var fivePct: Double?
        var fiveResetsAt: String?
        var weekPct: Double?
        var weekResetsAt: String?
        var sourceSessionID: String?
        var hasData: Bool { fivePct != nil || weekPct != nil }
    }

    /// Per-agent account usage for one agent ("claude" / "codex"), pulled
    /// off the freshest session bound to that agent. The broker now folds
    /// BOTH Anthropic (`/api/oauth/usage`) and ChatGPT (`/wham/usage`,
    /// codexaccountusage.go) limits into the same per-session status-frame
    /// fields, so the ambient Home strip can show `claude · codex` side by
    /// side (handoff §B.10) instead of Claude-only — but only for agents
    /// that actually carry data, never a fabricated number.
    struct AgentUsageSnapshot: Identifiable {
        var agent: String
        var fivePct: Double?
        var fiveResetsAt: String?
        var weekPct: Double?
        var weekResetsAt: String?
        var id: String { agent }
        var hasData: Bool { fivePct != nil || weekPct != nil }
    }

    /// Freshest account usage for each agent that has any, in a stable
    /// display order (claude first, then codex, then any others). Drives
    /// the ambient Home usage strip. Empty when no session carries usage.
    var accountUsageByAgent: [AgentUsageSnapshot] {
        // Group the freshest values per agent (live status preferred over the
        // session snapshot fallback). One snapshot per agent that has data.
        var byAgent: [String: AgentUsageSnapshot] = [:]
        for s in sessions {
            let agent = s.assistant
            if byAgent[agent]?.hasData == true { continue }
            let st = statusBySession[s.id]
            let five = st?.account5hPct ?? s.account5hPct
            let week = st?.account7dPct ?? s.account7dPct
            guard five != nil || week != nil else { continue }
            byAgent[agent] = AgentUsageSnapshot(
                agent: agent,
                fivePct: five,
                fiveResetsAt: st?.account5hResetsAt ?? s.account5hResetsAt,
                weekPct: week,
                weekResetsAt: st?.account7dResetsAt ?? s.account7dResetsAt
            )
        }
        let order = ["claude", "codex"]
        return byAgent.values.sorted { a, b in
            let ia = order.firstIndex(of: a.agent) ?? order.count
            let ib = order.firstIndex(of: b.agent) ?? order.count
            return ia == ib ? a.agent < b.agent : ia < ib
        }
    }

    /// The freshest account-usage values across Claude sessions (live status
    /// frame preferred, session snapshot as fallback).
    var accountUsage: AccountUsageSnapshot {
        for s in sessions where s.assistant == "claude" {
            let st = statusBySession[s.id]
            let five = st?.account5hPct ?? s.account5hPct
            let week = st?.account7dPct ?? s.account7dPct
            if five != nil || week != nil {
                return AccountUsageSnapshot(
                    fivePct: five,
                    fiveResetsAt: st?.account5hResetsAt ?? s.account5hResetsAt,
                    weekPct: week,
                    weekResetsAt: st?.account7dResetsAt ?? s.account7dResetsAt,
                    sourceSessionID: s.id
                )
            }
        }
        return AccountUsageSnapshot(sourceSessionID: sessions.first(where: { $0.assistant == "claude" })?.id)
    }

    /// Session-independent refresh for the ambient usage surfaces — drives the
    /// broker fetch via any Claude session. No-op when none is connected.
    func refreshAccountUsage() {
        guard let id = sessions.first(where: { $0.assistant == "claude" })?.id else { return }
        refreshAccountUsage(sessionID: id)
    }

    /// Upload a composer attachment to the session's
    /// `<workspace>/uploads/<sessionID>/<filename>` via the core 0x01
    /// binary frame (`ConduitClient.sendFile`). Awaited by the chat
    /// composer BEFORE the outgoing message is sent, so the bytes have
    /// landed by the time the agent reads the referenced upload path.
    /// Throws when there's no live transport or the WS write fails, so
    /// the caller can surface "upload failed" instead of sending a
    /// message that references a file the broker never received.
    func sendFile(sessionID: String, filename: String, mime: String, bytes: Data) async throws {
        guard let client = clientForSession(sessionID) else { throw ConduitError.NotConnected(message: "no session transport") }
        try await client.sendFile(
            sessionId: sessionID,
            filename: filename,
            mime: mime,
            payload: bytes
        )
    }

    /// True when a turn is currently active for the given session. Driven by
    /// the broker's authoritative `turn_active` field from the status frame.
    func isTurnActive(sessionID: String) -> Bool {
        statusBySession[sessionID]?.turnActive == true
    }

    /// True when the agent for this session supports `turn/steer` injection
    /// (codex app-server only). Gated on `supports.steer` from the agent
    /// descriptor -- never hardcoded by agent name.
    func supportsSteer(sessionID: String) -> Bool {
        let assistant = sessions.first(where: { $0.id == sessionID })?.assistant ?? ""
        return agentDescriptors[assistant.lowercased()]?.supports.steer ?? false
    }

    /// True when the session is blocked on a pending AskUserQuestion. Finds
    /// the LAST non-user `pending_input` item, ignoring trailing assistant/
    /// tool/system items that stream in after the question, and returns true
    /// only if that item is unresolved. Used to bypass the turn-queue gate so
    /// the answer reaches the broker immediately instead of deadlocking.
    func hasPendingAsk(sessionID: String) -> Bool {
        let items = conversationLog[sessionID] ?? []
        // Find the last non-user pending_input item, skipping trailing
        // assistant/tool/system items that stream in after the question.
        guard let idx = items.lastIndex(where: {
            $0.role.lowercased() != "user" && $0.kind.lowercased() == "pending_input"
        }) else { return false }
        let last = items[idx]
        // A user message AFTER the prompt means the answer was already sent (the
        // broker consumes the pending ask on the first user turn), so the next
        // message is a normal turn, not an answer.
        if items[items.index(after: idx)...].contains(where: { $0.role.lowercased() == "user" }) { return false }
        // Optimistic client-side resolution flag.
        if resolvedPendingInputIDs.contains(last.id) { return false }
        // Belt-and-suspenders: if the item carries a persisted resolution marker
        // (set by the broker on answer, kept in content by mapRemoteItem), the
        // card is already answered -- don't route the next message as an answer.
        if ConduitUI.ChatViewModel.parsePendingResolution(last.content)?.answered == true { return false }
        return true
    }

    /// Compute an anchor epoch one tick past the newest known item in the
    /// conversation log for `sessionID`. Used by both `resolvePendingInput`
    /// (to backfill the answered card's `ts`) and `answerPendingInput` (to
    /// stamp the optimistic user echo). Mirrors the Android helper
    /// `anchorEpochMillis`.
    ///
    /// Resolution order:
    ///   1. max parseable epoch across conversationLog + chatLog + 0.001 s
    ///   2. session startedAt epoch + 0.001 s
    ///   3. Date().timeIntervalSince1970 (last resort)
    private func anchorEpoch(sessionID: String) -> Double {
        let lastKnownEpoch = ((conversationLog[sessionID] ?? []).map { $0.ts }
            + (chatLog[sessionID] ?? []).map { $0.ts })
            .map { conduitConversationTsEpoch($0) }
            .filter { $0 < .greatestFiniteMagnitude }
            .max()
        let startedEpoch = (statusBySession[sessionID]?.startedAt)
            .map { conduitConversationTsEpoch($0) }
            .flatMap { $0 < .greatestFiniteMagnitude ? $0 : nil }
        return lastKnownEpoch.map { $0 + 0.001 }
            ?? startedEpoch.map { $0 + 0.001 }
            ?? Date().timeIntervalSince1970
    }

    /// Optimistically mark the last unanswered `pending_input` item for a
    /// session as resolved so the inline chat card flips to "ANSWERED" immediately
    /// on decision success, without waiting for the broker's WS echo. Called from
    /// every out-of-band decision path (ConduitApprovalsView, lock-screen intent).
    /// Idempotent; no-op when no unresolved pending item exists.
    ///
    /// Also backfills the card's `ts` if it is currently empty or unparseable
    /// (i.e. `conduitConversationTsEpoch` returns `.greatestFiniteMagnitude`).
    /// Without the backfill the chip stays pinned to the bottom of the
    /// transcript even after later assistant turns arrive — because the sort
    /// treats an empty `ts` as "newest". Stamping it one tick past the max
    /// known epoch anchors it in chronological order.
    func resolvePendingInput(sessionID: String) {
        var items = conversationLog[sessionID] ?? []
        guard let idx = items.indices.last(where: {
            items[$0].kind.lowercased() == "pending_input"
                && !resolvedPendingInputIDs.contains(items[$0].id)
        }) else { return }
        let item = items[idx]
        resolvedPendingInputIDs.insert(item.id)
        // Backfill ts if the card has no real broker timestamp so the chip
        // sorts into its chronological position rather than floating to the
        // bottom of the transcript.
        if conduitConversationTsEpoch(item.ts) == .greatestFiniteMagnitude {
            let stampedTs = conduitConversationTsString(epoch: anchorEpoch(sessionID: sessionID))
            items[idx].ts = stampedTs
            conversationLog[sessionID] = items
            Telemetry.breadcrumb("approvals", "pending_input ts backfilled on resolve",
                data: ["session": sessionID, "item_id": item.id, "ts": stampedTs])
        }
        Telemetry.breadcrumb("approvals", "pending_input optimistically resolved",
            data: ["session": sessionID, "item_id": item.id])
    }

    /// Deliver an elicitation answer DIRECTLY, bypassing the `isTurnActive`
    /// queue gate. The broker's `sendChat` handler already routes a message
    /// that arrives while a `pending_ask` is active to `takePendingAsk` /
    /// `encodeAskAnswer`, which resumes the blocked turn. Trapping the answer
    /// in `sendChatQueued` instead causes a deadlock: the turn never ends
    /// (result never arrives), so `flushQueuedOnTurnComplete` never fires.
    ///
    /// This path intentionally skips slash-command routing, optimistic echo
    /// (the pending-input card is already the visual placeholder), and the
    /// normal `pendingChats` queue -- it just registers a pending entry and
    /// immediately attempts WS delivery, the same as the bottom half of
    /// `sendChat` when the turn is idle.
    func answerPendingInput(sessionID: String, message: String) {
        Telemetry.breadcrumb("chat", "answer-pending-input",
            data: ["session": sessionID, "chars": "\(message.count)"])
        // Anchor the echo into the broker clock domain (same approach as
        // `sendChat`) so it sorts ahead of the agent's reply regardless of
        // device-vs-broker clock drift.
        let echoEpoch = anchorEpoch(sessionID: sessionID)
        let now = conduitConversationTsString(epoch: echoEpoch)
        let localID = "local-\(UUID().uuidString)"
        quickReplies[sessionID] = nil
        resolvePendingInput(sessionID: sessionID)
        pendingChats.enqueue(sessionID: sessionID, localID: localID, message: message, ts: now)
        attemptDeliver(sessionID: sessionID, localID: localID, message: message)
    }

    func sendChat(sessionID: String, message: String, bypassTurnGate: Bool = false) {
        // §D: a fresh user turn is the retry — drop any standing agent-auth
        // failure flag so the "Sign in on this box" banner clears. If the
        // retry 401s again, the next assistant/result line re-sets it.
        if agentAuthFailure[sessionID] != nil { agentAuthFailure[sessionID] = nil }
        // Slash-command routing: intercept recognised `/`-commands before
        // they reach the agent. Pass-through commands (Claude only) fall
        // through to the normal send below; app-handled ones are handled
        // here and we return early. See docs/SLASH-COMMANDS.md.
        if handleSlashCommand(sessionID: sessionID, message: message) { return }

        // Diagnostic: capture the routing-decision inputs for EVERY delivered
        // send so a message that silently gets queued behind a stuck turn, or
        // consumed as an answer to a stale pending-ask, is reconstructable from
        // Sentry without a repro. This is the "no replies after /clear" device
        // report (#844 verification): the reply path is proven healthy, so the
        // failure is a mis-route here — record which branch we're about to take.
        // Cheap: ring-buffered breadcrumb, attached to the next captured event.
        Telemetry.breadcrumb("chat", "send routing", data: [
            "session": sessionID,
            "turn_active": isTurnActive(sessionID: sessionID) ? "1" : "0",
            "pending_ask": hasPendingAsk(sessionID: sessionID) ? "1" : "0",
            "has_client": clientForSession(sessionID) != nil ? "1" : "0",
            "is_slash": message.hasPrefix("/") ? "1" : "0",
        ])

        // ELICITATION BYPASS: if the session is blocked on a pending
        // AskUserQuestion, the answer MUST bypass the turn-queue gate and
        // reach the broker immediately. Routing through `sendChatQueued`
        // here deadlocks: the answer is held until the turn ends, but the
        // turn can only end once the answer is delivered.
        if hasPendingAsk(sessionID: sessionID) {
            answerPendingInput(sessionID: sessionID, message: message)
            return
        }

        // QUEUED-NEXT GATE: if a turn is active, queue the message in the
        // "Queued Next" panel instead of delivering immediately. For codex
        // (supports.steer), queue AND immediately attempt a steer so the
        // message is injected into the running turn. For all other agents
        // (claude, etc.), hold it and auto-send when the turn ends.
        // bypassTurnGate=true is used by flushQueuedOnReply to deliver a
        // queued message even when turn_active has not yet flipped false (the
        // assistant reply is itself proof the turn ended).
        if !bypassTurnGate, isTurnActive(sessionID: sessionID) {
            sendChatQueued(sessionID: sessionID, message: message)
            return
        }

        // Bug #2: previously this method returned early when `client`
        // was nil -- that swallowed the optimistic local echo *and* the
        // outbound WS write, so typing into the composer simply
        // disappeared if the user happened to send during a reconnect
        // window. Always materialize the local echo first so the user
        // sees their own message, and only skip the outbound WS write
        // when we genuinely have no transport.
        //
        // Optimistic local echo so the user sees their message immediately.
        // The harness doesn't loop user messages back as `on_chat_event`, so
        // without this the chat tab stays empty until the assistant replies.
        // The synthetic item carries a `local-` id; `refreshConversation`
        // preserves it until the server's typed log catches up by content.
        //
        // Anchor the echo into the broker clock domain rather than the device
        // wall-clock: every item already in the log is broker-stamped, as is
        // the reply this triggers. Stamping with a device clock that runs
        // ahead of the broker sorts the echo AFTER its reply (agent-before-user
        // bug). One ms past the newest known item keeps it ahead of any reply
        // regardless of device drift; fall back to now() for the first turn.
        let lastKnownEpoch = ((conversationLog[sessionID] ?? []).map { $0.ts }
            + (chatLog[sessionID] ?? []).map { $0.ts })
            .map { conduitConversationTsEpoch($0) }
            .filter { $0 < .greatestFiniteMagnitude }
            .max()
        // First turn has nothing to anchor to: anchor to the broker-stamped
        // session start rather than the device clock. The reply is
        // broker-stamped and necessarily after session start, so start+1ms
        // keeps the echo ahead of it even when the device runs ahead. This is
        // the codex case (one-shot reply, tiny gap) where the old device-now
        // fallback flipped the order. now() is the last resort.
        let startedEpoch = (statusBySession[sessionID]?.startedAt)
            .map { conduitConversationTsEpoch($0) }
            .flatMap { $0 < .greatestFiniteMagnitude ? $0 : nil }
        let echoEpoch = lastKnownEpoch.map { $0 + 0.001 }
            ?? startedEpoch.map { $0 + 0.001 }
            ?? Date().timeIntervalSince1970
        let now = conduitConversationTsString(epoch: echoEpoch)
        let localID = "local-\(UUID().uuidString)"
        let item = ConversationItem(
            id: localID,
            role: "user",
            kind: "message",
            // PENDING until a successful WS write acks it (flushPendingChats
            // flips it to "done"). The user bubble draws a clock while
            // pending and a retry affordance if it ultimately fails.
            status: "pending",
            content: message,
            ts: now,
            files: [],
            toolName: nil,
            command: nil,
            exitCode: nil,
            durationMs: nil,
            diffSummary: nil,
            pendingOptions: [],
            sourceAgent: nil,
            targetAgent: nil,
            taskText: nil,
            resultSummary: nil,
            planSteps: []
        )
        conversationLog[sessionID, default: []].append(item)
        let localEvent = ChatEvent(role: "user", content: message, ts: now, files: [])
        chatLog[sessionID, default: []].append(localEvent)
        // Funnel: first ever turn sent -- first session, no prior conversation items.
        let priorItems = (conversationLog[sessionID] ?? []).filter { !$0.id.hasPrefix("local-") }
        if sessions.count <= 1, priorItems.isEmpty {
            Telemetry.breadcrumb("onboarding", OnboardingStep.firstTurnSent,
                data: ["session": sessionID,
                       "chars": "\(message.count)"])
        }
        // The user has answered -- clear the AI quick-reply chips so they
        // don't linger over the next turn (task #233).
        quickReplies[sessionID] = nil
        if useRustStore {
            ensureRustSessionPresent(sessionID)
            _ = rustStore.applyChat(sessionId: sessionID, event: localEvent)
        }
        // Register the message as pending and persist BEFORE attempting any
        // WS write. This is the fix for the device-reported "send then
        // background -> message lost" bug: the queue (and the persisted copy)
        // outlives a fire-and-forget WS write that the OS may suspend before
        // it flushes, and outlives `client == nil` during a reconnect window.
        // The flush -- on connect / foreground / reconnect -- re-delivers it.
        pendingChats.enqueue(sessionID: sessionID, localID: localID, message: message, ts: now)
        Telemetry.breadcrumb("chat", "queued", data: ["session": sessionID, "chars": "\(message.count)"])
        // Attempt immediate delivery. If `client` is nil (reconnect window)
        // we DON'T drop it -- it stays queued for the next flush. Previously
        // a nil client here silently abandoned the WS write.
        attemptDeliver(sessionID: sessionID, localID: localID, message: message)
    }

    /// Queue a message in the "Queued Next" panel while a turn is active.
    /// For codex (supports.steer) this immediately attempts a steer; for
    /// all other agents (claude, etc.) it holds the entry and auto-sends
    /// when the turn ends via `flushQueuedOnTurnComplete`.
    ///
    /// NOTE: The optimistic transcript echo is NOT created here -- the
    /// panel card is the visual placeholder. The echo is created when the
    /// entry is actually delivered (turn ends or steer succeeds).
    private func sendChatQueued(sessionID: String, message: String) {
        let now = conduitConversationTsString(epoch: Date().timeIntervalSince1970)
        let localID = "local-\(UUID().uuidString)"
        pendingChats.enqueueForActiveTurn(sessionID: sessionID, localID: localID, message: message, ts: now)
        Telemetry.breadcrumb("chat", "queued for active turn",
            data: ["session": sessionID, "chars": "\(message.count)",
                   "supports_steer": supportsSteer(sessionID: sessionID) ? "1" : "0"])

        if supportsSteer(sessionID: sessionID) {
            // Codex: attempt immediate steer injection.
            steerQueuedEntry(sessionID: sessionID, localID: localID, message: message)
        }
        // Claude / others: no-op here; flushQueuedOnTurnComplete fires on turn-end.
    }

    /// Attempt to steer a queued codex entry into the running turn by
    /// delivering it via the normal chat-send path. The broker sees an active
    /// turn and routes via `turn/steer`. On WS-write success the card clears;
    /// on failure the kind flips to `.retrying` so the Steer button re-appears.
    func steerQueuedEntry(sessionID: String, localID: String, message: String) {
        guard let client = clientForSession(sessionID) else {
            pendingChats.markRetrying(sessionID: sessionID, localID: localID)
            return
        }
        pendingChats.markSteering(sessionID: sessionID, localID: localID)
        Telemetry.breadcrumb("chat", "steer attempt",
            data: ["session": sessionID, "local_id": localID])
        Task {
            do {
                // Carry the localID as client_msg_id for broker dedup/ack
                // parity (task K). The steer panel card clears on WS-write as
                // before; the later chat_ack just no-ops (entry already gone).
                try await client.sendChat(sessionId: sessionID, msg: message, clientMsgId: localID)
                // Steer ack: the broker injected the message. Clear the panel card.
                self.pendingChats.markDelivered(sessionID: sessionID, localID: localID)
                Telemetry.breadcrumb("chat", "steer ack",
                    data: ["session": sessionID, "local_id": localID])
            } catch {
                // Steer failed: flip to retrying so the panel shows the Steer button.
                self.pendingChats.markRetrying(sessionID: sessionID, localID: localID)
                Telemetry.breadcrumb("chat", "steer failed -> retrying",
                    data: ["session": sessionID, "local_id": localID])
                Telemetry.capture(
                    error: error,
                    message: "iOS steer attempt failed",
                    tags: ["surface": "ios", "phase": "steer"],
                    extras: ["session": sessionID]
                )
            }
        }
    }

    /// Cancel a queued-turn entry the user no longer wants to send.
    /// Removes it from the panel and persists the updated queue.
    func cancelQueuedEntry(sessionID: String, localID: String) {
        pendingChats.markDelivered(sessionID: sessionID, localID: localID)
        Telemetry.breadcrumb("chat", "queued entry cancelled",
            data: ["session": sessionID, "local_id": localID])
    }

    /// Called when a turn transitions from active to idle for a session.
    /// Delivers the OLDEST queued-turn entry via the normal send path
    /// (which creates the optimistic echo and fires the WS write). Remaining
    /// entries stay queued for the NEXT turn-complete. If the entry is
    /// `.steering` it was already in flight; we skip it (delivery is
    /// in-progress or just succeeded). Un-steered or `.retrying` codex
    /// entries also flush here so nothing is lost.
    func flushQueuedOnTurnComplete(sessionID: String) {
        guard let entry = pendingChats.flushOnTurnComplete(sessionID: sessionID) else { return }
        Telemetry.breadcrumb("chat", "flush-on-turn-complete",
            data: ["session": sessionID, "local_id": entry.localID,
                   "kind": entry.kind.rawValue])
        // Remove the queued entry BEFORE re-sending so the queue doesn't
        // accumulate a duplicate when sendChat enqueues it again as .normal.
        pendingChats.markDelivered(sessionID: sessionID, localID: entry.localID)
        // Route through the full sendChat path so the optimistic echo is
        // created and the message is persisted via the normal enqueue(.normal).
        sendChat(sessionID: sessionID, message: entry.message)
    }

    /// Belt-and-suspenders flush called when a LIVE (not replayed) assistant
    /// reply arrives. A settled assistant reply is proof the turn ended, so we
    /// deliver the oldest queued-turn entry here even if the status frame
    /// reporting turn_active=false has not arrived yet (missed/delayed frame).
    /// Idempotent with flushQueuedOnTurnComplete: markDelivered removes the
    /// entry before re-sending, so whichever trigger fires second finds nil and
    /// is a no-op. The broker also dedups by client_msg_id.
    func flushQueuedOnReply(sessionID: String) {
        guard let entry = pendingChats.flushOnTurnComplete(sessionID: sessionID) else { return }
        Telemetry.breadcrumb("chat", "flush-on-reply",
            data: ["session": sessionID, "local_id": entry.localID,
                   "kind": entry.kind.rawValue])
        // Remove BEFORE re-sending so the queue never holds a duplicate.
        pendingChats.markDelivered(sessionID: sessionID, localID: entry.localID)
        // bypassTurnGate=true: the reply proves the turn is done even if
        // turn_active is still true in memory at this instant.
        sendChat(sessionID: sessionID, message: entry.message, bypassTurnGate: true)
    }

    /// True when a send/deliver error means the broker no longer knows this
    /// session (restarted/redeployed/GC'd) — `ConduitError.UnknownSession`.
    /// Such an error will NEVER recover by retrying the same dead session, so
    /// the deliver path stops retrying and routes the user to Resume instead
    /// of burning the retry budget + capturing a Sentry ERROR on every broker
    /// restart. Matched on the exact UniFFI case (not a string) so it stays
    /// correct if the message wording changes.
    // `internal` (not `private`) so the @testable unit suite can exercise the
    // exact-case match + the expired-echo flip without a live WS.
    func isUnknownSession(_ error: Error) -> Bool {
        if case ConduitError.UnknownSession = error { return true }
        return false
    }

    /// Handle a send/deliver that failed because the broker GC'd/forgot the
    /// session (`UnknownSession`). Stops retrying immediately (drops the entry
    /// from the queue so later flushes don't re-hit the dead session), marks
    /// the echo `expired` so the bubble offers a Resume affordance, and
    /// downgrades the telemetry to an info breadcrumb (NOT a captured ERROR).
    func handleExpiredSession(sessionID: String, localID: String, box: String?) {
        // Drop from the queue so flushPendingChats / turn-complete flushes
        // don't keep re-delivering into a session the broker no longer has.
        pendingChats.markDelivered(sessionID: sessionID, localID: localID)
        setEchoStatus(sessionID: sessionID, localID: localID, status: "expired")
        var data: [String: String] = ["session": sessionID]
        if let box { data["box"] = box }
        // Downgrade: info breadcrumb, not Telemetry.capture. This fires on
        // every broker restart and is not an actionable error.
        Telemetry.breadcrumb("chat", "send hit UnknownSession — session expired, offering Resume", data: data)
    }

    /// Attempt to deliver one queued message over the live WS, reporting the
    /// outcome back to `pendingChats` (ack on success, attempt-bump on
    /// failure) and flipping the transcript echo's status accordingly. Safe
    /// to call when `client` is nil — it just leaves the entry queued for a
    /// later flush. Shared by the send path and `flushPendingChats`.
    private func attemptDeliver(sessionID: String, localID: String, message: String) {
        // Multi-box: route to the connection that OWNS this session (via the
        // `sessionBox` stamp). If that box is connected we send there — no
        // cross-box block needed because every connected box is reachable at
        // once. If it ISN'T connected, fall through to the single-box gate so
        // the message stays queued with a clear "connect that box" prompt.
        if multiBoxEnabled, let stamped = sessionBox[sessionID], let conn = boxConnections[stamped] {
            let boxClient = conn.client
            Task {
                do {
                    // Pass the echo's stable localID as client_msg_id so the
                    // broker can dedup resends and ack THIS message (task K).
                    try await boxClient.sendChat(sessionId: sessionID, msg: message, clientMsgId: localID)
                    // WS write returned — NOT yet durably delivered. Keep the
                    // entry queued and faded; only the broker's chat_ack
                    // (onChatDelivered) marks it done.
                    self.pendingChats.markSent(sessionID: sessionID, localID: localID)
                    self.setEchoStatus(sessionID: sessionID, localID: localID, status: "sent")
                    Telemetry.breadcrumb("chat", "ws-write ok — awaiting broker ack",
                        data: ["session": sessionID, "box": stamped])
                } catch {
                    // Broker forgot the session (restart/redeploy/GC): retrying
                    // can't recover it. Stop now + route to Resume; don't burn
                    // the retry budget or capture a Sentry ERROR.
                    if self.isUnknownSession(error) {
                        self.handleExpiredSession(sessionID: sessionID, localID: localID, box: stamped)
                        return
                    }
                    let gaveUp = self.pendingChats.markAttemptFailed(sessionID: sessionID, localID: localID)
                    if gaveUp {
                        self.setEchoStatus(sessionID: sessionID, localID: localID, status: "failed")
                        Telemetry.capture(
                            error: error,
                            message: "chat send to agent failed (gave up after retries)",
                            tags: ["surface": "ios", "phase": "chat_send", "multibox": "1"],
                            extras: ["session": sessionID, "box": stamped]
                        )
                    } else {
                        Telemetry.breadcrumb("chat", "send attempt failed — keeping queued",
                            data: ["session": sessionID, "box": stamped])
                    }
                }
            }
            return
        }
        guard let client else { return }
        // Box-identity gate: if the session was stamped to a different box
        // than the one we're currently connected to, sending into this
        // client is wrong — it would reach the wrong broker and produce
        // ConduitError: UnknownSession. Surface the mismatch and leave the
        // message queued; the user must switch boxes to deliver it.
        //
        // On the multi-box path, a stamped-but-not-connected box also lands
        // here: the prompt then reads "connect that box" rather than "switch".
        let currentBoxID = savedHistoryServerID
        if let stamped = sessionBox[sessionID], stamped != currentBoxID {
            let boxName = savedServers.first(where: { $0.id == stamped })?.name
                ?? stamped
            Telemetry.breadcrumb("chat", "blocked — session on different box",
                data: ["session": sessionID, "session_box": stamped,
                       "current_box": currentBoxID])
            // Mark the echo as failed and remove from queue so it isn't
            // retried into the wrong broker on every flush.
            setEchoStatus(sessionID: sessionID, localID: localID, status: "failed")
            pendingChats.markDelivered(sessionID: sessionID, localID: localID)
            let action = multiBoxEnabled ? "Connect" : "Switch to"
            sessionCreationError = "Session is on '\(boxName)'. \(action) that box to send."
            return
        }
        Task {
            do {
                // Pass the echo's stable localID as client_msg_id so the
                // broker can dedup resends and ack THIS message (task K).
                try await client.sendChat(sessionId: sessionID, msg: message, clientMsgId: localID)
                // WS write returned — NOT yet durably delivered. Keep the
                // entry queued and faded; only the broker's chat_ack
                // (onChatDelivered) marks it done. This fixes the "send then
                // background → message lost but shown as sent" bug.
                self.pendingChats.markSent(sessionID: sessionID, localID: localID)
                self.setEchoStatus(sessionID: sessionID, localID: localID, status: "sent")
                Telemetry.breadcrumb("chat", "ws-write ok — awaiting broker ack",
                    data: ["session": sessionID])
            } catch {
                // Broker forgot the session (restart/redeploy/GC): retrying
                // can't recover it. Stop now + route to Resume; don't burn the
                // retry budget or capture a Sentry ERROR.
                if self.isUnknownSession(error) {
                    self.handleExpiredSession(sessionID: sessionID, localID: localID, box: nil)
                    return
                }
                let gaveUp = self.pendingChats.markAttemptFailed(sessionID: sessionID, localID: localID)
                if gaveUp {
                    self.setEchoStatus(sessionID: sessionID, localID: localID, status: "failed")
                    Telemetry.capture(
                        error: error,
                        message: "chat send to agent failed (gave up after retries)",
                        tags: ["surface": "ios", "phase": "chat_send"],
                        extras: ["session": sessionID]
                    )
                } else {
                    // Transient: stays queued + pending for the next flush.
                    Telemetry.breadcrumb("chat", "send attempt failed — keeping queued",
                        data: ["session": sessionID])
                }
            }
        }
    }

    /// Re-deliver every still-pending message for a session — called when the
    /// connection/agent becomes ready again (connect success, app foreground,
    /// reconnect). `failed` entries are skipped until the user retries them.
    /// Pass `nil` to flush every session.
    func flushPendingChats(sessionID: String? = nil) {
        let sessionIDs = sessionID.map { [$0] } ?? Array(pendingChats.bySession.keys)
        for sid in sessionIDs {
            let due = pendingChats.flushable(for: sid)
            guard !due.isEmpty else { continue }
            Telemetry.breadcrumb("chat", "flush pending", data: ["session": sid, "count": "\(due.count)"])
            for entry in due {
                attemptDeliver(sessionID: sid, localID: entry.localID, message: entry.message)
            }
        }
    }

    /// User tapped retry on a failed message bubble — re-arm the entry and
    /// attempt delivery again immediately.
    func retryPendingChat(sessionID: String, localID: String) {
        guard let entry = pendingChats.entries(for: sessionID).first(where: { $0.localID == localID }) else { return }
        pendingChats.retry(sessionID: sessionID, localID: localID)
        setEchoStatus(sessionID: sessionID, localID: localID, status: "pending")
        attemptDeliver(sessionID: sessionID, localID: localID, message: entry.message)
    }

    /// Flip the `status` of a `local-…` transcript echo in place (e.g.
    /// pending → done / failed). Drives the user-bubble indicator without
    /// touching the message content or its position in the log.
    private func setEchoStatus(sessionID: String, localID: String, status: String) {
        guard var items = conversationLog[sessionID],
              let idx = items.firstIndex(where: { $0.id == localID }) else { return }
        let old = items[idx]
        items[idx] = ConversationItem(
            id: old.id, role: old.role, kind: old.kind, status: status,
            content: old.content, ts: old.ts, files: old.files,
            toolName: old.toolName, command: old.command, exitCode: old.exitCode,
            durationMs: old.durationMs, diffSummary: old.diffSummary,
            pendingOptions: old.pendingOptions, sourceAgent: old.sourceAgent,
            targetAgent: old.targetAgent, taskText: old.taskText,
            resultSummary: old.resultSummary, planSteps: old.planSteps
        )
        conversationLog[sessionID] = items
    }

    /// Routes a recognised `/`-command. Returns true when handled here
    /// (caller must NOT send to the agent); false when the text isn't a
    /// command, or is a supported pass-through to deliver verbatim.
    private func handleSlashCommand(sessionID: String, message: String) -> Bool {
        let agent = sessions.first(where: { $0.id == sessionID })?.assistant ?? "claude"
        let descriptor = agentDescriptors[agent.lowercased()]
        guard let match = SlashCommandRegistry.classify(message, agent: agent, descriptor: descriptor) else { return false }
        if match.command.clazz == .passThrough {
            if match.supported { return false } // deliver verbatim to the agent
            let reason = descriptor.map { $0.displayName.isEmpty ? agent : $0.displayName } ?? agent
            postSystemMessage(sessionID, "\u{201C}/\(match.command.name)\u{201D} is not supported by \(reason).")
            return true
        }
        switch match.command.name {
        case "help":
            postSystemMessage(sessionID, slashHelpText())
        case "model":
            if match.args.isEmpty {
                postSystemMessage(sessionID, "Usage: /model <name> — forks this session onto a different model.")
            } else {
                forkSession(sessionID: sessionID, model: match.args)
                postSystemMessage(sessionID, "Forking onto model \u{201C}\(match.args)\u{201D}…")
            }
        case "effort":
            if match.args.isEmpty {
                postSystemMessage(sessionID, "Usage: /effort <minimal|low|medium|high> — forks with a different reasoning effort.")
            } else {
                forkSession(sessionID: sessionID, reasoningEffort: match.args)
                postSystemMessage(sessionID, "Forking with reasoning effort \u{201C}\(match.args)\u{201D}…")
            }
        // The live repeat-a-prompt loop is intentionally not wired yet — an
        // untested auto-sender hammering the agent is a bad blind ship.
        // Lands in a follow-up with on-device verification.
        case "loop":
            postSystemMessage(sessionID, "\u{201C}/loop\u{201D} is recognised; the repeat-a-prompt loop ships in a follow-up update.")
        case "usage", "context":
            postSystemMessage(sessionID, "\u{201C}/\(match.command.name)\u{201D} is a Claude Code terminal-only panel — it isn’t available in chat yet.")
        default:
            return false
        }
        return true
    }

    /// Appends a client-only `role:"system"` chat line (e.g. /help output,
    /// a "not supported" note). Mirrors the optimistic echo in `sendChat`;
    /// the `local-` id survives the next conversation refresh.
    private func postSystemMessage(_ sessionID: String, _ text: String) {
        let now = ISO8601DateFormatter().string(from: Date())
        let item = ConversationItem(
            id: "local-\(UUID().uuidString)",
            role: "system",
            kind: "message",
            status: "done",
            content: text,
            ts: now,
            files: [],
            toolName: nil,
            command: nil,
            exitCode: nil,
            durationMs: nil,
            diffSummary: nil,
            pendingOptions: [],
            sourceAgent: nil,
            targetAgent: nil,
            taskText: nil,
            resultSummary: nil,
            planSteps: []
        )
        conversationLog[sessionID, default: []].append(item)
        let ev = ChatEvent(role: "system", content: text, ts: now, files: [])
        chatLog[sessionID, default: []].append(ev)
        if useRustStore {
            ensureRustSessionPresent(sessionID)
            _ = rustStore.applyChat(sessionId: sessionID, event: ev)
        }
    }

    private func slashHelpText() -> String {
        var out = "Slash commands\n"
        for c in SlashCommandRegistry.commands {
            out += "/\(c.name) — \(c.description)\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func resize(sessionID: String, rows: UInt16, cols: UInt16) {
        guard let client = clientForSession(sessionID) else { return }
        Task { try? await client.resize(sessionId: sessionID, rows: rows, cols: cols) }
    }

    // MARK: - Agent credentials (PLAN-AGENT-OAUTH stage 2)

    /// Ship the per-user agent OAuth credential to the broker over the
    /// existing authenticated WS. The Rust transport picks any active
    /// session handle (the broker's set_agent_credentials handler keys
    /// the stored blob by bearer-token identity, not per-session — see
    /// docs/PLAN-AGENT-OAUTH.md §D.1).
    ///
    /// Encodes the credential's **native on-disk shape** as JSON (the
    /// inner `AuthDotJson` for OpenAI, the inner `ClaudeCredentialsJson`
    /// for Anthropic). The broker's parser at
    /// `broker/internal/ws/server.go:handleSetAgentCredentials` reads
    /// `credential` as `json.RawMessage` and persists it verbatim, so
    /// staying byte-for-byte aligned with what the agent CLI writes to
    /// disk means the broker can pass it through without translation.
    ///
    /// Throws `ConduitError.NotConnected` if no session is live; the
    /// caller is expected to keep the Keychain copy and surface a
    /// retry affordance (the Settings → Agent accounts "Sync to broker"
    /// row, or wait for the next `createSession` to fire the resend).
    func sendAgentCredentials(provider: OAuthProvider, credential: OAuthCredential) async throws {
        guard let client else {
            throw ConduitError.NotConnected(message: "no active conduit client")
        }
        let json = try Self.encodeCredentialAsJSONString(credential)
        try await client.setAgentCredentials(
            provider: provider.rawValue,
            credentialJson: json
        )
    }

    /// Push every locally-stored agent credential to a specific box over
    /// HTTP (`POST /api/agent/credentials`), independent of any live
    /// session. This is the session-less analogue of
    /// `replayStoredAgentCredentials()` (which rides the live WS via
    /// `sendAgentCredentials`): the connect paths call it so a box that was
    /// added AFTER sign-in still receives the device-global credential
    /// before its first session — the "signed in but 401 on another box"
    /// bug (docs/PLAN-credential-propagate.md §A).
    ///
    /// Best-effort per provider: a missing local credential, an encode
    /// failure, a network error, or a non-2xx (notably `503` from an old
    /// broker without the credential store) just breadcrumbs and moves on.
    /// POST /api/device/presence to every connected box so the broker knows
    /// this device is online. Fire-and-forget; never surfaces errors.
    func reportDevicePresence() async {
        let endpoints: [StoredEndpoint]
        if boxConnections.isEmpty {
            guard self.endpoint.isComplete else { return }
            endpoints = [self.endpoint]
        } else {
            endpoints = boxConnections.values.map { $0.endpoint }
        }
        for endpoint in endpoints {
            guard let base = endpoint.httpBaseURL else { continue }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.path = "/api/device/presence"
            guard let url = components?.url else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 10
            req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["device_id": DeviceIdentity.deviceID])
            Telemetry.breadcrumb("device_presence", "heartbeat", data: ["host": endpoint.displayHost])
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    /// Never throws — callers fire it from connect closures and must not
    /// have a propagate failure break the connect.
    ///
    /// The broker stores the `credential` bytes verbatim, so the body's
    /// `credential` field MUST be a real JSON OBJECT (the native blob),
    /// NOT a stringified blob — a quoted string would re-break auth. We
    /// reuse `encodeCredentialAsJSONString` (the canonical blob encoder)
    /// and re-parse its output via `JSONSerialization` to inject it as a
    /// JSON value.
    func propagateStoredAgentCredentials(to endpoint: StoredEndpoint) async {
        guard let base = endpoint.httpBaseURL else { return }
        for provider in [OAuthProvider.openai, .anthropic] {
            guard let credential = OAuthCredentialStore.load(provider: provider) else { continue }

            // Refresh Anthropic tokens that are near or past expiry before
            // pushing — a stale access token silently breaks agent auth.
            var credentialToPush = credential
            if case .anthropic(let creds) = credential {
                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                if creds.claudeAiOauth.expiresAt - nowMs < 5 * 60 * 1000 {
                    Telemetry.breadcrumb("agent_creds", "anthropic token near expiry — refreshing",
                                         data: ["host": endpoint.displayHost])
                    if let refreshed = try? await OAuthClient(provider: .anthropic)
                            .refreshAnthropicCredential(using: creds) {
                        try? OAuthCredentialStore.save(refreshed)
                        credentialToPush = refreshed
                        Telemetry.breadcrumb("agent_creds", "anthropic refresh ok before push",
                                             data: ["host": endpoint.displayHost])
                    } else {
                        Telemetry.breadcrumb("agent_creds", "anthropic refresh failed — pushing stale",
                                             data: ["host": endpoint.displayHost])
                    }
                }
            }

            guard let jsonString = try? Self.encodeCredentialAsJSONString(credentialToPush),
                  let blobData = jsonString.data(using: .utf8),
                  // Re-parse so `credential` lands as a nested JSON object,
                  // not a quoted string (the load-bearing correctness point).
                  let blobObject = try? JSONSerialization.jsonObject(with: blobData)
            else {
                Telemetry.breadcrumb("agent_creds", "propagate encode skipped", data: [
                    "host": endpoint.displayHost,
                    "provider": provider.rawValue,
                ])
                continue
            }
            let body: [String: Any] = [
                "provider": provider.rawValue,
                "kind": "oauth",
                "credential": blobObject,
            ]
            guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { continue }

            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.path = "/api/agent/credentials"
            guard let url = components?.url else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 15
            req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = bodyData

            Telemetry.breadcrumb("agent_creds", "propagate", data: [
                "host": endpoint.displayHost,
                "provider": provider.rawValue,
            ])
            guard let (_, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse
            else {
                Telemetry.breadcrumb("agent_creds", "propagate network error", data: [
                    "host": endpoint.displayHost,
                    "provider": provider.rawValue,
                ])
                continue
            }
            if (200..<300).contains(http.statusCode) {
                Telemetry.breadcrumb("agent_creds", "propagate stored", data: [
                    "host": endpoint.displayHost,
                    "provider": provider.rawValue,
                    "status": "\(http.statusCode)",
                ])
            } else {
                // 503 = old broker (no credential store); any other non-2xx is
                // a best-effort miss. Breadcrumb + continue, never surface.
                Telemetry.breadcrumb("agent_creds", "propagate non-2xx", data: [
                    "host": endpoint.displayHost,
                    "provider": provider.rawValue,
                    "status": "\(http.statusCode)",
                ])
            }
        }
    }

    /// Remove a single app-pushed agent credential from a specific box over
    /// HTTP (`POST /api/agent/credentials/clear`), independent of any live
    /// session. This is the per-box counterpart of
    /// `propagateStoredAgentCredentials(to:)`: it deletes the credential the
    /// app pushed to the broker's encrypted store so the box stops using the
    /// app account. It does NOT touch the box owner's own shell login
    /// (`~/.claude` / `~/.codex` created by `claude`/`codex` on the host) --
    /// see docs/PLAN-credential-propagate.md section C.
    ///
    /// Same request shape as the propagate POST, different path; the body is
    /// just `{"provider": <anthropic|openai>}` (no `credential`). Best-effort
    /// and idempotent: the broker answers 200 even when nothing was stored,
    /// and a 503 (old broker without the credential store) just breadcrumbs.
    /// Never throws -- callers fire it from menus and must not have a clear
    /// failure surface as an error.
    func clearAgentCredential(provider: OAuthProvider, on endpoint: StoredEndpoint) async {
        guard let base = endpoint.httpBaseURL else { return }
        let body: [String: Any] = ["provider": provider.rawValue]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }

        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/api/agent/credentials/clear"
        guard let url = components?.url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        Telemetry.breadcrumb("agent_creds", "clear", data: [
            "host": endpoint.displayHost,
            "provider": provider.rawValue,
        ])
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse
        else {
            Telemetry.breadcrumb("agent_creds", "clear network error", data: [
                "host": endpoint.displayHost,
                "provider": provider.rawValue,
            ])
            return
        }
        if (200..<300).contains(http.statusCode) {
            Telemetry.breadcrumb("agent_creds", "cleared", data: [
                "host": endpoint.displayHost,
                "provider": provider.rawValue,
                "status": "\(http.statusCode)",
            ])
        } else {
            Telemetry.breadcrumb("agent_creds", "clear non-2xx", data: [
                "host": endpoint.displayHost,
                "provider": provider.rawValue,
                "status": "\(http.statusCode)",
            ])
        }
    }

    // MARK: - Agent OAuth login v2 (outbound)
    //
    // Forward the three v2 login control frames through the Rust core's
    // UDL surface. Like `sendAgentCredentials`, the flow is identity-
    // scoped, so the core carries each frame over any live session WS;
    // broker handlers are live (PR #114) and progress returns as
    // `agent_login_*` view-events routed by `routeAgentLoginViewEvent`.
    // Throws `ConduitError.NotConnected` if no session is live — the
    // coordinator surfaces it to the sheet as `.failed`.

    func sendAgentLoginStart(provider: String) async throws {
        guard let client else {
            throw ConduitError.NotConnected(message: "no active conduit client")
        }
        try await client.startAgentLogin(provider: provider)
    }

    func sendAgentLoginCallback(sessionToken: String, queryString: String) async throws {
        guard let client else {
            throw ConduitError.NotConnected(message: "no active conduit client")
        }
        try await client.agentLoginCallback(sessionToken: sessionToken, queryString: queryString)
    }

    func sendAgentLoginCancel(sessionToken: String) async throws {
        guard let client else {
            throw ConduitError.NotConnected(message: "no active conduit client")
        }
        try await client.cancelAgentLogin(sessionToken: sessionToken)
    }

    /// Encode the credential's native blob to a JSON string suitable
    /// for the wire envelope's `credential` field. Hoisted as a
    /// `static` so the envelope-shape test in
    /// `AgentCredentialEnvelopeTests` can call it without spinning up a
    /// `SessionStore`.
    ///
    /// Why the inner blob and not the enum: the broker writes the bytes
    /// to disk byte-for-byte as `~/.codex/auth.json` /
    /// `~/.claude/.credentials.json`; the discriminated-enum wrapping we
    /// use locally would force the broker to peel a layer it doesn't
    /// care about. Same encoding shape as `AgentLoginSheet`'s
    /// `logCredentialToConsole` (PR #100) so the spike-time
    /// console-eyeball output is exactly what travels the wire.
    nonisolated static func encodeCredentialAsJSONString(_ credential: OAuthCredential) throws -> String {
        let encoder = JSONEncoder()
        // codex's auth.json `last_refresh` is an RFC3339 string
        // (DateTime<Utc>). Without this, Swift's default strategy encodes
        // `AuthDotJson.lastRefresh` (a Date) as a NUMBER, which codex fails
        // to deserialize → it rejects the OAuth file and falls back to
        // API-key mode. (Harmless for the Anthropic blob — it has no Dates.)
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        switch credential {
        case .openai(let blob):    data = try encoder.encode(blob)
        case .anthropic(let blob): data = try encoder.encode(blob)
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "SessionStore.sendAgentCredentials",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "credential JSON utf8 encode failed"]
            )
        }
        return string
    }

    // MARK: - Agent OAuth v2 (upstream pattern) transport
    //
    // The v2 flow (docs/PLAN-AGENT-OAUTH.md "Approach v2") drives the
    // OAuth dance broker-side: the iOS app sends a `start_agent_login`
    // control message, the broker spawns the CLI subprocess + emits an
    // `agent_login_url` view_event, the app opens that URL in
    // `ASWebAuthenticationSession`, captures the loopback callback on
    // 127.0.0.1, and ships the raw query string back via
    // `agent_login_callback`. The broker waits for the CLI to mint
    // tokens and emits `agent_login_complete`.
    //
    // The send-side wiring requires UDL surface
    // (`ConduitClient.start_agent_login` etc.) that hasn't shipped in
    // the ConduitCore xcframework yet — the broker (PR #114) is live
    // but the Rust→Swift bridge is the missing link. Until that lands,
    // the transport methods throw a typed "not yet bridged" error so
    // the coordinator's state machine resolves to `.failed(...)` with
    // an actionable message instead of hanging forever. The inbound
    // dispatch sites below are already wired so the moment the Rust
    // bridge lands the flow is one method-body update away from green.

    /// Dispatch an inbound `agent_login_*` view_event to the active
    /// coordinator. Called from the WS receive path (see
    /// `dispatchViewEvent(_:)`). No-op when no coordinator is bound —
    /// late deliveries after `cancel()` are silently dropped, same as
    /// the broker side's stale-token handling in `login_session.go`.
    func routeAgentLoginViewEvent(kind: String, payload: [String: String]) {
        guard let coordinator = activeLoginCoordinator else { return }
        switch kind {
        case "agent_login_url":
            guard
                let portStr = payload["loopback_port"], let port = UInt16(portStr),
                let token = payload["session_token"],
                let urlStr = payload["url"], let url = URL(string: urlStr)
            else { return }
            coordinator.handleAgentLoginURL(loopbackPort: port, sessionToken: token, authorizeURL: url)
        case "agent_login_complete":
            coordinator.handleAgentLoginComplete()
            activeLoginCoordinator = nil
        case "agent_login_failed":
            let reason = payload["reason"] ?? "broker reported failure"
            coordinator.handleAgentLoginFailed(reason: reason)
            activeLoginCoordinator = nil
        default:
            break
        }
    }

    /// Re-send any Keychain-stored agent credentials over the (now
    /// live) WS. Called after `createSession` succeeds so a brand-new
    /// pairing immediately gets the user's tokens — without waiting
    /// for the user to navigate to Settings.
    ///
    /// Best-effort: errors are logged via Telemetry but never bubbled
    /// up to the UI, because the Keychain copy is canonical (the broker
    /// just mirrors it). Idempotent on the broker side
    /// (last-writer-wins per PLAN §D.1).
    fileprivate func replayStoredAgentCredentials() {
        for provider in [OAuthProvider.openai, .anthropic] {
            guard let credential = OAuthCredentialStore.load(provider: provider) else { continue }
            Task { @MainActor in
                do {
                    try await self.sendAgentCredentials(provider: provider, credential: credential)
                } catch {
                    Telemetry.capture(
                        error: error,
                        message: "iOS agent credential replay failed",
                        tags: [
                            "surface": "ios",
                            "phase": "agent_credentials_replay",
                            "provider": provider.rawValue,
                        ],
                        extras: ["detail": String(describing: error)]
                    )
                }
            }
        }
    }

    /// Upload a file to the session via the 0x01 binary WS frame
    /// (sweswe-parity #file-upload). The broker lands the bytes under
    /// `<workspace>/uploads/<sessionID>/<filename>` and emits a tool
    /// view_event when it's done — that's what surfaces back as a
    /// chat-tab notification, no inline message needed.
    func sendFile(sessionID: String, filename: String, mime: String, payload: Data) {
        guard let client = clientForSession(sessionID) else { return }
        Task {
            try? await client.sendFile(
                sessionId: sessionID,
                filename: filename,
                mime: mime,
                payload: payload
            )
        }
    }

    // MARK: - Pinned context

    /// Pin a context chip onto `sessionID`. No-op if an identical
    /// chip (same kind + payload) is already pinned — keeps the UI
    /// from accumulating duplicates when the same file is dragged
    /// in twice.
    func pinContext(_ ctx: PinnedContext, for sessionID: String) {
        var list = pinnedContexts[sessionID] ?? []
        guard !list.contains(where: { $0.kind == ctx.kind && $0.payload == ctx.payload }) else { return }
        list.append(ctx)
        pinnedContexts[sessionID] = list
    }

    /// Remove a pinned context by id. Used by ContextBar's tap-to-
    /// dismiss affordance.
    func unpinContext(_ id: UUID, from sessionID: String) {
        guard var list = pinnedContexts[sessionID] else { return }
        list.removeAll { $0.id == id }
        if list.isEmpty {
            pinnedContexts.removeValue(forKey: sessionID)
        } else {
            pinnedContexts[sessionID] = list
        }
    }

    // MARK: - Internal

    fileprivate func refreshSessions() {
        // Multi-box path: the "live" set is the UNION of every connected box's
        // sessions, each stamped to its own box. Build that union, then keep
        // every OTHER session as a dimmed history row (unchanged grouping).
        // The single global `client` may be nil here (boxes own their own
        // clients), so this branch must not depend on it.
        if multiBoxEnabled, !boxConnections.isEmpty {
            var liveStampedIDs = Set<String>()
            var live: [ProjectSession] = []
            var seen = Set<String>()
            for (boxID, conn) in boxConnections {
                let boxListed = conn.client.listSessions()
                    .filter { !SavedSessionsStore.shared.isTombstoned(id: $0.id) }
                for s in boxListed {
                    sessionBox[s.id] = boxID          // stamp ownership (routing key)
                    liveStampedIDs.insert(s.id)
                    if seen.insert(s.id).inserted { live.append(s) }
                }
            }
            // Other-box rows (not currently live on any connected box) stay as
            // dimmed history, exactly as the single-box path keeps them.
            let historyRows = sessions.filter { !liveStampedIDs.contains($0.id) }
            sessions = historyRows + live
            for s in self.sessions where sessionLifecycle[s.id] == nil {
                if let phase = statusBySession[s.id]?.phase,
                   phase.lowercased().hasPrefix("exited") {
                    sessionLifecycle[s.id] = .exited(Self.exitCode(fromPhase: phase) ?? 0)
                }
            }
            for s in self.sessions {
                refreshConversationOffMain(sessionID: s.id)
            }
            return
        }
        guard let client else { return }
        // Drop any session the user has explicitly deleted. The deployed
        // broker keeps tmux-backed PTYs alive (#199), so `listSessions`
        // can keep reporting a just-deleted session — without this filter
        // it would reappear in the home list and (because its tmux is
        // live) read as interactive. The client-side tombstone is the
        // guarantee that delete is terminal regardless of broker state.
        let listed = client.listSessions()
            .filter { !SavedSessionsStore.shared.isTombstoned(id: $0.id) }
        // Per-box merge: stamp each listed session with the currently-connected
        // box so the home list can group by box and gate sends to the right
        // broker. Always stamp, even when the list is empty, so the box
        // identity is established for subsequent calls.
        let currentBoxID = savedHistoryServerID
        for s in listed {
            sessionBox[s.id] = currentBoxID
        }
        // Box-switch fix: instead of replacing ALL sessions or skipping
        // entirely (the old "if !listed.isEmpty" guard), merge at the
        // box granularity:
        //   - Keep sessions whose sessionBox stamp points to a DIFFERENT box
        //     (they stay visible as dimmed history rows per #522).
        //   - Replace this box's session entries with the freshly-listed ones.
        // This means a box switch (A->B) correctly shows:
        //   - Box B's sessions once the broker responds (even if box B has zero
        //     sessions -- the correct empty state for that box).
        //   - Box A's prior sessions remain (stamped boxA) until B fully loads.
        // The old guard prevented box B from ever populating when the Rust
        // client returned [] before status frames landed -- the "stuck showing
        // previous box" bug.
        let otherBoxSessions = sessions.filter { s in
            guard let stamp = sessionBox[s.id] else { return false }
            return stamp != currentBoxID
        }
        sessions = otherBoxSessions + listed
        // Do NOT blanket-default listed sessions to `.live`. `listSessions`
        // can include recovered / exited / not-currently-running rows, and
        // a default of `.live` made every one of them open interactive
        // (the "History still interactive" bug). Liveness is now proven by
        // a live-phase status delta (`ingestStatus`) or the create/attach
        // round-trip — never by mere presence in the list. We seed a
        // terminal lifecycle from the listed phase when we can already see
        // the session is dead, so `isReadOnly` is correct on first paint
        // even before a fresh status frame arrives.
        for s in self.sessions where sessionLifecycle[s.id] == nil {
            if let phase = statusBySession[s.id]?.phase,
               phase.lowercased().hasPrefix("exited") {
                sessionLifecycle[s.id] = .exited(Self.exitCode(fromPhase: phase) ?? 0)
            }
        }
        // Fan out the per-session conversation pulls OFF the main thread:
        // doing N blocking FFI clones on the @MainActor every status delta
        // was the App Hang source. Results apply back on the main actor.
        for s in self.sessions {
            refreshConversationOffMain(sessionID: s.id)
        }
    }

    // `internal` access (not `fileprivate`) so ConduitTests can drive
    // the parity tests in SessionStoreRustParityTests. Same rationale
    // as `ingestChat` / `ingestStatus`.
    func ingestPtyData(_ sessionID: String, _ bytes: Data) {
        terminalBuffer[sessionID, default: Data()].append(bytes)
        scheduleTerminalPersist(sessionID)
        if useRustStore {
            // Synthesize the session in Rust if Swift hasn't seen it yet —
            // PTY data can race ahead of `register_session` from
            // `create_session`. Without the placeholder the `apply_pty_data`
            // returns nil and the parity check below would falsely fail.
            ensureRustSessionPresent(sessionID)
            _ = rustStore.applyPtyData(sessionId: sessionID, data: bytes)
            #if DEBUG
            assertRustScrollbackParity(sessionID)
            #endif
        }
    }

    // `internal` (not `fileprivate`) so ConduitTests can drive this
    // path directly. The fileprivate access was originally to lock
    // down "only the transport delegate can ingest"; that constraint
    // is fine to relax for tests because the type guards (ChatEvent)
    // make malformed calls a compile error anyway.
    /// Ingest a broker-generated quick-reply set for a session (task
    /// #233). Replaces any prior set; an unusable payload (no replies)
    /// clears the chips. Mirrored on Android in `ingestQuickReplies`.
    func ingestQuickReplies(_ sessionID: String, payload: [String: String]) {
        if let qr = AIQuickReplies.from(payload: payload) {
            quickReplies[sessionID] = qr
        } else {
            quickReplies[sessionID] = nil
        }
    }

    /// The broker acked durable receipt of a chat we sent (task K). The
    /// `clientMsgId` is the optimistic echo's `localID`. Drop the entry from
    /// the persisted outbox (so it is NOT re-sent) and flip the transcript
    /// echo to "done" (solid bubble). Idempotent: a duplicate ack (e.g. a
    /// resend whose first ack we missed) just no-ops once the entry is gone.
    func ingestChatDelivered(_ sessionID: String, clientMsgId: String) {
        Telemetry.breadcrumb("chat", "broker ack — delivered",
            data: ["session": sessionID, "local_id": clientMsgId])
        pendingChats.markDelivered(sessionID: sessionID, localID: clientMsgId)
        setEchoStatus(sessionID: sessionID, localID: clientMsgId, status: "done")
    }

    /// Handle a `chat_streaming` view_event: store partial assistant content
    /// as the in-memory streaming overlay and feed the StreamingRendererCoordinator.
    /// No-op if the payload is missing required fields (old broker path).
    func ingestChatStreaming(_ sessionID: String, payload: [String: String]) {
        guard let content = payload["content"], let turnTs = payload["turn_ts"] else { return }
        streamingMessage[sessionID] = content
        // Record the turn timestamp of the active streaming turn. ingestChat
        // uses this to skip clearing streaming state when a broker replay
        // delivers an older settled message during a live turn.
        streamingTurnTs[sessionID] = turnTs
        Telemetry.breadcrumb("streaming", "partial arrived",
            data: ["turn_ts": turnTs, "len": "\(content.count)", "session": sessionID])
        if let coordinator = streamingCoordinator {
            coordinator.update(itemID: "streaming-\(turnTs)", content: content, isComplete: false)
        }
    }

    /// Handle a `turn_phase` view_event: record the current broker-reported
    /// turn phase ("writing", "working", or ""). Used by the typing indicator
    /// to show distinct states instead of a generic "typing" animation.
    func ingestTurnPhase(_ sessionID: String, payload: [String: String]) {
        let phase = payload["turn_phase"] ?? ""
        turnPhaseBySession[sessionID] = phase
    }

    /// Handle a `thinking_streaming` view_event: store the accumulated reasoning
    /// text for the current Claude turn. Ephemeral (not persisted). Cleared
    /// alongside streamingMessage when the turn ends.
    func ingestThinkingStreaming(_ sessionID: String, payload: [String: String]) {
        guard let content = payload["content"] else { return }
        thinkingBySession[sessionID] = content
        Telemetry.breadcrumb("thinking", "partial arrived",
            data: ["len": "\(content.count)", "session": sessionID])
    }

    func ingestChat(_ sessionID: String, _ event: ChatEvent) {
        // Funnel: first assistant reply on the very first session.
        // Guard: no prior assistant items in the chat log for this session.
        if event.role == "assistant" {
            let priorAssistant = (chatLog[sessionID] ?? []).filter { $0.role == "assistant" }
            if sessions.count <= 1, priorAssistant.isEmpty {
                Telemetry.breadcrumb("onboarding", OnboardingStep.firstReplyReceived,
                    data: ["session": sessionID,
                           "chars": "\(event.content.count)"])
            }
            // Reconcile: a reply proves the broker received the sent message(s).
            // Drain `sent=true` pending entries so their bubbles go solid now
            // without waiting for the explicit chat_ack (which may race or lag).
            let drained = pendingChats.drainSentNormal(sessionID: sessionID)
            for localID in drained {
                setEchoStatus(sessionID: sessionID, localID: localID, status: "done")
            }
            if !drained.isEmpty {
                Telemetry.breadcrumb("chat", "reconciled sent on reply",
                    data: ["session": sessionID, "count": "\(drained.count)"])
            }
            // Final assistant message arrived — clear the in-memory streaming
            // overlay. Guard: only clear when this event belongs to the
            // current-or-newer turn, not an older broker-replayed transcript
            // message. On WS reconnect the broker replays the last 200 settled
            // messages; each replayed assistant event must NOT evict the live
            // streaming state for an in-flight turn that is still producing
            // tokens. Compare the event ts against streamingTurnTs to decide.
            let shouldClearStreaming: Bool = {
                guard let activeTurnTs = streamingTurnTs[sessionID] else {
                    // No active streaming turn recorded: safe to clear.
                    return true
                }
                let activeTurnEpoch = conduitConversationTsEpoch(activeTurnTs)
                let eventEpoch = conduitConversationTsEpoch(event.ts)
                if activeTurnEpoch == .greatestFiniteMagnitude || eventEpoch == .greatestFiniteMagnitude {
                    // Timestamps not comparable (unparseable); fall back to
                    // checking whether the broker says the turn is still active.
                    return statusBySession[sessionID]?.turnActive != true
                }
                // Clear only when this event is the current turn or newer.
                return eventEpoch >= activeTurnEpoch
            }()
            if shouldClearStreaming {
                streamingMessage[sessionID] = nil
                turnPhaseBySession[sessionID] = nil
                streamingTurnTs[sessionID] = nil
                thinkingBySession[sessionID] = nil
                // Belt-and-suspenders: flush the oldest queued-turn entry now
                // that we know the turn settled (the reply IS the proof). This
                // handles the case where the status frame reporting
                // turn_active=false was missed or delayed across a reconnect.
                // Idempotent with flushQueuedOnTurnComplete (second call gets nil).
                flushQueuedOnReply(sessionID: sessionID)
            } else {
                Telemetry.breadcrumb("streaming", "replay skipped clear",
                    data: ["session": sessionID, "event_ts": event.ts,
                           "turn_ts": streamingTurnTs[sessionID] ?? ""])
            }
        }
        chatLog[sessionID, default: []].append(event)
        // Memory telemetry: breadcrumb at milestones so Sentry has context
        // before a crash/hang caused by a large in-memory conversation store.
        let chatCount = chatLog[sessionID]?.count ?? 0
        if chatCount == 100 || chatCount == 500 || chatCount == 1000 || (chatCount > 1000 && chatCount % 2500 == 0) {
            let convCount = conversationLog[sessionID]?.count ?? 0
            Telemetry.breadcrumb("memory", "chat_log_milestone",
                data: ["session": sessionID, "chat": "\(chatCount)", "conv": "\(convCount)"])
        }
        // §D 401 handling (string-match fallback): the claude/codex auth
        // failure currently arrives as plain assistant/result chat text with
        // no typed signal (broker claudechat.go; the typed
        // `agent_auth_required` view_event is a deferred follow-up — see
        // docs/PLAN-credential-propagate.md §D + "Follow-up"). Detect it here
        // and auto-recover by re-propagating the device credential to this
        // session's box, plus flagging the session so the chat surfaces a
        // "Sign in on this box" affordance instead of a bare error.
        if event.role == "assistant" || event.role == "result" {
            detectAgentAuthFailure(sessionID: sessionID, text: event.content)
        }
        // A fresh user/assistant turn invalidates the previous turn's AI
        // chips — clear them so stale suggestions don't linger. The
        // broker emits the new set after the assistant turn completes.
        quickReplies[sessionID] = nil
        refreshConversationOffMain(sessionID: sessionID)
        if useRustStore {
            ensureRustSessionPresent(sessionID)
            // applyChat returns the full ProjectSessionState over FFI — on a
            // large session this deserializes hundreds of ConversationItems, which
            // blocked the main thread for up to 28 s (CONDUIT-IOS-2P). The return
            // value is discarded; the Rust store is an async cache that the next
            // refreshConversation will pick up. Fire and forget on a background
            // queue so the main actor stays responsive.
            let store = rustStore
            let sid = sessionID
            let ev = event
            rustApplyQueue.async {
                _ = store.applyChat(sessionId: sid, event: ev)
            }
        }
        // Notify the streaming renderer that an assistant turn landed.
        // The harness delivers `ChatEvent`s whole (no per-token deltas
        // yet — see broker/transport), so every ingest is the terminal
        // chunk for that fingerprint. The coordinator is keyed by
        // `ConversationItem.id`; we mirror the same id resolution the
        // view will use by matching role+content against the freshly
        // refreshed conversation log. When the broker grows real
        // streaming this is where the partial deltas will land.
        if let coordinator = streamingCoordinator, event.role == "assistant" {
            let fingerprint = "\(event.role)|\(event.content)"
            let id = conversationLog[sessionID]?
                .last(where: { "\($0.role)|\($0.content)" == fingerprint })?
                .id ?? "chat-\(sessionID)-\(event.ts)"
            coordinator.update(itemID: id, content: event.content, isComplete: true)
        }
    }

    /// §D string-match 401 detection. Narrow + provider-attributed to avoid
    /// false positives on benign chat text that merely mentions "401". On a
    /// hit we (1) flag the session so the chat shows a "Sign in on this box"
    /// affordance, and (2) best-effort re-propagate the device credential to
    /// the session's box over HTTP (the box may simply be missing the
    /// credential — re-pushing it lets a retry succeed without user action).
    /// If no device credential exists, the flag stands and the banner routes
    /// the user to sign in. The typed-event version is a deferred follow-up.
    private func detectAgentAuthFailure(sessionID: String, text: String) {
        // Require BOTH a 401/auth marker AND the live "authenticate" framing so
        // a stray "HTTP 401" in legit chat content doesn't trip it. The broker
        // surfaces the claude failure as e.g.
        // "Failed to authenticate. API Error: 401 ... Invalid authentication credentials".
        let lower = text.lowercased()
        let hasAuthFailure =
            (lower.contains("api error: 401") && lower.contains("authenticat"))
            || lower.contains("invalid authentication credentials")
            || lower.contains("failed to authenticate")
        guard hasAuthFailure else {
            // Bidirectional: a successful (non-401) agent reply means auth is
            // working again, so clear any standing failure flag and dismiss the
            // "Sign in on this box" banner. Without this the banner is set-only
            // and lingers forever after the user fixes auth OUT OF BAND (signs
            // in on the box / shell rather than via an app retry) — that path
            // never reaches sendChat's clear (the only other clear site).
            if agentAuthFailure[sessionID] != nil {
                agentAuthFailure[sessionID] = nil
                Telemetry.breadcrumb("agent_creds", "401 banner cleared — agent replied OK",
                    data: ["session": sessionID])
            }
            return
        }

        let provider = agentProvider(forSessionID: sessionID)
        // Idempotent: don't re-fire propagate/telemetry every time the same
        // failing transcript line re-ingests (e.g. on a conversation refresh).
        if agentAuthFailure[sessionID] == provider { return }
        agentAuthFailure[sessionID] = provider

        let endpoint = endpointForSession(sessionID)
        Telemetry.breadcrumb("agent_creds", "401 detected in chat", data: [
            "session": sessionID,
            "provider": provider.rawValue,
            "host": endpoint.displayHost,
        ])
        Telemetry.capture(
            error: NSError(
                domain: "Conduit",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "agent auth 401 surfaced in chat"]
            ),
            message: "iOS agent auth 401 (string-match)",
            tags: ["surface": "ios", "phase": "agent_auth_401", "provider": provider.rawValue],
            extras: ["session": sessionID, "host": endpoint.displayHost]
        )
        // Auto-recover: re-push the device credential to this session's box.
        // Best-effort — if there's no local credential, the flagged banner
        // sends the user to sign in instead.
        if OAuthCredentialStore.load(provider: provider) != nil {
            Task { await self.propagateStoredAgentCredentials(to: endpoint) }
        }
    }

    /// Best-effort provider attribution for a session, used by §D 401
    /// handling. Prefers the broker descriptor's `loginProvider`; falls back
    /// to the assistant name (claude -> anthropic, codex -> openai), and
    /// defaults to anthropic when the assistant is unknown.
    private func agentProvider(forSessionID sessionID: String) -> OAuthProvider {
        let assistant = (sessions.first(where: { $0.id == sessionID })?.assistant ?? "").lowercased()
        if let raw = agentDescriptors[assistant]?.loginProvider,
           let provider = OAuthProvider(loginProvider: raw) {
            return provider
        }
        switch assistant {
        case "codex": return .openai
        case "claude": return .anthropic
        default: return .anthropic
        }
    }

    /// The endpoint that OWNS a session: the stamped box's endpoint on the
    /// multi-box path, else the single global `endpoint`. Mirrors the routing
    /// invariant in `clientForSession`.
    private func endpointForSession(_ sessionID: String) -> StoredEndpoint {
        if multiBoxEnabled,
           let boxID = sessionBox[sessionID],
           let conn = boxConnections[boxID] {
            return conn.endpoint
        }
        return endpoint
    }

    /// Synchronous refresh — used where the caller reads `conversationLog`
    /// right after (e.g. `ingestChat` resolves the streaming item id against
    /// the freshly-merged log). Single-session and low-frequency (once per
    /// turn), so the blocking FFI here isn't the hang source.
    fileprivate func refreshConversation(sessionID: String) {
        guard let client = clientForSession(sessionID) else { return }
        guard let items = try? client.listConversationItems(sessionId: sessionID) else { return }
        applyRefreshedConversation(sessionID: sessionID, items: items)
    }

    /// Off-main refresh for the `refreshSessions` fan-out. `listConversationItems`
    /// is a BLOCKING FFI call (locks the core session mutex, deep-clones the
    /// whole conversation, marshals every record across UniFFI). Doing it for
    /// EVERY session on each status delta on the @MainActor froze the UI on long
    /// transcripts / under ingest-lock contention past Sentry's 2s App Hang
    /// threshold (CONDUIT-IOS App Hanging). Pull off the main thread; apply the
    /// merge back on it. The UniFFI client is thread-safe (Arc+Mutex in Rust)
    /// but isn't `Sendable`, hence the explicit unsafe capture; the result rides
    /// back across the actor hop inside a `@unchecked Sendable` box.
    private func refreshConversationOffMain(sessionID: String) {
        Telemetry.breadcrumb("perf", "refresh_conversation_off_main", data: ["session": sessionID])
        guard let client = clientForSession(sessionID) else { return }
        nonisolated(unsafe) let capturedClient = client
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            // Blocking FFI call — stays off-main.
            guard let items = try? capturedClient.listConversationItems(sessionId: sessionID) else { return }
            // Snapshot the main-actor state we need for the merge in a single
            // brief hop, then do the heavy sort+merge work off-main.
            let liveBox = SendableConvItems(items: items)
            let snapshot: SendableMergeSnapshot = await MainActor.run {
                let existing = self.conversationLog[sessionID] ?? []
                let serverFingerprints = Set(liveBox.items.map { "\($0.role)|\($0.content)" })
                let stillPending = existing.filter {
                    $0.id.hasPrefix("local-") && !serverFingerprints.contains("\($0.role)|\($0.content)")
                }
                return SendableMergeSnapshot(
                    past: self.hydratedChat[sessionID] ?? [],
                    pending: stillPending
                )
            }
            // mergeConversation is nonisolated static — safe to call off-main.
            let merged = SessionStore.mergeConversation(
                past: snapshot.past,
                live: liveBox.items,
                pending: snapshot.pending
            )
            Telemetry.breadcrumb("perf", "refresh_conversation_merge_done",
                data: ["session": sessionID, "count": String(merged.count)])
            let mergedBox = SendableConvItems(items: merged)
            await MainActor.run {
                self.conversationLog[sessionID] = mergedBox.items
            }
        }
    }

    /// Box that carries the (value-type, effectively-immutable) conversation
    /// items across the off-main <-> main-actor hops under strict concurrency.
    private struct SendableConvItems: @unchecked Sendable {
        let items: [ConversationItem]
    }

    /// Snapshot of the main-actor merge inputs passed into the detached task.
    private struct SendableMergeSnapshot: @unchecked Sendable {
        let past: [ConversationItem]
        let pending: [ConversationItem]
    }

    /// Merge freshly-pulled live items into `conversationLog` on the main
    /// actor (shared by the sync path — e.g. direct callers that already
    /// hold main-actor state and want an immediate synchronous apply).
    private func applyRefreshedConversation(sessionID: String, items: [ConversationItem]) {
        // Preserve locally-echoed `local-*` items not yet reflected by the
        // server (matched by role+content). Once the harness mirrors the same
        // text back under a server id, the local copy drops.
        //
        // Bug #3 nuance: the broker doesn't loop user messages back as
        // `on_chat_event`, so the user's `local-*` echo lives forever in
        // `stillPending`. Splicing by timestamp keeps order chronological.
        let existing = conversationLog[sessionID] ?? []
        let serverFingerprints = Set(items.map { "\($0.role)|\($0.content)" })
        let stillPending = existing.filter {
            $0.id.hasPrefix("local-") && !serverFingerprints.contains("\($0.role)|\($0.content)")
        }
        // Merge under any restored-from-disk past chat (a reattached session —
        // the broker doesn't replay chat over the WS, so the Rust core's live
        // `items` only cover turns since reattach).
        conversationLog[sessionID] = Self.mergeConversation(
            past: hydratedChat[sessionID] ?? [],
            live: items,
            pending: stillPending
        )
    }

    /// Splice restored-from-disk past chat (`past`) under the live Rust-core
    /// items (`live`) plus still-unmirrored local echoes (`pending`), dropping
    /// any past entry the live list already represents (same role+content), so
    /// a reattached session shows its full history without doubling messages.
    /// Pure + static so ConduitTests can pin the merge without a live client.
    /// `nonisolated` because it touches no actor state — lets the synchronous
    /// (non-MainActor) test call it directly.
    nonisolated static func mergeConversation(
        past: [ConversationItem],
        live: [ConversationItem],
        pending: [ConversationItem]
    ) -> [ConversationItem] {
        // Use the stripped key (drops [[conduit:needs-input]] and
        // [[conduit:resolved]] lines) so the resolved and unanswered versions
        // of the same AskUserQuestion card are treated as one logical item.
        // For normal messages the stripped key equals the raw content.
        let resolvedMarker = ConduitUI.ChatViewModel.pendingResolvedMarker
        func fp(_ item: ConversationItem) -> String {
            "\(item.role)|\(ConduitUI.ChatViewModel.pendingInputStrippedKey(item.content))"
        }
        // Keys where past (HTTP transcript) carries the resolved marker but
        // the matching live item doesn't. On a fresh app restart
        // resolvedPendingInputIDs is empty, so the transcript version must win
        // over the unanswered live replay — it's the only signal that the card
        // was already answered.
        let liveByKey = Dictionary(live.map { (fp($0), $0) }, uniquingKeysWith: { f, _ in f })
        let resolvedPastKeys = Set(past.compactMap { item -> String? in
            let key = fp(item)
            guard item.content.contains(resolvedMarker),
                  !(liveByKey[key]?.content.contains(resolvedMarker) ?? false)
            else { return nil }
            return key
        })
        let liveFingerprints = Set(live.map { fp($0) })
        let pastNotInLive = past.filter { item in
            let key = fp(item)
            return !liveFingerprints.contains(key) || resolvedPastKeys.contains(key)
        }
        // Drop live items superseded by the resolved past version.
        let liveFiltered = live.filter { !resolvedPastKeys.contains(fp($0)) }
        let combined = (pastNotInLive + liveFiltered + pending).sortedByConversationTs { $0.ts }
        // Final dedup: resolved pending_input beats unresolved for the same key
        // so that answered AskUserQuestion state survives close+reopen. Without
        // this the broker-persisted resolved card was silently dropped in favour
        // of the original unanswered entry which shares the same ts.
        var bestByKey = [String: ConversationItem]()
        for item in combined {
            let key = fp(item)
            if let existing = bestByKey[key] {
                if item.content.contains(resolvedMarker) && !existing.content.contains(resolvedMarker) {
                    bestByKey[key] = item
                }
            } else {
                bestByKey[key] = item
            }
        }
        var seenKeys = Set<String>()
        return combined.compactMap { item in
            let key = fp(item)
            guard seenKeys.insert(key).inserted else { return nil }
            return bestByKey[key]
        }
    }

    /// Directly splice `hydratedChat[sessionID]` into `conversationLog`
    /// WITHOUT requiring a live Rust client. Used by `fetchOlderConversation`
    /// to surface paginated older history for EXITED sessions (where
    /// `refreshConversation` silently no-ops because there is no live
    /// `ConduitClient`). For reattached live sessions this is a harmless
    /// no-op because `refreshConversation` → `applyRefreshedConversation`
    /// does the equivalent merge immediately after.
    ///
    /// Only touches `conversationLog[sessionID]` if there IS a hydrated base
    /// AND no live items are currently present (i.e. it is truly exited). If
    /// `conversationLog[sessionID]` is already non-empty (live session), we
    /// leave the normal merge path to handle it.
    private func mergeHydrationIntoConversationLog(sessionID: String) {
        guard let hydrated = hydratedChat[sessionID], !hydrated.isEmpty else { return }
        // If there are already live Rust-core items in conversationLog we
        // skip — `applyRefreshedConversation` will merge them on the next
        // Rust-core list callback.
        let existing = conversationLog[sessionID] ?? []
        let hasLiveItems = existing.contains { !$0.id.hasPrefix("saved-") && !$0.id.hasPrefix("paged-") && !$0.id.hasPrefix("local-") }
        if !hasLiveItems {
            conversationLog[sessionID] = hydrated
        }
    }

    // MARK: - Backward-pagination accessors (for ChatView)

    /// Returns `true` if there are older messages available to load for
    /// `sessionID`. `false` when the start of history is reached OR when
    /// the broker did not include the `has_more_before` field (old broker
    /// backward-compat: pagination never fires).
    func hasMoreHistory(_ sessionID: String) -> Bool {
        hasMoreHistoryBySession[sessionID] ?? false
    }

    /// Returns `true` while a backward-pagination network fetch is in-flight
    /// for `sessionID`. Guards `ChatView` against overlapping fetches.
    func isLoadingOlderHistory(_ sessionID: String) -> Bool {
        isLoadingOlderBySession[sessionID] ?? false
    }

    /// Remove the broker's pending-input sentinel line from raw transcript
    /// content (the HTTP `fetchConversation` replay bypasses the core
    /// classifier, which strips it on the live path). Byte-identical to the
    /// broker / core constant; mirrors core `strip_pending_sentinel`.
    nonisolated static func stripPendingSentinel(_ text: String) -> String {
        let sentinel = ConduitUI.ChatViewModel.pendingInputSentinel
        guard text.contains(sentinel) else { return text }
        return text
            .components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces) != sentinel }
            .joined(separator: "\n")
    }

    /// Restore a reattached live session's prior conversation from the
    /// broker's persisted transcript (`GET /api/session/conversation/<id>`).
    /// The broker replays only the terminal snapshot over the WS on reattach,
    /// not the chat — so without this the chat stays blank until the next
    /// turn. Idempotent: only fetches once per session per launch, and seeds
    /// the sticky `hydratedChat` base so `refreshConversation` keeps it.
    func hydrateChatConversation(_ sessionID: String) async {
        guard hydratedChat[sessionID] == nil else { return }
        guard let items = try? await fetchConversation(sessionID: sessionID),
              !items.isEmpty else { return }
        hydratedChat[sessionID] = items
        // Seed resolvedPendingInputIDs from the transcript so hasPendingAsk stays
        // correct after close+reopen (resolvedPendingInputIDs is ephemeral).
        // Mirror of Android's mapRemoteItem which seeds _resolvedPendingInputIDs.
        let resolvedIDs = items.compactMap { item -> String? in
            guard item.kind == "pending_input" else { return nil }
            guard ConduitUI.ChatViewModel.parsePendingResolution(item.content)?.answered == true else { return nil }
            return item.id
        }
        if !resolvedIDs.isEmpty {
            resolvedPendingInputIDs.formUnion(resolvedIDs)
        }
        refreshConversationOffMain(sessionID: sessionID)
    }

    /// Seed `hydratedChat` + `conversationLog` for an EXITED session whose
    /// transcript was fetched over HTTP (used by `SavedTranscriptView` to
    /// route the exited-session read-only path through the store so that
    /// `ChatView` can trigger backward pagination via `fetchOlderConversation`).
    ///
    /// Idempotent: if a hydrated base already exists for this session the call
    /// is a no-op (prevents clobbering in-progress pagination). Returns the
    /// items so callers can check emptiness without a second store read.
    @discardableResult
    func seedExitedConversation(sessionID: String, items: [ConversationItem]) -> [ConversationItem] {
        guard hydratedChat[sessionID] == nil else {
            return conversationLog[sessionID] ?? []
        }
        guard !items.isEmpty else { return [] }
        hydratedChat[sessionID] = items
        // Directly populate conversationLog — no live Rust client for exited
        // sessions, so `refreshConversation` would silently no-op here.
        conversationLog[sessionID] = items
        return items
    }

    // `internal` (not `fileprivate`) so ConduitTests can drive this
    // path directly — same rationale as `ingestChat` above. The status
    // frame carries `reasoningEffort` / `cwd` / `startedAt` etc. and
    // a test confirms `statusBySession` reflects those fields end-to-end.
    func ingestStatus(_ status: SessionStatus) {
        // Detect turn-active -> idle transition BEFORE overwriting statusBySession.
        // When the prior status had turn_active=true and the new one is false/nil,
        // a turn just ended -- flush ONE queued entry for the session.
        let priorTurnActive = statusBySession[status.session]?.turnActive ?? false
        let newTurnActive = status.turnActive ?? false
        let turnJustCompleted = priorTurnActive && !newTurnActive

        statusBySession[status.session] = status
        if let p = status.preview { preview[status.session] = p }
        // Mirror turn_phase from the status frame so reconnecting clients show
        // the correct indicator immediately without waiting for a view_event
        // replay (view_events are not buffered/replayed on reconnect).
        if let tp = status.turnPhase {
            turnPhaseBySession[status.session] = tp
        }

        // Flush one queued-turn entry now that the agent is idle.
        if turnJustCompleted {
            flushQueuedOnTurnComplete(sessionID: status.session)
        } else if !newTurnActive,
                  pendingChats.flushOnTurnComplete(sessionID: status.session) != nil,
                  pendingChats.flushable(for: status.session).isEmpty {
            // Level-triggered flush (deadlock fix): the app reconnected/opened
            // to a session that is ALREADY idle yet still holds a queued-turn
            // entry. This happens when the broker restarts mid-turn — the app
            // still believes turn_active=true (so the user's next message was
            // parked in "Queued Next"), but the recovered session comes back
            // idle, so the true→false edge above never fires and neither the
            // edge- nor reply-triggered flush ever runs. Without this the
            // queued message is stuck forever ("message sent but the agent
            // never picks it up" after every broker restart). The guard on an
            // empty flushable() set keeps delivery one-at-a-time: a just-
            // flushed .normal entry blocks the next queued entry until it acks
            // or draws a reply, preserving the natural per-turn serialization.
            Telemetry.breadcrumb("chat", "flush-on-idle-status",
                data: ["session": status.session])
            flushQueuedOnTurnComplete(sessionID: status.session)
        }
        // Safety net: when turnActive transitions false, clear any lingering
        // streaming state. This covers cancelled turns and clock-skew cases
        // where no final ingestChat arrives with a matching ts to trigger the
        // normal clear path above.
        if turnJustCompleted {
            streamingMessage[status.session] = nil
            turnPhaseBySession[status.session] = nil
            streamingTurnTs[status.session] = nil
            thinkingBySession[status.session] = nil
            Telemetry.breadcrumb("streaming", "cleared on turn-complete status",
                data: ["session": status.session])
        }
        // Promote lifecycle from a non-terminal state using the phase the
        // broker actually reported — NOT a blanket `.live`. A status frame
        // for a recovered/exited session carries `phase: "exited…"`; that
        // must lock the row read-only, not resurrect it as interactive.
        // (`.exited` / `.failed` are terminal and never downgraded here.)
        switch sessionLifecycle[status.session] {
        case .none, .creating?:
            if Self.isLivePhase(status.phase) {
                sessionLifecycle[status.session] = .live
            } else if status.phase.lowercased().hasPrefix("exited") {
                // Surface an explicit exit even if we never saw an
                // `exit` frame — e.g. joining an already-dead session.
                let code = Self.exitCode(fromPhase: status.phase) ?? 0
                sessionLifecycle[status.session] = .exited(code)
            }
            // A non-live, non-exited phase (empty / unknown) leaves the
            // lifecycle unset → `isReadOnly` returns true (fail closed).
        case .live?:
            // Already live: a later exited phase still demotes to terminal.
            if status.phase.lowercased().hasPrefix("exited") {
                let code = Self.exitCode(fromPhase: status.phase) ?? 0
                sessionLifecycle[status.session] = .exited(code)
            }
        case .exited?, .failed?:
            break // terminal — never revived by a status delta
        }
        // Mirror a broker-supplied rename label (protocol §3.3) into
        // the local displayNames map so every existing title surface
        // (ThreadSwitcher, HomeScreen, SessionInfo) picks it up without
        // each having to re-read the status bag. Prefer `displayName`;
        // fall back to legacy `sessionName` for older brokers.
        let serverLabel = (status.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? (status.sessionName?
                .trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        // Only mirror a *meaningful* broker label. The broker frequently
        // echoes the bare session id as its `sessionName`/`displayName`;
        // mirroring that would re-pollute `displayNames` with a UUID and
        // resurrect the raw-id-as-title bug, so we drop any UUID-shaped or
        // id-equal label here.
        if let label = serverLabel,
           !SessionNaming.looksLikeRawID(label, sessionID: status.session),
           displayNames[status.session] != label {
            displayNames[status.session] = label
        }
        harness = .live
        refreshSessions()
        if useRustStore {
            // `apply_status` is the one reducer entry that synthesizes a
            // placeholder when the session id is unknown, so we don't
            // need to call `ensureRustSessionPresent` here.
            _ = rustStore.applyStatus(status: status)
            #if DEBUG
            assertRustStatusParity(status.session)
            #endif
        }
        recordSavedSession(forSessionID: status.session)
    }

    func ingestPreview(_ sessionID: String, _ p: PreviewInfo) {
        preview[sessionID] = p
        if useRustStore {
            ensureRustSessionPresent(sessionID)
            _ = rustStore.applyPreview(sessionId: sessionID, preview: p)
            #if DEBUG
            assertRustPreviewParity(sessionID)
            #endif
        }
    }

    func ingestSnapshot(_ sessionID: String, _ gunzipped: Data) {
        // Replace terminal scrollback with the authoritative snapshot from the server.
        terminalBuffer[sessionID] = gunzipped
        scheduleTerminalPersist(sessionID)
        if useRustStore {
            ensureRustSessionPresent(sessionID)
            _ = rustStore.applySnapshot(sessionId: sessionID, gunzipped: gunzipped)
            #if DEBUG
            assertRustScrollbackParity(sessionID)
            #endif
        }
    }

    // MARK: - Terminal scrollback disk persistence (cold-launch restore)
    //
    // The broker keeps the authoritative scrollback (256KB ring, persisted to
    // `scrollback.bin`) and replays it on re-attach. But the client's
    // `terminalBuffer` is in-memory only, so after an app kill a reopened
    // session shows a BLANK terminal until the socket reconnects and the live
    // snapshot arrives. We mirror the buffer to a small per-session file so a
    // cold launch can paint the last-known terminal instantly; the live
    // snapshot then REPLACES it. Mirrored on Android in `SessionStore.kt`.

    /// Cap each persisted file to the broker ring size — keep the TAIL (most
    /// recent bytes), matching the broker's circular scrollback.
    private static let terminalPersistCap = 256 * 1024

    private static var terminalScrollbackDir: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("terminal-scrollback", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func terminalScrollbackURL(_ sessionID: String) -> URL? {
        // Session ids are UUIDs; sanitize defensively to keep them path-safe.
        let safe = sessionID.replacingOccurrences(of: "/", with: "_")
        guard !safe.isEmpty else { return nil }
        return terminalScrollbackDir?.appendingPathComponent("\(safe).bin")
    }

    /// Mark a session dirty and schedule a coalesced disk flush. Debounced
    /// (~3s) so a streaming PTY doesn't thrash I/O — the broker is
    /// authoritative on reconnect, so a slightly-stale on-disk copy is fine.
    private func scheduleTerminalPersist(_ sessionID: String) {
        terminalPersistDirty.insert(sessionID)
        guard !terminalPersistScheduled else { return }
        terminalPersistScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.terminalPersistScheduled = false
            self.flushTerminalPersist()
        }
    }

    /// Write every dirty session's tail-capped buffer to disk. No-op when
    /// nothing is dirty. Also invoked on app background.
    ///
    /// The tail bytes are captured on the main actor (reading `terminalBuffer`),
    /// then the actual file I/O is handed to a background queue — a synchronous
    /// ≤256KB `Data.write` on the main thread every few seconds was a periodic
    /// main-thread stall that compounds the terminal render hang.
    func flushTerminalPersist() {
        guard !terminalPersistDirty.isEmpty else { return }
        let dirty = terminalPersistDirty
        terminalPersistDirty.removeAll()
        var writes: [(URL, Data)] = []
        for id in dirty {
            guard let data = terminalBuffer[id], !data.isEmpty,
                  let url = Self.terminalScrollbackURL(id) else { continue }
            let tail = data.count > Self.terminalPersistCap
                ? Data(data.suffix(Self.terminalPersistCap))
                : data
            writes.append((url, tail))
        }
        guard !writes.isEmpty else { return }
        Self.terminalPersistIOQueue.async {
            for (url, tail) in writes {
                try? tail.write(to: url, options: .atomic)
            }
        }
    }

    /// Serial background queue for terminal-scrollback disk writes — keeps the
    /// best-effort cache off the main thread.
    private static let terminalPersistIOQueue =
        DispatchQueue(label: "sh.nikhil.conduit.terminal-persist", qos: .utility)

    /// Block until all queued scrollback writes have hit disk. Test-only seam
    /// (`flushTerminalPersist` is now async) — a barrier on the serial IO queue
    /// returns once every prior write has run.
    func waitForTerminalPersistIO() {
        Self.terminalPersistIOQueue.sync {}
    }

    /// Load a session's persisted scrollback into the in-memory buffer when we
    /// don't already hold live bytes. Called on (re)attach so a cold launch
    /// shows the last-known terminal instantly; the broker's live snapshot
    /// later REPLACES this via `ingestSnapshot`. Seeds the Rust mirror too so
    /// the DEBUG scrollback-parity assertion stays consistent.
    func hydrateTerminalBuffer(_ sessionID: String) {
        guard terminalBuffer[sessionID]?.isEmpty ?? true else { return }
        guard let url = Self.terminalScrollbackURL(sessionID),
              let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        terminalBuffer[sessionID] = data
        if useRustStore {
            ensureRustSessionPresent(sessionID)
            _ = rustStore.applySnapshot(sessionId: sessionID, gunzipped: data)
        }
    }

    /// Drop a session's persisted scrollback (session deleted server-side).
    func discardPersistedTerminal(_ sessionID: String) {
        terminalPersistDirty.remove(sessionID)
        if let url = Self.terminalScrollbackURL(sessionID) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func ingestExit(_ sessionID: String, _ code: Int32) {
        sessionLifecycle[sessionID] = .exited(code)
        recordSavedSession(forSessionID: sessionID, isExited: true)
        if var status = statusBySession[sessionID] {
            status = SessionStatus(
                session: status.session,
                assistant: status.assistant,
                phase: "exited(\(code))",
                health: "red",
                rows: status.rows,
                cols: status.cols,
                yolo: status.yolo,
                preview: status.preview,
                sessionName: status.sessionName,
                viewers: status.viewers,
                reasoningEffort: status.reasoningEffort,
                cwd: status.cwd,
                startedAt: status.startedAt,
                lastActivityAt: status.lastActivityAt,
                displayName: status.displayName,
                totalInputTokens: status.totalInputTokens,
                totalOutputTokens: status.totalOutputTokens,
                totalCachedTokens: status.totalCachedTokens,
                totalCostUsd: status.totalCostUsd,
                contextUsedTokens: status.contextUsedTokens,
                contextWindowTokens: status.contextWindowTokens
            )
            statusBySession[sessionID] = status
        }
        if useRustStore {
            ensureRustSessionPresent(sessionID)
            _ = rustStore.applyExit(sessionId: sessionID, code: code)
            #if DEBUG
            assertRustLifecycleParity(sessionID)
            #endif
        }
    }

    fileprivate func ingestDisconnected(_ reason: String) {
        // If we already knew this pairing was expired (e.g. createSession just
        // failed with Auth), don't clobber that diagnosis with the raw
        // URLSession close reason — the server tearing down the socket right
        // after an auth rejection is part of the same failure, not a new one.
        if case .failed(let existing) = harness,
           existing.lowercased().contains("pairing expired") {
            return
        }
        // Also preserve a self-heal already in progress so we don't clobber
        // the reconnecting state with a terminal Failed.
        if case .reconnecting = harness { return }
        let lower = reason.lowercased()
        let isAuthReason = lower.contains("auth") || lower.contains("401") || lower.contains("unauthorized")
        if isAuthReason {
            // SSH boxes: token mismatch is recoverable via re-bootstrap.
            // Token-paired boxes: the pairing QR is genuinely expired.
            if savedServers.first(where: { $0.endpoint == endpoint })?.ssh != nil {
                Telemetry.breadcrumb("session", "auth failure on SSH box — triggering self-heal",
                    data: ["phase": "ingest_disconnected", "endpoint": endpoint.displayHost])
                harness = .reconnecting(attempt: 1, maxAttempts: 3)
                attemptSshSelfHeal()
                return
            }
            harness = .failed("Pairing expired. Scan a new QR code from the server.")
        } else {
            harness = .failed("Disconnected: \(reason)")
        }
        // Routine disconnects (code 0 / clean close, network loss, server
        // restart) are expected lifecycle — 676 useless Sentry events per quota
        // window. Downgraded to breadcrumb so the reason is still attached to
        // the next real error without burning a quota event each time.
        // Auth failures are NOT downgraded: those land in ingestConnectionHealth
        // above as genuine ERROR-level events (code 401 / auth_expired).
        Telemetry.breadcrumb(
            "connect", "disconnected from harness",
            data: [
                "reason_code": Self.connectionReasonCode(from: reason),
                "endpoint": endpoint.displayHost,
                "detail": reason,
            ]
        )
    }

    /// Per-session connection health, driven by the Rust core's reconnect
    /// worker. We aggregate across sessions into the single visible
    /// `HarnessState`: any in-progress reconnect dominates; an auth-flavoured
    /// terminal disconnect promotes to the friendly "Pairing expired" state.
    /// Clear the transient "agent is working" state for a session when the
    /// connection drops. A turn's in-flight status cannot be trusted across a
    /// connection drop: the broker may have restarted and the turn is gone.
    /// The authoritative reconnect status frame re-asserts turn_active=true if
    /// a turn genuinely survived. This prevents the composer from being stuck
    /// on the Stop button and the send gate from blocking all subsequent
    /// messages until a force-quit (bug: stuck on Stop after broker restart).
    private func clearStaleTurnState(_ sessionID: String) {
        if var status = statusBySession[sessionID], status.turnActive == true {
            status.turnActive = false
            statusBySession[sessionID] = status
        }
        streamingMessage[sessionID] = nil
        turnPhaseBySession[sessionID] = nil
        streamingTurnTs[sessionID] = nil
        thinkingBySession[sessionID] = nil
        Telemetry.breadcrumb("chat", "cleared stale turn state on disconnect",
            data: ["session": sessionID])
    }

    func ingestConnectionHealth(_ sessionID: String, _ health: ConnectionHealth) {
        switch health {
        case .connected:
            connectionHealthBySession[sessionID] = health
            if !sessionLifecycle.isEmpty {
                harness = .live
            } else {
                harness = .linked
            }
            // Change 4: record the last good harness and clear any active
            // grace window suppression (reconnect succeeded before expiry).
            lastReachableHarness = sessionLifecycle.isEmpty ? .linked : .live
            if suppressGraceReconnecting {
                suppressGraceReconnecting = false
                graceWindowTask?.cancel()
                graceWindowTask = nil
                Telemetry.breadcrumb("session", "fg_grace_window_connected_cleared",
                    data: ["session": sessionID])
            }
            // Change 3: forced post-replay re-read for sessions marked at
            // foreground. Explicit bypass of PR #871's empty-log gate --
            // calls refreshConversationOffMain directly (not through
            // refreshSessions) so it always runs regardless of log state.
            if sessionsNeedingPostConnectRefresh.remove(sessionID) != nil {
                refreshConversationOffMain(sessionID: sessionID)
                Telemetry.breadcrumb("session", "fg_post_connect_refresh_fired",
                    data: ["session": sessionID])
            }
            // Promote any queuedTurn entries to normal so they are picked up
            // by flushPendingChats below. After a broker restart the turn they
            // were waiting on is gone; they should be re-delivered now that the
            // turn gate is clear (clearStaleTurnState zeroed it on disconnect).
            pendingChats.promoteQueuedTurnToNormal(sessionID: sessionID)
            // Flush any `sent`-but-unacked messages for this session. The
            // Rust core's per-session reconnect worker fires this callback
            // when it re-establishes the WS (distinct from the app-level
            // `connectToHarness` which also flushes all sessions). Without
            // this flush, messages whose WS write succeeded but whose
            // `chat_ack` arrived after the connection dropped stay stuck in
            // the `sent`/faded state forever -- the app-level flush only
            // runs on a full app-level reconnect, not Rust-layer auto-reconnects.
            // Calling flushPendingChats here is idempotent: if there is nothing
            // to flush (normal initial connect) it is a no-op.
            Telemetry.breadcrumb("chat", "flush on session reconnect",
                data: ["session": sessionID])
            flushPendingChats(sessionID: sessionID)
        case let .connecting(attempt, maxAttempts):
            connectionHealthBySession[sessionID] = health
            harness = .reconnecting(attempt: attempt, maxAttempts: maxAttempts)
            // stale-turn clearing must run immediately regardless of grace window
            // (SAFETY: do NOT gate this on the grace window).
            clearStaleTurnState(sessionID)
            // Change 4: start the "assume connected" grace window when the
            // reconnect cycle begins within ~5s of a foreground event. The
            // banner stays green for ~4s; if .connected arrives first the timer
            // is cancelled and no flicker is ever shown.
            if let fg = foregroundedAt,
               Date().timeIntervalSince(fg) < 5.0,
               !suppressGraceReconnecting {
                suppressGraceReconnecting = true
                graceWindowTask?.cancel()
                graceWindowTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 4_000_000_000) // 4s
                    guard let self else { return }
                    self.suppressGraceReconnecting = false
                    Telemetry.breadcrumb("session", "fg_grace_window_expired",
                        data: ["session": sessionID])
                }
                Telemetry.breadcrumb("session", "fg_grace_window_started",
                    data: ["session": sessionID])
            }
        case let .disconnected(reason, auth):
            connectionHealthBySession[sessionID] = health
            if auth {
                // SSH boxes: token mismatch after a tunnel restart is
                // recoverable — re-bootstrap fetches the broker's live token.
                // Token-paired boxes: QR pairing is genuinely expired.
                if savedServers.first(where: { $0.endpoint == endpoint })?.ssh != nil {
                    Telemetry.breadcrumb("session", "auth failure on SSH box — triggering self-heal",
                        data: ["phase": "connection_health", "endpoint": endpoint.displayHost,
                               "session_id": sessionID])
                    harness = .reconnecting(attempt: 1, maxAttempts: 3)
                    attemptSshSelfHeal()
                } else {
                    harness = .failed("Pairing expired. Scan a new QR code from the server.")
                }
                Telemetry.capture(
                    error: NSError(domain: "SessionStore", code: 401, userInfo: [NSLocalizedDescriptionKey: reason]),
                    message: "iOS connection health auth failure",
                    tags: [
                        "surface": "ios",
                        "phase": "connection_health",
                        "reason_code": "auth_expired",
                        "is_ssh": "\(savedServers.first(where: { $0.endpoint == endpoint })?.ssh != nil)",
                    ],
                    extras: [
                        "endpoint": endpoint.displayHost,
                        "session_id": sessionID,
                        "detail": reason,
                    ]
                )
            } else {
                clearStaleTurnState(sessionID)
                ingestDisconnected(reason)
            }
        }
    }

    // MARK: - Saved-session history

    /// Server-stable identity for the saved-session index. Prefer the
    /// id of the matching `SavedServer` row (carries through across
    /// renames / endpoint mutations); fall back to the endpoint host
    /// for pairings the user hasn't named yet. Stable enough for
    /// `(serverID, sessionID)` to identify a row across launches.
    private var savedHistoryServerID: String {
        if let server = savedServers.first(where: { $0.endpoint == endpoint }) {
            return server.id
        }
        let host = endpoint.displayHost
        return host.isEmpty ? "(unsaved)" : host
    }

    /// Best-effort first user message for the session, scanning whichever
    /// of the typed `conversationLog` / raw `chatLog` actually carries it.
    private func firstUserMessage(in sessionID: String) -> String? {
        if let log = conversationLog[sessionID] {
            if let first = log.first(where: { $0.role.lowercased() == "user" }) {
                return first.content
            }
        }
        if let chat = chatLog[sessionID] {
            if let first = chat.first(where: { $0.role.lowercased() == "user" }) {
                return first.content
            }
        }
        return nil
    }

    /// Fold the latest snapshot of `sessionID` into the persistent
    /// "Resume" index. Invoked from `ingestStatus` (on every status
    /// frame) and `ingestExit` (with `isExited: true` so the row locks
    /// into the terminal status). Idempotent — `SavedSessionsStore.upsert`
    /// suppresses writes when the row would be unchanged.
    private func recordSavedSession(forSessionID sessionID: String, isExited: Bool = false) {
        // We only have a meaningful `ProjectSession` for sessions the
        // live store has confirmed exist; placeholder lifecycle rows
        // (`pending-*`) don't carry an agent or cwd worth persisting.
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        let status = statusBySession[sessionID]
        let exitedFromLifecycle: Bool
        if case .exited = sessionLifecycle[sessionID] {
            exitedFromLifecycle = true
        } else {
            exitedFromLifecycle = false
        }
        let messageCount = (conversationLog[sessionID]?.count)
            ?? (chatLog[sessionID]?.count)
            ?? 0
        // Owner stability: the SavedSession key is (id, serverID). Prefer the
        // session's EXISTING box stamp so a status frame arriving while a
        // DIFFERENT box is the active endpoint can't re-key the history row to
        // the wrong owner (the duplicate/mislabeled David/Hostinger rows).
        // Fall back to the active endpoint only when the session is unstamped.
        let ownerID = sessionBox[sessionID] ?? savedHistoryServerID
        SavedSessionsStore.shared.upsert(
            session: session,
            serverID: ownerID,
            status: status,
            firstUserMessage: firstUserMessage(in: sessionID),
            messageCount: messageCount,
            isExited: isExited || exitedFromLifecycle
        )
    }

    // MARK: - Persistence

    private static let endpointKey = "conduit.endpoint.url"
    private static let tokenKey = "conduit.endpoint.token"
    private static let savedServersKey = "conduit.saved_servers.json"
    private static let legacyEndpointDefaultsKey = "conduit.endpoint.url"

    private static func loadPersisted() -> StoredEndpoint {
        let token = Keychain.get(tokenKey) ?? ""
        let endpoint = Keychain.get(endpointKey)
            ?? UserDefaults.standard.string(forKey: legacyEndpointDefaultsKey)
            ?? ""
        if !endpoint.isEmpty, Keychain.get(endpointKey) == nil {
            Keychain.set(endpoint, for: endpointKey)
            UserDefaults.standard.removeObject(forKey: legacyEndpointDefaultsKey)
        }
        return StoredEndpoint(url: endpoint, token: token)
    }

    private static func persist(_ e: StoredEndpoint) {
        Keychain.set(e.url.isEmpty ? nil : e.url, for: endpointKey)
        Keychain.set(e.token.isEmpty ? nil : e.token, for: tokenKey)
        UserDefaults.standard.removeObject(forKey: legacyEndpointDefaultsKey)
    }

    private static func loadSavedServers() -> [SavedServer] {
        guard let raw = Keychain.get(savedServersKey),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([SavedServer].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func persistSavedServers(_ servers: [SavedServer]) {
        if servers.isEmpty {
            Keychain.set(nil, for: savedServersKey)
            return
        }
        guard let data = try? JSONEncoder().encode(servers),
              let raw = String(data: data, encoding: .utf8) else {
            return
        }
        Keychain.set(raw, for: savedServersKey)
    }

    private static let displayNamesKey = "conduit.session.displayNames"

    static func loadDisplayNames() -> [String: String] {
        guard let raw = UserDefaults.standard.data(forKey: displayNamesKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: raw) else {
            return [:]
        }
        return decoded
    }

    static func persistDisplayNames(_ names: [String: String]) {
        if names.isEmpty {
            UserDefaults.standard.removeObject(forKey: displayNamesKey)
            return
        }
        if let data = try? JSONEncoder().encode(names) {
            UserDefaults.standard.set(data, forKey: displayNamesKey)
        }
    }

    private static let brokerTitlesKey = "conduit.session.brokerTitles"

    static func loadBrokerTitles() -> [String: String] {
        guard let raw = UserDefaults.standard.data(forKey: brokerTitlesKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: raw) else {
            return [:]
        }
        return decoded
    }

    static func persistBrokerTitles(_ titles: [String: String]) {
        if titles.isEmpty {
            UserDefaults.standard.removeObject(forKey: brokerTitlesKey)
            return
        }
        if let data = try? JSONEncoder().encode(titles) {
            UserDefaults.standard.set(data, forKey: brokerTitlesKey)
        }
    }

    private static let sessionBoxKey = "conduit.session.sessionBox"

    static func loadSessionBox() -> [String: String] {
        guard let raw = UserDefaults.standard.data(forKey: sessionBoxKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: raw) else {
            return [:]
        }
        return decoded
    }

    static func persistSessionBox(_ map: [String: String]) {
        if map.isEmpty {
            UserDefaults.standard.removeObject(forKey: sessionBoxKey)
            return
        }
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: sessionBoxKey)
        }
    }

    private static let pendingChatsKey = "conduit.session.pendingChats"

    static func loadPendingChats() -> PendingChatQueue {
        guard let raw = UserDefaults.standard.data(forKey: pendingChatsKey),
              let decoded = try? JSONDecoder().decode([String: [PendingChat]].self, from: raw) else {
            return PendingChatQueue()
        }
        return PendingChatQueue(bySession: decoded)
    }

    static func persistPendingChats(_ queue: PendingChatQueue) {
        if queue.bySession.isEmpty {
            UserDefaults.standard.removeObject(forKey: pendingChatsKey)
            return
        }
        if let data = try? JSONEncoder().encode(queue.bySession) {
            UserDefaults.standard.set(data, forKey: pendingChatsKey)
        }
    }

    /// Ingest a broker AI session title (task: ai-session-titles). Stores
    /// the title for the session so every title surface (home list,
    /// history, session header) picks it up live. A blank/empty title is
    /// ignored so we never clobber a good name. Mirrored on Android in
    /// `ingestSessionTitle`.
    func ingestSessionTitle(_ sessionID: String, payload: [String: String]) {
        guard let title = payload["title"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return }
        brokerTitles[sessionID] = title
    }

    /// Ingest a full subagent roster snapshot for a session (subagent-panel spec).
    /// The broker emits a FULL snapshot on every task_* frame so reconnecting
    /// clients get current state immediately via PublishText record+replay.
    /// Mirrored on Android in `ingestAgents`.
    func ingestAgents(_ sessionID: String, payload: [String: String]) {
        guard let roster = SubagentEntry.roster(from: payload) else { return }
        let isFirstPopulate = subagentRosters[sessionID] == nil || subagentRosters[sessionID]?.isEmpty == true
        subagentRosters[sessionID] = roster
        if isFirstPopulate && !roster.isEmpty {
            Telemetry.breadcrumb("agents_panel", "roster first populate",
                data: ["session": sessionID, "count": "\(roster.count)"])
        }
    }

    /// Ingest a `credential_source` view_event from the broker. Stores the
    /// source ("box" or "app_forwarded") so the chat view can show a subtle
    /// banner when the app credential is being used as a fallback because the
    /// box is not logged in locally.
    func ingestCredentialSource(_ sessionID: String, payload: [String: String]) {
        guard let source = payload["source"], !source.isEmpty else { return }
        credentialSource[sessionID] = source
        Telemetry.breadcrumb("credential", "credential_source_received",
            data: ["source": source, "session": sessionID])
    }

    /// Friendly, user-facing name for a session. NEVER returns the raw
    /// UUID. Priority (see `SessionNaming`):
    ///   1. A genuine user-set custom name — one the user typed, never a
    ///      UUID. We screen `displayNames[id]` because the broker also
    ///      mirrors its `sessionName`/`displayName` label here, and that
    ///      label is frequently the bare session id.
    ///   2. The broker AI-generated title (`brokerTitles[id]`), once the
    ///      broker has minted one from the conversation's purpose.
    ///   3. The first user chat message (live: scanned from
    ///      `conversationLog`), trimmed to a short single line.
    ///   4. Fallback: `"<agent> · <relative start time>"`.
    /// True when the session was reconciled from the currently-connected
    /// box (or has no stamp yet — optimistic assume local until reconciled).
    func isSessionOnCurrentBox(_ sessionID: String) -> Bool {
        guard let stamped = sessionBox[sessionID] else { return true }
        return stamped == savedHistoryServerID
    }

    /// Count of LIVE (not exited/failed) sessions stamped to `serverID`.
    /// `store.sessions` deliberately retains other-box rows as dimmed history,
    /// so a plain `sessions.count` over-counts the mixed list. This filters to
    /// the box's own sessions and excludes terminal ones, so each box row shows
    /// its real live count (works for non-active boxes too — their stamps +
    /// lifecycle persist even when they aren't the connected endpoint).
    func liveSessionCount(forBox serverID: String) -> Int {
        sessions.reduce(into: 0) { acc, s in
            guard sessionBox[s.id] == serverID else { return }
            switch sessionLifecycle[s.id] {
            case .exited, .failed:
                return
            default:
                acc += 1
            }
        }
    }

    /// Display name for the box a session belongs to. Used in the home
    /// list to label sessions from non-connected boxes.
    func boxDisplayName(for sessionID: String) -> String? {
        guard let boxID = sessionBox[sessionID] else { return nil }
        return savedServers.first(where: { $0.id == boxID })?.name
            ?? savedServers.first(where: { $0.id == boxID })?.endpoint.displayHost
    }

    /// The saved server that owns this session (nil if unknown or current).
    func server(for sessionID: String) -> SavedServer? {
        guard let boxID = sessionBox[sessionID] else { return nil }
        return savedServers.first(where: { $0.id == boxID })
    }

    func displayName(for session: ProjectSession) -> String {
        if let custom = displayNames[session.id],
           !SessionNaming.looksLikeRawID(custom, sessionID: session.id) {
            return custom
        }
        if let aiTitle = brokerTitles[session.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !aiTitle.isEmpty,
           !SessionNaming.looksLikeRawID(aiTitle, sessionID: session.id) {
            return aiTitle
        }
        if let message = firstUserMessage(in: session.id),
           let title = SessionNaming.titleFromMessage(message) {
            return title
        }
        return SessionNaming.fallbackName(
            agent: session.assistant,
            startedAt: session.startedAt ?? session.lastActivityAt
        )
    }

    /// Whether a session is read-only — there's no live WS to interact
    /// with, so the `ProjectView` collapses to a chat-only, composer-less
    /// transcript (the user can read the log but can't type, switch tabs,
    /// etc.).
    ///
    /// READ-ONLY IS THE DEFAULT. A session opens interactive only when
    /// we can positively confirm it is *currently live on the broker* —
    /// i.e. `isConfirmedLive(sessionID:)`. Everything else (exited,
    /// failed, recovered-but-not-running, archived, or a stale row we
    /// merely listed without a fresh running status) is read-only.
    ///
    /// This inversion fixes the "History still interactive" bug: the old
    /// logic defaulted to interactive and only flipped read-only on a
    /// *confirmed-exited* signal (lifecycle `.exited` or a status phase
    /// of `exited…`). But `refreshSessions` / `ingestStatus` blanket
    /// marked every listed or status-bearing session `.live`, so a dead
    /// session the broker never explicitly reported as exited (app was
    /// disconnected when it died, a recovered session, a phase the broker
    /// reports as non-running) stayed interactive forever. We now require
    /// proof of liveness rather than proof of death.
    func isReadOnly(sessionID: String) -> Bool {
        !isConfirmedLive(sessionID: sessionID)
    }

    /// True only when the session is positively known to be running on
    /// the broker *right now*. Requires BOTH:
    ///   1. a non-terminal local lifecycle (`.live` / `.creating` — never
    ///      `.exited` / `.failed`), and
    ///   2. a current broker status whose `phase` is a live/running phase
    ///      (see `Self.isLivePhase`). A session with no status at all is
    ///      treated as not-confirmed-live: we listed it but the broker
    ///      hasn't told us it's running.
    ///
    /// `.creating` is honored without a status because a brand-new
    /// session we just spun up locally has no broker status yet but is
    /// genuinely on its way live — the create round-trip owns that state.
    func isConfirmedLive(sessionID: String) -> Bool {
        switch sessionLifecycle[sessionID] {
        case .exited, .failed:
            return false
        case .none:
            // No local lifecycle entry — e.g. a session restored from the
            // saved list or re-listed after a reconnect, before any create
            // round-trip recorded a lifecycle. Trust the broker: if it's
            // reporting a current running phase, the session is interactive.
            // Without this a reconnected `running` session opened read-only
            // (device bug: codex listed as "running" but the chat had no
            // composer until the session was re-created). Still fails closed
            // when there's no status or a terminal phase.
            if let phase = statusBySession[sessionID]?.phase {
                return Self.isLivePhase(phase)
            }
            return false
        case .creating:
            // Newly-created session mid-handshake: interactive, even
            // before the first status frame. A confirmed-exited phase
            // (raced ahead) still wins.
            if let phase = statusBySession[sessionID]?.phase,
               !Self.isLivePhase(phase) {
                return false
            }
            return true
        case .live:
            // `.live` is necessary but not sufficient — it can be a
            // stale default. Demand a current running phase if we have a
            // status; if we somehow have a `.live` lifecycle with no
            // status (e.g. a freshly-created session promoted by the
            // create path) trust the lifecycle.
            guard let phase = statusBySession[sessionID]?.phase else {
                return true
            }
            return Self.isLivePhase(phase)
        }
    }

    /// Classify a broker `SessionStatus.phase` as live/running vs
    /// terminal/unknown. The broker reports `running` for an active
    /// agent and `exited` (optionally `exited(N)` after our own
    /// `ingestExit` rewrites it) for a dead one; recovered sessions
    /// restore whatever phase was persisted. We treat anything that
    /// isn't an affirmatively-running phase as NOT live so an unfamiliar
    /// or empty phase fails closed (read-only) rather than open.
    static func isLivePhase(_ phase: String) -> Bool {
        let p = phase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if p.isEmpty { return false }
        if p.hasPrefix("exited") || p.hasPrefix("failed") || p.hasPrefix("dead") {
            return false
        }
        // Known running/active phases emitted by the broker + adapters.
        let live: Set<String> = [
            "running", "ready", "idle", "thinking", "working",
            "starting", "booting", "swapping",
        ]
        return live.contains(p)
    }

    /// Pull the exit code out of an `exited(N)` phase string. The broker
    /// emits a bare `exited`; our own `ingestExit` rewrites the cached
    /// status to `exited(<code>)`. Returns nil when there's no parseable
    /// code (caller defaults to 0).
    static func exitCode(fromPhase phase: String) -> Int32? {
        guard let open = phase.firstIndex(of: "("),
              let close = phase.firstIndex(of: ")"),
              open < close else { return nil }
        let inner = phase[phase.index(after: open)..<close]
        return Int32(inner.trimmingCharacters(in: .whitespaces))
    }

    /// Switch the active session — drives the iPhone `NavigationStack`
    /// destination + the iPad detail pane. No reducer / Rust-core call;
    /// the existing `onChange(of: store.selectedSessionID)` in
    /// `HomeView` picks this up and pushes the target session.
    ///
    /// Lives here (not on a coordinator) so the multi-thread switcher
    /// in `ThreadSwitcherSheet` and any future "jump to thread" deep
    /// link have one place to call. Mirrors upstream's
    /// `ConversationThreadSwitcher` semantics. PR H owns the reducer
    /// path; this is the navigation-level setter only.
    func switchTo(sessionID: String) {
        guard sessions.contains(where: { $0.id == sessionID })
            || sessionLifecycle[sessionID] != nil
        else {
            // No-op if the target doesn't exist — guards against a
            // stale row tap after a session exited and was reaped.
            return
        }
        selectedSessionID = sessionID
    }

    /// Reconcile the local session list against the broker's AUTHORITATIVE
    /// live set on (re)connect — the keep-alive model: the server is the source
    /// of truth for liveness, not our locally-saved `.live` flags.
    ///
    /// The previous implementation blindly `joinSession`'d every saved
    /// `.live` row on connect. That was the bug behind the device-test
    /// report: an agent's live process can't survive a broker restart (every
    /// release redeploys the broker), so on relaunch most "live" rows were
    /// actually dead — and `joinSession` silently *recovered* each from disk
    /// as a fresh agent with reset timestamps and (often) a blank screen.
    /// Result: exited sessions shown as "running", no history, wrong times.
    ///
    /// Now we ask the broker what's genuinely alive (`GET /api/sessions`,
    /// which never resurrects) and:
    ///   1. reattach ONLY the running ones → they enter the ACTIVE list with
    ///      the broker's real scrollback + correct status/timestamps;
    ///   2. demote every saved `.live` row the broker no longer has to
    ///      `.exited`, so it drops out of ACTIVE and into History (where the
    ///      user can reopen it read-only or resume on tap).
    /// Does NOT navigate — rows just go live (or fall to history) in place.
    func reconcileLiveSessions() {
        guard client != nil else { isLoadingSessions = false; return }
        let serverID = savedHistoryServerID
        // Show a loading state in the home list (instead of flashing "No
        // sessions yet") until the broker's live set lands and we've joined.
        // Set synchronously here — before connect()'s flow yields to a render —
        // so the `.linked` empty state never paints. Cleared at every Task exit.
        isLoadingSessions = true
        Telemetry.breadcrumb("session", "reconcile_live_begin", data: ["server": serverID])
        Task { @MainActor in
            // Always clear the loading flag, however this reconcile exits.
            defer { isLoadingSessions = false }
            try? await waitUntilCommandReady()
            guard let client else { return }

            let aliveList: [LiveSessionInfo]
            do {
                aliveList = try await fetchLiveSessions()
            } catch {
                // Older broker without /api/sessions, or a transient fetch
                // failure. Do NOT fall back to reattaching everything (that
                // resurrects dead sessions — the exact bug we're fixing).
                // Leave saved `.live` rows in History untouched; the user can
                // resume any of them on tap.
                Telemetry.breadcrumb("session", "reconcile_live_unavailable", data: [
                    "error": Self.describe(error),
                ])
                return
            }

            let running = aliveList.filter { $0.running }
            let aliveIDs = Set(running.map { $0.id })
            Telemetry.breadcrumb("session", "reconcile_live_fetched", data: [
                "alive": "\(running.count)",
                "reported": "\(aliveList.count)",
            ])

            // Stamp each live session with the box it came from so we can
            // (a) group by box on the home list and (b) gate sends to avoid
            // routing into the wrong broker (UnknownSession root cause).
            for info in running {
                sessionBox[info.id] = serverID
            }

            // 1. Reattach genuinely-alive sessions the broker is keeping
            //    running. Skip tombstoned ids and ones already live locally.
            for info in running
            where !SavedSessionsStore.shared.isTombstoned(id: info.id)
                && !sessions.contains(where: { $0.id == info.id }) {
                if sessionLifecycle[info.id] == nil {
                    sessionLifecycle[info.id] = .creating
                }
                // Seed the terminal from persisted scrollback so the row
                // paints instantly; the broker snapshot replaces it once the
                // join lands (`ingestSnapshot`).
                hydrateTerminalBuffer(info.id)
                try? await client.joinSession(sessionId: info.id, assistant: info.assistant)
                // Restore the prior CHAT too — the broker replays only the
                // terminal snapshot over the WS on reattach, so without this
                // the conversation would be blank until the next turn. Fire it
                // off the reconcile path so the spinner clears as soon as the
                // rows are joined; the chat fills in a beat later.
                let sid = info.id
                Task { @MainActor in await self.hydrateChatConversation(sid) }
            }

            // 2. For each locally-saved `.live` session the broker did NOT
            //    return as running, decide keep-vs-demote:
            //
            //    a) Recoverable (broker restart, cold session that will
            //       respawn on /ws open): auto-rejoin so it stays Active.
            //       Scope guard: only sessions already in OUR local active
            //       store -- never mass-join the broker's full recoverable
            //       list (it can contain dozens of unrelated sessions).
            //    b) Genuinely gone (not recoverable): demote to History as
            //       before.
            //
            //    recoverableSessionIDs is populated as a side-effect of
            //    fetchLiveSessions() just above.
            let savedLive = SavedSessionsStore.shared.sessions.filter {
                $0.serverID == serverID && $0.status == .live
            }
            var demoted = 0
            var rejoining = 0
            for saved in savedLive where !aliveIDs.contains(saved.id) {
                guard !SavedSessionsStore.shared.isTombstoned(id: saved.id) else {
                    // Tombstoned -- treat as gone, don't touch SavedSessionsStore.
                    continue
                }
                if recoverableSessionIDs.contains(saved.id) {
                    // Anti-thrash: skip if a join for this session is already
                    // live or in progress from step 1.
                    let lc = sessionLifecycle[saved.id]
                    if case .live = lc {
                        // Already live -- nothing to do; skip the demote too.
                        continue
                    }
                    if lc == .creating {
                        // Already being created this cycle -- don't issue a
                        // second join. Skip the demote.
                        rejoining += 1
                        continue
                    }
                    // Stamp the box and put the session into a transient
                    // rejoining state (.creating is the correct non-terminal
                    // lifecycle for an in-progress attach) so it appears as
                    // reconnecting rather than vanishing from the Active list.
                    sessionBox[saved.id] = serverID
                    sessionLifecycle[saved.id] = .creating
                    hydrateTerminalBuffer(saved.id)
                    Telemetry.breadcrumb("session", "reconcile_rejoin_start", data: [
                        "session": saved.id,
                        "assistant": saved.agent,
                    ])
                    let rejoinID = saved.id
                    let rejoinAssistant = saved.agent
                    Task { @MainActor in
                        do {
                            try await client.joinSession(
                                sessionId: rejoinID,
                                assistant: rejoinAssistant
                            )
                            // Hydrate chat: broker replays terminal snapshot on
                            // reattach (#700) but chat is HTTP-fetched separately.
                            await self.hydrateChatConversation(rejoinID)
                            Telemetry.breadcrumb("session", "reconcile_rejoin_success", data: [
                                "session": rejoinID,
                            ])
                        } catch {
                            // Join failed -- demote NOW so the row doesn't stay
                            // stuck as an un-joined `.creating` placeholder.
                            if self.sessionLifecycle[rejoinID] == .creating {
                                self.sessionLifecycle[rejoinID] = .exited(0)
                            }
                            SavedSessionsStore.shared.markExited(
                                id: rejoinID,
                                serverID: serverID
                            )
                            Telemetry.capture(
                                error: error,
                                message: "iOS reconcile auto-rejoin failed",
                                tags: ["surface": "ios", "phase": "reconcile_rejoin"],
                                extras: ["session_id": rejoinID, "assistant": rejoinAssistant]
                            )
                        }
                        self.refreshSessions()
                    }
                    rejoining += 1
                } else {
                    // Genuinely gone: demote to History as before.
                    SavedSessionsStore.shared.markExited(id: saved.id, serverID: serverID)
                    // If a stale local row exists, reflect the death so it
                    // reads read-only rather than interactive.
                    if sessions.contains(where: { $0.id == saved.id }),
                       sessionLifecycle[saved.id] == nil {
                        sessionLifecycle[saved.id] = .exited(0)
                    }
                    demoted += 1
                }
            }
            if demoted > 0 {
                Telemetry.breadcrumb("session", "reconcile_live_demoted", data: [
                    "count": "\(demoted)",
                ])
            }
            if rejoining > 0 {
                Telemetry.breadcrumb("session", "reconcile_live_rejoining", data: [
                    "count": "\(rejoining)",
                ])
            }

            // Evict .exited sessions the broker has GC'd (no longer on disk).
            // Only runs when fetchLiveSessions() succeeded, so the broker's view
            // is current. Safe to remove: the server-side file is gone.
            let brokerKnownIDs = Set(running.map { $0.id }).union(recoverableSessionIDs)
            let gcEvicted = SavedSessionsStore.shared.sessions.filter {
                $0.serverID == serverID &&
                $0.status == .exited &&
                !brokerKnownIDs.contains($0.id)
            }
            if !gcEvicted.isEmpty {
                for s in gcEvicted {
                    SavedSessionsStore.shared.remove(id: s.id)
                }
                Telemetry.breadcrumb("session", "reconcile_gc_evicted", data: [
                    "count": "\(gcEvicted.count)",
                ])
            }

            // CHANGE 4: Auto-resume sessions snapshotted at broker-update
            // confirm time. Only resume the ids we snapshotted — never
            // mass-resume arbitrary old recoverable sessions.
            if let resumeSet = pendingResume.removeValue(forKey: serverID), !resumeSet.isEmpty {
                Telemetry.breadcrumb("broker_update", "auto_resume fired", data: [
                    "box": serverID, "count": "\(resumeSet.count)",
                ])
                for sessionID in resumeSet where recoverableSessionIDs.contains(sessionID) {
                    // Look up the assistant from the saved sessions list.
                    let assistant = SavedSessionsStore.shared.sessions
                        .first(where: { $0.id == sessionID })?.agent ?? "claude"
                    Telemetry.breadcrumb("broker_update", "auto_resume fire", data: [
                        "session": sessionID, "assistant": assistant,
                    ])
                    resumeRecoverableSession(sessionID: sessionID, assistant: assistant)
                }
            }

            refreshSessions()
        }
    }

    /// Attach to a session that's still LIVE on the broker but isn't in
    /// our local live set yet — the "open a historical row" path from
    /// `SessionsScreen`. The session list on a fresh client is empty
    /// until status frames trickle back (see `refreshSessions`), so we
    /// can't `switchTo` synchronously; instead we `join_session` (which
    /// opens the WS for an existing id — the same `open_session` route
    /// `create_session` takes) and then poll until the row materializes
    /// before navigating.
    ///
    /// Idempotent: if the session is already live locally we just
    /// `switchTo` and return. Assumes the caller has already selected
    /// the right saved server.
    func attachLiveSession(sessionID: String, assistant: String) {
        if sessions.contains(where: { $0.id == sessionID }) {
            switchTo(sessionID: sessionID)
            return
        }
        // Cold-launch restore: seed the terminal from the last persisted
        // scrollback so the view paints instantly instead of waiting for the
        // socket. The broker's authoritative snapshot REPLACES this once
        // `joinSession` lands (`ingestSnapshot`).
        hydrateTerminalBuffer(sessionID)
        // Multi-box: join on the connection that OWNS this session (via the
        // existing `sessionBox` stamp). Single-box: nil → global client.
        let ownerBox: BoxConnection? = {
            guard multiBoxEnabled, let boxID = sessionBox[sessionID] else { return nil }
            return boxConnections[boxID]
        }()
        Task { @MainActor in
            do {
                try await waitUntilCommandReady(box: ownerBox)
                guard let client = clientForSession(sessionID) else { return }
                // Mark creating so the home list shows the row as
                // attaching rather than vanishing during the round-trip.
                if sessionLifecycle[sessionID] == nil {
                    sessionLifecycle[sessionID] = .creating
                }
                try await client.joinSession(sessionId: sessionID, assistant: assistant)
                self.refreshSessions()
                // Poll briefly for the joined session to surface in
                // `list_sessions()` (it lands as soon as `open_session`
                // inserts it, but status frames can lag). Once present,
                // promote to live + navigate.
                let pollNs: UInt64 = 100_000_000
                var elapsedNs: UInt64 = 0
                let timeoutNs: UInt64 = 6_000_000_000
                while !self.sessions.contains(where: { $0.id == sessionID }),
                      elapsedNs < timeoutNs {
                    try await Task.sleep(nanoseconds: pollNs)
                    elapsedNs += pollNs
                    self.refreshSessions()
                }
                if self.sessions.contains(where: { $0.id == sessionID }) {
                    // Promote the placeholder using the broker's reported
                    // phase, not a blanket `.live`. Joining an existing id
                    // can resolve to a session that already exited; in that
                    // case `ingestStatus` has set `.exited` (so we're no
                    // longer `.creating` and skip this), or — if no status
                    // landed yet but the cached phase is terminal — we lock
                    // it read-only here. Otherwise promote to live and the
                    // destination opens interactive. Either way navigate so
                    // the user lands on the (correctly read-only or live)
                    // session rather than a dead-end.
                    if self.sessionLifecycle[sessionID] == .creating {
                        let phase = self.statusBySession[sessionID]?.phase
                        if let phase, phase.lowercased().hasPrefix("exited") {
                            let code = Self.exitCode(fromPhase: phase) ?? 0
                            self.sessionLifecycle[sessionID] = .exited(code)
                        } else if phase.map(Self.isLivePhase) ?? true {
                            // Live phase, or no status yet (a join we
                            // initiated — trust it as live until a status
                            // frame says otherwise).
                            self.sessionLifecycle[sessionID] = .live
                        }
                        // A non-live, non-exited phase leaves `.creating`
                        // in place; the next status frame resolves it.
                    }
                    self.selectedSessionID = sessionID
                } else if self.sessionLifecycle[sessionID] == .creating {
                    // Never showed up — clear the placeholder so the
                    // list doesn't keep a stuck "attaching" row.
                    self.sessionLifecycle[sessionID] = nil
                }
            } catch {
                if self.sessionLifecycle[sessionID] == .creating {
                    self.sessionLifecycle[sessionID] = nil
                }
                Telemetry.capture(
                    error: error,
                    message: "iOS attach live session failed",
                    tags: ["surface": "ios", "phase": "attach_session"],
                    extras: ["endpoint": self.endpoint.displayHost, "session_id": sessionID]
                )
            }
        }
    }

    /// Locally rename a session — persisted to `UserDefaults`, no
    /// harness round-trip. Empty/whitespace strings clear the override.
    func renameSession(sessionID: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            displayNames[sessionID] = nil
        } else {
            displayNames[sessionID] = trimmed
        }
    }

    /// Fork: create a fresh session with the same assistant + branch,
    /// and seed it with a one-line hand-off pointing at the original.
    /// The fork can target a different reasoning effort and/or model than
    /// the original — both are optional overrides that ride through the
    /// core's `create_session` to the broker, which applies them to the
    /// new agent's CLI flags. nil for either means "same as the original"
    /// (the broker falls back to the adapter default). Reasoning effort
    /// can't be changed mid-session — that's why this is a fork (new
    /// session), not a live switch.
    func forkSession(sessionID: String, reasoningEffort: String? = nil, model: String? = nil, permissionMode: String? = nil, fastMode: Bool? = nil) {
        guard let original = sessions.first(where: { $0.id == sessionID }) else { return }
        // A fork must live on the SAME box as the original — route the create
        // through the original session's owning connection and stamp the new
        // id to that box too.
        guard let client = clientForSession(sessionID) else { return }
        let forkBoxID = sessionBox[sessionID]
        let trimmedMode = permissionMode?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pickedMode = (trimmedMode?.isEmpty == false) ? trimmedMode : nil
        let modeCrumb = pickedMode ?? "auto"
        Telemetry.breadcrumb("session", "fork override", data: [
            "assistant": original.assistant,
            "permission_mode": modeCrumb,
            "session_id": sessionID,
        ])
        Task {
            do {
                let newID = try await client.createSession(
                    assistant: original.assistant,
                    branch: original.branch,
                    reasoningEffort: reasoningEffort,
                    model: model,
                    cwd: nil,
                    permissionMode: pickedMode,
                    fastMode: fastMode,
                    deviceId: DeviceIdentity.deviceID
                )
                if let forkBoxID { self.sessionBox[newID] = forkBoxID }
                let seed = "Forked from \(original.name) (id \(sessionID)). Pick up where the previous session left off."
                // Fire-and-forget seed: not tracked in the outbox, but still
                // carries a stable client_msg_id so the broker dedups/acks it
                // (the ack just no-ops — no matching echo). Task K signature.
                try? await client.sendChat(sessionId: newID, msg: seed, clientMsgId: "local-fork-seed-\(newID)")
                // Same model record as createSession: an explicit fork-onto
                // model is the only honest source for the identity header;
                // a no-override fork inherits the original's record.
                if let model, !model.isEmpty {
                    self.modelBySession[newID] = model
                } else if let inherited = self.modelBySession[sessionID] {
                    self.modelBySession[newID] = inherited
                }
                self.sessionLifecycle[newID] = .live
                self.refreshSessions()
                self.selectedSessionID = newID
                self.displayNames[newID] = "Fork: \(self.displayName(for: original))"
            } catch {
                let detail = Self.describe(error)
                self.sessionCreationError = "fork: \(detail)"
                Telemetry.capture(
                    error: error,
                    message: "iOS fork session failed",
                    tags: ["surface": "ios", "phase": "fork_session"],
                    extras: ["endpoint": self.endpoint.displayHost, "session_id": sessionID, "detail": detail]
                )
            }
        }
    }

    private func refreshRecentDirectories() {
        let all = Self.loadRecentDirectoriesByServer()
        recentDirectories = all[endpoint.displayHost] ?? []
    }

    private func rememberRecentDirectory(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var all = Self.loadRecentDirectoriesByServer()
        let key = endpoint.displayHost
        var current = all[key] ?? []
        current.removeAll { $0 == trimmed }
        current.insert(trimmed, at: 0)
        if current.count > 12 { current = Array(current.prefix(12)) }
        all[key] = current
        Self.persistRecentDirectoriesByServer(all)
        recentDirectories = current
    }

    private static func loadRecentDirectoriesByServer() -> [String: [String]] {
        guard let data = UserDefaults.standard.data(forKey: recentDirectoriesByServerKey),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func persistRecentDirectoriesByServer(_ value: [String: [String]]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: recentDirectoriesByServerKey)
    }

    private func waitUntilCommandReady(timeoutMs: UInt64 = 6000, box: BoxConnection? = nil) async throws {
        let pollNs: UInt64 = 100_000_000
        var elapsedNs: UInt64 = 0
        let timeoutNs = timeoutMs * 1_000_000
        while elapsedNs < timeoutNs {
            // On the multi-box path the global `harness` mirrors the primary
            // box; when an op targets a SPECIFIC box, gate on THAT box's
            // harness instead so a different primary's state can't block it.
            switch (box?.harness ?? harness) {
            case .linked, .live, .reconnecting:
                return
            case .failed(let reason):
                throw NSError(domain: "SessionStore", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
            default:
                break
            }
            try await Task.sleep(nanoseconds: pollNs)
            elapsedNs += pollNs
        }
        throw NSError(domain: "SessionStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for server link"])
    }

    // MARK: - Rust shadow-store helpers

    /// Ensure the Rust store has at least a placeholder
    /// `ProjectSessionState` for `sessionID` before applying an event
    /// that would otherwise return nil. iOS' Swift maps tolerate
    /// "apply chat to an unknown session id" (they auto-vivify the
    /// dictionary entry); the Rust store only auto-vivifies on
    /// `apply_status`. Without this nudge, every `apply_chat` /
    /// `apply_pty_data` etc. that lands before the first `on_status`
    /// would silently no-op and the parity asserts would fail.
    fileprivate func ensureRustSessionPresent(_ sessionID: String) {
        guard !rustStore.contains(sessionId: sessionID) else { return }
        rustStore.registerSession(
            session: ProjectSession(
                id: sessionID,
                name: sessionID,
                assistant: statusBySession[sessionID]?.assistant ?? "claude",
                branch: nil,
                preview: preview[sessionID],
                reasoningEffort: statusBySession[sessionID]?.reasoningEffort,
                cwd: statusBySession[sessionID]?.cwd,
                startedAt: statusBySession[sessionID]?.startedAt,
                lastActivityAt: statusBySession[sessionID]?.lastActivityAt,
                displayName: statusBySession[sessionID]?.displayName,
                totalInputTokens: nil,
                totalOutputTokens: nil,
                totalCachedTokens: nil,
                totalCostUsd: nil,
                contextUsedTokens: nil,
                contextWindowTokens: nil
            )
        )
    }

    #if DEBUG
    /// Compare scrollback bytes Swift-side vs Rust-side for `sessionID`.
    /// Off in release builds so the FFI hop + memcmp cost doesn't ride
    /// every PTY frame. Reports a single assertionFailure with the size
    /// delta so the test breakpoint can land directly on it.
    fileprivate func assertRustScrollbackParity(_ sessionID: String) {
        let swiftBytes = terminalBuffer[sessionID] ?? Data()
        let rustBytes = rustStore.get(sessionId: sessionID)?.terminal.scrollback ?? Data()
        assert(
            swiftBytes == rustBytes,
            "Rust/Swift scrollback diverged for \(sessionID): swift=\(swiftBytes.count) rust=\(rustBytes.count)"
        )
    }

    fileprivate func assertRustChatLogParity(_ sessionID: String) {
        let swiftEvents = chatLog[sessionID] ?? []
        let rustEvents = rustStore.get(sessionId: sessionID)?.chat.events ?? []
        // Compare counts first — the cheap signal — then by role/content
        // tuple. We don't compare ts because the Rust dedup is on (role,
        // content, ts) and matches the Swift order one-to-one.
        assert(
            swiftEvents.count == rustEvents.count
                && zip(swiftEvents, rustEvents).allSatisfy {
                    $0.role == $1.role && $0.content == $1.content && $0.ts == $1.ts
                },
            "Rust/Swift chat log diverged for \(sessionID): swift=\(swiftEvents.count) rust=\(rustEvents.count)"
        )
    }

    fileprivate func assertRustStatusParity(_ sessionID: String) {
        let swiftStatus = statusBySession[sessionID]
        let rustStatus = rustStore.get(sessionId: sessionID)?.status
        assert(
            swiftStatus?.session == rustStatus?.session
                && swiftStatus?.phase == rustStatus?.phase
                && swiftStatus?.reasoningEffort == rustStatus?.reasoningEffort,
            "Rust/Swift status diverged for \(sessionID)"
        )
    }

    fileprivate func assertRustPreviewParity(_ sessionID: String) {
        let swiftPreview = preview[sessionID]
        let rustPreview = rustStore.get(sessionId: sessionID)?.browser.preview
        assert(
            swiftPreview?.port == rustPreview?.port
                && swiftPreview?.url == rustPreview?.url,
            "Rust/Swift preview diverged for \(sessionID)"
        )
    }

    fileprivate func assertRustLifecycleParity(_ sessionID: String) {
        // The Swift `SessionLifecycle` and Rust-bridged
        // `SessionLifecycleCore` are intentionally separate types (the
        // Swift one predates the FFI; their case names diverge —
        // `.failed` vs `.failedToStart`). Map for comparison.
        let swiftLifecycle = sessionLifecycle[sessionID]
        let rustLifecycle = rustStore.lifecycle(sessionId: sessionID)
        let parityOK: Bool
        switch (swiftLifecycle, rustLifecycle) {
        case (nil, nil): parityOK = true
        case (.creating?, .creating?): parityOK = true
        case (.live?, .live?): parityOK = true
        case let (.exited(swiftCode)?, .exited(code: rustCode)?):
            parityOK = swiftCode == rustCode
        case (.failed?, .failedToStart?): parityOK = true
        default: parityOK = false
        }
        assert(parityOK, "Rust/Swift lifecycle diverged for \(sessionID)")
    }
    #endif
}

extension SessionStore {
    /// True when the error is a TCP connection-refused — the SSH tunnel or
    /// broker is dead but the harness still reports `.live`. Callers use this
    /// to trigger SSH self-heal instead of showing a cryptic error.
    static func isConnectionRefused(_ error: Error) -> Bool {
        let t = String(describing: error).lowercased()
        if t.contains("connection refused") || t.contains("os error 61") || t.contains("econnrefused") {
            return true
        }
        if let urlErr = error as? URLError, urlErr.code == .cannotConnectToHost {
            return true
        }
        return false
    }
}

private extension SessionStore {
    static let recentDirectoriesByServerKey = "conduit.recentDirectoriesByServer"

    static func describe(_ error: Error) -> String {
        if isAuth(error) {
            return "Authentication failed. This pairing token has expired; scan a fresh QR code from the server."
        }
        return String(describing: error)
    }

    static func isAuth(_ error: Error) -> Bool {
        let text = String(describing: error).lowercased()
        return text.contains("auth(") || text == "auth" || text.contains("unauthorized")
    }

    static func describeSsh(_ err: SshError) -> String {
        switch err {
        case .Dial(let m):
            return "Couldn't reach the host: \(m)"
        case .Handshake(let m):
            return "SSH handshake failed: \(m)"
        case .HostKeyRejected(let m):
            return "Host key rejected: \(m)"
        case .AuthFailed(let m):
            return "Authentication failed: \(m)"
        case .DockerMissing(_):
            // Dead variant — bare-binary bootstrap never emits this.
            return "This box isn't supported: Docker-based setup is no longer used."
        case .DockerPermission(_):
            // Dead variant — bare-binary bootstrap never emits this.
            return "This box isn't supported: Docker-based setup is no longer used."
        case .PortConflict(let m):
            return "Server port is already in use: \(m)"
        case .HarnessStartTimeout(let m):
            return "Server took too long to come up: \(m)"
        case .BrokerInstallFailed(let m):
            return "Couldn't download the conduit broker — this box can't reach the release host (firewall/proxy?), or the download failed. Check egress and reconnect. (\(m))"
        case .CurlMissing(_):
            return "This box has no curl or wget — install one and reconnect."
        case .UnsupportedPlatform(let m):
            return "conduit doesn't support this box (\(m)). Supported: Linux x86_64 / arm64."
        case .BrokerExecFailed(let m):
            return "The conduit broker won't run on this box (architecture mismatch, noexec home, or a security policy). This box isn't supported. (\(m))"
        case .HomeUnwritable(_):
            return "Can't write to the home directory on this box (read-only or out of disk)."
        case .BootstrapExitCode(let m):
            return "Bootstrap script failed: \(m)"
        case .BootstrapParse(let m):
            return "Couldn't parse bootstrap output: \(m)"
        case .PortForward(let m):
            return "Port forward failed: \(m)"
        case .Io(let m):
            return "I/O error: \(m)"
        }
    }

    static func sshCode(_ err: SshError) -> String {
        switch err {
        case .Dial:                  return "dial"
        case .Handshake:             return "handshake"
        case .HostKeyRejected:       return "host_key_rejected"
        case .AuthFailed:            return "auth_failed"
        case .DockerMissing:         return "docker_missing"
        case .DockerPermission:      return "docker_permission"
        case .PortConflict:          return "port_conflict"
        case .HarnessStartTimeout:   return "harness_start_timeout"
        case .BrokerInstallFailed:   return "broker_install_failed"
        case .CurlMissing:           return "curl_missing"
        case .UnsupportedPlatform:   return "unsupported_platform"
        case .BrokerExecFailed:      return "broker_exec_failed"
        case .HomeUnwritable:        return "home_unwritable"
        case .BootstrapExitCode:     return "bootstrap_exit"
        case .BootstrapParse:        return "bootstrap_parse"
        case .PortForward:           return "port_forward"
        case .Io:                    return "io"
        }
    }

    static func connectionReasonCode(from reason: String) -> String {
        let lower = reason.lowercased()
        if lower.contains("auth") || lower.contains("401") || lower.contains("unauthorized") {
            return "auth_expired"
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return "timeout"
        }
        if lower.contains("refused") {
            return "ws_refused"
        }
        if lower.contains("network") {
            return "network_unavailable"
        }
        return "disconnected"
    }
}

/// Wraps either a real `ProjectSession` or an in-flight placeholder so the
/// sidebar can render a row before the server confirms creation.
enum VisibleSession: Identifiable {
    case real(ProjectSession)
    case creating(String)

    var id: String {
        switch self {
        case .real(let s):     return s.id
        case .creating(let p): return p
        }
    }
}

/// Bridges the Rust SSH layer's TOFU callback into the SwiftUI sheet.
/// The Rust side invokes `acceptHostKey(fingerprint:)` synchronously on a
/// background runtime thread; we either short-circuit on a previously
/// trusted fingerprint or block via a semaphore while the user taps
/// Accept/Reject on the main actor.
final class SshHostKeyBridge: SshHostKeyDelegate {
    private weak var store: SessionStore?
    private let host: String
    private let port: UInt16

    init(store: SessionStore, host: String, port: UInt16) {
        self.store = store
        self.host = host
        self.port = port
    }

    func acceptHostKey(fingerprint: String) -> Bool {
        if let trusted = SshHostKeyTrustStore.known(host: host, port: port), trusted == fingerprint {
            Telemetry.breadcrumb(
                "ssh_hostkey", "host key auto-trusted (known)",
                data: ["host": host, "fp_prefix": String(fingerprint.prefix(16))]
            )
            return true
        }
        let sem = DispatchSemaphore(value: 0)
        var decision = false
        let host = self.host
        let port = self.port
        Task { @MainActor in
            guard let store = self.store else {
                sem.signal()
                return
            }
            store.presentHostKeyPrompt(host: host, port: port, fingerprint: fingerprint) { accepted in
                decision = accepted
                sem.signal()
            }
        }
        let result = sem.wait(timeout: .now() + 120)
        if result == .timedOut {
            Telemetry.breadcrumb(
                "ssh_hostkey", "host key decision timed out -> reject",
                data: ["host": host, "fp_prefix": String(fingerprint.prefix(16))]
            )
            return false
        }
        return decision
    }
}

// MARK: - SshProgressBridge

/// Bridges the Rust SSH bootstrap progress callbacks into SwiftUI state.
/// Called synchronously on the russh worker thread; each call dispatches
/// to the `@MainActor` store to update `sshBootstrapState` with a
/// friendly human-readable message. The mapping covers both the Rust
/// connect-sequence phases and the STEP markers in remote-bootstrap.sh.
final class SshProgressBridge: SshProgressDelegate {
    private weak var store: SessionStore?
    private let host: String

    init(store: SessionStore, host: String) {
        self.store = store
        self.host = host
    }

    func onProgress(phase: String, detail: String?) {
        let message = SshProgressBridge.friendlyMessage(phase: phase, detail: detail, host: host)
        guard let message else { return }
        Task { @MainActor [weak store] in
            store?.sshBootstrapState = .running(message: message)
        }
    }

    /// Map (phase, detail) pairs from the Rust core + bootstrap script to
    /// user-facing strings. Returns nil for lines we choose to suppress
    /// (raw human stderr that isn't a STEP marker).
    private static func friendlyMessage(phase: String, detail: String?, host: String) -> String? {
        switch phase {
        case "connecting":
            return "Connecting to \(detail ?? host)…"
        case "handshake":
            return "Securing connection…"
        case "authenticating":
            return "Authenticating…"
        case "tunnel":
            return "Opening secure tunnel…"
        case "bootstrap":
            guard let line = detail else { return nil }
            // Machine-parseable STEP markers from remote-bootstrap.sh.
            switch line {
            case "STEP reuse_check":    return "Checking for existing server…"
            case "STEP download_broker": return "Downloading server…"
            case "STEP start_broker":   return "Starting server…"
            case "STEP install_agent":  return "Installing agent…"
            case "STEP wait_ready":     return "Waiting for server…"
            default:
                // Suppress other human-readable stderr lines to avoid spam.
                return nil
            }
        default:
            return nil
        }
    }
}

// MARK: - AgentLoginTransport (Approach v2)
//
// `AgentLoginCoordinator` ships the outbound control envelopes via this
// protocol; each method forwards through the SessionStore's Rust client
// (`startAgentLogin` / `agentLoginCallback` / `cancelAgentLogin`, bridged
// over UDL). The broker handlers are live (PR #114) and the inbound
// dispatch path (`routeAgentLoginViewEvent`) consumes the `agent_login_*`
// view-events, so the flow is now end-to-end.
//
// Concrete `AgentLoginTransport` conformance is a thin actor-isolated
// wrapper around a SessionStore reference so the coordinator
// (`@MainActor`) and the protocol (`Sendable`) compose without
// dragging the store across actor boundaries.

/// Error raised when the v2 OAuth transport can't reach the store
/// (released) — the live-client `NotConnected` case is thrown by the
/// store methods themselves. Caught by `AgentLoginCoordinator` and
/// surfaced to the sheet as a `.failed(reason:)` state.
struct AgentLoginTransportError: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}

/// `AgentLoginTransport` impl backed by `SessionStore`. Kept as a
/// separate `final class` (not the store itself) so the `Sendable`
/// conformance can be `nonisolated` while the store stays
/// `@MainActor`.
final class SessionStoreAgentLoginTransport: AgentLoginTransport, @unchecked Sendable {
    private weak var store: SessionStore?

    init(store: SessionStore) { self.store = store }

    func sendStartAgentLogin(provider: String) async throws {
        guard let store else {
            throw AgentLoginTransportError(detail: "SessionStore was released")
        }
        try await store.sendAgentLoginStart(provider: provider)
    }

    func sendAgentLoginCallback(sessionToken: String, queryString: String) async throws {
        guard let store else {
            throw AgentLoginTransportError(detail: "SessionStore was released")
        }
        try await store.sendAgentLoginCallback(sessionToken: sessionToken, queryString: queryString)
    }

    func sendCancelAgentLogin(sessionToken: String) async throws {
        guard let store else {
            throw AgentLoginTransportError(detail: "SessionStore was released")
        }
        try await store.sendAgentLoginCancel(sessionToken: sessionToken)
    }
}

/// Bridges Rust-side callbacks (arbitrary thread) onto the MainActor store.
final class StoreDelegate: ConduitDelegate {
    private weak var store: SessionStore?
    /// nil on the single-box path (callbacks update global state directly).
    /// On the multi-box path this is the owning `SavedServer.id`, so the
    /// box-scoped `onDisconnected` updates only that box's
    /// `BoxConnection.harness` instead of clobbering the global harness.
    private let boxID: String?
    /// Generation counter stamped at creation time. Any callback whose
    /// generation no longer matches `store.clientGeneration` belongs to a
    /// stale old ConduitClient (e.g. the one being torn down by `disconnect()`
    /// during a box switch) and is dropped so it cannot clobber state that the
    /// new client has already set (e.g. `.linked` → `.failed` flicker).
    private let generation: UInt64
    init(store: SessionStore, boxID: String? = nil, generation: UInt64 = 0) {
        self.store = store
        self.boxID = boxID
        self.generation = generation
    }

    /// Returns true when this delegate's callbacks should still be delivered.
    /// False means a new client has already been created and we are a ghost.
    @MainActor private func isCurrent(store: SessionStore) -> Bool {
        // boxID delegates are scoped to their box, not the global generation.
        guard boxID == nil else { return true }
        return store.clientGeneration == generation
    }

    func onPtyData(sessionId: String, data: Data) {
        Task { @MainActor in
            guard let s = self.store, self.isCurrent(store: s) else { return }
            s.ingestPtyData(sessionId, data)
        }
    }
    func onChatEvent(sessionId: String, event: ChatEvent) {
        Task { @MainActor in
            guard let s = self.store, self.isCurrent(store: s) else { return }
            s.ingestChat(sessionId, event)
        }
    }
    func onPreviewReady(sessionId: String, preview: PreviewInfo) {
        Task { @MainActor in
            guard let s = self.store, self.isCurrent(store: s) else { return }
            s.ingestPreview(sessionId, preview)
        }
    }
    func onStatus(status: SessionStatus) {
        Task { @MainActor in
            guard let s = self.store, self.isCurrent(store: s) else { return }
            s.ingestStatus(status)
        }
    }
    func onSnapshot(sessionId: String, gunzipped: Data) {
        Task { @MainActor in
            guard let s = self.store, self.isCurrent(store: s) else { return }
            s.ingestSnapshot(sessionId, gunzipped)
        }
    }
    func onExit(sessionId: String, code: Int32) {
        Task { @MainActor in
            guard let s = self.store, self.isCurrent(store: s) else { return }
            s.ingestExit(sessionId, code)
        }
    }
    func onDisconnected(reason: String) {
        Task { @MainActor in
            guard let s = self.store else { return }
            if let boxID = self.boxID {
                s.ingestBoxDisconnected(boxID: boxID, reason: reason)
            } else {
                guard self.isCurrent(store: s) else {
                    Telemetry.breadcrumb("connect", "stale client onDisconnected dropped",
                        data: ["generation": "\(self.generation)",
                               "current": "\(s.clientGeneration)",
                               "reason": reason])
                    return
                }
                s.ingestDisconnected(reason)
            }
        }
    }
    func onConnectionHealth(sessionId: String, health: ConnectionHealth) {
        Task { @MainActor in
            guard let s = self.store, self.isCurrent(store: s) else { return }
            s.ingestConnectionHealth(sessionId, health)
        }
    }
    func onChatDelivered(sessionId: String, clientMsgId: String) {
        Task { @MainActor in
            guard let s = self.store, self.isCurrent(store: s) else { return }
            s.ingestChatDelivered(sessionId, clientMsgId: clientMsgId)
        }
    }
    func onViewEvent(sessionId: String, kind: String, payload: [String: String]) {
        Task { @MainActor in
            guard let s = self.store, self.isCurrent(store: s) else { return }
            if kind == "quick_replies" {
                s.ingestQuickReplies(sessionId, payload: payload)
            } else if kind == "session_title" {
                s.ingestSessionTitle(sessionId, payload: payload)
            } else if kind == "agents" {
                s.ingestAgents(sessionId, payload: payload)
            } else if kind == "credential_source" {
                s.ingestCredentialSource(sessionId, payload: payload)
            } else if kind == "chat_streaming" {
                s.ingestChatStreaming(sessionId, payload: payload)
            } else if kind == "turn_phase" {
                s.ingestTurnPhase(sessionId, payload: payload)
            } else if kind == "thinking_streaming" {
                s.ingestThinkingStreaming(sessionId, payload: payload)
            } else {
                s.routeAgentLoginViewEvent(kind: kind, payload: payload)
            }
        }
    }
}
