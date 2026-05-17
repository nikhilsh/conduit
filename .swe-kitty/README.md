# `.swe-kitty/` — dev harness for *this* repo

This directory is **read by upstream [swe-swe](https://github.com/choonkeat/swe-swe)** so multiple AI agents can work on swe-kitty in parallel, each on its own git worktree, each in its own PTY-backed container. Once `swe-kitty-harness` exists, it will read the same files.

## What lives here

| Path | Purpose | Committed to git? |
|---|---|---|
| `config.toml` | Agent roster, port range, task list, watchdog policy | ✅ |
| `env.example` | Template for API keys | ✅ |
| `env` | Real API keys you provide | ❌ (gitignored) |
| `agents/*.toml` | Per-agent dev-time adapter contracts | ✅ |
| `tasks/*.md` | Self-contained task briefs for parallel agents | ✅ |
| `memory/index.html` | Project-wide memory (decisions, conventions) | ✅ |
| `memory/sessions/*.html` | Per-session memory (live state) | ❌ (gitignored) |
| `memory/session-template.html` | Template the harness writes per new session | ✅ |
| `memory/memory.css` | Styles for the HTML, also rendered in mobile browser view | ✅ |
| `sessions/<uuid>/work/` | The per-session git worktree (scratch space) | ❌ (gitignored) |

## Two adapter directories — why?

- `.swe-kitty/agents/` — what swe-swe uses *right now* to build this repo (dev-time)
- `agents/` (repo root) — what `swe-kitty-harness` will use when it runs in production

These are intentionally separate so a change to dev-time tooling never breaks the shipped product.

## Bootstrapping a parallel session

1. `cp env.example env`, fill in keys
2. `swe-swe up`
3. In the swe-swe UI: New session → pick agent → pick a task brief from `tasks/`
4. The worktree is created under `sessions/<uuid>/work`. `HANDOFF.html` lands at its root.
5. Work, commit, push branch, open PR.
