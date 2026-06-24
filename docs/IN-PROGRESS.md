# In Progress

Items currently being built. On merge, move each to
[VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) under its release version.

---

## Active

- **Collapse answered pending-input card to chip** — answered AskUserQuestion
  cards shrink to a compact green pill chip (e.g. `✓ Fix both`) instead of
  remaining as a full dimmed card. iOS + Android parity. Branch `pending-chip`,
  PR #735. Needs on-device verification (iOS + Android).

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
