Title: Connection health & freshness — smoother onboarding for both flows.

WS-H.1 (THIS PR): the /api/capabilities readiness block — broker-only, mergeable+redeployable independently.

The broker extends `GET /api/capabilities` with a `readiness` block:

```json
"readiness": {
  "broker_version": "<ldflags-stamped tag or 'dev'>",
  "node_present": <bool>,
  "tmux_present": <bool>,
  "agents": {
    "<name>": {
      "cli_present":      <bool>,
      "signed_in":        <bool>,
      "auth_expires_in_s": <int|null>
    }
  }
}
```

Implementation notes:
- `broker_version`: `main.version` ldflags var, injected by the release workflow (`-X main.version=${RELEASE_TAG}`); defaults to `"dev"` for local builds.
- `node_present`: `session.Manager.Health().SidecarExpected` (true when node was found at startup and termgrid.NewManager succeeded).
- `tmux_present`: `exec.LookPath("tmux") == nil`.
- `agents[name].cli_present`: `exec.LookPath(adapter.Command[0]) == nil` for each non-hidden adapter.
- `agents[name].signed_in` / `auth_expires_in_s`: box-global — reads the host-login credential file (`~/.claude/.credentials.json` for anthropic, `~/.codex/auth.json` for openai). API-key env vars (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY` via `adapter.EnvPassthrough`) → `signed_in=true, auth_expires_in_s=null`. Absent file → `signed_in=false`. Expiry decoded from the provider-native blob (same logic as `session.credentialExpiryMillis`).
- Identity decision: box-global (not per-bearer). Single-operator broker; the per-bearer `credentials.Store` is not checked here. Extension point for multi-tenant: check `credentials.Store.Has(provider)` and decode the stored blob.
- Box-global bits (version/node/tmux/cli-present) are cached with a ~30s TTL. Sign-in state is always fresh (cheap file read per request).

WS-H.2 (follow-up, app, needs device verify): app compares `readiness.broker_version` to a known-minimum → non-blocking "update available" banner; flow-1 one-tap re-runs SSH bootstrap (idempotent, installs latest), flow-2 shows the `curl install.sh` one-liner. Honest-state: don't claim updated until a fresh capabilities fetch confirms.

WS-H.3 (follow-up, app, needs device verify): post-pair readiness checklist from this payload ("Claude ✓ · Codex not signed in (Sign in) · opencode not installed"); sign-in deep-links the existing agent-login flow; informational, never blocking.

Out of scope (separate plans): SSH-tunnel transport, harness bootstrap, UnifiedPush distributor auto-setup.
