# PLAN — Review & Ship from phone

Status: design. Mobile-first diff review + git-ship flow for a session's live
workspace. Orca-ADE-style line-anchored comments batched into ONE agent prompt,
riding the always-on broker.

---

## 0. What exists today (grounded)

- `broker/internal/ws/git.go` already ships **two** git endpoints, routed from
  the `/api/session/` catch-all in `api.go` `serveSessionDelete`
  (`api.go:591-601`):
  - `POST /api/session/{id}/git/commit` — `git add -A` + commit + optional push.
    Uses `sess.WorkspaceDir()` (the STATIC dir, NOT the live cwd).
  - `POST /api/session/{id}/git/pr` — `gh pr create`.
  Both shell out via `runShellCmd(ctx, dir, name, args...)` — argv array, 30 s
  timeout, no shell string interpolation, no stdin. Reuse this helper verbatim.
- There is **no structured-diff endpoint**. The current iOS `DiffReviewView`
  (`apps/ios/Sources/ConduitUI/Views/ConduitDiffReviewView.swift`) scrapes the
  diff out of the chat transcript (`DiffReviewModel.hasInlineDiff`). Feature A
  replaces that scrape with a real broker diff.
- Live-cwd resolution already exists: `session/statusframe.go:158`
  `liveGitState()` resolves the agent's REAL cwd via `agentCWD(pid)`
  (`gitstate.go:16`, reads `/proc/<pid>/cwd`) and falls back to
  `WorkspaceDir()`. This is the resolution Feature A must reuse — expose it.
- Diffstat parsing precedent: `session/diffsummary.go` `DiffSummary(workdir,
  base)` runs `git diff --stat base...HEAD`. The branch-scope diffstat reuses
  the same `base...HEAD` ref and `pickBase()` (`gitstate.go:133`,
  `origin/main` → `main`).
- Capabilities `features.*` block lives in `api.go:95-184` (struct) +
  `api.go:243-266` (population). App decoders read `features.*` at
  `apps/ios/.../SessionStore.swift:2513 fetchBoxFeatures` and
  `apps/android/.../SessionStore.kt:5038 fetchBoxFeatures`.

---

## 1. Design

### 1.1 New broker seam — live git dir

Add ONE public method reusing the existing private resolution:

```go
// session/gitstate.go (new public wrapper; body identical to liveGitState's dir pick)
func (s *Session) LiveGitDir() string {
    dir := s.WorkspaceDir()
    if pid := s.agentPID(); pid > 0 {
        if cwd := agentCWD(pid); cwd != "" {
            dir = cwd
        }
    }
    return dir
}
```

All Feature-A endpoints resolve their working directory through `LiveGitDir()`,
NOT `WorkspaceDir()`. This is the invariant: **diff/stage/commit operate on the
directory the agent is actually standing in**, so a worktree-remapped session
(`worktree.go`) reviews the right tree. `git/commit` and `git/pr` today use
`WorkspaceDir()`; leave them (back-compat) but the new endpoints use
`LiveGitDir()`.

### 1.2 Diff builder (new file `broker/internal/ws/gitdiff.go`)

Parse `git diff` porcelain into structured JSON. Two scopes:

- `uncommitted` — working tree + index vs HEAD, INCLUDING untracked files as
  all-added. Command plan:
  - `git -C <dir> diff --no-color HEAD` (tracked, staged+unstaged combined
    against HEAD).
  - `git -C <dir> status --porcelain=v1 -z` to enumerate untracked (`??`) and
    per-file staged state (index vs worktree columns).
  - For each untracked file: `git -C <dir> diff --no-color --no-index
    /dev/null <file>` to synthesize an all-added hunk (binary → `binary:true`,
    no hunks).
- `branch` — HEAD vs merge-base with the default branch:
  - base = `pickBase(dir)` (`origin/main` else `main`).
  - `git -C <dir> merge-base <base> HEAD` → `<mb>`; diff `git -C <dir> diff
    --no-color <mb>...HEAD` (three-dot = merge-base range).

Parse the unified-diff text with a small hand-rolled scanner (file headers,
`@@` hunk headers → old_start/old_lines/new_start/new_lines, `+`/`-`/` ` line
prefixes → kind add/del/context, tracking old/new line counters). Rename:
`git diff` emits `rename from`/`rename to` → `status:"renamed"`, `old_path`
set. Binary: `Binary files ... differ` → `binary:true`, no hunks.

**Caps** (consts, tune later): `maxLinesPerFile = 2000` (per-file cap →
`truncated:true`, remaining hunks dropped), `maxFiles = 300` (payload cap →
top-level `truncated:true`, extra files omitted from `files` but still counted
in `diffstat`). `context` query param (default 3) passed as `-U<n>`.

Per-file `additions`/`deletions` counted from parsed lines; top-level
`diffstat` summed. `staged` is a **best-effort whole-file flag**: true when the
file appears in the index diff (`git diff --cached --name-only`), which the
handler fetches once and set-membership-tests. A partially-staged file reports
`staged:true` (v1 granularity is whole-file; documented non-goal below).

### 1.3 App UX (spec — implementers build; iOS is source of truth, Android mirrors)

Entry: a **"Changes" surface** on the session screen with a diffstat badge
(`+N −M` from `git/state`). Phone + tablet, BOTH platforms.

1. **File list** — rows from `git/diff`: status glyph (tinted bare symbol, per
   the rows rule), path, per-file `+add −del`. Tap → file diff view.
2. **File diff view** — hunk rendering. **New shared components**:
   `ConduitUI/Components/DiffHunk.swift` + `DiffLine.swift` and the Android
   value-for-value mirror `ui/components/DiffHunk.kt` + `DiffLine.kt`.
   add/del/context colors come from `ConduitUI.Palette` /
   `LocalNeonTheme` — NO hex/radius literals. Monospace line text, old/new
   gutter numbers.
3. **Annotate** — tap a line → comment sheet (markdown `TextEditor`).
   Annotated lines get a gutter chip (`Chip` mono capsule). Comments are stored
   **client-side only**, keyed by session id (local persistence:
   `@AppStorage`/SwiftData on iOS, DataStore/Room on Android). No broker
   annotation storage in v1.
4. **Review bar** — "N comments · Send to agent". Composes the §2 prompt and
   sends it through the EXISTING durable chat-send path (client_msg_id dedup) —
   NOT a new endpoint. Comments STAY pinned after sending (verification).
5. **Ship card** — per-file stage/unstage toggles (`git/stage` / `git/unstage`),
   commit-message field, `Commit` / `Push` / `Create PR` buttons. Surface
   `stdout`/`stderr` verbatim on failure (never swallow). `Create PR` is gated
   on `git/state.has_gh`.
6. **Re-anchoring** — after the diff changes (agent revised), re-fetch and
   re-locate each comment by **(file, exact line text)**; prefer same
   `kind`/nearest line. Matched → re-pin (update line numbers). Unmatched →
   move to an **"Unanchored comments"** section; NEVER silently dropped.

**Telemetry** (standing order — mobile is CI-compile-only): breadcrumb at
`changes_open`, `diff_fetch_start/finish/fail`, `annotate_add`,
`send_to_agent`, `stage/unstage`, `commit_start/finish/fail`,
`push_*`, `pr_*`; `Telemetry.capture` ERROR on each failure terminus.

---

## 2. Send-to-agent prompt template (client-composed, verbatim)

One markdown message, batched, unambiguous. `{N}` comments, each block quotes
file path + line (number & kind) + a small context window + the user comment:

```
I reviewed the current changes and left {N} inline comment(s). Please address each one, then stop so I can re-review.

===== Comment {i} of {N} =====
File: {relative/path/from/repo/root}
Location: {kind} line {new_or_old_lineno}
Annotated line:
    {annotated line text, verbatim}
Context:
    {ctx_before_2}
    {ctx_before_1}
>>> {annotated line text}
    {ctx_after_1}
    {ctx_after_2}
Comment:
{user markdown comment}

===== End of comments =====
Guidance: make only the changes these comments call for; keep the diff focused. When done, reply with a one-line summary per comment and wait for my re-review.
```

Rules for the composer:
- `Location` uses `new` line number for `add`/`context` lines, `old` for `del`.
- `Annotated line` and the `>>>` context marker use the exact stored line text.
- Context window = up to 2 lines each side from the same hunk (fewer at hunk
  edges). Omit the `Context:` block entirely if the hunk is a single line.
- Separator `===== Comment i of N =====` is literal so the agent can't confuse
  comment boundaries with diff content.
- Unanchored comments (re-anchor failed) are still sent, with
  `Location: (unanchored — line text no longer present)` and no context block.

---

## 3. Wire contract (all bearer-authed; `?token=` accepted like every /api route)

Routed by extending the `/api/session/` dispatcher in `api.go serveSessionDelete`
(same `strings.HasSuffix(tail, "/git/…")` pattern already there).

### 3.1 `GET /api/session/{id}/git/diff?scope=uncommitted|branch&context=3`

```
200:
{
  "scope": "uncommitted",
  "default_branch": "main",
  "base": "origin/main",              // scope=branch only: the merge-base ref
  "files": [
    {
      "path": "broker/internal/ws/git.go",
      "old_path": "",                  // set only for renamed/copied
      "status": "modified",            // added|modified|deleted|renamed|copied|untracked
      "staged": true,                  // whole-file: file present in the index diff
      "binary": false,
      "additions": 12,
      "deletions": 3,
      "truncated": false,              // per-file line cap hit; later hunks dropped
      "hunks": [
        {
          "header": "@@ -10,6 +10,8 @@ func serve() {",
          "old_start": 10, "old_lines": 6,
          "new_start": 10, "new_lines": 8,
          "lines": [
            {"kind":"context","old":10,"new":10,"text":"func serve() {"},
            {"kind":"del","old":11,"new":0,"text":"  old()"},
            {"kind":"add","old":0,"new":11,"text":"  new()"}
          ]
        }
      ]
    }
  ],
  "diffstat": {"files_changed": 3, "additions": 47, "deletions": 12},
  "truncated": false                   // payload file cap hit; extra files omitted
}
409 {"error":"not_a_git_repo","message":"…"}      // LiveGitDir() is not a git repo
400 {"error":"invalid_request","message":"scope must be uncommitted|branch"}
401 {"error":"auth_expired","message":"unauthorized"}
404 {"error":"session_not_found","message":"…"}
```

### 3.2 `GET /api/session/{id}/git/state`

```
200:
{
  "is_git_repo": true,
  "branch": "conduit/session-abc",
  "detached": false,
  "default_branch": "main",
  "upstream": "origin/conduit/session-abc",  // "" when no upstream set
  "ahead": 2, "behind": 0,
  "staged": 1, "unstaged": 3, "untracked": 2, "dirty": 6,
  "has_gh": true,                             // gh binary present on box
  "pr": {"url":"https://github.com/o/r/pull/9","number":9,"state":"open"}  // omitted if none / undetectable
}
200 {"is_git_repo": false}                    // dir is not a repo (not an error)
401 / 404 as above
```
`pr` is best-effort via `gh pr view --json url,number,state` (omitted on any
error or when `has_gh:false`).

### 3.3 `POST /api/session/{id}/git/stage` and `/git/unstage`

```
Body: {"paths":["a.go","dir/b.go"]}
stage   → git -C <dir> add -- <paths...>
unstage → git -C <dir> restore --staged -- <paths...>   (fallback: git reset -q HEAD -- <paths...>)

200 {"ok":true,"stderr":""}
200 {"ok":false,"stderr":"…"}          // git failed; caller keys on ok (mirrors git/commit)
400 {"error":"invalid_request","message":"paths is required"}
401 / 404 as above
```
Paths are argv after `--`; never interpolated into a shell string. Absolute or
`..`-escaping paths rejected 400 `invalid_path`.

### 3.4 `POST /api/session/{id}/git/commit` (EXTEND existing, back-compat)

```
Body: {"message":"msg","all":true,"push":false}
- all omitted / true  → git add -A then commit   (EXISTING behavior — unchanged for old callers)
- all:false           → commit staged only (no add)
Uses LiveGitDir() for the NEW app; existing WorkspaceDir() behavior retained only
when the field is absent AND you keep the old handler — see §4 note.

200 {"ok":true,"stdout":"…","stderr":"…","commit_sha":"abc1234"}
200 {"ok":false,"stdout":"…","stderr":"…"}
400 {"error":"invalid_request","message":"message is required"}
401 / 404 as above
```

### 3.5 `POST /api/session/{id}/git/push`

```
Body: {}                                // no options in v1
- upstream missing → git -C <dir> push --set-upstream origin <branch>
- upstream present → git -C <dir> push
- NEVER --force. Default branch allowed (boxes are the user's own).

200 {"ok":true,"stdout":"…","stderr":"…","branch":"…","ahead":0,"behind":0,"set_upstream":true}
200 {"ok":false,"stdout":"…","stderr":"…"}   // report git output verbatim
401 / 404 as above
```

### 3.6 `POST /api/session/{id}/git/pr` (EXISTING — unchanged)

```
Body: {"title":"…","body":"…"} → 200 {"ok":true,"pr_url":"…"} / {"ok":false,"stderr":"…"}
```

---

## 4. Capability flag

Name: **`review_ship`**, placed under **`features.review_ship`** (bool) in the
capabilities payload.

- Broker: add `ReviewShip bool \`json:"review_ship"\`` to the `Features` struct
  in `api.go:95` and set `resp.Features.ReviewShip = true` in
  `serveCapabilities` (`api.go:243`). NESTED under `features`, matching
  `host_metrics`/`session_discovery`. **Not** a root mirror — the
  root-vs-features bug (capability-flag-nesting-trap, #891) bit the `pipeline_*`
  flags ONLY because already-shipped apps decoded them at root; here the app
  support ships in the SAME release that reads `features.review_ship`, so
  nested-only is correct. Do NOT add a root mirror.
- iOS: extend `BoxFeatures` (`SessionStore.swift:2149`) with `var reviewShip:
  Bool` and the nested `Features` decoder in `fetchBoxFeatures`
  (`SessionStore.swift:2515`) `case reviewShip = "review_ship"`, defaulting
  `false`. Gate the "Changes" entry point on `boxFeatures.reviewShip`.
- Android: extend `BoxFeatures` (`SessionStore.kt:4754`) with `val reviewShip:
  Boolean = false` and read `features?.optBoolean("review_ship", false)` in
  `fetchBoxFeatures` (`SessionStore.kt:5047`). Gate the entry point identically.

---

## 5. File-touch map

**broker (diff + gitops):**
- `broker/internal/session/gitstate.go` — add `func (s *Session) LiveGitDir()`.
- `broker/internal/ws/gitdiff.go` — NEW: diff parser + `serveSessionGitDiff` +
  `serveSessionGitState`.
- `broker/internal/ws/git.go` — add `serveSessionGitStage`,
  `serveSessionGitUnstage`, `serveSessionGitPush`; extend `gitCommitRequest`
  with `All *bool`; switch NEW handlers to `LiveGitDir()`.
- `broker/internal/ws/api.go` — extend the `serveSessionDelete` git dispatcher
  with `/git/diff`, `/git/state`, `/git/stage`, `/git/unstage`, `/git/push`
  suffixes; add `Features.ReviewShip` + set it true.
- Tests: `broker/internal/ws/gitdiff_test.go` (parse fixtures: modified,
  added, deleted, renamed, untracked, binary, truncation, both scopes),
  `git_test.go` additions for stage/unstage/push against a temp repo.

**iOS:**
- `ConduitUI/Components/DiffHunk.swift`, `DiffLine.swift` — NEW shared comps.
- `ConduitUI/Views/ConduitChangesView.swift` — NEW Changes surface (file list +
  file diff + annotate sheet + ship card + unanchored section).
- `ConduitUI/Models/ChangesModel.swift` — diff fetch, local annotation store,
  re-anchor, prompt composer.
- `SessionStore.swift` — `BoxFeatures.reviewShip` + git endpoint client methods.
- `ConduitProjectView.swift` — entry point gated on `reviewShip`.
- `ConduitTests` — prompt-composer + re-anchor unit tests (cross-platform ARGB
  test stays green for the new components).

**Android (value-for-value mirror):**
- `ui/components/DiffHunk.kt`, `DiffLine.kt` — NEW.
- `ui/ChangesScreen.kt` + `ChangesViewModel.kt` — NEW.
- `SessionStore.kt` — `BoxFeatures.reviewShip` + git endpoint client methods.
- entry point gated on `reviewShip`.
- unit tests for prompt composer + re-anchor + component ARGB parity.

---

## 6. Test plan

- Broker: table tests for the diff parser over captured `git diff` fixtures
  (all statuses, binary, rename, truncation, untracked-as-added, both scopes) —
  `cd broker && gofmt -l . && go vet ./... && go test ./...`. stage/unstage/
  commit(all=false)/push against a temp git repo with a fake remote.
- App: prompt-composer golden test (N comments → exact template), re-anchor
  matcher tests (exact match / moved line / deleted line → unanchored). Diff
  component ARGB cross-platform parity test.
- Manual (needs on-device verification): worktree-remapped session diffs the
  live cwd; large-diff truncation renders; PR button hidden when `has_gh:false`.

---

## 7. Rollout

- Broker change → **redeploy required** (docs/BROKER-REDEPLOY.md); tagging does
  NOT deploy the broker.
- App gates all UI on `features.review_ship`; old brokers → feature ships dark.
- Old apps ignore the new endpoints entirely.

---

## 8. Non-goals (v1)

- No broker-side annotation storage (client-local only).
- No hunk-level / line-level staging (whole-file granularity only).
- No merge-conflict resolution UI, no interactive rebase, no `--force` push.
- No multi-repo / submodule diffing.
- No amending or squashing from the app.
- No PR review-comment posting to GitHub (comments go to the AGENT, not to gh).
