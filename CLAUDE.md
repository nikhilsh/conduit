# CLAUDE.md

Operating principles for Claude agents working in this repo.

| Principle              | Problem It Solves                                       | The One-Liner                                                |
|------------------------|---------------------------------------------------------|--------------------------------------------------------------|
| Think Before Coding    | Wrong assumptions, hidden confusion, missing tradeoffs  | Don't assume. Don't hide confusion. Surface tradeoffs.       |
| Simplicity First       | Overcomplication, bloated abstractions                  | Minimum code that solves the problem. Nothing speculative.   |
| Surgical Changes       | Orthogonal edits, touching code you shouldn't           | Touch only what you must. Clean up only your own mess.       |
| Goal-Driven Execution  | Vague plans with no verification                        | Define success criteria. Loop until verified.                |
| Compose, Don't Hand-Roll | Re-rolled cards/rows/chips; drifting tokens; N-place fixes | Build screens from ConduitUI/Components. Never a raw color/radius literal. |

## Operating model

A one-liner task should run start-to-end without re-explaining cleanliness,
roadmap, subagent choice, or CI-watching. The orchestrator (session model) PLANS
and ORCHESTRATES; opus/sonnet agents EXECUTE. Playbooks: `/ship` (one-liner →
done), `/merge-when-green`, `/cut-release`, `/broker-redeploy`.

**Delegation + model tiers** (`.claude/agents/`; honest roster — model tier was
rarely the failure point, footgun checklists + 1-2 CI round-trips were):
- **opus** — `researcher` (protocol capture / web research / coupling
  inventories) and `architect` (interface/protocol design, risky refactors;
  where a wrong abstraction is expensive AND silent).
- **sonnet** — `broker-engineer`, `app-engineer`, `ci-fixer`, `doc-writer` (the
  bulk; mechanical-but-careful, well-mapped work).
- **orchestrator keeps**: planning, merge-gating, CI-watching, redeploy, tag,
  and TRULY trivial 1-liners (spawning costs more than doing them).
- Cap concurrency ~3 (box RAM). Every agent's scaffold (already in its file):
  verify `pwd` (Bash starts in the SHARED checkout — leaked files twice),
  run gates, **end at push + PR open, do NOT watch CI**.

**CI gating is the orchestrator's job, not the agent's.** Agents end at push+PR.
The orchestrator watches to green and merges using the pending-count pattern:
`gh pr checks <N>` exits NON-ZERO on any failure, so capture with `|| true` and
decide from the OUTPUT (pending/failed counts), **never the exit code** (bit us
twice). **Never `gh pr merge` before reading the failure count** (merged two red
PRs once). Known flakes (rerun, don't fix): ghostty-spm 502/404; broker
conformance_test.go i/o-timeout. See `/merge-when-green`.

**Definition of Done** (every task self-applies before claiming done):
- [ ] local gates green (broker/core); iOS/Android flagged needs-device-verify
- [ ] CI watched to GREEN via the `gh pr checks || true` pending-count pattern
- [ ] pipeline docs updated (ROADMAP/IN-PROGRESS/VERIFY-CHECKLIST/DONE) per the
      roadmap verification pipeline rule below
- [ ] memory updated (new footgun/decision → note + index entry)
- [ ] SHARED checkout clean: no leaked untracked files; finished worktrees
      removed (`git worktree list`)
- [ ] broker redeployed IF `broker/` changed and it must be live (tagging does
      NOT deploy the broker)

**Compaction:** Claude Code has NO automatic new-task detection. Convention:
`/clear` when switching to UNRELATED work (fresh context, cheapest); `/compact`
mid-task to summarize while continuing; add focus via `/compact <instructions>`
or a "Compact instructions" block in this file. Auto-compaction only fires near
the context limit. The SessionStart hook surfaces this reminder. Activate the
harness hooks once with `/hooks`; see `docs/OPERATING-HARNESS.md`.

## Working in this repo

**Standing order: instrument everything that can fail with Sentry breadcrumbs.**
Because mobile is CI-compile-only (below), on-device failures and crashes are
otherwise invisible. For ANY new flow or screen that can fail, drop
`Telemetry.breadcrumb(category, message, data)` at each meaningful step (screen
open, network start/finish/fail, OAuth steps, session create, connect/reconnect,
browser-preview load, file upload, chat send) and a `Telemetry.capture(...)`
ERROR on the failure terminus. Breadcrumbs are lightweight (ring-buffered,
attached to the next event — not a full event each), so scatter them freely.
Use `Telemetry.debug` for runtime state you'll want to read back. Helpers live
in `apps/ios/Sources/Telemetry.swift` and `apps/android/.../Telemetry.kt`. The
goal: the next crash/error is self-diagnosing from Sentry without a device.

**Mobile is CI-compile-only on the dev box.** There is no Mac/Xcode and no
Android SDK on the machine agents run on. Only the Go **broker** (`broker/`) and
Rust **core** (`core/`) are locally buildable/testable. iOS (`apps/ios/`) and
Android (`apps/android/`) changes are verified **only by CI**
(`.github/workflows/ci.yml`): iOS `xcodebuild test` of `ConduitTests`, Android
`./gradlew :app:testDebugUnitTest`, plus both apps build. **CI green means it
COMPILES and unit-tests pass — NOT that the UI/runtime behaves.** Flag any
UI / layout / keyboard / render fix as **"needs on-device verification"** and
don't claim it's fixed until verified on a device. Batch one release per
device-test session.

**CI gate commands** (run locally before pushing what you can):

- broker: `cd broker && gofmt -l . && go vet ./... && go test ./...`
- core: `cd core && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`
- Android: `cd apps/android && ./gradlew :app:testDebugUnitTest` (needs the SDK
  plus generated UniFFI bindings — CI does this; can't run on the dev box).
- iOS: CI-only (no local toolchain).

**Broker ops footguns:**

- **Never `pkill -f 'conduit-broker'`** — the pattern matches the shell
  running it, so you kill your own process. Kill by **PID**.
- Redeploy via atomic `mv`, **never `cp`** (`cp` over the running binary →
  `ETXTBSY`). Relaunch **from `/root`** (cwd matters — a worktree cwd picks up a
  stale `./agents` dir).
- Pin `CONDUIT_TOKEN` to the **current** token or every reup mints a fresh one
  and forces both devices to re-pair. Full procedure: `docs/BROKER-REDEPLOY.md`.

**Releases** are tag-triggered (`.github/workflows/release.yml`). **Always cut
tags from a freshly-fetched `origin/main`** — use `scripts/cut-release.sh
vX.Y.Z`, which refuses to tag a commit that isn't `origin/main`'s tip. A stale
local `main` once shipped old code under a new tag (v0.0.35) and burned a device
cycle; the About screen shows the git SHA to catch this.

**Known CI flakes — rerun, don't "fix":**

- libghostty-spm xcframework download can 502/404 on the iOS build. A 404 means
  the upstream `storage.*` release was deleted — see the pin note in
  `scripts/fetch-ghostty-kit-xcframework.sh` / `docs/ROADMAP.md`.
- `broker/internal/ws/conformance_test.go` occasionally i/o-timeouts.

Re-run the job before touching either.

**Worktree & branch hygiene:**

1. **Reset to fresh origin/main before starting any task** — always branch off
   a fetch: `git fetch origin && git checkout -B <branch> origin/main`. Never
   start work on a stale local branch; stale main once shipped old code (v0.0.35).
2. **Delete the worktree + branch after its PR merges** — `git worktree remove
   --force <path>`, `git branch -D <branch>`, `git worktree prune`. Note:
   `gh pr merge --delete-branch` silently fails to delete the local branch when
   a worktree holds it (merge still succeeds). Squash-merged branches are NOT
   ancestors of main, so `git merge-base --is-ancestor` can't detect them as
   merged — key off the PR being merged (e.g. `gh pr view --json state`).
3. **Always give implementer agents their own worktree.** An agent without an
   isolated worktree commits into the shared checkout and leaks files (bit us
   twice).
4. **Verify the push landed.** Agent-tool `isolation:worktree` has silently left
   the remote at a stale commit (work lost, #645 124k tokens). After any agent
   push, confirm with `git ls-remote origin <branch>` or `gh pr view --json
   files` before trusting the result.

**Roadmap verification pipeline** — four docs, four states:

1. **ROADMAP.md** — backlog only. When starting work: cut from backlog, add an
   entry to **IN-PROGRESS.md** with branch + PR#.
2. **IN-PROGRESS.md** — actively building. On merge: move the entry to the
   single **Next release (pending)** section at the top of
   **VERIFY-CHECKLIST.md** — do NOT mint a new `vX.Y.Z` heading. Merged ≠
   released: everything merged between two tags ships together in the next tag,
   so it accumulates under that one pending heading (minting a version per merge
   is what produced the phantom v0.0.205–211 headings while only v0.0.204 was
   live). The real version is stamped only when `/cut-release` cuts the tag —
   it renames **Next release (pending)** to `vX.Y.Z` and opens a fresh empty
   pending section. Remove the merged worktree + branch (`git worktree remove
   --force`, `git branch -D`, `git worktree prune`).
3. **VERIFY-CHECKLIST.md** — **Next release (pending)** holds merged-not-yet-
   released items; the versioned sections below it are released, awaiting owner
   on-device verification. When the owner verifies: move to **DONE.md**.
4. **DONE.md** — verified complete. Nothing moves backwards.

Do the doc move as part of the work (ship playbook, merge-when-green, or
cut-release step). Never call a feature "done" until it is in DONE.md.
CI green means it compiles — it does NOT mean device-verified (mobile is
CI-compile-only).

**Commit style:** a single tight subject line. No body, no `Co-Authored-By`
trailer.

## Design: compose from the component library

Every screen is built from the shared component library — never raw
`VStack`/`Column` + literal colors, never a hand-rolled card/row/chip/button.

- **iOS** is the source of truth: `apps/ios/Sources/ConduitUI/Components/`
  (`Card`, `ListRow` + `navRow`/`valueRow`/`toggleRow`, `Chip`, `PillButton`,
  `StatTile`, `Button`, `Header`, `ConduitMark`). Surfaces are Liquid Glass
  (`conduitGlass*`); tokens come from `ConduitUI.Palette` + `@Environment(\.neonTheme)`.
- **Android** mirrors it value-for-value in `apps/android/.../ui/components/`,
  built on `Glass.kt` (`glass*` modifiers) + `LocalNeonTheme`. No consolidated
  `Card`/`ListRow`/`Chip` existed before — screens re-rolled them inline; that is
  the drift this rule kills.
- **Never hardcode a hex/size/radius.** Read the token (iOS `ConduitUI.Palette` /
  `neon.*`; Android `LocalNeonTheme`). If you type `#` or `Color(0x…)` in a
  screen, stop — the token exists.
- **A component close-but-not-right → EXTEND the library**, don't fork a variant
  inside a screen. A new recurring shape becomes a new component in
  `ConduitUI/Components` AND the Android `ui/components` mirror (keep them
  value-for-value; the cross-platform ARGB unit tests must stay green).
- Card radius is **14** on both platforms (owner-decided; iOS `ConduitUI.Card` + HTML are
  already 14, Android drops `ConduitTheme.cardCornerRadiusDp` 20→14). Chips are mono capsules. Rows lead with a bare tinted symbol, not
  a filled tile.

Design reference lives outside the repo (the "SWE Kitty" design project:
`conduit-kit.jsx` tokens + `conduit-primitives.jsx` + rendered `Conduit.html`).
When the HTML primitive and the shipped native component disagree, the **native
app wins** — fix the HTML, not the app.
