# Agent adapters (frozen contract v1)

How an arbitrary CLI coding agent (Claude Code, Codex, Gemini, Aider, Goose, OpenCode, …) is integrated into swe-kitty so that all such agents are **interchangeable** end-to-end — including mid-session swap with state preservation.

Two physical locations on disk:

- `.swe-kitty/agents/*.toml` — dev-time, read by upstream `swe-swe` when building this repo
- `agents/*.toml` — production, read by `swe-kitty-harness` when running the shipped product

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

## 2. Container contract

When the harness spawns an agent, the container receives:

### 2.1 Mounts
- `<host worktree>:/workspace` (read-write)
- `<host>/.swe-kitty/memory:/swe-kitty-memory` (read-only, for `swe-kitty memory render` calls)

### 2.2 Environment variables (always set by harness)
| Var | Value |
|---|---|
| `SESSION_UUID` | session id |
| `PORT` | preview port (3000–3019) |
| `AGENT_CHAT_PORT` | `PORT + 1000` — for MCP `view_event` bridge |
| `WORKTREE_BRANCH` | git branch checked out in `/workspace` |
| `FROM_AGENT` / `TO_AGENT` | only inside `on_swap` |
| `KITTY_HANDOFF_PATH` | `/workspace/.swe-kitty/HANDOFF.html` |
| `KITTY_HANDOFF_OUT_PATH` | `/workspace/.swe-kitty/HANDOFF-OUT.html` |
| ... | plus any KEY=VALUE from `.swe-kitty/env` with `$VAR` expansion |

### 2.3 Entrypoint expectations

Every adapter image's entrypoint MUST:

1. **Read `$KITTY_HANDOFF_PATH` first.** If non-empty, prepend its contents to the agent's system prompt.
   - Claude Code: `claude --system-prompt-file "$KITTY_HANDOFF_PATH"`
   - Codex: pass via Codex's prompt-prefix mechanism
2. **Trap `SIGUSR1`.** On receipt, write a final structured summary to `$KITTY_HANDOFF_OUT_PATH` and exit cleanly. This is how the harness initiates an atomic agent swap.
3. **Run the agent CLI in foreground** so PTY connects directly. No `tail -f` wrappers.

The Dockerfile is responsible for installing the agent CLI; the entrypoint shell script lives at `/swekitty/entrypoint.sh` inside the image. A canonical `entrypoint.sh` template ships at `harness/docker/entrypoint-template.sh` (task 006).

## 3. Hooks

Hooks run on the **harness host** (not inside the container) so they have access to the persistence rails (scrollback ring, memory HTML, git worktree).

| Hook | When | Available env |
|---|---|---|
| `on_start` | After container has booted, before PTY is exposed to clients | `SESSION_UUID`, `AGENT_NAME` |
| `on_exit` | After container has stopped (any reason: clean, crash, SIGKILL) | `SESSION_UUID`, `AGENT_NAME`, `EXIT_CODE` |
| `on_swap` | After old container has stopped, before new container starts | `SESSION_UUID`, `FROM_AGENT`, `TO_AGENT` |

Hooks must be idempotent — recovery (`docs/SESSION-LIFECYCLE.md` §4) may invoke them again after a crash.

## 4. Agent swap mechanics

Triggered by `{"type":"switch_agent","assistant":"<new>"}` JSON control message. The harness:

1. Sends `SIGUSR1` to the agent inside the container; waits up to 30s for `$KITTY_HANDOFF_OUT_PATH` to land.
2. If it does, parses it as memory HTML and merges its `data-section="handoff"` into the session memory file. If it doesn't, falls back to the last memory checkpoint.
3. Stops the container (`docker stop` with 10s grace, then kill).
4. Runs `on_swap` hook.
5. Renders fresh `HANDOFF.html` into the worktree.
6. Spawns the new container with the new adapter; PTY scrollback ring is preserved client-side via the standard reconnect snapshot.
7. Broadcasts `status` with `phase: "swapping"` then `phase: "running"`.

The worktree, branch, and git state are **identical** across the swap.

## 5. Image build & versioning

Per-agent Dockerfiles live at `harness/docker/<agent>.Dockerfile`. They are built and tagged as `swekitty/<agent>:latest` and `swekitty/<agent>:v<release>`. The harness pins to `latest` by default; override with `image_tag` field in the TOML for reproducibility.

CI builds these images on every release tag (see `docs/PLAN.md` Part C5). They are NOT pushed to a public registry in v1 — users build locally on first `swe-kitty-harness up` if not present.

## 6. Adding a new agent (post-v1)

1. Drop `agents/<name>.toml`.
2. Drop `harness/docker/<name>.Dockerfile` + matching `entrypoint.sh`.
3. The agent CLI must support a system-prompt mechanism that can be fed by file or stdin — required for handoff. If it doesn't, write a tiny shim wrapper inside the image.
4. No Go or Rust code changes. Registry auto-discovers.
