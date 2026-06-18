# In Progress

Items currently being built. On merge, move each to
[VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) under its release version.

---

## Active

- **SSH chat takeover** — `conduit-broker chat <session-id>` CLI to view + drive
  a live session's chat from an SSH terminal on the box (plan:
  `docs/PLAN-SSH-CHAT-TAKEOVER.md`). Phase 1 (CLI) branch `feat/ssh-chat-cli`
  PR #695; Phase 2 (owner-presence push-gate fix) branch
  `fix/push-gate-owner-presence` PR #696. Phase 2 needs on-device verify
  (backgrounded phone still gets pushes while SSH attached) + broker redeploy.

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
