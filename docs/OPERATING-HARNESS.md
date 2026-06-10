# Operating Harness

Encodes the conduit operating model so a one-liner task runs start-to-end
without re-instructing cleanliness, roadmap upkeep, subagent choice, or
CI-watching. Schema verified against Claude Code **2.1.170**.

## Pain-point → mechanism

| User pain (verbatim) | Mechanism |
|---|---|
| "I always need to give you instructions on cleanliness" | DoD checklist in CLAUDE.md + `/ship` step 5 + opt-in `Stop` cleanliness hook (untracked-files / stale-worktree reminder) |
| "...or updating roadmap" | DoD checklist line (roadmap + memory) baked into CLAUDE.md and every agent's scaffold; `doc-writer` owns roadmap edits |
| "...or deciding when to use subagent" | Delegation roster + model tiers in CLAUDE.md; six `.claude/agents/*.md` with auto-selection descriptions; `/ship` step 1 routing table |
| "...or doing checks and verifying CI is clean (I even have to check for you)" | `/merge-when-green` encodes the correct `gh pr checks <N> \|\| true` pending-count watch; orchestrator owns gating; agents end at push+PR |
| "...and playbook etc." | `/ship`, `/merge-when-green`, `/cut-release`, `/broker-redeploy` commands; SessionStart hook surfaces the index |
| "cannot give a one liner task and you carry out from start to end without maximizing tokens" | `/ship` is the one-liner→done flow; orchestrate-cheaply rules (plan+delegate, agents don't CI-watch, concurrency ~3) |
| "have active compaction when its a new task" | Compaction guidance below — CC has NO auto new-task detection; `/clear` convention + SessionStart reminder (closest available) |

## What Claude Code can and cannot do (this version)

- **Subagents** (`.claude/agents/*.md`): supported. Frontmatter `name`,
  `description` (drives automatic delegation), `tools`, `model`
  (`opus`/`sonnet`/`haiku`/`inherit` or a full ID). Six agents created.
- **Commands** (`.claude/commands/*.md`): supported; each creates `/<name>`.
  (Custom commands merged into Skills, but `.claude/commands/` still works and
  is lighter for these playbooks. Frontmatter: `description`, `argument-hint`,
  `allowed-tools`; `$ARGUMENTS` / `$1`.)
- **Hooks** (`.claude/settings.json`): supported. Events used: `SessionStart`
  (inject `additionalContext`), `PreToolUse` (matcher `Bash`, exit 2 blocks),
  `Stop` (non-blocking `systemMessage`). Exit codes: 0 = ok (parse stdout JSON);
  **2 = block** (PreToolUse blocks the tool, Stop prevents stopping); other =
  non-blocking error.
- **Auto new-task detection / auto-`/clear`: NOT supported.** There is no event
  that fires "user started a new task," and no `autoCompactWindow` /
  `autoCompactEnabled` setting in this version. Closest workable alternative:
  the `/clear` convention + a SessionStart reminder. (A `UserPromptSubmit` hook
  *could* heuristically detect a topic switch and inject a "consider /clear"
  note, but it cannot itself clear context and would fire on false positives —
  not recommended.)

## Hooks: AUTO vs OPT-IN

All three scripts were pipe-tested (fed representative stdin, asserted exit code
+ JSON validity) before landing.

| Hook | Event | State | Why |
|---|---|---|---|
| `session-start-index.sh` | `SessionStart` | **AUTO** (enabled in settings.json) | Cheap, non-blocking, can't disrupt; injects the playbook/roster/DoD reminder so a one-liner knows the model |
| `gate-broker-on-push.sh` | `PreToolUse(Bash)` | **OPT-IN** | Runs broker gates on `git push` when `broker/` changed and **blocks** (exit 2) on failure. `go test ./...` is ~60s and the termgrid test needs sidecar npm deps installed — too heavy/disruptive to force on |
| `stop-cleanliness.sh` | `Stop` | **OPT-IN** | Non-blocking reminder if the checkout has untracked files / stale worktrees. Noisy on this box during multi-agent sessions (many live worktrees); best for solo sessions |

### Enable an opt-in hook

Edit `.claude/settings.json`, add the block, then run `/hooks` to load.

PreToolUse broker gate:

```json
"PreToolUse": [
  {
    "matcher": "Bash",
    "hooks": [
      { "type": "command",
        "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/gate-broker-on-push.sh",
        "timeout": 120 }
    ]
  }
]
```

Stop cleanliness reminder:

```json
"Stop": [
  {
    "hooks": [
      { "type": "command",
        "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/stop-cleanliness.sh",
        "timeout": 15 }
    ]
  }
]
```

## Compaction recommendation

CC has no automatic new-task detection. Use this convention:
- `/clear` when switching to UNRELATED work — fresh context, cheapest.
- `/compact` mid-task to summarize and keep going; `/compact <focus>` to steer
  what's kept (e.g. `/compact Focus on test output and code changes`). A
  "Compact instructions" block in CLAUDE.md sets a default.
- Auto-compaction fires only near the context limit — don't rely on it for
  task boundaries.

## One-time activation

This PR only adds files; nothing is live until loaded. After review/merge, run
**`/hooks`** in a session at the repo root to load `.claude/settings.json`. The
SessionStart reminder then appears at the next session start. Commands and
agents are picked up automatically (no activation needed).
