# In Progress

Items currently being built. On merge, move each to the single **Next release
(pending)** section at the top of [VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) —
do NOT mint a new `vX.Y.Z` heading. The real version is assigned only when
`/cut-release` cuts the tag.

---

## Active

- **Working indicator styles E+F (packets@prompt + piped prompt)** —
  branch `feat/working-indicator-bd-combos`. Extracts `PacketPipe` atom from
  style B, adds `packetsPrompt` (E) and `pipedPrompt` (F) to iOS
  `ConduitWorkingStyle` enum + `WorkingIndicator` view; Android mirror adds
  `PacketsPrompt`/`PipedPrompt` cases + `PacketPipe`/`PromptHeader` composables.
  Debug-menu style picker auto-includes new cases via `allCases`/`.entries`.
  Needs on-device verification.

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
