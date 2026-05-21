# Agent adapters (frozen contract v1)

How an arbitrary CLI coding agent (Claude Code, Codex, Gemini, Aider, Goose, OpenCode, …) is integrated into swe-kitty so that all such agents are **interchangeable** end-to-end — including mid-session swap with state preservation.

Two physical locations on disk:

- `.swe-kitty/agents/*.toml` — dev-time, read by `swe-kitty-broker` when working on this repo
- `agents/*.toml` — production, read by `swe-kitty-broker` when running the shipped product

The TOML schema is the same; only the consumers differ.

## 1. TOML schema

```toml
name             = "claude"                              # required; matches ?assistant=
image            = "swekitty/claude:latest"              # required; Docker image tag
command          = ["claude"]                            # required; ENTRYPOINT override
args             = ["--dangerously-skip-permissions"]    # optional; appended to command
env_passthrough  = ["ANTHROPIC_API_KEY"]                 # env keys to forward from host
workdir          = "/workspace"                          # cwd inside container; mount target
chat_event_port_env = "AGENT_CHAT_PORT"                  # optional MCP bridge port var

[hooks]
on_start = "swe-kitty memory render --session $SESSION_UUID > /workspace/.swe-kitty/HANDOFF.html"
on_exit  = "swe-kitty memory checkpoint --session $SESSION_UUID --reason 'exit'"
on_swap  = "swe-kitty memory handoff --session $SESSION_UUID --from $FROM_AGENT --to $TO_AGENT"
```

Required fields: `name`, `image`, `command`, `workdir`. Everything else has a documented default.

## 2. Container model

**One container per broker, all agents pre-installed inside it.** This
matches the pattern upstream `swe-swe` settled on after experimenting with
per-agent containers: per-session isolation comes from per-session git
worktrees and per-session PTY/process trees, not from per-session Docker
containers. The broker binary runs as user `app` (uid 1000) inside the
image — that's specifically what lets claude accept
`--dangerously-skip-permissions`, which it refuses under root.

The canonical image is built from `broker/docker/Dockerfile` and tagged
`swekitty/broker:latest`. See `docs/SELF-HOST.md` for the
`docker compose up -d` flow.

### 2.1 What the image ships
- `swe-kitty-broker` binary (the Go server), built from this repo.
- Every agent CLI we ship a TOML adapter for (currently `claude`,
  `codex`) — installed globally via `npm install -g`.
- `git`, `bash`, `jq`, `curl`, `openssl`, `procps`, `tini`.
- The production agent TOMLs from `agents/` mounted at
  `/etc/swe-kitty/agents` and read on startup via `--agents-dir`.

### 2.2 Mounts (set by `docker-compose.yml`)
- `${WORKSPACE_DIR:-./workspace}:/workspace:rw` — the project root that
  every spawned agent's cwd points into.
- `swe-kitty-worktrees:/worktrees:rw` — per-session worktrees (named
  volume so they survive container restarts; one of the three
  persistence rails in `docs/SESSION-LIFECYCLE.md §1`).
- `swe-kitty-home:/home/app:rw` — agent auth caches + npm globals
  (claude logins, codex tokens, etc).

### 2.3 Environment variables the broker sets per-session
The broker spawns each agent as a child process inside the same
container via `pty.Start(exec.Command(adapter.Command[0], …))` from
`broker/internal/session/lifecycle.go`. Each spawn gets:

| Var | Value |
|---|---|
| `SESSION_UUID` | session id |
| `PORT` | preview port (3000–3019) |
| `AGENT_CHAT_PORT` | `PORT + 1000` — for MCP `view_event` bridge |
| `WORKTREE_BRANCH` | git branch checked out in `/workspace` |
| `FROM_AGENT` / `TO_AGENT` | only set inside `on_swap` |
| `KITTY_HANDOFF_PATH` | `/workspace/.swe-kitty/HANDOFF.html` |
| `KITTY_HANDOFF_OUT_PATH` | `/workspace/.swe-kitty/HANDOFF-OUT.html` |
| `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` | forwarded from `broker/docker/.env` |
| ... | plus any KEY=VALUE from `.swe-kitty/env` with `$VAR` expansion |

### 2.4 Agent process expectations

Every adapter's `command` + `args` from `agents/*.toml`:

1. **Read `$KITTY_HANDOFF_PATH` first.** If non-empty, prepend its contents to the agent's system prompt.
   - Claude Code: `claude --system-prompt-file "$KITTY_HANDOFF_PATH"`
   - Codex: pass via Codex's prompt-prefix mechanism
2. **Trap `SIGUSR1`.** On receipt, write a final structured summary to `$KITTY_HANDOFF_OUT_PATH` and exit cleanly. This is how the broker initiates an atomic agent swap.
3. **Run the agent CLI in foreground** so PTY connects directly. No `tail -f` wrappers.

## 3. Hooks

Hooks run on the **broker host** (not inside the container) so they have access to the persistence rails (scrollback ring, memory HTML, git worktree).

| Hook | When | Available env |
|---|---|---|
| `on_start` | After container has booted, before PTY is exposed to clients | `SESSION_UUID`, `AGENT_NAME` |
| `on_exit` | After container has stopped (any reason: clean, crash, SIGKILL) | `SESSION_UUID`, `AGENT_NAME`, `EXIT_CODE` |
| `on_swap` | After old container has stopped, before new container starts | `SESSION_UUID`, `FROM_AGENT`, `TO_AGENT` |

Hooks must be idempotent — recovery (`docs/SESSION-LIFECYCLE.md` §4) may invoke them again after a crash.

## 4. Agent swap mechanics

Triggered by `{"type":"switch_agent","assistant":"<new>"}` JSON control message. The broker:

1. Sends `SIGUSR1` to the running agent process; waits up to 30s for `$KITTY_HANDOFF_OUT_PATH` to land.
2. If it does, parses it as memory HTML and merges its `data-section="handoff"` into the session memory file. If it doesn't, falls back to the last memory checkpoint.
3. Sends `SIGTERM` (10s grace, then `SIGKILL`) to the old agent process.
4. Runs `on_swap` hook.
5. Renders fresh `HANDOFF.html` into the worktree.
6. `pty.Start`s the new agent process inside the same container; PTY scrollback ring is preserved client-side via the standard reconnect snapshot.
7. Broadcasts `status` with `phase: "swapping"` then `phase: "running"`. On spawn failure the broker still flips back to `running` with `reason_code: "agent_switch_failed"` so the mobile UI doesn't get stuck (regression fixed 2026-05-20).

The worktree, branch, and git state are **identical** across the swap.

## 5. Image build & distribution

The whole broker ships as one image: `swekitty/broker:latest`, built from
`broker/docker/Dockerfile`. CI builds it on every release tag and attaches
the tag-pinned variant (e.g. `swekitty/broker:v0.0.x`). Users pull and
run via `broker/docker/docker-compose.yml`.

There are **no per-agent images** any more. Adding a new agent means
adding an `npm install -g` line in the Dockerfile and a new
`agents/<name>.toml`, then rebuilding — no second Dockerfile to maintain.

## 6. Adding a new agent

1. Add a line to the `npm install -g` block in `broker/docker/Dockerfile`
   (or an `apt-get install` line if the CLI distributes that way).
2. Drop `agents/<name>.toml` with the right `command` / `args` / handoff flags.
3. Rebuild the image: `docker compose -f broker/docker/docker-compose.yml build`.
4. The agent CLI must support a system-prompt mechanism that can be fed
   by file or stdin — required for handoff. If it doesn't, write a tiny
   shim wrapper inside the image.
4. No Go or Rust code changes. Registry auto-discovers.
