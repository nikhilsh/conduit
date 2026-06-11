# Harness bootstrap

The marquee differentiator: agents that **know** they run under Conduit, plus a
one-tap **"Set up agent harness"** affordance for a user's project. Two
deliberately separable parts so the safer half can merge alone.

- **Part A (broker)** — a concise "conduit-awareness" system-prompt addendum
  injected into every spawned agent. Behavior-changing → **REVIEW before
  merge**; gated by a kill-switch env (default ON).
- **Part B (apps + small broker endpoint)** — a tasteful, dismissible chip in
  the new-session directory picker that seeds a curated bootstrap prompt when
  the chosen folder lacks both CLAUDE.md and AGENTS.md. App-only behavior +
  one read-only broker endpoint → lower risk.

## Part A — conduit-awareness system prompt

### What it says

A single source string (`conduitAwarenessPrompt()` in
`broker/internal/session/conduitprompt.go`) tells the agent it runs under
Conduit and how to **use** the affordances it already has:

- bind dev servers to `$PORT` / `$CONDUIT_PREVIEW_PORT` — Conduit
  reverse-proxies them so the user previews on their phone;
- files the user sends arrive under `uploads/<session>/` in the cwd;
- use the **AskUserQuestion** tool for interactive choices (renders as tappable
  cards, waits for the answer; prose questions don't pause the turn);
- durable notes/handoff live under `.conduit/memory/`.

One builder → both agents share exact wording. ASCII-only (it rides claude's
command line — no curly quotes / em-dashes; a test enforces this).

### Injection mechanism + the claude/codex asymmetry

| Agent | Mechanism | Why |
|-------|-----------|-----|
| **claude** | **Merged into the existing `--append-system-prompt`** value (`claudeAppendSystemPrompt()` = `askUserQuestionNudge` + the addendum, one flag). | claude already injects a system-prompt addendum (the askUserQuestion nudge). We extend, never clobber it — still a single `--append-system-prompt`. |
| **codex** | **Managed section written into `<workspace>/AGENTS.md`** (`upsertConduitAwarenessSection`), injected from `startChatBackend` when the protocol is codex. | codex has **no clean append-system-prompt flag**. The app-server `thread/start` params carry no base-instructions field. codex reads `AGENTS.md` from cwd natively, so an AGENTS.md section is the cleanest path — and it covers **both** the app-server and the exec-fallback backends. |

The AGENTS.md write is **idempotent**: the block is fenced with
`<!-- BEGIN/END CONDUIT AWARENESS (managed by Conduit) -->` and upserted in
place, so re-spawns/reconnects don't accumulate copies or churn the workspace's
git status. A write failure is logged and never blocks the spawn.

**Asymmetry caveat:** the codex path mutates a file in the user's working tree
(AGENTS.md). For a repo with no AGENTS.md this creates one; if the user already
has AGENTS.md, a managed section is appended/updated. claude's path touches no
files. This is documented for reviewer awareness — if file-touch is undesired
for codex, the kill-switch turns the whole feature (both agents) off.

### Flag / default decision

**Default ON, with a kill-switch env** `CONDUIT_HARNESS_AWARENESS`. Set it to a
falsey value (`0`/`off`/`false`/`no`/`disable[d]`) to disable injection for
both agents with **no code change** — the off path is byte-identical to the
pre-feature argv (a test pins this).

Justification for ON-by-default:

- The addendum is purely **additive/informational** — it describes affordances
  the agent already has; it changes no flags or permissions.
- There is direct **precedent**: claude already injects the askUserQuestion
  nudge unconditionally via the same flag.
- The marquee value ("agents that know they run under Conduit") only lands if
  it's on by default.

Because it nonetheless changes **every session's** system prompt, the PR is
marked REVIEW-only and the kill-switch is the reviewer's one-line off-ramp.

### Relationship to the on_start hook (WS-0.4)

The `on_start` adapter hook (now invoked, WS-0.4) runs an arbitrary command
after spawn — it's the right place for *side effects* like `conduit memory
render`. Part A is **prompt content**, not a side effect, so it rides the
existing injection seams (claude's append flag / codex's AGENTS.md) rather than
on_start. They're complementary: on_start could later scaffold `.conduit/`
while the awareness prompt teaches the agent to use it.

### Observability

`logConduitAwarenessInjected(sessionID, agent, mechanism)` emits a structured
log line each spawn (the broker has no direct Sentry client; box logs are the
breadcrumb). Mechanism is `claude:append-system-prompt` or `codex:AGENTS.md`.

### Tests

`conduitprompt_test.go` table-tests: kill-switch semantics, prompt content +
ASCII-only, the claude merge (off = legacy byte-identical / on = both present),
the AGENTS.md upsert (insert/append/idempotent/replace-in-place), and the codex
protocol predicate. The existing claude argv golden now asserts against
`claudeAppendSystemPrompt()` (the single source of truth).

## Part B — "Set up agent harness" chip

### Detection

`/api/fs/list` (the picker's existing call) is **dirs-only** — it can't surface
files. So a new lightweight read-only endpoint:

`GET /api/fs/harness-status?path=<dir>` →
`{ has_claude_md, has_agents_md, has_harness }` (`has_harness = either present`).

### UX

In the new-session directory picker (iOS `ConduitUI.DirectoryPicker`, Android
`DirectoryStep`), after each listing the app fetches harness-status for the
resolved path. When `has_harness == false` (BOTH absent) it shows a tasteful,
dismissible chip ("Set up agent harness") in the action bar. Honest,
non-nagging: only when both files are absent, and an x hides it for the session.
A status fetch failure leaves the chip hidden (default = don't nag).

Tapping seeds the session's `initialPrompt` with the curated bootstrap prompt
(`SessionStore.harnessBootstrapPrompt` / `HARNESS_BOOTSTRAP_PROMPT`):

> Audit this repository … identify the real build/test/lint commands (don't
> guess) and verify each runs … write a concise CLAUDE.md + AGENTS.md with the
> verified gate commands … propose CI gates. Ask before committing.

…and starts the session cd'd into that folder. It **reuses the existing
initialPrompt seeding** (the voice-transcript path): the picker's `onCreate`
gained a 5th `seedPrompt` arg; a chip tap passes the bootstrap prompt, normal
starts pass nil and fall back to the sheet's `initialPrompt`.

### Files

- broker: `internal/ws/fs.go` (endpoint), `internal/ws/server.go` (route),
  `internal/ws/api_test.go` (tests).
- iOS: `SessionStore.swift` (`RemoteHarnessStatus`, `harnessStatus(path:)`,
  `harnessBootstrapPrompt`), `ConduitUI/Views/ConduitAgentPickerSheet.swift`
  (chip + onCreate seed arg).
- Android: `SessionStore.kt` (`RemoteHarnessStatus`, `harnessStatus`,
  `HARNESS_BOOTSTRAP_PROMPT`, `connectAndStart` initialPrompt),
  `ui/AgentPickerSheet.kt` (`HarnessChip` + onCreate seed arg).

## Unknowns / follow-ups

- **On-device verification needed** for both app UIs (CI is compile + unit only;
  the chip render, fetch timing, and seeded-first-turn behavior are unverified
  on a device).
- **codex AGENTS.md provenance**: confirm on a device that codex actually reads
  the workspace AGENTS.md under the app-server backend (it does for the CLI; the
  app-server should inherit cwd, but verify the section influences behavior).
- **AGENTS.md git churn**: the managed section is created in the working tree;
  for a clean repo this is a new untracked file. Acceptable for the harness
  use-case, but worth a device sanity check that it doesn't surprise users.
- Consider surfacing the kill-switch / a per-session opt-out in the app if
  reviewers want a UI toggle rather than a broker env.
