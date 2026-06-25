# In Progress

Items currently being built. On merge, move each to
[VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) under its release version.

---

## Active

- **§10/§10b command-run Mono block — default ON** — PR #760. Flips `chat.commandRunBlock` to
  `true` on both iOS and Android, adds the always-expanded `MonoInlineBlock`/`MonoCommandBlockInline`
  for single-command runs (§10 B), and threshold-dispatches: 1 command = inline flat block, 2+
  = collapsible (§10b). Branch `worktree-feat+cmd-run-block-default-on`.
  [iOS + Android phone + tablet, needs on-device verification]

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
