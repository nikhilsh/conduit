# In Progress

Items currently being built. On merge, move each to
[VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) under its release version.

---

## Active

- **Chat streaming — broker** (PR #770, branch `feat/chat-streaming`). Adds
  `chat_streaming` view_event for per-token content delivery and `turn_phase`
  view_event for writing/working/thinking indicator. CI re-triggered after
  lint fix.

- **Chat streaming — app** (PR #771, branch `feat/chat-streaming-app`). iOS +
  Android streaming overlay: partial assistant content appears live as tokens
  arrive; turn_phase indicator (writing / working / thinking). Depends on
  PR #770. CI re-triggered after import fix.

- **Sequential agent pipeline — broker** (PR #774, branch
  `feat/pipeline-backend`). `POST/GET /api/pipeline`, `/continue`, `DELETE`,
  `/api/pipelines` list; full state machine + worktree-per-step + handoff from
  HANDOFF-OUT + gate support. Rebasing onto main to pick up #773's conflict in
  `api.go`/`server.go`.

- **FanOut compare + Pipeline Builder/Monitor — Android** (PR #777, branch
  `feat/mobile-android-compare-pipeline`). Mirrors iOS PR #776 (merged). CI
  running.

## Deferred (not active)

- **Per-identity readiness/push** — architect-sized multi-tenant refactor (auth
  bearer→identity mapping, credential-store crypto, per-bearer readiness + push
  registration). Not being built now; see ROADMAP.md Deferred section.
