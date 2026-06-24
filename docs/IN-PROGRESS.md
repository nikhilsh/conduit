# In Progress

Items currently being built. On merge, move each to
[VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) under its release version.

---

## Active

- **Watch notification action flow — AskUserQuestion dynamic labels** — `feat/watch-ask-notification-actions` PR #743. Relay forwards `options[]` + `mutable-content:1`; broker sends `ask` category with numbered body; new `POST /api/session/answer`; iOS `ConduitNotificationService` extension registers dynamic category so Watch shows actual option text as buttons. Deploy: relay first, then broker. Needs on-device verify.

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
