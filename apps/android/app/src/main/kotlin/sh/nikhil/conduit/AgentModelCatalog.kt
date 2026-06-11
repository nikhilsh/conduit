package sh.nikhil.conduit

import org.json.JSONObject

/**
 * Parse the broker's `/api/capabilities` "models" map — the per-assistant
 * model+effort catalogs the broker discovered live from the agent CLIs
 * (broker/internal/session/modelcatalog.go). Empty map when the key is
 * absent (old broker / discovery still running) so callers keep their
 * static fallbacks. Pure + top-level for unit tests.
 */
internal fun parseModelCatalog(raw: String): Map<String, List<SessionStore.AgentModel>> {
    val models = JSONObject(raw).optJSONObject("models") ?: return emptyMap()
    val out = mutableMapOf<String, List<SessionStore.AgentModel>>()
    for (assistant in models.keys()) {
        val arr = models.optJSONArray(assistant) ?: continue
        val list = buildList {
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val efforts = o.optJSONArray("efforts")?.let { ja ->
                    (0 until ja.length()).mapNotNull { idx ->
                        ja.optString(idx).takeIf { it.isNotEmpty() }
                    }
                } ?: emptyList()
                add(
                    SessionStore.AgentModel(
                        id = o.optString("id", ""),
                        displayName = o.optString("display_name", ""),
                        description = o.optString("description", ""),
                        isDefault = o.optBoolean("is_default", false),
                        defaultEffort = o.optString("default_effort", ""),
                        efforts = efforts,
                        supportsFastMode = o.optBoolean("supports_fast_mode", false),
                    ),
                )
            }
        }
        if (list.isNotEmpty()) out[assistant] = list
    }
    return out
}

/**
 * Per-assistant capability flags declared by the broker in the `agents`
 * map of `/api/capabilities` (PR #440). All fields have safe defaults so
 * an old broker (no `agents` key) keeps today's behavior: the static
 * Claude-only gating stays in place.
 *
 * Mirror of iOS `ConduitUI.AgentDescriptor`.
 */
data class AgentDescriptor(
    /** Human-readable name from the broker ("Claude", "Codex", …). */
    val displayName: String,
    /** OAuth provider key ("anthropic", "openai", …). Maps to [OAuthProvider]. */
    val loginProvider: String,
    /** Agent supports `/compact` and context-summarisation (stream-json only). */
    val supportsCompact: Boolean,
    /** Agent supports AskUserQuestion interactive prompts. */
    val supportsAskUserQuestion: Boolean,
    /** Agent supports per-session reasoning-effort override (`--effort`). */
    val supportsEffort: Boolean,
    /** Agent supports plan-mode (read-only planning posture). */
    val supportsPlanMode: Boolean,
    /** Agent has an account-level usage/limits endpoint. */
    val supportsUsage: Boolean,
    /**
     * Agent supports real-time turn steering (inject input into the RUNNING
     * turn). True only for the codex app-server backend which exposes
     * `turn/steer`. All other backends are false (default).
     * Mirror of iOS `AgentDescriptor.supportsSteer`.
     */
    val supportsSteer: Boolean = false,
)

/**
 * Static fallback descriptors for the two known agents. Used when the
 * broker is too old to serve the `agents` map — keeps today's hard-coded
 * behavior pixel-identical.
 */
internal val staticAgentDescriptors: Map<String, AgentDescriptor> = mapOf(
    "claude" to AgentDescriptor(
        displayName = "Claude",
        loginProvider = "anthropic",
        supportsCompact = true,
        supportsAskUserQuestion = true,
        supportsEffort = true,
        supportsPlanMode = true,
        supportsUsage = true,
    ),
    "codex" to AgentDescriptor(
        displayName = "Codex",
        loginProvider = "openai",
        supportsCompact = false,
        supportsAskUserQuestion = false,
        supportsEffort = true,
        supportsPlanMode = true,
        supportsUsage = true,
        supportsSteer = true,
    ),
)

/**
 * Parse the broker's `/api/capabilities` "agents" map (PR #440). Empty map
 * when the key is absent (old broker) — callers fall back to
 * [staticAgentDescriptors]. Pure + top-level for unit tests.
 */
internal fun parseAgentDescriptors(raw: String): Map<String, AgentDescriptor> {
    val agents = JSONObject(raw).optJSONObject("agents") ?: return emptyMap()
    val out = mutableMapOf<String, AgentDescriptor>()
    for (name in agents.keys()) {
        val o = agents.optJSONObject(name) ?: continue
        val supports = o.optJSONObject("supports") ?: JSONObject()
        out[name] = AgentDescriptor(
            displayName = o.optString("display_name", name.replaceFirstChar { it.uppercaseChar() }),
            loginProvider = o.optString("login_provider", ""),
            supportsCompact = supports.optBoolean("compact", false),
            supportsAskUserQuestion = supports.optBoolean("ask_user_question", false),
            supportsEffort = supports.optBoolean("effort", false),
            supportsPlanMode = supports.optBoolean("plan_mode", false),
            supportsUsage = supports.optBoolean("usage", false),
            supportsSteer = supports.optBoolean("steer", false),
        )
    }
    return out
}

/**
 * Resolve the descriptor for [assistant], preferring the broker-provided
 * [descriptors] and falling back to [staticAgentDescriptors] for the two
 * known agents, then a neutral generic descriptor for unknowns.
 */
internal fun descriptorFor(assistant: String, descriptors: Map<String, AgentDescriptor>): AgentDescriptor {
    val key = assistant.lowercase()
    return descriptors[key]
        ?: staticAgentDescriptors[key]
        ?: AgentDescriptor(
            displayName = assistant.replaceFirstChar { it.uppercaseChar() },
            loginProvider = "",
            supportsCompact = false,
            supportsAskUserQuestion = false,
            supportsEffort = false,
            supportsPlanMode = false,
            supportsUsage = false,
            supportsSteer = false,
        )
}

/**
 * Resolve the OAuth provider key ("anthropic", "openai", …) for an
 * assistant. Uses the broker-provided descriptor when available;
 * falls back to the static mapping for claude/codex so old-broker
 * behavior is pixel-identical.
 *
 * The returned string is the provider's wire name — callers compare
 * it against the raw value of their `OAuthProvider` enum (or
 * `AgentLoginProvider`).
 */
internal fun loginProviderFor(assistant: String, descriptors: Map<String, AgentDescriptor>): String =
    descriptorFor(assistant, descriptors).loginProvider
