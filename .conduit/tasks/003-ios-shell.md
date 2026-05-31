# Task 003 — iOS app shell (terminal view only)

## Scope
Generate the Xcode project, wire up the Rust core as an xcframework, and ship a minimal SwiftUI app that connects to a harness and renders the terminal view of one project.

**In scope:**
- `apps/ios/project.yml` — xcodegen spec; bundle id `sh.nikhil.conduit`
- `apps/ios/build-rust.sh` — compiles `core/` for `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-ios`; packages `ConduitCore.xcframework`
- `apps/ios/Sources/ConduitApp.swift` — `@main`
- `apps/ios/Sources/SessionStore.swift` — `@Observable` wrapper around `ConduitClient`
- `apps/ios/Sources/Views/ProjectListView.swift` — top-level session switcher
- `apps/ios/Sources/Views/ProjectView.swift` — segmented picker for Terminal/Chat/Browser; terminal tab wired, chat+browser stubbed
- `apps/ios/Sources/Views/TerminalTab.swift` — SwiftTerm binding to `on_pty_data` / `send_input`
- `apps/ios/Sources/Views/ChatTab.swift`, `BrowserTab.swift` — stub views
- `apps/ios/ExportOptions.plist` — `method=ad-hoc`

**Out of scope:**
- Chat view + Browser view implementation → task 007
- QR / mDNS auth → task 009; for now, manual endpoint+token entry
- iPad split view polish

## Frozen contracts
- `docs/WEBSOCKET-PROTOCOL.md` (consumed via Rust core)
- `docs/AGENT-ADAPTERS.md` (display the agent badge correctly)
- Project layout in `docs/PLAN.md` Part B4

## Done means
- Open in Xcode 16+, target iPhone 16 sim, build succeeds with no warnings
- Run sim → enter endpoint `ws://<mac-ip>:1977` + bearer token in a settings sheet → create session → type in terminal → PTY echoes
- `ci.yml` `ios-build` job green (sim compile, no signing)

## Files allowed
- `apps/ios/**`
- `Makefile` (only the `ios` target)

## Branch
`agent/<your-name>-003-ios-shell`
