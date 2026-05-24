# Agent adapters (frozen contract v1)

How an arbitrary CLI coding agent (Claude Code, Codex, Gemini, Aider, Goose, OpenCode, …) is integrated into swe-kitty so that all such agents are **interchangeable** end-to-end — including mid-session swap with state preservation.

Two physical locations on disk:

- `.swe-kitty/agents/*.toml` — dev-time, read by `swe-kitty-broker` when working on this repo
- `agents/*.toml` — production, read by `swe-kitty-broker` when running the shipped product

The TOML schema is the same; only the consumers differ.

## 1. TOML schema

```toml
name             = "claude"                              # required; matches ?assistant=
command          = ["claude"]                            # required; the CLI to exec
args             = ["--dangerously-skip-permissions"]    # optional; appended to command
env_passthrough  = ["ANTHROPIC_API_KEY"]                 # env keys to forward from host
workdir          = "/workspace"                          # required; fallback cwd (a per-session worktree is used when available)
chat_event_port_env = "AGENT_CHAT_PORT"                  # optional MCP bridge port var

[hooks]
on_start = "swe-kitty memory render --session $SESSION_UUID > .swe-kitty/HANDOFF.html"
on_exit  = "swe-kitty memory checkpoint --session $SESSION_UUID --reason 'exit'"
on_swap  = "swe-kitty memory handoff --session $SESSION_UUID --from $FROM_AGENT --to $TO_AGENT"
```

Required fields: `name`, `command`, `workdir`. Everything else has a documented default. (A legacy `image` field is still accepted but ignored — see §2.)

## 2. Process model

**The broker runs directly on the host and spawns each agent as a child
process** — no Docker, no containers. Per-session isolation comes from a
per-session git **worktree**, a per-session ephemeral **`$HOME`**, and the
per-session **PTY/process tree** — not from any container boundary.

The broker may run as **root**: it sets `IS_SANDBOX=1` for the agents it
spawns, which is what lets Claude Code accept
`--dangerously-skip-permissions` under root (it otherwise refuses). See
`docs/SELF-HOST.md` for install + run, and `PLAN-DEVICE-BUGS-2026-05-24.md`
for why this replaced the old "run as a non-root container user" approach.

> A legacy `image` field may still appear in older TOMLs; it is parsed but
> **ignored** (the broker `pty.Start`s `command`, it never `docker run`s).

### 2.1 What the host needs
- `swe-kitty-broker` binary (the Go server), installed via `install.sh`.
- Every agent CLI you ship a TOML adapter for (e.g. `claude`, `codex`) on
  `PATH`. See `docs/SELF-HOST.md` for host install (Anthropic apt repo /
  native installer for claude; `npm i -g @openai/codex` for codex).
- `git`, `bash`, `jq`, `curl`, `openssl` on `PATH`.

### 2.2 Per-session filesystem
- **Working directory** — a per-session git worktree (or the adapter's
  `workdir` / a requested `cwd`). One of the three persistence rails in
  `docs/SESSION-LIFECYCLE.md §1`.
- **Ephemeral `$HOME`** — each spawn gets a private `$HOME`
  (`<workspace>/.swe-kitty/agent-home/<session-id>`) seeded with the host's
  agent credentials, so concurrent agents don't race on OAuth refresh
  (`broker/internal/session/lifecycle.go`).

### 2.3 Environment variables the broker sets per-session
The broker spawns each agent as a child process via
`pty.Start(exec.Command(adapter.Command[0], …))` from
`broker/internal/session/lifecycle.go`. Each spawn gets:

| Var | Value |
|---|---|
| `SESSION_UUID` | session id |
| `AGENT_NAME` | adapter name |
| `IS_SANDBOX` | `1` — lets claude accept `--dangerously-skip-permissions` under root |
| `HOME` | the per-session ephemeral agent home |
| `PORT` | preview port (3000–3019) |
| `AGENT_CHAT_PORT` | `PORT + 1000` — for MCP `view_event` bridge |
| `KITTY_HANDOFF_PATH` | `<worktree>/.swe-kitty/HANDOFF.html` |
| `KITTY_HANDOFF_OUT_PATH` | `<worktree>/.swe-kitty/HANDOFF-OUT.html` |
| `FROM_AGENT` / `TO_AGENT` | only set inside `on_swap` |
| `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` | from the broker's env / `.swe-kitty/env` (empty values are stripped so they don't clobber OAuth fallback) |
| ... | plus any KEY=VALUE from `.swe-kitty/env` with `$VAR` expansion |

### 2.4 Agent process expectations

Every adapter's `command` + `args` from `agents/*.toml`:

1. **Read `$KITTY_HANDOFF_PATH` first.** If non-empty, prepend its contents to the agent's system prompt.
   - Claude Code: `claude --system-prompt-file "$KITTY_HANDOFF_PATH"`
   - Codex: pass via Codex's prompt-prefix mechanism
2. **Trap `SIGUSR1`.** On receipt, write a final structured summary to `$KITTY_HANDOFF_OUT_PATH` and exit cleanly. This is how the broker initiates an atomic agent swap.
3. **Run the agent CLI in foreground** so PTY connects directly. No `tail -f` wrappers.

## 3. Hooks

Hooks run on the **broker host** so they have access to the persistence rails (scrollback ring, memory HTML, git worktree).

| Hook | When | Available env |
|---|---|---|
| `on_start` | After the agent process is spawned, before PTY is exposed to clients | `SESSION_UUID`, `AGENT_NAME` |
| `on_exit` | After the agent process exits (any reason: clean, crash, SIGKILL) | `SESSION_UUID`, `AGENT_NAME`, `EXIT_CODE` |
| `on_swap` | After the old agent process exits, before the new one starts | `SESSION_UUID`, `FROM_AGENT`, `TO_AGENT` |

Hooks must be idempotent — recovery (`docs/SESSION-LIFECYCLE.md` §4) may invoke them again after a crash.

## 4. Agent swap mechanics

Triggered by `{"type":"switch_agent","assistant":"<new>"}` JSON control message. The broker:

1. Sends `SIGUSR1` to the running agent process; waits up to 30s for `$KITTY_HANDOFF_OUT_PATH` to land.
2. If it does, parses it as memory HTML and merges its `data-section="handoff"` into the session memory file. If it doesn't, falls back to the last memory checkpoint.
3. Sends `SIGTERM` (10s grace, then `SIGKILL`) to the old agent process.
4. Runs `on_swap` hook.
5. Renders fresh `HANDOFF.html` into the worktree.
6. `pty.Start`s the new agent process in the same worktree; PTY scrollback ring is preserved client-side via the standard reconnect snapshot.
7. Broadcasts `status` with `phase: "swapping"` then `phase: "running"`. On spawn failure the broker still flips back to `running` with `reason_code: "agent_switch_failed"` so the mobile UI doesn't get stuck (regression fixed 2026-05-20).

The worktree, branch, and git state are **identical** across the swap.

## 5. Distribution

The broker ships as a single static Go binary (`swe-kitty-broker`), built
per release and attached to the GitHub Release (linux/darwin × amd64/arm64).
Install it with `install.sh` and run it on the host — there is no container
image. See `docs/SELF-HOST.md`.

## 6. Adding a new agent

1. Install the agent CLI on the broker host's `PATH`.
2. Drop `agents/<name>.toml` with the right `command` / `args` / handoff flags.
3. The agent CLI must support a system-prompt mechanism that can be fed by
   file or stdin — required for handoff. If it doesn't, write a tiny shim
   script on `PATH`.
4. No Go or Rust code changes, and no rebuild. The registry auto-discovers
   the TOML on the next broker start.
