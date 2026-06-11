# In Progress

Items currently being built. On merge, move each to
[VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) under its release version.

---

## Active

- **Fast-mode toggle** — branch `fast-mode-toggle-ship`, PR #509. Actionable claude fast-mode toggle: read-only "Fast mode available" label replaced by a Toggle (iOS) / Switch (Android) in the new-session picker + fork sheets; launches claude with `--settings '{"fastMode":true}'` via core→broker. Tablet+phone. On merge → VERIFY-CHECKLIST.md.

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
