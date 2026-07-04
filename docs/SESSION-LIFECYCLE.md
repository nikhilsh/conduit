# Session lifecycle (frozen contract v1)

How a conduit session is created, kept alive, checkpointed, watchdogged, swapped between agents, and recovered after a crash. The guarantees here are what makes "long-running sessions with constant checks and ability to switch out agents without losing where we are" real.

## 1. Three persistence rails

Every session has three independent rails on disk. Recovery is possible iff all three are intact.

| Rail | What | Where | Cadence |
|---|---|---|---|
| **Scrollback ring** | Last N MiB raw PTY bytes (`N = 16` default) | `.conduit/sessions/<uuid>/scrollback.bin` (mmap) | Continuous |
| **Memory HTML** | Structured agent state per `docs/MEMORY-FORMAT.md` | `.conduit/memory/sessions/<uuid>.html` | Every 60s + on event |
| **Worktree** | Code changes | `.conduit/sessions/<uuid>/work/` git worktree | Every agent commit + auto-WIP every 5 min |

## 2. Session creation

1. Client `GET /ws/<new-uuid>?assistant=<a>` with bearer auth.
2. Broker:
   1. Allocates a preview port from `[3000, 3019]`.
   2. Creates worktree: `git worktree add .conduit/sessions/<uuid>/work -b agent/<a>-<task-or-uuidshort> origin/main`
   3. Renders session memory HTML from `.conduit/memory/session-template.html` (substitutes placeholders).
   4. Creates `scrollback.bin` (16 MiB mmap).
   5. Looks up adapter for `<a>`, runs `on_start` hook.
   6. Spawns the agent as a host child process: `pty.Start` in the worktree with
      a per-session ephemeral `$HOME` and the env from
      [`AGENT-ADAPTERS.md §2.3`](AGENT-ADAPTERS.md) (no Docker — the broker runs
      directly on the host).
   7. Connects the PTY to the agent process.
3. Server sends initial `status` JSON.

## 3. Checkpoints

A checkpoint is a coordinated flush of all three rails. Triggers:
- 60s ticker (configurable: `[checkpoint] interval_sec`)
- Every `switch_agent`
- Every clean `exit`
- `SIGTERM` to the broker
- Manual `conduit memory checkpoint --session <uuid>` from the broker host

Checkpoint sequence (atomic):
1. Pause PTY drain into an in-memory tail buffer
2. Flush scrollback ring to disk: temp file + `rename(2)` + `fsync(2)`
3. Update memory HTML: render with current scrollback tail in `env-snapshot`, bump `last-checkpoint`, validate, atomic write
4. Auto-WIP: in the worktree, `git add -A && git stash push -m "checkpoint:<ts>" --include-untracked` (only if there are changes; idempotent on no-op)
5. Resume PTY drain (flush in-memory tail first)

A successful checkpoint is broadcast as `{"type":"status", "phase":"running", "last_checkpoint": "<iso>"}` so clients can update the Health badge.

## 4. Watchdog

A goroutine per session, independent of the PTY drain. Runs three checks every 30s (configurable: `[watchdog] liveness_probe_interval_sec`).

| Check | Probe | Failure action |
|---|---|---|
| Agent process alive | the PTY child's exit is observed | Mark session `dead`; broadcast the phase change; emit `view_event` to chat tab; **do not** auto-restart |
| PTY producing output | bytes-since-last-output > `[watchdog] stall_alert_after_sec` (default 300s) | Mark health `warning`; **phase stays `running`** (PR #385 — a quiet-but-alive agent must not flip the app read-only); broadcast the health change |
| Memory writable | open + fsync probe file under `.conduit/memory/` | Log error; health `warning`; **phase stays `running`**; do not crash broker |

`auto_restart_on_crash` is `false` by default (avoids agents looping forever burning credits). Users tap "Resume" in the mobile app to restart.

Health states surfaced via `status` JSON:
- 🟢 `healthy` — agent process alive, PTY drained <`stall_alert_after_sec` ago, last checkpoint <`interval_sec * 1.5` ago
- 🟡 `warning` — one of the above is missed but session still recoverable
- 🔴 `dead` — agent process exited

## 5. Agent swap

Triggered by `{"type":"switch_agent","assistant":"<new>"}` from any connected client.

1. Reject the request if a structured turn, `AskUserQuestion`, approval, or
   other pending input is active. A switch never interrupts or silently denies
   an interaction.
2. Broadcast `phase:"swapping"` and force a checkpoint.
3. Build a bounded broker-owned handoff from the tail of
   `conversation.jsonl`, session identity, workspace path, branch, and
   `git status --short`. Persist it in the session memory `handoff` section.
4. Start the target structured backend with that agent's own persisted resume
   id (`claude_chat_session_id` or `codex_thread_id`). Claude and Codex keep
   independent threads across repeated switches.
5. Commit `assistant`, adapter, backend, and pending-handoff metadata only after
   target startup succeeds. On failure the old backend and metadata remain
   active. Structured-to-structured swaps retain the Terminal tab's shell.
6. Close the old structured backend. Run external `on_swap` / target
   `on_start` hooks best-effort; failures are logged and cannot veto the switch.
7. Invisibly prepend the handoff to the incoming backend's next normal user
   message. The user's original message alone is written to
   `conversation.jsonl`; pending-input answers and slash commands do not
   consume the handoff.
8. Broadcast `phase:"running", assistant:"<new>"`.

Production switching does not depend on `SIGUSR1`, `HANDOFF-OUT.html`, or an
agent consuming `HANDOFF.html`. Those paths remain compatibility surfaces for
external adapters only. The worktree, branch, git state, scrollback, memory,
and each agent's native thread are preserved.

## 6. Broker restart recovery

`conduit-broker up` after a kill / reboot:

1. Scan `.conduit/sessions/*/` for sessions.
2. For each:
   1. Validate all three rails (§1). If any rail missing, mark `corrupted` and skip with a warning.
   2. Check whether the session's tmux server still holds the PTY (tmux survives
      a broker restart since it's a separate process).
      - If yes: re-attach to the live tmux PTY.
      - If no: re-spawn the agent per §2 step 6. The new agent reads the existing `HANDOFF.html` (last checkpoint state).
   3. Mark `phase: "running"`.
3. Start the WebSocket server. Reconnecting clients get the standard snapshot and resume.

Sessions can survive an arbitrary number of broker restarts as long as tmux and the filesystem persist.

## 7. Session shutdown

Triggered by:
- `{"type":"exit"}` from any client (graceful, prompts confirm in app)
- Explicit `conduit-broker session rm <uuid>` from CLI

Shutdown sequence:
1. Final checkpoint (§3).
2. `SIGTERM` the agent process (10s grace, then `SIGKILL`); tear down its tmux PTY.
3. Run `on_exit` hook.
4. Optionally archive: move `.conduit/sessions/<uuid>/` to `.conduit/archive/<uuid>/` (configurable; default off — keeps disk usage in check).
5. Remove the git worktree: `git worktree remove --force <path>`.
6. Mobile clients drop the session from their list.

## 8. Failure-mode matrix (must pass before v0.2 release)

| Failure | Expected behavior |
|---|---|
| Agent CLI crashes | Watchdog detects, session `dead`, mobile shows Resume sheet; scrollback + memory intact; Resume re-runs `on_start` and respawns the agent with the same adapter |
| Agent OOM-killed | Same as above |
| Broker process `kill -9` | On restart (§6), all sessions recovered; clients reconnect and see snapshot — appears as a brief network blip |
| Mid-PR agent swap | §5 round-trip; incoming agent receives the bounded broker handoff on its next normal message |
| Phone loses network for 1h | Sessions keep running on broker; on reconnect, gzip snapshot brings UI up to date |
| Concurrent memory edits (human + broker) | Detected via mtime+hash; human content in non-meta sections wins; `meta` and `env-snapshot` re-rendered by broker |
| User force-quits mobile app | No effect — broker sessions are server-side |
| Disk full during checkpoint | Checkpoint aborted with logged error, session continues in degraded mode (memory rail stale but PTY and worktree still live); mobile shows 🟡 warning |
| Target backend fails to start | Switch rolls back; assistant/backend metadata and the old live backend remain unchanged |

Integration tests under `broker/internal/session/integration_test.go` cover each row (task 005).
