# In Progress

Items currently being built. On merge, move each to the single **Next release
(pending)** section at the top of [VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) —
do NOT mint a new `vX.Y.Z` heading. The real version is assigned only when
`/cut-release` cuts the tag.

---

## Active

- **Queued-Next reply-flush belt-and-suspenders** (`fix/queued-next-reply-flush`, PR #851) —
  add a second flush trigger on live assistant reply so queuedTurn entries are
  never stranded by a missed/delayed turn_active status frame (iOS +
  Android). Idempotent with the existing status-frame trigger.

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
