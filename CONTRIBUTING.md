# Contributing to swe-kitty

This repo is built **under a swe-swe harness**. Whether you are a human or an AI agent (Claude Code, Codex, Gemini, …), the workflow is the same: pick a task brief from `.swe-kitty/tasks/`, get a fresh git worktree, work in isolation, open a PR. Multiple agents can be in flight at once; the frozen contracts in `docs/` keep them from colliding.

## TL;DR

```bash
# one-time
git clone git@github.com:nikhilsh/swe-kitty.git
cd swe-kitty
cp .swe-kitty/env.example .swe-kitty/env   # add your API keys
npm i -g swe-swe                            # or alias swe-swe='npx -y swe-swe'

# every task
swe-swe up                                  # opens http://localhost:1977
#  → spawn a session with your preferred agent
#  → the harness creates a worktree at .swe-kitty/sessions/<uuid>/work
#  → the agent reads .swe-kitty/HANDOFF.html (if any) first
#  → work in that worktree, commit, push the branch
#  → open a PR on GitHub
```

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

When a session is created, the harness writes `HANDOFF.html` into the worktree. **Read it first.** It contains:
- Current task brief
- What previous agents have done
- Open questions
- Last-known-good state

When you stop work (manual exit, agent swap, or harness shutdown), the harness invokes hooks that update `.swe-kitty/memory/sessions/<uuid>.html`. You can edit it directly in your worktree if you need to leave a specific note for the next agent — the harness merges your edits on the next checkpoint.

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
- `harness`: `go vet`, `go test`, `golangci-lint`
- `core`: `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test`
- `ios-build`: compile against iPhone 16 simulator (no signing)
- `android-build`: `./gradlew assembleDebug`

Any agent can self-merge a green PR — `CODEOWNERS` is intentionally empty for now.

## Releases

Tags `v*` trigger three workflows (see [`docs/PLAN.md`](docs/PLAN.md) Part C). Don't tag from a feature branch.

## Style

- **No comments** unless something is non-obvious. Identifiers and types should explain themselves.
- **No future-proofing.** Build for the current contract; the next contract change comes with its own PR.
- **Match upstream where possible.** WebSocket framing is byte-identical to swe-swe. Build scripts mirror litter's shape. Don't reinvent terminals — use SwiftTerm / termux-terminal-view.
