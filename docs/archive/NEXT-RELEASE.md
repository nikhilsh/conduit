# Next Release Plan

> **Archived 2026-05-23.** Both shipping priorities (Tokio runtime fix and
> typed session-creation errors) landed on `main`; the iOS-UI convergence
> priority lives on under `PLAN-LITTER-VISUAL-PARITY.md` now. Current
> release status lives in [`PLAN.md`](PLAN.md) Status Snapshot.

Date: 2026-05-18 (updated 2026-05-19)

## Status (2026-05-19)

Priorities 1 and 2 below have shipped on `main`:

- `core/src/lib.rs` now owns a `Lazy<Runtime>` via `tokio::runtime::Builder::new_multi_thread()`; transport work runs on it. The `there is no reactor running` panic on first `create_session` is gone, and `cargo test` / `cargo clippy -D warnings` are green.
- `broker/internal/ws/conformance_test.go::TestPingPong` is green; ping/pong are now JSON text frames per `docs/WEBSOCKET-PROTOCOL.md §3.3`.
- Session creation failures surface as typed errors instead of a Rust panic. The apps now distinguish "Paired" (token stored) from a verified broker round-trip; auth failures map to a re-pair instruction (see `docs/SENTRY.md`).

Priority 3 (iOS UI convergence toward the KittyLitter surface) is the open work — tracked in `docs/MOBILE-PORT-MATRIX.md` (Package B sub-plan) and `docs/MOBILE-FEATURE-BACKLOG.md`.

The original findings below are kept for historical context.

## Findings

### 1. Session creation is broken on iOS because the Rust core is using Tokio I/O without owning a Tokio runtime

Symptom seen in the app:

- `Failed: create_session: rustPanic("there is no reactor running, must be called from the context of a Tokio 1.x runtime")`

Evidence:

- [apps/ios/Sources/SessionStore.swift](/root/developer/projects/kitty-swe/apps/ios/Sources/SessionStore.swift:85) calls `client.createSession(...)` inside a Swift `Task`.
- [core/generated/swe_kitty_core.swift](/root/developer/projects/kitty-swe/core/generated/swe_kitty_core.swift:629) exposes `createSession(...)` as an async UniFFI call, so the Swift side is not the source of the panic.
- [core/src/lib.rs](/root/developer/projects/kitty-swe/core/src/lib.rs:166) routes `create_session` into `open_session(...)`.
- [core/src/lib.rs](/root/developer/projects/kitty-swe/core/src/lib.rs:188) then calls `transport::connect(...)`.
- [core/src/transport.rs](/root/developer/projects/kitty-swe/core/src/transport.rs:89) uses Tokio networking/spawn/timers.

Interpretation:

- `connect()` on the Swift side currently only stores a delegate and returns; it does not touch the network, which is why initial connection looks healthy.
- The first real network work happens in `create_session`.
- At that point the Rust library is entering Tokio-dependent code without a guaranteed Tokio runtime owned by the library itself.
- Result: first session creation panics instead of returning a normal `SweKittyError`.

Required fix:

- Make `swe-kitty-core` own its async runtime boundary instead of assuming callers are already inside Tokio.
- The clean version is: create and hold a runtime/handle in the Rust client layer, then run transport work on that runtime.
- Also convert this panic path into a normal surfaced error if runtime setup fails.

### 2. The session-start failure is surfaced in the wrong place

Symptom:

- The app appears connected.
- The error only becomes obvious after navigating further into the UI, especially in Settings / status surfaces.

Evidence:

- [apps/ios/Sources/SessionStore.swift](/root/developer/projects/kitty-swe/apps/ios/Sources/SessionStore.swift:71) marks the app `.connected` immediately after `client.connect(...)`, even though no session-backed socket exists yet.
- [apps/ios/Sources/SessionStore.swift](/root/developer/projects/kitty-swe/apps/ios/Sources/SessionStore.swift:109) stores session creation failure into the global `connection` state.
- [apps/ios/Sources/Views/ProjectListView.swift](/root/developer/projects/kitty-swe/apps/ios/Sources/Views/ProjectListView.swift:80) shows that failure only in the compact bottom badge.
- [apps/ios/Sources/Views/RootView.swift](/root/developer/projects/kitty-swe/apps/ios/Sources/Views/RootView.swift:37) only shows the connection failure text when no session is selected.

Interpretation:

- The app has only one coarse `connection` state, but the real product model has at least two distinct states:
  - broker reachability / auth
  - per-session creation and lifecycle
- A session creation failure is being shoved into the same global connection bucket, so the UI has no focused place to present it.

Required fix:

- Add explicit session creation state and inline error presentation in the project/session creation flow.
- Do not report the app as fully "connected" until at least one broker operation has succeeded, or rename the state to something narrower like "configured".

### 3. The current iOS UI is intentionally a minimal shell, not the planned KittyLitter-style product surface

Evidence:

- [docs/PLAN.md](/root/developer/projects/kitty-swe/docs/PLAN.md:267) specifies a richer iOS hierarchy:
  - `RootView`
  - sidebar/drawer project list
  - project detail
  - header with agent badge
  - segmented terminal/chat/browser
- But [`.swe-kitty/tasks/003-ios-shell.md`](/root/developer/projects/kitty-swe/.swe-kitty/tasks/003-ios-shell.md:1) explicitly narrowed the first iOS delivery to:
  - "minimal SwiftUI app"
  - terminal view only
  - chat/browser stubbed
  - QR originally out of scope

Interpretation:

- The current app is not a faithful build of the full planned UI.
- It is the outcome of the narrower task brief that was actually implemented.
- So the divergence from the KittyLitter reference is not accidental styling drift alone; it is scope drift caused by shipping the shell milestone as if it were the product UI milestone.

### 4. We likely should have reused more of the KittyLitter structure instead of inventing a thinner shell

Assessment:

- For the broker/core integration work, the stripped-down shell was a fast way to validate transport and release plumbing.
- For the product surface, it was the wrong stopping point because it leaves too much design and behavior debt:
  - weaker error surfacing
  - less familiar information architecture
  - missing product affordances that were already described in the docs/reference

Recommendation:

- Treat the next iOS pass as a convergence release:
  - keep the new Rust core + broker plumbing
  - pull the UI hierarchy, navigation patterns, and view composition much closer to the KittyLitter reference / planned design
  - avoid another parallel custom shell unless a specific platform limitation forces it

## Next Release Scope

### Priority 1: Fix dogfooding blocker

- Add an owned Tokio runtime in `core/` and route all transport work through it.
- Ensure `create_session` returns a typed error instead of panicking.
- Rebuild bindings and ship a new IPA.

### Priority 2: Fix error presentation

- Separate broker/auth state from session lifecycle state.
- Show session creation failure inline at the point of action.
- Keep Settings for configuration, not as the main place users discover runtime failures.

### Priority 3: Converge iOS UI toward the planned KittyLitter surface

- Audit the KittyLitter reference against the current files under `apps/ios/Sources/Views/`.
- Rework the current shell to match the planned hierarchy in `docs/PLAN.md` instead of continuing to elaborate the minimal shell.
- Prefer lifting structure and interaction patterns from the reference where possible rather than redesigning them from scratch.

## Concrete Implementation Targets

- `core/src/lib.rs`
- `core/src/transport.rs`
- `core/src/swe_kitty_core.udl`
- `apps/ios/Sources/SessionStore.swift`
- `apps/ios/Sources/Views/RootView.swift`
- `apps/ios/Sources/Views/ProjectListView.swift`
- `apps/ios/Sources/Views/ProjectView.swift`
- `docs/PLAN.md` or a dedicated iOS follow-up task brief if we want the convergence work tracked explicitly

## Release Goal

The next iOS release should:

- successfully create and open a session against a live broker
- surface session creation failures in-context if anything goes wrong
- move the UI materially closer to the planned KittyLitter-style app instead of preserving the current scaffold feel
