# Task 002 — Rust shared core (`swe-kitty-core`)

## Scope
Build the WebSocket client + session state machine in Rust, exposed via UniFFI for iOS/Android.

**In scope:**
- `core/swe-kitty-core.udl` — UniFFI interface (see `docs/PLAN.md` Part B3)
- `core/src/lib.rs` — UniFFI exports
- `core/src/transport.rs` — `tokio-tungstenite` WebSocket client; demux binary vs text; gzip chunked-snapshot reassembly; 30s ping
- `core/src/session.rs` — `ProjectSession` model; per-session view state (terminal scrollback, chat log, preview info)
- `core/src/views.rs` — `ChatEvent`, `PreviewInfo`, `SessionStatus` types
- `core/Cargo.toml`, `core/build.rs` (UniFFI codegen)
- `core/examples/cli-driver.rs` — minimal CLI that connects to a real harness; used for integration testing

**Out of scope:**
- Discovery (mDNS) → can be stubbed; real impl is task 009
- iOS/Android binding scripts → tasks 003/004 own their build-rust.sh

## Frozen contracts
- `docs/WEBSOCKET-PROTOCOL.md` — must match the harness byte-for-byte
- `docs/MEMORY-FORMAT.md` — core does NOT parse memory HTML, but exposes a URL the apps load

## Done means
- `cd core && cargo test` green (uses a mock WS server in-process)
- `cargo run --example cli-driver -- ws://localhost:1977 <token>` connects to a running harness from task 001, creates a session, sends keystrokes, prints PTY data
- `cargo clippy -- -D warnings` clean
- `make bindings` generates `core/generated/swe_kitty_core.swift` and `core/generated/sweKittyCore.kt` without errors

## Files allowed
- `core/**`
- `Makefile` (only the `bindings` and `core` targets)

## Branch
`agent/<your-name>-002-rust-core`
