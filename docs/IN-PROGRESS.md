# In Progress

Items currently being built. On merge, move each to
[VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) under its release version.

---

## Active

- **Chat streaming — broker** (PR #770, branch `feat/chat-streaming`). Adds
  `chat_streaming` view_event for per-token content delivery and `turn_phase`
  view_event for writing/working/thinking indicator. CI re-triggered after
  lint fix.

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
