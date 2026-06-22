# In Progress

Items currently being built. On merge, move each to
[VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) under its release version.

---

## Active

- **Session-safe broker auto-update** — branch `app/broker-update-session-safe`,
  PR #711. Both apps silently re-bootstrapped (restarted) a stale SSH broker on
  reconnect, reaping all live sessions with no warning. Now: gate the auto-update
  on live-session presence (silent only when 0 live; warn + confirm when live),
  retire the dead `v0.0.120` floor (compare broker vs app version —
  `BuildInfo.marketingVersion` / `BuildConfig.RELEASE_TAG`), and auto-resume the
  snapshotted live sessions after the restart. iOS+Android, **needs on-device
  verification** (banner UI + restart→reconnect→auto-resume path).

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
