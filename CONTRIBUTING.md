# Contributing to swe-kitty

This repo is **built under its own broker**. Whether you are a human or an AI agent (Claude Code, Codex, Gemini, …), the workflow is the same: pick a task brief from `.swe-kitty/tasks/`, get a fresh git worktree, work in isolation, open a PR. Multiple agents can be in flight at once; the frozen contracts in `docs/` keep them from colliding.

## TL;DR

```bash
# one-time
git clone git@github.com:nikhilsh/swe-kitty.git
cd swe-kitty
cp .swe-kitty/env.example .swe-kitty/env   # add your API keys

# every task
make broker && ./broker/bin/swe-kitty-broker up --local   # opens http://localhost:1977
#  → spawn a session with your preferred agent
#  → the broker creates a worktree at .swe-kitty/sessions/<uuid>/work
#  → the agent reads .swe-kitty/HANDOFF.html (if any) first
#  → work in that worktree, commit, push the branch
#  → open a PR on GitHub
```

> **Historical note:** earlier versions of this guide pointed at `npm i -g swe-swe` for the dev workflow. swe-kitty has since absorbed everything it needed from that prior art and now ships its own broker binary (`swe-kitty-broker`). Don't install or run upstream swe-swe alongside — its `/swe-swe-auth/login` redirect breaks our bearer-only client. See `docs/SELF-HOST.md`.

## Picking a task

`.swe-kitty/tasks/` contains numbered task briefs. Each is self-contained:
- **Scope** — what to build, what NOT to build
- **Contract refs** — which `docs/*.md` files to treat as ground truth
- **Files** — paths to touch (whitelist)
- **Done means** — verification command + criterion

Claim a task by renaming `001-foo.md` → `001-foo.claimed-by-<agent-name>.md` in your worktree's commit. If two agents claim the same task, second-to-merge rebases and picks another.

## Frozen contracts

These four documents are the source of truth across all parallel work. **Do not change them in a task PR** — they're amended only by their own deliberate PRs that all in-flight agents must rebase onto.

1. [`docs/WEBSOCKET-PROTOCOL.md`](docs/WEBSOCKET-PROTOCOL.md) — wire format
2. [`docs/AGENT-ADAPTERS.md`](docs/AGENT-ADAPTERS.md) — how agents are spawned and swapped
3. [`docs/MEMORY-FORMAT.md`](docs/MEMORY-FORMAT.md) — the HTML schema for inter-agent handoff
4. [`docs/SESSION-LIFECYCLE.md`](docs/SESSION-LIFECYCLE.md) — checkpoints, watchdogs, recovery

## Memory / handoff

When a session is created, the broker writes `HANDOFF.html` into the worktree. **Read it first.** It contains:
- Current task brief
- What previous agents have done
- Open questions
- Last-known-good state

When you stop work (manual exit, agent swap, or broker shutdown), the broker invokes hooks that update `.swe-kitty/memory/sessions/<uuid>.html`. You can edit it directly in your worktree if you need to leave a specific note for the next agent — the broker merges your edits on the next checkpoint.

Project-wide knowledge (architecture decisions, "do not do X") lives in `.swe-kitty/memory/index.html` and is committed to git. Promote useful per-session findings up to it via:
```bash
swe-kitty memory promote --session <uuid> --decision <id>
```

## Branch + commit conventions

- Branch name: `agent/<agent-name>-<task-id>` (e.g., `agent/claude-002-rust-core`)
- Commit subject: imperative, ≤72 chars, references task ID (`002: add WebSocket transport`)
- One PR per task brief; small follow-ups okay; do not bundle unrelated work
- Rebase before opening PR if `main` has moved

## CI gates

PRs must pass `.github/workflows/ci.yml`:
- `broker`: `go vet`, `go test`, `golangci-lint`
- `core`: `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test`
- `ios-build`: compile against iPhone 16 simulator (no signing)
- `android-build`: `./gradlew assembleDebug`

Any agent can self-merge a green PR — `CODEOWNERS` is intentionally empty for now.

## Releases

Tags `v*` (and `workflow_dispatch -f release_tag=…` from `release.yml`) trigger one reusable-workflow DAG that fans out to `ios`, `android`, `broker`, then deploys the website. See [`docs/RELEASE.md`](docs/RELEASE.md). Don't tag from a feature branch.

## Style

- **No comments** unless something is non-obvious. Identifiers and types should explain themselves.
- **No future-proofing.** Build for the current contract; the next contract change comes with its own PR.
- **Standalone product.** swe-kitty has its own wire shape, its own auth, its own apps, and its own release pipeline. Don't reach for upstream `swe-swe` semantics (cookie auth, browser UI, etc.) — they were prior art, not a contract. Don't reinvent terminals though: `SwiftTerm` on iOS, `termux-terminal-view` on Android.
