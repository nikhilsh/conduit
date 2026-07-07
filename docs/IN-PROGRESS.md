# In Progress

Items currently being built. On merge, move each to the single **Next release
(pending)** section at the top of [VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) —
do NOT mint a new `vX.Y.Z` heading. The real version is assigned only when
`/cut-release` cuts the tag.

---

## Active

- **Thinking block + indicator peek** (iOS + Android) -- consume `thinking_streaming` view_event; collapsible "Thinking..." disclosure above streaming prose; live reasoning line fed to WorkingIndicator peek. Branch `feat/thinking-app-ui`, PR #857.
- **Session tasks UI PR 2/4** (RunningPill) -- persistent capsule above the chat composer showing the live per-session running-task count (green, "N running task(s)") / gated state (amber, "N running · M needs you"); wired to `SessionStore.subagentRosters`/`subagentRoster` filtered by session id, `gatedCount` always 0 (no gate status in the roster yet). Tap only sets a `showTasksSheet` flag -- the Tasks sheet itself lands in PR 3/4. iOS + Android. Branch `session-tasks-pr2`, PR #923.
- **Session tasks UI PR 3/4** (Tasks sheet) -- bottom sheet grouping a session's background tasks (NEEDS YOU / RUNNING / FINISHED), opened from the RunningPill tap; maps `SessionStore.subagentRosters`/`subagentRoster` to sheet rows (`ConduitTasksSheetLogic`/`TasksSheetLogic`), ticking elapsed for running rows. `canStop` is hard-false (no broker kill verb yet) and "View transcript" is omitted (no nav target exists yet for a roster entry) -- both flagged as follow-ups. iOS + Android. Branch `session-tasks-pr3`, PR #925.

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
