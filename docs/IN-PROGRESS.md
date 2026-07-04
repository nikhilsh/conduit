# In Progress

Items currently being built. On merge, move each to the single **Next release
(pending)** section at the top of [VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) —
do NOT mint a new `vX.Y.Z` heading. The real version is assigned only when
`/cut-release` cuts the tag.

---

## Active

- **Foreground refresh latency + assume-connected UX** (iOS + Android) -- proactive HTTP refresh on foreground, reconcile live sessions, post-connect conversation re-read, 4s grace window suppressing Reconnecting banner. Branch `app/foreground-refresh-connected-ux`, PR pending.

- **Thinking block + indicator peek** (iOS + Android) -- consume `thinking_streaming` view_event; collapsible "Thinking..." disclosure above streaming prose; live reasoning line fed to WorkingIndicator peek. Branch `feat/thinking-app-ui`, PR #857.
- **Surgical performance fixes** (iOS + Android) -- gate O(N) conv re-fetch on status frames; cancel off-screen animation Task loops; debounce main-thread persist writes. Branch `perf/surgical-lag-fixes`, PR #871.

- **Send/turn-state reliability fixes** (iOS + Android) -- stopTurn retry-on-failure, flush preserves original localID, exit clears queued messages, reconcile demotion grace (2 misses). Branch `app/stop-and-restart-stuck-fixes`, PR pending.

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
