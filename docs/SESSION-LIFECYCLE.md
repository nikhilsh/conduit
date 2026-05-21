# Session lifecycle (frozen contract v1)

How a swe-kitty session is created, kept alive, checkpointed, watchdogged, swapped between agents, and recovered after a crash. The guarantees here are what makes "long-running sessions with constant checks and ability to switch out agents without losing where we are" real.

## 1. Three persistence rails

Every session has three independent rails on disk. Recovery is possible iff all three are intact.

| Rail | What | Where | Cadence |
|---|---|---|---|
| **Scrollback ring** | Last N MiB raw PTY bytes (`N = 16` default) | `.swe-kitty/sessions/<uuid>/scrollback.bin` (mmap) | Continuous |
| **Memory HTML** | Structured agent state per `docs/MEMORY-FORMAT.md` | `.swe-kitty/memory/sessions/<uuid>.html` | Every 60s + on event |
| **Worktree** | Code changes | `.swe-kitty/sessions/<uuid>/work/` git worktree | Every agent commit + auto-WIP every 5 min |

## 2. Session creation

1. Client `GET /ws/<new-uuid>?assistant=<a>` with bearer auth.
2. Broker:
   1. Allocates a preview port from `[3000, 3019]`.
   2. Creates worktree: `git worktree add .swe-kitty/sessions/<uuid>/work -b agent/<a>-<task-or-uuidshort> origin/main`
   3. Renders session memory HTML from `.swe-kitty/memory/session-template.html` (substitutes placeholders).
   4. Creates `scrollback.bin` (16 MiB mmap).
   5. Looks up adapter for `<a>`, runs `on_start` hook.
   6. Spawns container: `docker run -d --name swekitty-<uuid> -v <work>:/workspace -v <memory>:/swe-kitty-memory:ro -e SESSION_UUID=<uuid> -e PORT=<p> -e AGENT_CHAT_PORT=<p+1000> --restart unless-stopped <image>`
   7. Connects PTY to the container's main process.
3. Server sends initial `status` JSON.

## 3. Checkpoints

A checkpoint is a coordinated flush of all three rails. Triggers:
- 60s ticker (configurable: `[checkpoint] interval_sec`)
- Every `switch_agent`
- Every clean `exit`
- `SIGTERM` to the broker
- Manual `swe-kitty memory checkpoint --session <uuid>` from inside the container or host

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
| Container alive | `docker exec <name> /bin/true` | Mark session `dead`; broadcast `phase: "stalled"`; emit `view_event` to chat tab; **do not** auto-restart |
| PTY producing output | bytes-since-last-output > `[watchdog] stall_alert_after_sec` (default 300s) | Mark `warning`; broadcast `phase: "stalled"`; emit alert `view_event` |
| Memory writable | open + fsync probe file under `.swe-kitty/memory/` | Log error; broadcast `phase: "stalled"`; do not crash broker |

`auto_restart_on_crash` is `false` by default (avoids agents looping forever burning credits). Users tap "Resume" in the mobile app to restart.

Health states surfaced via `status` JSON:
- 🟢 `healthy` — container alive, PTY drained <`stall_alert_after_sec` ago, last checkpoint <`interval_sec * 1.5` ago
- 🟡 `warning` — one of the above is missed but session still recoverable
- 🔴 `dead` — container exited

## 5. Agent swap

Triggered by `{"type":"switch_agent","assistant":"<new>"}` from any connected client.

1. Broadcast `{"type":"status","phase":"swapping","from":"<old>","to":"<new>"}`.
2. **Force checkpoint** (§3) so we have a known-good baseline.
3. Send `SIGUSR1` to the container's main process. Adapter entrypoint traps this and writes `/workspace/.swe-kitty/HANDOFF-OUT.html`. Wait up to 30s.
4. If `HANDOFF-OUT.html` lands within timeout: parse, validate against `docs/MEMORY-FORMAT.md`, merge its `handoff` section into the session memory.
   If timeout: log a warning, proceed with the last checkpoint's session memory as the handoff baseline.
5. `docker stop swekitty-<uuid> -t 10` (then kill if non-compliant).
6. Run adapter `on_swap` hook with `FROM_AGENT`, `TO_AGENT` env.
7. Re-render session memory's `handoff` section into `/workspace/.swe-kitty/HANDOFF.html` for the incoming agent.
8. Spawn new container with new adapter (§2 step 6). The new agent's entrypoint reads `HANDOFF.html` and prepends to system prompt.
9. PTY is **the same on-disk scrollback ring** — the new container's stdout/stderr appends. Clients reconnecting see the seamless transition via the standard snapshot.
10. Broadcast `{"type":"status","phase":"running","assistant":"<new>"}`.

The worktree, branch, git state, scrollback, and memory are preserved across the swap. The container instance and process state are reset (deliberately — that's the point).

## 6. Broker restart recovery

`swe-kitty-broker up` after a kill / reboot:

1. Scan `.swe-kitty/sessions/*/` for sessions.
2. For each:
   1. Validate all three rails (§1). If any rail missing, mark `corrupted` and skip with a warning.
   2. Check if `docker inspect swekitty-<uuid>` still exists. Docker's `--restart unless-stopped` policy usually means yes.
      - If yes: re-attach PTY to the live container.
      - If no: re-spawn container per §2 step 6. The new agent reads the existing `HANDOFF.html` (last checkpoint state).
   3. Mark `phase: "running"`.
3. Start the WebSocket server. Reconnecting clients get the standard snapshot and resume.

Sessions can survive an arbitrary number of broker restarts as long as Docker and the filesystem persist.

## 7. Session shutdown

Triggered by:
- `{"type":"exit"}` from any client (graceful, prompts confirm in app)
- Explicit `swe-kitty-broker session rm <uuid>` from CLI

Shutdown sequence:
1. Final checkpoint (§3).
2. `docker stop swekitty-<uuid> -t 10`.
3. Run `on_exit` hook.
4. Optionally archive: move `.swe-kitty/sessions/<uuid>/` to `.swe-kitty/archive/<uuid>/` (configurable; default off — keeps disk usage in check).
5. Remove the git worktree: `git worktree remove --force <path>`.
6. Mobile clients drop the session from their list.

## 8. Failure-mode matrix (must pass before v0.2 release)

| Failure | Expected behavior |
|---|---|
| Agent CLI crashes inside container | Watchdog detects, session `dead`, mobile shows Resume sheet; scrollback + memory intact; Resume re-runs `on_start` and respawns container with same adapter |
| Container OOM-killed | Same as above |
| Broker process `kill -9` | On restart (§6), all sessions recovered; clients reconnect and see snapshot — appears as a brief network blip |
| Mid-PR agent swap | §5 round-trip; new agent sees diff-so-far via `git stash list` from the auto-WIP, plus `HANDOFF.html` |
| Phone loses network for 1h | Sessions keep running on broker; on reconnect, gzip snapshot brings UI up to date |
| Concurrent memory edits (human + broker) | Detected via mtime+hash; human content in non-meta sections wins; `meta` and `env-snapshot` re-rendered by broker |
| User force-quits mobile app | No effect — broker sessions are server-side |
| Disk full during checkpoint | Checkpoint aborted with logged error, session continues in degraded mode (memory rail stale but PTY and worktree still live); mobile shows 🟡 warning |
| `HANDOFF-OUT.html` malformed | Validator rejects it; broker falls back to last checkpoint's handoff; logged |

Integration tests under `broker/internal/session/integration_test.go` cover each row (task 005).
