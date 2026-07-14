# PLAN — Agent memory persistence (keep credential isolation, persist the memory subtree)

Status: **SUPERSEDED.** This plan's Option A (a symlink from the per-session
ephemeral HOME's `.claude/projects` into a stable `<conduitRoot>/agent-state/`
store, implemented as `linkPersistentAgentState` in `agent_memory.go`) shipped
but is now dead code and has been DELETED. Persistence is now inherent to the
shared canonical config dir (`CONDUIT_SHARED_AGENT_CREDS` design, unconditional
as of docs/PLAN-AGENT-CREDENTIAL-LINEAGE.md): every session's `CLAUDE_CONFIG_DIR`
already points at ONE canonical directory (the operator's real `~/.claude` under
Option A, or a broker-owned `<conduitRoot>/agent-cred/.claude` under Option B),
so `projects/<slug>/` naturally lives outside `sessions/` and is never GC'd —
no symlink trick required. `agent_memory.go` / `agent_memory_test.go` were
removed; `<conduitRoot>/agent-state/` may still exist as a harmless leftover on
boxes that ran an older broker but is no longer written.

**One behavioral difference, known and accepted:** the symlink mechanism this
doc designed explicitly keyed memory on the ORIGINAL requested cwd (pre-worktree
-remap — see this doc's §6.4), so every worktree of the same repo shared one
memory bucket. The canonical config dir does not apply that pre-remap keying —
`projects/<slug>/` is keyed on whatever cwd the CLI itself sees, so a
per-session worktree remap (`CONDUIT_SESSION_WORKTREE`) now gets its own,
separate memory bucket per worktree rather than one shared bucket per real
project. This is a narrower regression than it sounds (worktree mode is
opt-in and off by default) and is accepted rather than re-solved.

The rest of this document is kept as the historical design record.

Owner decision points are collected in §6 (Open questions / risks).

---

## 1. Current model (verified against the code)

When the broker spawns a `claude` / `codex` agent for a session it sets two
things that matter here:

- **cwd = the user's selected project folder.**
  `broker/internal/session/manager.go:425-426`:
  ```go
  s.workspaceDir = s.maybeRemapToWorktree(s.commandDir(adapter))
  cmd.Dir = s.workspaceDir
  ```
  `commandDir` (`broker/internal/session/lifecycle.go:50-69`) returns the
  requested CWD when present (the user's chosen folder), else the adapter
  `Workdir`, else `s.worktreeDir`. So the agent runs inside the real project
  directory — GOOD.

- **$HOME = a per-session EPHEMERAL dir.**
  `broker/internal/session/manager.go:458`:
  ```go
  ephemeral := filepath.Join(s.sessionDir, "agent-home")
  ```
  with `s.sessionDir = <conduitRoot>/sessions/<id>` (`manager.go:2519`,
  `applyPaths`). `commandEnv` then exports it
  (`broker/internal/session/lifecycle.go:124-129`):
  ```go
  if s.agentHomeDir != "" {
      pairs["HOME"] = s.agentHomeDir
      if s.Assistant == "codex" {
          pairs["CODEX_HOME"] = filepath.Join(s.agentHomeDir, ".codex")
      }
  }
  ```
  Note: `CLAUDE_CONFIG_DIR` is **not** set anywhere; Claude derives its config
  root from `$HOME/.claude`. For codex, both `$HOME` and `$CODEX_HOME` are set.

### Why $HOME is per-session (the constraint we must not break)

The rationale is spelled out in the big comment at
`broker/internal/session/manager.go:431-457`: multiple concurrent
`claude`/`codex` agents sharing one `$HOME` race on OAuth refresh-token
rotation in `.claude/.credentials.json` / `.codex/auth.json`. Whoever refreshes
last wins; every other agent's refresh token is invalidated and that session
gets "Please run /login". A per-session HOME gives each agent a private copy of
the credential file to rotate in isolation, which breaks the race.

Credentials are populated into the ephemeral HOME from one of two sources
(`manager.go:439-495`): an app-pushed per-user OAuth blob via `credStore`
(with a staleness guard, `credfresh.go`), else a mirror of the broker host's
own credential files (`mirrorHostCredentials`, `lifecycle.go:240`). Every other
known provider's host login is also mirrored so the interactive Terminal tab is
logged in regardless of the session's agent (`manager.go:519-530`).

### What is staged forward into a new session

Only the **resume transcript** is staged, and only for explicit external
adopt-resume / adopt-fork:

- `stageExternalTranscript` (`broker/internal/session/stage_transcript.go:34`)
  copies the external agent's conversation `.jsonl` from the broker's real
  `$HOME` into the ephemeral agent-home so `--resume` / `exec resume` can find
  it: claude `~/.claude/projects/<slug>/<id>.jsonl`
  (`stage_transcript.go:51-86`), codex
  `~/.codex/sessions/YYYY/MM/DD/<rollout>.jsonl`
  (`stage_transcript.go:91-137`).

Nothing else is seeded forward. A brand-new session starts with a freshly
`MkdirAll`'d empty `agent-home` (plus copied credentials and a seeded
`.claude.json` theme/onboarding marker, `seedClaudeConfig`,
`lifecycle.go:357`).

### Session close + GC behavior

- On session close, `cleanupAgentHomeCredentials`
  (`manager.go:1340,1349-1361`) removes only the credential files
  (`.claude/.credentials.json`, `.codex/auth.json`) from the agent-home,
  deliberately PRESERVING `.claude/projects` / `.codex/sessions` so recovery's
  `--resume` keeps working across a broker restart.
- `RunGC` (`broker/internal/session/gc.go:26-83`) periodically scans
  `<conduitRoot>/sessions/`, and for any dir not in `m.sessions` whose most-
  recent touch is older than `maxAge` (default 7 days,
  `CONDUIT_SESSION_GC_AGE_DAYS`, `gc.go:110`) it does
  `os.RemoveAll(sessionDir)` (`gc.go:62`). That removes `agent-home` and
  everything under it.

### Per-session agent-home layout (effective)

```
<conduitRoot>/sessions/<id>/agent-home/        ← $HOME for the agent
├── .claude.json                               ← seeded theme/onboarding
├── .claude/
│   ├── .credentials.json                      ← removed on close
│   └── projects/<workspace-slug>/             ← transcripts + memory + history
│       ├── <session-uuid>.jsonl               ← (staged on adopt-resume)
│       └── memory/                            ← agent-written MEMORY  ← the loss
└── .codex/
    ├── auth.json                              ← removed on close
    └── sessions/YYYY/MM/DD/<rollout>.jsonl
```

`<workspace-slug>` is derived by Claude itself from the cwd: abs path with the
leading `/` stripped and remaining `/` → `-`, e.g.
`/root/developer/projects/conduit` → `-root-developer-projects-conduit`. The
broker already knows this rule — see `claudeSlugToCWD`
(`broker/internal/session/external_discovery.go:419-428`). The key fact: the
slug is keyed on the **workspace path**, so it is naturally per-project and
stable across sessions for the same folder.

---

## 2. Precise statement of the failure

Claude Code / Codex write persistent MEMORY (and conversation/projects history)
under `$HOME/.claude/projects/<slug>/memory/` (and equivalents). Because
`$HOME` is the per-session ephemeral `sessions/<id>/agent-home`:

1. **No cross-session visibility.** Each new session gets a fresh empty
   agent-home (only the resume transcript is staged, and only for explicit
   adopt-resume). Memory written in session A is in
   `sessions/A/agent-home/...` and is never read by session B.
2. **The store is GC'd.** `RunGC` `os.RemoveAll`s the whole `sessions/<id>/`
   dir after `maxAge` (default 7 days). The memory lives in a short-lived,
   un-maintained directory and is eventually deleted outright.

Net: the agent's persistent-memory feature is effectively broken across
sessions. There is no per-project aggregation point.

---

## 3. Design options

The shared requirement for every option: **credential files
(`.claude/.credentials.json`, `.codex/auth.json`) MUST remain per-session
ephemeral** so the OAuth refresh-race fix is preserved. Only MEMORY (and
arguably projects/history) may be made persistent + shared per project.

A second shared concern: **what is the persistence KEY?** Claude/Codex already
key their projects dir on the workspace path (the slug above). So a per-project
key (`provider` × `workspace path`) maps cleanly onto the CLIs' own layout and
is the right grain. We need a stable broker-side slug for the workspace path;
reuse the existing `claudeSlugToCWD` rule inverted (a `cwdToClaudeSlug`
helper), so the broker store and the CLI's own slug agree.

### Option A — Symlink ONLY the memory/projects subtree to a stable per-project store (RECOMMENDED)

Keep `$HOME = sessions/<id>/agent-home` exactly as today, but before launch
replace the **memory/projects subtree** inside it with a symlink (or a
bind-equivalent) into a stable, non-GC'd, per-project location:

```
<conduitRoot>/agent-state/<provider>/<workspace-slug>/
├── projects/            (claude:  $HOME/.claude/projects        → symlink here)
└── ...                  (codex:   $HOME/.codex/sessions or a memory subdir)
```

Concretely for claude: create the stable dir, then
`os.Symlink(stableProjectsDir, filepath.Join(ephemeral, ".claude", "projects"))`.
The credential file `.claude/.credentials.json` stays a real ephemeral file in
`agent-home/.claude/` — only the `projects` child is redirected. Codex is
analogous but needs care (see §6: which codex subdir actually holds memory vs.
rotation-sensitive state).

- **Credential isolation:** fully preserved. `.credentials.json` /
  `auth.json` remain per-session real files; only `projects` (memory + history)
  is shared. The symlink is a child of `.claude`, not `.claude` itself, so the
  credential file is untouched.
- **GC implications:** the stable store lives OUTSIDE `<conduitRoot>/sessions/`,
  so `RunGC` (which only scans `sessions/`) never touches it — no gc.go change
  strictly required. But we should still ADD a guard/comment so a future
  broadening of GC's scan root can't accidentally reap `agent-state/`. And
  `cleanupAgentHomeCredentials` already only removes credential files, so it is
  safe; the symlink target is preserved.
- **Concurrency safety:** two concurrent sessions on the SAME project now share
  one `projects/` dir. This is the only real risk in this option — see §6.
  Claude/Codex append per-session `.jsonl` files (distinct filenames per
  session id), so transcript writes don't collide. MEMORY files are the open
  question: if both sessions edit the same memory file we can get last-writer-
  wins. This is the SAME failure mode the credential isolation avoids, but for
  memory the blast radius is far smaller (a lost memory edit, not a logout) and
  only affects concurrent same-project sessions. Acceptable for v1; mitigation
  options in §6.
- **Back-compat / migration:** existing live sessions are unaffected (their
  agent-home is already created). For the cutover, optionally do a one-time
  best-effort copy: on first spawn for a `<provider, slug>` whose stable store
  is empty, seed it from the most recent matching `sessions/*/agent-home/.claude/projects/<slug>/`
  that still exists on disk. Best-effort, never blocks spawn (mirror the
  `stageExternalTranscript` discipline).
- **Slug key:** `cwdToClaudeSlug(s.workspaceDir)` (inverse of
  `claudeSlugToCWD`). This makes the broker's stable dir name equal to the
  slug the CLI itself uses, so the symlinked `projects/<slug>` lines up with
  what claude expects.

This is the **minimum design that holds the invariant**: it changes one
filesystem edge (a single child symlink) and leaves the credential isolation,
the env wiring, GC, and the transcript-staging path all intact.

### Option B — Route memory into the project's own `.conduit/memory`

Conduit already maintains a gitignored box-local tree per workspace:
`<workspace>/.conduit/knowledge/` (`broker/internal/kb/userbox.go:46`,
`BoxLocalDir`), protected by `EnsureBoxLocalGitignore` which writes
`<workspace>/.conduit/.gitignore` containing `*`
(`userbox.go:96-110`). We could add `<workspace>/.conduit/memory` and redirect
the agent's memory there.

- **Credential isolation:** preserved the same way as Option A (we only
  redirect the memory subtree, not credentials).
- **GC implications:** lives in the user's repo, not under `sessions/`, so
  `RunGC` never touches it. But it is now the broker's job to ensure the
  gitignore covers it (the existing `*` rule under `.conduit/` already does).
- **Concurrency safety:** identical to Option A (shared per-project dir).
- **Pollution / commit risk (the real downside):** this drops broker-managed
  state INTO the user's working tree. The `.conduit/.gitignore: *` guard means
  it shouldn't be committed, but: (a) it pollutes the user's folder with a
  directory they didn't create; (b) if the user's repo predates the gitignore
  or uses `git add -f`, secrets/history could be committed; (c) a worktree
  remap (`maybeRemapToWorktree`) changes the workspace path, so memory would
  fragment across worktrees of the same repo. The credential-isolation comment
  at `manager.go:453-457` explicitly rejected putting agent-home into the
  workspace for exactly this "pollute the working tree / risk committing
  secrets" reason. Memory is less sensitive than credentials, but the
  precedent argues against it.
- **Slug key:** the workspace path itself (the dir IS the key). No slug needed,
  but fragments across worktrees.

Reasonable, and it reuses an existing pattern — but the in-repo pollution and
worktree-fragmentation make it weaker than Option A for a broker-owned store.

### Option C — Stable per-(project, provider) HOME reused across sessions

Make `$HOME` itself stable per `<provider, slug>` instead of per session:
`ephemeral := <conduitRoot>/agent-home/<provider>/<slug>` reused across
sessions for the same project.

- **Credential isolation:** BROKEN for the concurrent-same-project case. Two
  concurrent sessions on the same project would again share
  `.credentials.json` and re-introduce the exact OAuth refresh-token race the
  current design exists to prevent. Sessions on DIFFERENT projects are still
  isolated (different slug), and serial sessions on the same project are fine.
- **Mitigations if pursued:** (a) per-`<provider, slug>` advisory lock allowing
  only one live session per project at a time (changes product behavior —
  rejects/queues a second session on the same repo); (b) keep credentials
  ephemeral-per-session by materializing them into a session-private overlay
  while the rest of HOME is shared — which collapses back into Option A
  (selective redirect) anyway.
- **GC implications:** the stable HOME must be excluded from `RunGC`. Since it
  is not under `sessions/`, the current GC won't touch it; same guard note as A.
- **Slug key:** same `cwdToClaudeSlug` as A.

Simplest mental model, but it trades away the invariant for the concurrent
case. Only acceptable if the owner is willing to serialize same-project
sessions. Not recommended.

### Option D — CLAUDE_CONFIG_DIR / CODEX_HOME override scoping

Use the CLIs' env overrides to relocate config. The trap: pointing
`CLAUDE_CONFIG_DIR` (or `CODEX_HOME`) at a SHARED directory moves the WHOLE
config — including `.credentials.json` / `auth.json` — back to a shared
location, which re-creates the OAuth race. So a config-dir override is only
safe if it is **per-session** (no benefit) OR if the CLI offers a memory-only
override that does NOT also relocate credentials.

- For **codex**, `$CODEX_HOME` is already set per-session
  (`lifecycle.go:127`). A shared `$CODEX_HOME` would share `auth.json` →
  race. So codex memory persistence cannot ride on a shared `CODEX_HOME`; it
  needs the same selective-subtree redirect as Option A.
- For **claude**, there is no separate documented "memory dir" env that is
  decoupled from `CLAUDE_CONFIG_DIR`. (FLAG: this is unverified against the
  current Claude Code release — see §6. If such an env exists, a narrow
  redirect via env is cleaner than a symlink.)

Conclusion: env overrides only help if there is a **narrow, memory-only** env
that doesn't move credentials. Absent that, the symlink in Option A is the
narrow redirect. Option D, as a whole-config move, is unsafe.

---

## 4. Recommendation

**Adopt Option A: symlink only the memory/projects subtree from each
ephemeral agent-home into a stable, non-GC'd, per-project store keyed by
`<provider>/<workspace-slug>`, keeping credential files per-session
ephemeral.**

Rationale:
- It preserves the credential-isolation invariant exactly: only `projects`
  (memory + history) is shared; `.credentials.json` / `auth.json` stay
  per-session real files rotated in isolation.
- It aligns with the CLIs' own layout: claude already keys `projects/<slug>` on
  the workspace path, so the symlinked target matches what the CLI computes.
- It is the smallest change — one filesystem edge per session — and touches no
  env wiring, no GC scan logic (the store is outside `sessions/`), and leaves
  the existing transcript-staging path working.
- The only new risk (concurrent same-project memory writes) is low blast-radius
  (a lost memory edit vs. a logout) and can be tightened later if it bites.

### Concrete file-touch list (for the follow-up implementation PR — NOT this PR)

1. **`broker/internal/session/manager.go`** (agent-home setup, ~458-530):
   after `MkdirAll(ephemeral)` and before launch, call a new helper to create
   the stable store and replace the `projects` subtree with a symlink into it.
   Order matters: must run before `seedClaudeConfig` / `stageExternalTranscript`
   so staged transcripts land in the shared store (and become resumable across
   sessions as a bonus).
2. **New helper, e.g. `broker/internal/session/agent_memory.go`**:
   - `cwdToClaudeSlug(path string) string` — inverse of `claudeSlugToCWD`
     (`external_discovery.go:419`); keep the two in one place / cross-reference
     so they can't drift.
   - `linkPersistentAgentState(ephemeralHome, conduitRoot, provider, workspaceDir string) error`
     — mkdir `<conduitRoot>/agent-state/<provider>/<slug>/projects`, mkdir the
     `.claude` parent in the ephemeral home, then symlink the `projects` child
     to the stable dir. Best-effort: on any error, log and fall back to today's
     ephemeral behavior (never block the spawn). Codex variant redirects the
     correct codex memory subdir (see §6).
   - Optional one-time migration seed from the newest existing
     `sessions/*/agent-home/.../projects/<slug>` (best-effort).
3. **`broker/internal/session/gc.go`**: NO behavioral change required (GC only
   scans `sessions/`). ADD a short comment documenting that `agent-state/` is a
   persistent store deliberately outside the GC scan root, so a future change
   to `root` can't silently reap it. (Defensive only.)
4. **`broker/internal/session/stage_transcript.go`**: no change needed, but
   note in a comment that with the symlink in place, staged transcripts now
   land in the shared per-project store (intended).

No iOS/Android/core changes. This is broker-only and does not change any
protocol or `chat_mode` alias, so it stays well inside the backend-abstraction
budget.

---

## 5. Invariants this design protects

- **Credential isolation invariant:** each session's
  `.claude/.credentials.json` / `.codex/auth.json` is a private ephemeral file;
  no two sessions ever rotate the same refresh token. Protected by redirecting
  ONLY the `projects` child, never the credential file or the config root.
- **GC-safety invariant:** persistent memory lives outside
  `<conduitRoot>/sessions/`, so the session GC's `RemoveAll` cannot reap it.
- **No-workspace-pollution invariant:** broker-owned state stays under
  `<conduitRoot>` (not in the user's repo), honoring the existing
  `manager.go:453-457` decision.

---

## 6. Open questions / risks for the owner

1. **Concurrent same-project memory writes.** Do Claude Code / Codex tolerate
   two processes sharing one `projects/<slug>` dir for MEMORY files (not just
   distinct per-session `.jsonl`)? If memory is a single file edited in place,
   we risk last-writer-wins between concurrent same-project sessions. Options:
   accept for v1; or add a per-`<provider, slug>` advisory file lock around the
   shared dir; or only redirect memory when no other live session shares the
   slug. NEEDS a behavior check against the current CLI releases — could not be
   verified from the broker code alone.
2. **Exact codex memory location.** This doc verified claude's
   `.claude/projects/<slug>/memory/` layout from the broker's own staging /
   slug code. The precise codex path that holds persistent memory (vs.
   rotation-sensitive `auth.json` and vs. `sessions/`) was NOT confirmed from
   the broker code. Before implementing the codex side, confirm which codex
   subdir is memory and ensure the redirect does not pull `auth.json` into the
   shared store. FLAGGED as unverified.
3. **Does a memory-only env override exist?** If Claude Code / Codex expose an
   env that relocates ONLY memory (decoupled from credentials), prefer that
   narrow env over a symlink (Option D becomes safe and cleaner). Unverified
   against current releases.
4. **Worktree remap.** When a session runs in a per-session git worktree
   (`maybeRemapToWorktree`, `manager.go:425`), `s.workspaceDir` is the worktree
   path, so its slug differs from the base repo. Should the persistence key be
   the worktree path (memory fragments per worktree) or the base repo path
   (one memory per repo)? Recommend keying on the ORIGINAL requested CWD /
   repo root, not the remapped worktree, so memory is per real project. Needs a
   decision.
5. **Symlinks vs. copy-back.** Symlink is simplest but assumes the agent
   follows symlinks for its config root (it does for `$HOME`). If any code path
   `RemoveAll`s `.claude/projects` (none found today), it would delete the
   shared store through the link. A copy-in / copy-out alternative is safer but
   races on concurrent sessions and is more code. Recommend symlink + the gc.go
   guard comment; revisit if a destructive path appears.
6. **Migration scope.** Should we seed the new store from existing
   `sessions/*/agent-home` memory before GC eats it, or accept that pre-change
   memory is already effectively lost? A best-effort one-time seed is cheap and
   recovers anything not yet GC'd; owner to confirm it's worth the code.
