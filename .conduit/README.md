# `.conduit/` — dev harness state for *this* repo

This directory is read by **`conduit-harness`** so multiple AI agents can
work on conduit in parallel, each on its own git worktree, each in its
own PTY-backed container.

> Earlier iterations of this README pointed at upstream `swe-swe` for the
> dev workflow. conduit now ships its own harness binary and is no
> longer a swe-swe consumer. Don't install upstream swe-swe alongside.

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

- `.conduit/agents/` — what the harness reads when working **on this repo**
  (dev-time). These TOMLs are tuned for the agents that work on conduit
  itself.
- `agents/` (repo root) — what `conduit-harness` ships **to users**. End
  users get this set when they run the harness against their own project.

These are intentionally separate so a change to dev-time tooling never
breaks the shipped product.

## Bootstrapping a parallel session

```sh
cp env.example env                              # fill in your API keys
make harness                                    # build ./harness/bin/conduit-harness
./harness/bin/conduit-harness up --local      # opens http://localhost:1977
```

In the local UI (or the mobile app, paired via the printed QR):

1. New session → pick agent → pick a task brief from `tasks/`.
2. Worktree is created under `sessions/<uuid>/work/`. `HANDOFF.html` lands at its root.
3. Work, commit, push branch, open PR. Multiple agents can run in parallel — the frozen contracts in `docs/` keep them from colliding.
