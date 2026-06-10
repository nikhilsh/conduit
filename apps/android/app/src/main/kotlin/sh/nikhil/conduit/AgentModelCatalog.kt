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
                    ),
                )
            }
        }
        if (list.isNotEmpty()) out[assistant] = list
    }
    return out
}
