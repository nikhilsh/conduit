# In Progress

Items currently being built. On merge, move each to the single **Next release
(pending)** section at the top of [VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) —
do NOT mint a new `vX.Y.Z` heading. The real version is assigned only when
`/cut-release` cuts the tag.

---

## Active

- **Thinking block + indicator peek** (iOS + Android) -- consume `thinking_streaming` view_event; collapsible "Thinking..." disclosure above streaming prose; live reasoning line fed to WorkingIndicator peek. Branch `feat/thinking-app-ui`, PR #857.
- **Session tasks UI PR 4/4** (transcript integration, FINAL) -- a dispatched background task now renders as `ConduitUI.TaskRow`/`ConduitTaskRow` inline in the chat transcript at its dispatch point, replacing the old expand/collapse `ConduitSubagentCard`/`SubagentCard` (deleted). No shared id exists on the wire between a `kind == "subagent"` transcript event and a live `SubagentEntry`, so `ConduitInlineTaskLogic` (both platforms, Kotlin's lives in ChatPage.kt) binds by best-effort name/description match + nearest-timestamp, falling back to the event's own static content/status (done/failed) when nothing matches -- the common case, since the current broker never actually emits a `subagent`-kind chat line for a live dispatch. Elapsed ticks + tail (`lastTool`) refresh at ~1Hz; tap opens the Tasks sheet. iOS + Android, unit-tested. Branch `session-tasks-pr4`, PR #927.

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
