# In Progress

Items currently being built. On merge, move each to the single **Next release
(pending)** section at the top of [VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) —
do NOT mint a new `vX.Y.Z` heading. The real version is assigned only when
`/cut-release` cuts the tag.

---

## Active

- **Peer-session messaging MVP** (broker) -- sessions can message each other:
  `POST /api/session/message` + one-shot `conduit-broker chat send
  <session-id> "..."`; delivered as a labeled untrusted `CONDUIT PEER MESSAGE`
  block (never a bare user prompt); awareness-prompt bullet teaches agents the
  affordance; 6/min per-recipient rate cap as the ping-pong loop guard; live
  sessions only (never wakes a recoverable one). Branch
  `worktree-peer-session-chat`.

- **Thinking block + indicator peek** (iOS + Android) -- consume `thinking_streaming` view_event; collapsible "Thinking..." disclosure above streaming prose; live reasoning line fed to WorkingIndicator peek. Branch `feat/thinking-app-ui`, PR #857.

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
