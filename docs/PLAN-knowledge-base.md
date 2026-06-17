# PLAN: Cross-agent knowledge base (Phase 0)

## Problem

Agent knowledge in this repo is fragmented in three ways:

1. **Memory-only facts.** 46 Claude-session memory files (at
   `~/.claude/projects/.../memory/`) are invisible to Codex and to human
   contributors. Durable facts — the UniFFI checksum trap, the IS_SANDBOX root
   requirement, the Sentry quota diagnosis — live in one agent's memory and are
   lost the moment the session compacts or a different agent picks up the task.

2. **Doc contradiction.** Existing docs reference the same facts in
   slightly-different ways (e.g. `docs/BROKER-REDEPLOY.md` pre-dates systemd;
   `CLAUDE.md` has the authoritative update but the runbook still describes
   `pkill`). Roughly 10 live contradictions. No mechanism surfaces them.

3. **No shared layer.** Claude reads `CLAUDE.md` + its memory; Codex reads
   `AGENTS.md`. There is no cross-agent store. What Claude learns Monday, Codex
   does not know Tuesday.

The goal is a git-tracked knowledge base any agent (Claude or Codex) and any
human can reliably consult.

## The two hard problems

Storage is not hard. Two things are:

**1. Cross-agent discovery.** Claude and Codex bootstrap from different context
files. Neither will consult a file they are not told about. The only common
authoritative layer that reaches both agents is the conduit broker's
`conduitprompt.go` injection: it already normalizes a "conduit awareness" block
into BOTH agents at session spawn — claude via `--append-system-prompt`, codex
via `upsertConduitAwarenessSection` into the workspace's `AGENTS.md`. Extending
that injection is the unlock.

**2. Reliable consultation.** An index in the system prompt is useless if the
agent never reads it. The index must be short enough to scan (one line per
entry), the "how to read more" instruction must be in the injected block, and a
per-turn relevance hook must surface the right entries when the user's message
touches a known-footgun topic.

## The key existing seam

`broker/internal/session/conduitprompt.go` — verified present on `origin/main`.

It injects a normalized block into every session:
- Claude: `--append-system-prompt` flag (wired in `claudechat.go`).
- Codex: `upsertConduitAwarenessSection` writes a managed section in the
  workspace's `AGENTS.md` (handled in `manager.go`; logged via
  `logConduitAwarenessInjected`).

The KB generalizes what this block's payload carries.

## Architecture

### Layer 1 — Store: `knowledge/`

Git-tracked directory at repo root. Each entry is an atomic markdown file with
YAML frontmatter (`title`, `tags`, `scope`, `source`, `status`). A generated
`knowledge/INDEX.md` carries one-line summaries. This mirrors the proven
pattern in `docs/MEMORY-FORMAT.md`: index first, open only what you need.

Phase 0 is static — files written by humans/agents, committed normally.
Phase 1 adds a `conduit kb` CLI that appends entries programmatically.

### Layer 2 — Discovery/injection

Extend `conduitprompt.go` to include the KB INDEX content + query instructions
in the injected block. Both agents receive it at spawn. No agent-specific
wiring needed beyond what already exists.

Phase 2 adds a per-turn relevance hook: broker greps the KB on the incoming
user prompt and prepends the top-matching entry summaries (not full content)
ahead of the turn.

### Layer 3 — Retrieval

Index-then-open: the agent reads INDEX.md (from the injected block) and shells
out to `cat knowledge/<ENTRY>.md` for the full entry. No special tool required
in Phase 0.

Phase 1 ships a `conduit kb` subcommand (broker binary) with:
- `conduit kb list` — print the index
- `conduit kb get <slug>` — print one entry
- `conduit kb search <terms>` — grep titles + tags
- `conduit kb add <title> [--tags] [--scope]` — append a new entry (with
  write-path checks: dedup, schema validation, secret scrub, contradiction
  detection → staging on conflict; index sync)

Phase 3 adds MCP tool exposure and optional embedding-based search when grep
stops scaling.

### Layer 4 — Quality gates

- `kb lint` (Phase 2, CI): no orphan entries (every file in `knowledge/`
  appears in `INDEX.md`), index in sync, frontmatter schema valid,
  contradictions flagged.
- Write-path checks on `kb add`: dedup against existing entries, secret-pattern
  scrub (Bearer/token/key regexes), contradiction detection (same key facts
  different values → staging, not auto-commit).

## Product integration (user boxes — Phase 3)

The above covers the conduit repo itself (dogfood). Shipping to users' boxes
requires additional design:

**Overlay, never replace.** On first run, scan the user's workspace for
existing knowledge sources (README, docs/, ADRs, their `CLAUDE.md`,
`AGENTS.md`, `.cursor/rules`) and index them as *registered pointers* with
generated summaries. Zero migration, useful day one.

**Two tiers:**
- Registered sources — pointers only; conduit never edits the user's files.
- Native entries — structured `knowledge/*.md` files agents auto-append.

**Privacy/git hygiene.** Agent-written entries default to
`.conduit/knowledge/` (gitignored, box-local). User opts in to promote to
tracked `knowledge/` (PR-reviewed). `kb add` scrubs/blocks secret-looking
content before writing. Auto-commit to the user's repo never happens.

**Transparency.** The mobile app adds a "Knowledge" view per box (precedent:
the app already renders memory HTML per `docs/MEMORY-FORMAT.md`) with
edit/delete/promote-to-repo actions.

**Why conduit specifically.** Conduit is the only layer that spans
agents + sessions + devices. What Claude learns on a box Monday, Codex knows
Tuesday; box discoveries are queryable from the phone. No standalone CLI can do
this.

**Highest-leverage improvement.** Contradiction detection turns stale docs into
flagged work items. Closing-the-loop: when an agent writes a new entry, conduit
can offer to open a PR against the user's real docs with the learned fact.

## Phased plan

| Phase | Scope | Gate |
|-------|-------|------|
| 0 | Seed `knowledge/` (this PR) + PLAN doc. Static files, no tooling. | Merge to main. |
| 1 | `conduit kb` CLI subcommand + extend `conduitprompt.go` injection + write-path checks. Gated to the conduit workspace (dogfood only). | Broker CI green + local gates. |
| 2 | Per-turn relevance hook + contradiction check + `kb lint` CI step. | Lint in CI. |
| 3 | Product rollout to user boxes: registered-sources ingest, `.conduit/knowledge/` default, app Knowledge view, MCP tool, embeddings search. | Device verify. |

## Acceptance criteria for Phase 0 (this PR)

- [ ] `docs/PLAN-knowledge-base.md` exists (this file).
- [ ] `knowledge/INDEX.md` exists with one-line summaries for each entry,
      grouped by area, plus pointer sections for living process / runbooks /
      protocol contracts.
- [ ] Each entry file in `knowledge/` has valid YAML frontmatter and
      stands alone as a self-contained reference.
- [ ] No existing file edited.
- [ ] No `AGENTS.md` committed.
- [ ] `git ls-remote origin kb-foundation` SHA equals local HEAD.

## Open questions / risks

- **Context bloat.** If the index grows to 200+ entries, injecting it raw
  inflates every session's context. Mitigation: cap the injected index to a
  ranked subset; full list available via `conduit kb list`. Monitor injection
  size as the index grows.
- **Drift/noise from auto-append.** Agents may write redundant or subtly
  wrong entries. Mitigation: write-path dedup + lint + human-review gate for
  promotion to tracked `knowledge/`.
- **Secrets.** Agents may include tokens or keys in learned entries. Mitigation:
  scrub regex on `kb add`; `.conduit/knowledge/` gitignored by default.
- **Store location.** The conduit-repo `knowledge/` is for shared repo facts.
  User box-local facts go to `.conduit/knowledge/`. The two are separate and
  must not be conflated.
- **`conduit kb` binary delivery.** Subcommand of the broker binary is the
  simplest path (already on every box via bootstrap). Alternative: standalone
  script in `scripts/`.
