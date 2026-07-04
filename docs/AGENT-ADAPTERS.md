# Agent adapters (frozen contract v1)

How an arbitrary CLI coding agent (Claude Code, Codex, Gemini, Aider, Goose, OpenCode, …) is integrated into conduit so that all such agents are **interchangeable** end-to-end — including mid-session swap with state preservation.

Two physical locations on disk:

- `.conduit/agents/*.toml` — dev-time, read by `conduit-broker` when working on this repo
- `agents/*.toml` — production, read by `conduit-broker` when running the shipped product

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
on_start = "conduit memory render --session $SESSION_UUID > .conduit/HANDOFF.html"
on_exit  = "conduit memory checkpoint --session $SESSION_UUID --reason 'exit'"
on_swap  = "conduit memory handoff --session $SESSION_UUID --from $FROM_AGENT --to $TO_AGENT"
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
`docs/SELF-HOST.md` for install + run, and `docs/ROADMAP.md` "Direction &
decisions" for why this replaced the old "run as a non-root container user"
approach (detail preserved in `docs/archive/PLAN-DEVICE-BUGS-2026-05-24.md`).

> A legacy `image` field may still appear in older TOMLs; it is parsed but
> **ignored** (the broker `pty.Start`s `command`, it never `docker run`s).

### 2.1 What the host needs
- `conduit-broker` binary (the Go server), installed via `install.sh`.
- Every agent CLI you ship a TOML adapter for (e.g. `claude`, `codex`) on
  `PATH`. See `docs/SELF-HOST.md` for host install (Anthropic apt repo /
  native installer for claude; `npm i -g @openai/codex` for codex).
- `git`, `bash`, `jq`, `curl`, `openssl` on `PATH`.

### 2.2 Per-session filesystem
- **Working directory** — a per-session git worktree (or the adapter's
  `workdir` / a requested `cwd`). One of the three persistence rails in
  `docs/SESSION-LIFECYCLE.md §1`.
- **Ephemeral `$HOME`** — each spawn gets a private `$HOME`
  (`<workspace>/.conduit/agent-home/<session-id>`) seeded with the host's
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
| `IS_SANDBOX` | `1` — lets claude accept `--dangerously-skip-permissions` under root. **Must also be set for one-shot helper invocations** (e.g. recap via `recapEnv`): `claude --dangerously-skip-permissions` is refused under root when `IS_SANDBOX` is absent. CI passes (non-root) while production (root) silently falls back — always include `IS_SANDBOX=1` in any subprocess env that runs `claude`. |
| `HOME` | the per-session ephemeral agent home |
| `PORT` | preview port (3000–3019) |
| `AGENT_CHAT_PORT` | `PORT + 1000` — for MCP `view_event` bridge |
| `KITTY_HANDOFF_PATH` | `<worktree>/.conduit/HANDOFF.html` |
| `KITTY_HANDOFF_OUT_PATH` | `<worktree>/.conduit/HANDOFF-OUT.html` |
| `FROM_AGENT` / `TO_AGENT` | only set inside `on_swap` |
| `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` | from the broker's env / `.conduit/env` (empty values are stripped so they don't clobber OAuth fallback) |
| ... | plus any KEY=VALUE from `.conduit/env` with `$VAR` expansion |

### 2.4 Agent process expectations

Every adapter's `command` + `args` from `agents/*.toml`:

1. Structured protocols must implement their registered `AgentBackend`.
2. Run foreground processes without `tail -f` wrappers.
3. `$KITTY_HANDOFF_PATH`, `$KITTY_HANDOFF_OUT_PATH`, and `SIGUSR1` are legacy
   compatibility affordances. Production Claude/Codex switching does not
   require a wrapper, signal trap, or handoff-file ingestion.

## 3. Hooks

Hooks run on the **broker host** so they have access to the persistence rails (scrollback ring, memory HTML, git worktree).

| Hook | When | Available env |
|---|---|---|
| `on_start` | After the agent process is spawned, before PTY is exposed to clients | `SESSION_UUID`, `AGENT_NAME` |
| `on_exit` | After the agent process exits (any reason: clean, crash, SIGKILL) | `SESSION_UUID`, `AGENT_NAME`, `EXIT_CODE` |
| `on_swap` | During a switch after target startup is proven, before commit | `SESSION_UUID`, `FROM_AGENT`, `TO_AGENT` |

Hooks must be idempotent. `on_start` and `on_swap` are best-effort: failures are
logged and do not terminate a live session or veto a prepared switch.

## 4. Agent swap mechanics

Triggered by `{"type":"switch_agent","assistant":"<new>"}` JSON control message. The broker:

1. Rejects switching while a turn or pending user decision is active.
2. Generates and persists a bounded handoff from broker-owned conversation and
   workspace state.
3. Starts the target backend using its independently persisted native thread.
4. Atomically commits the target only after startup succeeds; otherwise the old
   backend and metadata remain unchanged.
5. Runs external hooks best-effort, closes the old backend, and invisibly
   prepends the handoff to the target's next normal user prompt.
6. Broadcasts `status` with `phase:"swapping"` then `phase:"running"`.

The worktree, branch, and git state are **identical** across the swap.

## 5. Distribution

The broker ships as a single static Go binary (`conduit-broker`), built
per release and attached to the GitHub Release (linux/darwin × amd64/arm64).
Install it with `install.sh` and run it on the host — there is no container
image. See `docs/SELF-HOST.md`.

## 6. Adding a new agent

1. Install the agent CLI on the broker host's `PATH`.
2. Drop `agents/<name>.toml` with the right `command`, `args`, and `protocol`.
3. Implement/register a structured backend when the protocol is new. The
   broker's prompt handoff is protocol-independent once `chatBackend.Send`
   exists.
4. No Go or Rust code changes, and no rebuild. The registry auto-discovers
   the TOML on the next broker start.
