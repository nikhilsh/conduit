package sh.nikhil.conduit

import org.json.JSONObject

// ---------------------------------------------------------------------------
// WS-H.1 consumer: BrokerReadiness models + pure-logic helpers for
// WS-H.2 (broker-update banner) and WS-H.3 (post-pair readiness checklist).
// ---------------------------------------------------------------------------

// MARK: - BrokerReadiness models

/**
 * Per-agent readiness state reported by the broker in `/api/capabilities`
 * `readiness.agents`. Mirror of iOS `AgentReadiness`.
 */
data class AgentReadiness(
    /** The agent CLI binary is present on the box. */
    val cliPresent: Boolean,
    /** The agent is signed in (credential file exists or env-key set). */
    val signedIn: Boolean,
    /** Seconds until the credential expires; null = permanent (API key) or unknown. */
    val authExpiresInS: Int?,
    /** How the credential is held: "env" (API key on box), "box" (signed in on box), or "app" (pushed from Conduit app). */
    val credentialSource: String? = null,
)

/**
 * Top-level readiness block from `/api/capabilities` `readiness` key
 * (broker #450). Null fields are replaced by safe defaults so an older
 * broker that omits individual keys still parses cleanly.
 *
 * Mirror of iOS `BrokerReadiness`.
 */
data class BrokerReadiness(
    /** Broker build tag ("v0.0.120") or "dev" for hand-built boxes. */
    val brokerVersion: String,
    /** Node.js found at broker startup. */
    val nodePresent: Boolean,
    /** tmux found on the broker host. */
    val tmuxPresent: Boolean,
    /** git found on the broker host (agents need git to clone/commit). */
    val gitPresent: Boolean,
    /** Per-agent readiness, keyed by the agent name ("claude", "codex", …). */
    val agents: Map<String, AgentReadiness>,
)

// MARK: - WS-H.2: broker version comparison

/**
 * Result of comparing the broker's reported version to the app-compiled
 * minimum. Mirror of iOS `BrokerVersionStatus`.
 */
sealed class BrokerVersionStatus {
    /** "dev" or otherwise unparseable — no nag. */
    data object Unknown : BrokerVersionStatus()
    /** Broker is at or above the minimum expected version. */
    data object Current : BrokerVersionStatus()
    /** Broker is behind the minimum. */
    data class UpdateAvailable(val brokerVersion: String) : BrokerVersionStatus()
}

/**
 * Compare [brokerVersion] to [minimumVersion]. Both are expected in
 * "vMAJOR.MINOR.PATCH" form; anything else → [BrokerVersionStatus.Unknown].
 * "dev" / empty → [BrokerVersionStatus.Unknown].
 *
 * The caller is responsible for passing the appropriate threshold (typically
 * the app's own release tag, not a hardcoded constant). Pure function;
 * visible for unit tests. Mirror of iOS `brokerVersionStatus`.
 */
fun brokerVersionStatus(
    brokerVersion: String,
    minimumVersion: String,
): BrokerVersionStatus {
    fun parse(v: String): Triple<Int, Int, Int>? {
        val s = if (v.startsWith("v")) v.drop(1) else v
        val parts = s.split(".").mapNotNull { it.toIntOrNull() }
        return if (parts.size == 3) Triple(parts[0], parts[1], parts[2]) else null
    }
    fun Triple<Int, Int, Int>.lessThan(other: Triple<Int, Int, Int>): Boolean {
        if (first != other.first) return first < other.first
        if (second != other.second) return second < other.second
        return third < other.third
    }
    if (brokerVersion.isEmpty() || brokerVersion == "dev") return BrokerVersionStatus.Unknown
    val bv = parse(brokerVersion) ?: return BrokerVersionStatus.Unknown
    val mv = parse(minimumVersion) ?: return BrokerVersionStatus.Unknown
    return if (bv.lessThan(mv)) BrokerVersionStatus.UpdateAvailable(brokerVersion)
    else BrokerVersionStatus.Current
}

// MARK: - Broker-update decision (session-safe gate)

/**
 * What the app should do when it detects a stale broker.
 * Mirror of iOS [BrokerUpdateDecision].
 */
sealed class BrokerUpdateDecision {
    /** Not stale, or versions are unparseable — do nothing. */
    data object None : BrokerUpdateDecision()
    /** Stale + zero live sessions + SSH paired: silent auto-update is safe. */
    data object SilentUpdate : BrokerUpdateDecision()
    /** Stale + live sessions exist + SSH paired: must warn the user first. */
    data object DeferAndWarn : BrokerUpdateDecision()
    /** Stale + token-paired box: no auto-update path; show copy-install banner. */
    data object ShowCopyBanner : BrokerUpdateDecision()
}

/**
 * Pure, testable decision: given staleness, live-session count, and pairing
 * type, return what the broker-update gate should do. Mirror of iOS
 * `brokerUpdateDecision`.
 */
fun brokerUpdateDecision(
    isStale: Boolean,
    liveCount: Int,
    isSshPaired: Boolean,
): BrokerUpdateDecision {
    if (!isStale) return BrokerUpdateDecision.None
    if (!isSshPaired) return BrokerUpdateDecision.ShowCopyBanner
    return if (liveCount == 0) BrokerUpdateDecision.SilentUpdate else BrokerUpdateDecision.DeferAndWarn
}

/**
 * Payload attached to [SessionStore.pendingBrokerUpdate] when the silent
 * auto-update is deferred because there are live sessions on the box.
 * Mirror of iOS `PendingBrokerUpdate`.
 */
data class PendingBrokerUpdate(
    val boxId: String,
    val brokerVersion: String,
    val liveCount: Int,
)

// MARK: - WS-H.3: readiness checklist

/**
 * Status of one row in the post-pair readiness checklist.
 * Mirror of iOS `ReadinessCheckItem.Status`.
 */
sealed class ReadinessStatus {
    data object Ok : ReadinessStatus()
    data object NotSignedIn : ReadinessStatus()
    data object NotInstalled : ReadinessStatus()
    data object Absent : ReadinessStatus()
}

/**
 * One row in the post-pair readiness checklist. Mirror of iOS
 * `ReadinessCheckItem`.
 */
data class ReadinessCheckItem(
    /** "claude", "codex", "node", "tmux", … */
    val id: String,
    /** Human display label ("Claude", "Codex", "node", "tmux"). */
    val label: String,
    val status: ReadinessStatus,
    /** OAuth provider for sign-in deep-link (null for non-agent rows). */
    val loginProvider: String?,
    /**
     * True when the conduit broker will install this automatically on first
     * session start (i.e. agent CLIs). False for infra tools (git, node,
     * tmux) that the user must install themselves.
     */
    val autoInstalls: Boolean = false,
    /** How the credential is held when signed in: "env", "box", or "app". Null when not signed in or unknown. */
    val credentialSource: String? = null,
)

/**
 * Derive the ordered checklist from a [BrokerReadiness] block plus the live
 * [AgentDescriptor] map so display names are broker-accurate. Agent rows
 * come first (sorted by key), then infra rows (node, tmux) only when absent.
 *
 * Pure function; visible for unit tests. Mirror of iOS `readinessCheckItems`.
 */
fun readinessCheckItems(
    readiness: BrokerReadiness,
    descriptors: Map<String, AgentDescriptor>,
): List<ReadinessCheckItem> {
    val items = mutableListOf<ReadinessCheckItem>()
    // Agent rows — alphabetical by key.
    for (key in readiness.agents.keys.sorted()) {
        val ar = readiness.agents[key] ?: continue
        val desc = descriptors[key]
        val displayName = desc?.displayName?.takeIf { it.isNotEmpty() }
            ?: (key.replaceFirstChar { it.uppercaseChar() })
        val provider = desc?.loginProvider?.takeIf { it.isNotEmpty() }
        val status = when {
            !ar.cliPresent -> ReadinessStatus.NotInstalled
            !ar.signedIn   -> ReadinessStatus.NotSignedIn
            else           -> ReadinessStatus.Ok
        }
        items.add(ReadinessCheckItem(id = key, label = displayName, status = status, loginProvider = provider, autoInstalls = true, credentialSource = ar.credentialSource))
    }
    // Infra rows — only when absent. node is intentionally omitted: it is a
    // terminal-scrollback sidecar and does not block running any agent.
    if (!readiness.tmuxPresent) {
        items.add(ReadinessCheckItem(id = "tmux", label = "tmux", status = ReadinessStatus.Absent, loginProvider = null))
    }
    if (!readiness.gitPresent) {
        items.add(ReadinessCheckItem(id = "git", label = "git", status = ReadinessStatus.Absent, loginProvider = null))
    }
    return items
}

// MARK: - JSON parsing

/**
 * Parse the `readiness` block from the `/api/capabilities` JSON string.
 * Returns null if the key is absent (old broker) or the JSON is malformed.
 * Pure function; visible for unit tests.
 */
fun parseReadiness(raw: String): BrokerReadiness? {
    return runCatching {
        val obj = JSONObject(raw).optJSONObject("readiness") ?: return null
        val agentsObj = obj.optJSONObject("agents")
        val agents = mutableMapOf<String, AgentReadiness>()
        if (agentsObj != null) {
            for (name in agentsObj.keys()) {
                val a = agentsObj.optJSONObject(name) ?: continue
                agents[name] = AgentReadiness(
                    cliPresent       = a.optBoolean("cli_present", false),
                    signedIn         = a.optBoolean("signed_in", false),
                    authExpiresInS   = if (a.isNull("auth_expires_in_s") || !a.has("auth_expires_in_s")) null
                                       else a.optInt("auth_expires_in_s"),
                    credentialSource = a.optString("credential_source").takeIf { it.isNotEmpty() },
                )
            }
        }
        BrokerReadiness(
            brokerVersion = obj.optString("broker_version", "dev"),
            nodePresent   = obj.optBoolean("node_present", true),
            tmuxPresent   = obj.optBoolean("tmux_present", true),
            gitPresent    = obj.optBoolean("git_present", true),
            agents        = agents,
        )
    }.getOrNull()
}
