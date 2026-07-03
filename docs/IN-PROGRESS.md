# In Progress

Items currently being built. On merge, move each to the single **Next release
(pending)** section at the top of [VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) —
do NOT mint a new `vX.Y.Z` heading. The real version is assigned only when
`/cut-release` cuts the tag.

---

## Active

- **Thinking block + indicator peek** (iOS + Android) -- consume `thinking_streaming` view_event; collapsible "Thinking..." disclosure above streaming prose; live reasoning line fed to WorkingIndicator peek. Branch `feat/thinking-app-ui`, PR #857.
- **Pipeline v2: resume-from-failed + templates** — broker (feat/pipeline-resume-templates) + apps (feat/pipeline-resume-templates-apps, follows).
- **Pipeline v2: fanout-as-a-step** — broker (feat/pipeline-fanout-step, PR #TBD) + apps (follows). New `fanout` config on a step; AWAITING_PICK state; POST /api/pipeline/{id}/pick; TurnComplete signal fix so claude steps advance. Apps work follows in a separate branch.

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
