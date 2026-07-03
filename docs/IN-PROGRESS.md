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
- **Pipeline gate handoff preview + editable handoff + named step branches** —
  broker (feat/pipeline-gate-broker) + apps (feat/pipeline-gate-apps).
  Broker: `GatePreview` on `Pipeline`, gate entry populates `gate` in
  pipeline.json, `Continue(amendedPrev)` for edit-handoff, named step branches
  `pipeline-<id>-step-<k>`, `pipeline_gate_preview` capability flag.
  Apps: gate preview panel + editable handoff field on the Monitor screen.

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
