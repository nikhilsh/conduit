# In Progress

Items currently being built. On merge, move each to the single **Next release
(pending)** section at the top of [VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) —
do NOT mint a new `vX.Y.Z` heading. The real version is assigned only when
`/cut-release` cuts the tag.

---

## Active

- **Harness builder Phase 1: per-block model/effort/mode/instructions**
  (broker + iOS + Android) -- PLAN-HARNESS-BUILDER.md §2: shared `StepConfig`
  embed, widened pipeline `CreateSession` seam, `<block-instructions>` prompt
  preamble, `pipeline_block_config` capability flag; Builder gains catalog-driven
  agent list (gemini appears, model row hidden) + per-block config controls.
  Branches `broker/pipeline-block-config` + `app/pipeline-block-config`.

- **Thinking block + indicator peek** (iOS + Android) -- consume `thinking_streaming` view_event; collapsible "Thinking..." disclosure above streaming prose; live reasoning line fed to WorkingIndicator peek. Branch `feat/thinking-app-ui`, PR #857.

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
