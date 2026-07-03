# In Progress

Items currently being built. On merge, move each to the single **Next release
(pending)** section at the top of [VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) —
do NOT mint a new `vX.Y.Z` heading. The real version is assigned only when
`/cut-release` cuts the tag.

---

## Active

- **Stream extended-thinking to apps** — broker surfaces Claude's reasoning
  blocks as `thinking_streaming` view_events so apps can show live reasoning.
  Branch `feat/stream-thinking-broker`, PR #854.
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
