# Task 006 — Agent adapters: Claude + Codex Dockerfiles + registry

## Scope
The production-side agent adapters (lives at repo-root `agents/`, separate from dev-time `.conduit/agents/`). Make `switch_agent` work end-to-end.

**In scope:**
- `agents/claude.toml`, `agents/codex.toml` — production adapter contracts (see `docs/AGENT-ADAPTERS.md`)
- `harness/docker/claude.Dockerfile` — image `conduit/claude:latest`. Installs `claude` CLI. Entrypoint reads `/workspace/HANDOFF.html` and passes it as system-prompt prefix.
- `harness/docker/codex.Dockerfile` — image `conduit/codex:latest`. Installs OpenAI `codex` CLI. Entrypoint pattern same as claude.
- `harness/internal/agents/registry.go` — loads `agents/*.toml`, validates, returns adapter for assistant param
- `harness/internal/session/manager.go` — call into registry when spawning containers
- Plumb the `switch_agent` JSON control message: kill container, re-spawn with new adapter, keep PTY + worktree + scrollback (handoff details = task 005)

**Out of scope:**
- Full handoff round-trip (task 005)
- Gemini, Aider, Goose, OpenCode adapters (post-v1)

## Frozen contracts
- `docs/AGENT-ADAPTERS.md`

## Done means
- `docker build -t conduit/claude:latest -f harness/docker/claude.Dockerfile .` succeeds; same for codex
- `wscat` → `{"type":"switch_agent","assistant":"codex"}` swaps the container; PTY scrollback is preserved client-side via snapshot
- Registry rejects unknown assistants with a clear error
- `ci.yml` lint+test still green

## Files allowed
- `agents/*.toml`
- `harness/internal/agents/**`
- `harness/docker/**`
- `harness/internal/session/manager.go` (minimal additions)

## Branch
`agent/<your-name>-006-agent-adapters`
