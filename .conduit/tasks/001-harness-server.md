# Task 001 — Harness server (Go)

## Scope
Build the conduit harness server: an HTTP+WebSocket service that manages per-session PTYs, git worktrees, and Docker-spawned agent containers. Slimmed fork of swe-swe's server.

**In scope:**
- `harness/cmd/conduit-harness/main.go` — CLI: `up`, `down`, `memory`, `--public-url`, `--local` flags
- `harness/internal/session/manager.go` — Session struct, create/destroy, PTY drain goroutine
- `harness/internal/ws/server.go` — WebSocket server matching `docs/WEBSOCKET-PROTOCOL.md` byte-for-byte
- `harness/internal/auth/auth.go` — Bearer token check
- `harness/go.mod`, `harness/Makefile`

**Out of scope** (separate tasks):
- Agent adapters / Dockerfiles → task 006
- Checkpoint / watchdog / handoff / recovery → task 005
- mDNS discovery → can be a follow-up; stub it out

## Frozen contracts (do not change in this PR)
- `docs/WEBSOCKET-PROTOCOL.md`
- `docs/SESSION-LIFECYCLE.md` (only the protocol-visible parts; the internal subsystems live in task 005)

## Done means
- `go test ./...` green
- `go run ./harness/cmd/conduit-harness up --local` opens `:1977`
- `wscat -c "ws://localhost:1977/ws/$(uuidgen)?assistant=claude" -H "Authorization: Bearer <token>"` echoes typed input via PTY (hardcoded `sh` as the "agent" is fine for this task — real adapter integration is task 006)
- Resize (binary `0x00 RR CC`) and gzip-chunked snapshot (`0x02`) round-trip
- `ci.yml` `harness` job green

## Files allowed
- `harness/**/*.go`
- `harness/Makefile`, `harness/go.mod`, `harness/go.sum`

## Branch
`agent/<your-name>-001-harness-server`
