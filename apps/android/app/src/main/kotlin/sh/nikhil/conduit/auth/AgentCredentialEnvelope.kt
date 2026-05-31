package sh.nikhil.conduit.auth

import org.json.JSONObject
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/**
 * The `set_agent_credentials` WS control-message envelope (PLAN-AGENT-OAUTH
 * §D.1). Encoded with the provider's native credential blob nested
 * verbatim — the broker is intended to read-and-store the inner
 * `credential` object byte-for-byte. Stage 2's iOS implementation
 * will emit the same envelope; we co-locate the encoder here so the
 * Android end ships a byte-equal payload.
 *
 * Wire shape:
 * ```json
 * {
 *   "type": "set_agent_credentials",
 *   "ts": "2026-05-22T08:00:00Z",
 *   "provider": "openai" | "anthropic",
 *   "kind": "oauth",
 *   "credential": { ...native blob... }
 * }
 * ```
 *
 * The PLAN doc spells the provider tag as `"anthropic" | "openai"`;
 * we use the same raw values as [OAuthProvider.raw].
 */
object AgentCredentialEnvelope {
    /**
     * Build the `set_agent_credentials` envelope JSON. [timestampIso]
     * is exposed so tests can pin a deterministic `ts` field; in
     * production callers pass `null` and we read wall-clock UTC.
     */
    fun build(credential: OAuthCredential, timestampIso: String? = null): String {
        val ts = timestampIso ?: OffsetDateTime.now(ZoneOffset.UTC)
            .format(DateTimeFormatter.ISO_INSTANT)
        // Compose the envelope by hand so the inner `credential` field
        // is emitted verbatim — wrapping the native blob in a
        // JSONObject and re-serializing would re-order keys + drop
        // explicit `null`s (codex's `OPENAI_API_KEY: null` invariant).
        val sb = StringBuilder("{")
        sb.append("\"type\":\"set_agent_credentials\"")
        sb.append(",\"ts\":").append(JSONObject.quote(ts))
        sb.append(",\"provider\":").append(JSONObject.quote(credential.provider.raw))
        sb.append(",\"kind\":\"oauth\"")
        sb.append(",\"credential\":").append(credential.toJson())
        sb.append('}')
        return sb.toString()
    }
}
