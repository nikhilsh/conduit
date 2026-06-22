# In Progress

Items currently being built. On merge, move each to
[VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) under its release version.

---

## Active

- **Persist AskUserQuestion answered-state** — broker records the resolution
  (chosen option / timeout) into the conversation log tied to the pending-input
  card; iOS rehydrates the answered/selected state from the transcript so a
  tapped option still shows selected after close+reopen and across devices.
  Text-carried `[[conduit:resolved]]{...}` marker (no broker→core→app schema
  change), backward-compatible. Branch `fix/pending-input-resolution-persist`,
  PR #721. iOS = needs on-device verification.

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
