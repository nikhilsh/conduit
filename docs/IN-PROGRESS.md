# In Progress

Items currently being built. On merge, move each to the single **Next release
(pending)** section at the top of [VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) —
do NOT mint a new `vX.Y.Z` heading. The real version is assigned only when
`/cut-release` cuts the tag.

---

## Active

- **Thinking block + indicator peek** (iOS + Android) -- consume `thinking_streaming` view_event; collapsible "Thinking..." disclosure above streaming prose; live reasoning line fed to WorkingIndicator peek. Branch `feat/thinking-app-ui`, PR #857.
- **Flow (pipeline v2) redesign** (iOS + Android) -- SWE Kitty 5 handoff
  (`design_handoff_flow/`), replacing the pipeline Builder with a native
  Start-sheet + wizard create flow and richer flow surfaces. PRs: #921 (merged
  -- ConduitFlowAtoms/FlowCard components + home Flows section), #922 (broker
  step summaries), and this PR (branch `flow-wizard`) -- Start sheet
  (Session/Flow segmented), two-step wizard (Task, Steps), step editor (C1),
  If/Else editor (C2); replaces the old builder as the phone create UX at
  every "+" entry point, tablet unchanged (kept on the old builder). Monitor
  redesign + the `pipeline`→`flow` naming pass are follow-up PRs.
- **Session tasks UI PR 2/4** (RunningPill) -- persistent capsule above the chat composer showing the live per-session running-task count (green, "N running task(s)") / gated state (amber, "N running · M needs you"); wired to `SessionStore.subagentRosters`/`subagentRoster` filtered by session id, `gatedCount` always 0 (no gate status in the roster yet). Tap only sets a `showTasksSheet` flag -- the Tasks sheet itself lands in PR 3/4. iOS + Android. Branch `session-tasks-pr2`, PR #923.

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
