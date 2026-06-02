# CLAUDE.md

Operating principles for Claude agents working in this repo.

| Principle              | Problem It Solves                                       | The One-Liner                                                |
|------------------------|---------------------------------------------------------|--------------------------------------------------------------|
| Think Before Coding    | Wrong assumptions, hidden confusion, missing tradeoffs  | Don't assume. Don't hide confusion. Surface tradeoffs.       |
| Simplicity First       | Overcomplication, bloated abstractions                  | Minimum code that solves the problem. Nothing speculative.   |
| Surgical Changes       | Orthogonal edits, touching code you shouldn't           | Touch only what you must. Clean up only your own mess.       |
| Goal-Driven Execution  | Vague plans with no verification                        | Define success criteria. Loop until verified.                |

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

**Commit style:** a single tight subject line. No body, no `Co-Authored-By`
trailer.
