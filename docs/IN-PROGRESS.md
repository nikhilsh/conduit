# In Progress

Items currently being built. On merge, move each to
[VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) under its release version.

---

## Active

- **Recap navigation + running bar sheen** — wires `SessionRecapView` / `SessionRecapScreen` into Session Info action row on both iOS and Android; adds animated sheen sweep to the running-command progress bar (design spec RunC). Branch `feat/recap-nav-and-sheen`, PR #762.

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
