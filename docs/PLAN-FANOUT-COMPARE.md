# PLAN — FanOut "Compare & keep best"

Status: design. UI exists (`FanOutScreen.kt`, `ConduitFanOutView.swift`);
`onCompare` is a no-op stub. This wires the backend + the compare view.

---

## 0. What exists today

- A FanOut = N **independent** sessions of the same task, each created via
  `POST /api/session/start` (one call per run). There is no fan-out object on
  the broker — the apps hold the list of session ids.
- Per-session worktrees are keyed on **session id** (branch
  `conduit-session-<id>`, `worktree.go:55`). The session-start request has
  **no `branch` field** (`api.go:213`). The UI's per-run `branch` label is
  currently cosmetic only.
- Commit/PR already shipped: `POST /api/session/{id}/git/commit` and
  `/git/pr` (`broker/internal/ws/git.go`). "Keep best" reuses these.
- **Gap A** (prerequisite for named-branch fan-out): add an optional `branch`
  field to `startSessionRequest` so the worktree branch name matches the UI
  label. Without it, compare still works (diff each session worktree by
  session id); named branches are cosmetic until Gap A ships.

---

## 1. Trigger

`onCompare` fires after all runs reach a terminal phase (`exited(*)`). The app:
1. Collects the launched runs' `sessionID`s (it already holds them).
2. `POST /api/fanout/compare` with that list.
3. Pushes the new **Compare view** with the response.

No persistent fanout object in v1 — the app passes the session-id set each
call. A `fanout-id` is deferred to v2.

---

## 2. Broker endpoint

```
POST /api/fanout/compare
```

Request:
```json
{
  "base": "main",
  "runs": [
    { "session_id": "...", "label": "fix/ratelimit-a" },
    { "session_id": "...", "label": "fix/ratelimit-b" }
  ]
}
```

Response:
```json
{
  "base": "main",
  "runs": [
    {
      "session_id": "...",
      "label": "fix/ratelimit-a",
      "phase": "exited(0)",
      "files_changed": 7,
      "insertions": 142,
      "deletions": 30,
      "diff_stat": "core/src/x.rs | 12 +++--\n...",
      "agent_summary": "Added token-bucket limiter; 3 tests.",
      "error": ""
    }
  ]
}
```

Per run, the broker (`broker/internal/ws/fanout.go`, new file):
1. Resolve the session's worktree dir via `Session.WorkspaceDir()`.
2. Run `git -C <wt> diff --stat <base>...HEAD` → parse `files_changed`,
   `insertions`, `deletions`, `diff_stat`. New helper:
   `session.DiffSummary(workdir, base string) (files, ins, del int, stat string, err error)`
   in `broker/internal/session/diffsummary.go` — shell `git diff --stat`,
   pattern matches existing `worktree.go`/`git.go`.
3. `agent_summary`: last assistant text from the persisted transcript
   (`serveSessionConversation`, `api.go:364`), truncated to ~200 chars.
   Empty if unavailable — never fabricated.
4. A run whose worktree is missing or that exited non-zero → `error` set,
   diff fields zeroed. Always returns 200 with that run flagged.

**Same-box only**: all N worktrees are local dirs on this broker. No
multi-box fan-in; that is a v2 enhancement.

---

## 3. "Keep best" actions

User taps a run in the Compare view. Two actions (offer both):

- **Open** (zero-risk): navigate into that run's existing session chat.
  The other runs stay as-is; user continues iterating on the winner. Nothing
  is merged. This is the default.
- **Commit & PR** (promote): call the existing
  `POST /api/session/{winnerID}/git/commit` (stage + commit, `push: true`),
  then `POST /api/session/{winnerID}/git/pr`. The winner's branch becomes a
  PR against `base`. Reuses DiffReview verbatim — no new merge code.
- **Discard losers** (v1.1, explicit): `DELETE /api/session/{loserID}` for
  non-winners. Gated behind a confirm; never automatic.

**Invariant: a phone never auto-merges main.** Keep-best tops out at opening
a PR.

---

## 4. Mobile UX changes

**Existing FanOut sheet**: wire `onCompare` to call `POST /api/fanout/compare`
with the launched runs, then present the Compare view.

**New Compare view** — new files, both platforms:
- iOS: `apps/ios/Sources/ConduitUI/Views/ConduitFanOutCompareView.swift`
- Android: `apps/android/app/src/main/kotlin/sh/nikhil/conduit/ui/FanOutCompareScreen.kt`

Shows, per run (most files changed first as default sort):
- Branch label + status chip (reuse FanOut tints: done/failed).
- Diff stat line: `7 files · +142 −30`.
- Expandable `diff_stat` text block (mono).
- `agent_summary` (1–2 lines).
- Two action buttons per row: **Open** and **Commit & PR**.

Failed/empty runs render greyed with the `error` reason; no actions except Open.

**Telemetry** (per CLAUDE.md standing order):
- Breadcrumbs: compare-open, compare network start/finish/fail, keep-open,
  keep-commit-pr.
- `Telemetry.capture` ERROR on compare failure and on commit/PR failure.

---

## 5. Broker changes (file-touch list)

1. **`broker/internal/ws/fanout.go`** (new): `serveFanoutCompare` — auth,
   POST-only, iterate runs, build response.
2. **`broker/internal/ws/server.go`**: register
   `mux.HandleFunc("/api/fanout/compare", ...)`.
3. **`broker/internal/session/diffsummary.go`** (new): `DiffSummary(workdir,
   base string)` + test.
4. **`/api/capabilities`**: add `fanout_compare: true` so apps feature-gate
   the Compare button.
5. **Gap A (separate PR, prerequisite for named branches)**: add optional
   `branch` field to `startSessionRequest`; `maybeRemapToWorktree` uses it
   when set. Not required for compare to work — but needed for the UI's branch
   labels to match the actual git branches.

No protocol/UniFFI/`chat_mode` change.

---

## 6. Invariants

- **base is never auto-merged from a phone** — keep-best tops out at a PR.
- **No fabricated ranking** — failed runs flagged; summaries from real
  transcript only, never generated.
- **Reuse over reinvent** — commit/PR rides existing DiffReview endpoints.
