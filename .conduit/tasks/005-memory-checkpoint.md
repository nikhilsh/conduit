# Task 005 — Memory + checkpoint + watchdog + recovery

## Scope
The long-running-session engineering. Cannot defer to v2 per project requirements (see `docs/SESSION-LIFECYCLE.md`). Blocks v0.2.

**In scope:**
- `harness/internal/session/checkpoint.go` — 60s ticker + event-driven snapshots; scrollback flush; auto-WIP commit
- `harness/internal/session/watchdog.go` — liveness probe (`docker exec ... echo`), stall detection, dead-container alerts via `view_event`
- `harness/internal/session/handoff.go` — atomic agent swap: SIGUSR1 → HANDOFF-OUT.html → merge → restart with new image
- `harness/internal/session/recovery.go` — on `conduit-harness up`, reattach to existing sessions on disk
- `harness/internal/memory/` — HTML schema validator, render/checkpoint/handoff/promote operations
- `harness/cmd/conduit-harness/memory.go` — `conduit memory {init,render,checkpoint,handoff,promote,show}` subcommands
- Failure-mode matrix tests under `harness/internal/session/integration_test.go`

**Out of scope:**
- Mobile UI for "Health" badge → part of task 007
- The HTML schema itself is FROZEN in `docs/MEMORY-FORMAT.md`

## Frozen contracts
- `docs/SESSION-LIFECYCLE.md` — checkpoint cadence, watchdog rules, agent-swap atomicity
- `docs/MEMORY-FORMAT.md` — HTML5 subset, required sections, `data-section` attrs
- `docs/AGENT-ADAPTERS.md` — `on_start`/`on_exit`/`on_swap` hook semantics

## Done means
- Every failure mode in the matrix passes (agent crash, container OOM, harness SIGKILL, mid-PR swap, network blip, concurrent memory writes, app force-quit)
- `conduit memory render --session <uuid>` produces validator-passing HTML
- Mid-session swap: Claude does X, swap to Codex, Codex sees X in `HANDOFF.html` and continues coherently (integration test fixture)
- Harness `SIGKILL` → restart → all sessions recovered, clients reconnect transparently

## Files allowed
- `harness/internal/session/*.go` (new files)
- `harness/internal/memory/**`
- `harness/cmd/conduit-harness/memory.go`
- `.conduit/memory/index.html` (only seed updates)

## Branch
`agent/<your-name>-005-memory-checkpoint`
