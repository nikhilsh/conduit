# Testing Strategy

Written 2026-05-21. Counter to how we've been shipping so far.

## Current state (the honest version)

| Layer | Test files | Coverage |
| --- | --- | --- |
| Go server (`broker/`) | yes — `*_test.go` per package | reasonable; new code lands with table tests |
| Rust core (`core/`) | yes — `cargo test` | thin but real, especially `session.rs::tests` |
| iOS app (`apps/ios/`) | **none** | zero |
| Android app (`apps/android/`) | **none** | zero |
| End-to-end (mobile ↔ server ↔ agent) | **none** | zero |

```sh
$ find apps/ios apps/android -iname "*test*" -type f
(no output)
```

We've been shipping mobile by: writing code → CI compiles it → user runs it on a real device → user files a screenshot bug. The user has been the regression detector. That is the opposite of what we should be doing.

## The rule going forward

**If a feature touches client code (iOS or Android), it ships with a failing-first test that drives the code.** No exceptions for "small" changes — small changes are exactly when this discipline pays off, because they're cheap to test and the cost of a bug spreading is asymmetric.

The TDD loop we want, in one paragraph: write a test that captures the *contract* (a parser produces these blocks for that input; a store transitions to that state on this event; a view renders that bubble with this metadata). Run it; watch it fail. Write just enough code to make it pass. Watch it pass. Refactor with confidence because the test will catch regressions.

## Per-platform plan

### iOS — Swift Testing (unit) + XCTest (UI) + swift-snapshot-testing (visual)

**Framework choice notes:**
- **Swift Testing** (Apple's new framework, shipped with Xcode 16 in late 2024) is the recommended path for *unit* tests in new projects. Uses macros (`@Test`, `#expect`), runs in parallel by default, produces cleaner failure messages than `XCTAssert*`. We adopt it for unit work.
- **XCTest** stays for UI tests (`XCUITest`) and any case where Swift Testing's macro model is awkward — they coexist in the same target.
- **swift-snapshot-testing** (Point-Free, BSD-3) for visual regression. De facto standard; used by many large iOS codebases.

**Setup (~half day):**
- New target `SweKittyTests` in `apps/ios/project.yml`. Same code-signing as the app target but no entitlements needed.
- Add to CI: `xcodebuild test -scheme SweKitty -destination 'platform=iOS Simulator,name=iPhone 16'` in `release-ios` cycle and `ci.yml`.
- First test file: `apps/ios/Tests/SweKittyTests/ConversationRendererTests.swift` — table-driven against the `ConversationRenderer.blocks` parser from PR #15, written in **Swift Testing** style (`@Test func collapsesConsecutiveBashLines() { ... }`). Pure function, no UIKit; perfect first test.

**What to test first (priority order):**
1. **`ConversationRenderer.blocks(for:)`** — assert that a fenced code block separates from prose; assert that consecutive `$ cmd` lines collapse into a `.toolSummary` with the right count; assert that "Reading the docs..." stays in markdown (the length-guard edge case I built but only eyeballed).
2. **`AppearanceStore`** — assert that persisted `fontFamily` survives `init(defaults:)` round-trip; assert that `applyToWindows()` is a no-op when no scenes are connected (defends the theme fix from PR #11).
3. **`SessionStore` chat ingest** — using a fake `Client` protocol, drive `ingestChat` and assert that `chatLog[sessionID]` + `conversationLog[sessionID]` get populated in lockstep, that user-echo dedupe works, that the `awaitingReply` clear-condition holds.

**What to test next (snapshot + view tier):**
- Add [`pointfreeco/swift-snapshot-testing`](https://github.com/pointfreeco/swift-snapshot-testing) as a Swift Package dependency.
- Snapshot `ChatTab` with a representative `[ConversationItem]` fixture under each `AppearanceStore.FontFamily`. PRs that change rendering have to *intentionally* update snapshots; visual regressions stop being "user finds them in the screenshot".
- Snapshot `SessionInfoView`, `AppearanceSheet`, the agent-pill states.
- Consider [**ViewInspector**](https://github.com/nalexn/ViewInspector) for SwiftUI hierarchy introspection without taking pixel snapshots — a middle ground when we need to assert "this view contains a HealthDot" without committing to a specific render.

### Android — JUnit 4 + MockK + Robolectric + Compose UI Testing + Roborazzi

**Framework choice notes:**
- **JUnit 4** as the default. JUnit 5 is modern and supports parameterized tests / parallel execution more cleanly, but Compose tooling (`ComposeTestRule`, etc.) assumes JUnit 4 and the JUnit 5 Android plugin adds setup friction. We start with JUnit 4 and revisit if/when Compose lands a JUnit 5 path.
- **MockK** (Apache-2.0) for mocking. Kotlin-native, idiomatic for Kotlin (handles coroutines, sealed classes, top-level functions cleanly). De facto standard since ~2019 — Mockito-Kotlin is the older alternative but MockK has won.
- **Robolectric** (Apache-2.0) lets us run "Android" tests on the JVM without an emulator. Standard for fast unit-testing of Android classes (View, Context, etc.).
- **Compose UI Testing** (`androidx.compose.ui:ui-test-junit4`) for Compose views — the official Google framework.
- **Roborazzi** (Apache-2.0) for Compose snapshot testing on the JVM — the Compose-snapshot equivalent of swift-snapshot-testing for Android. **Updated from the original Paparazzi pick** because Roborazzi tracks AGP/Kotlin versions faster (Paparazzi has historically blocked AGP 8.5 / Kotlin 2.0 upgrades), and it integrates with Robolectric which we already have in the test classpath. Same value: visual regressions become explicit snapshot diffs in PRs.

**Setup (~half day):**
- New source set `apps/android/app/src/test/java/sh/nikhil/swekitty/`.
- Add JUnit 4 + MockK + Robolectric to `build.gradle`. CI: `./gradlew :app:testDebugUnitTest` added next to the existing `assembleDebug`.
- First test file: `TerminalBridgeTest.kt` against the JSON-parse path in `WebTerminal.kt` from PR #17 — the int-vs-double resize-event coercion is exactly the kind of thing nobody catches without a test.

**What to test first:**
1. **`TerminalBridge.postMessage`** — feed canned JSON strings, assert that `ready` flushes pending, that `input` calls `onInput` with UTF-8 bytes, that `resize` accepts both int and double values for cols/rows.
2. **`SessionStore` chat ingest** — same shape as the iOS test above.

**What to test next (Compose + snapshot tier):**
- Add `androidx.compose.ui:ui-test-junit4` + `compose-ui-test-manifest`.
- Add Roborazzi for snapshot tests of the same surfaces iOS snapshots: `ChatPage`, agent picker, project list.
- Compose tree assertions (`hasText`, `assertIsDisplayed`) for interactive behavior; Roborazzi snapshots for visual regression.

### Rust core — already covered, expand the surface

`cargo test --workspace` works today. Add:
- **Integration test for `apply_status`** — assert that the new info-sheet fields from PR #16 actually thread through.
- **End-to-end protocol test** — spin up a fake WebSocket server in-process, drive `transport::connect`, assert the `ChatEvent` / `SessionStatus` round-trip. This is the **real** test broker: it exercises the wire format end-to-end without spawning an agent.

### Server (currently `broker/`) — keep the discipline

The Go side is the only place we already do TDD. Don't regress. The session GC (`PR #14`), the PTY scraper (`PR #13`), and the ANSI stripper all landed with tests because we were in the habit there.

## CI gates

`ci.yml` workflow steps to add, in this order:

1. `ios sim build` step gains a `xcodebuild test` invocation (single test target, ~30s overhead for the unit suite).
2. New `android unit tests` job: `./gradlew :app:testDebugUnitTest`.
3. New `core (rust)` step: `cargo test --workspace` (just calls what's already wired).
4. New `e2e` job (eventual): runs the Rust + Go round-trip test against an in-process fake.

Required-to-merge: all four. No `[skip ci]` for client changes. No "I'll add the test after" — that test never gets added.

## What this enables

- **Refactoring without dread.** The Litter-style rewrite, the Tier 1.5 chat refresh, the Claude-style typography change — all of those would have been lower-risk with a snapshot suite. We have done several visual rewrites blindly; the next one shouldn't be.
- **Catching protocol drift early.** The reason the chat tab was silent for two weeks (PRs #12, #13) was that the wire format had a gap nobody noticed. An e2e test that asserted "user-sent chat round-trips to an assistant reply within N ms" would have caught this on PR #12.
- **Confidence to delete code.** Legacy `TerminalTab.swift` (the SwiftTerm leftover) and `AnsiTerminal.kt` were both removed only after the user confirmed in production. With tests, we delete them when the test says the replacement passes.

## What this costs

- ~1 day to stand up both targets, wire CI, write the first 3 tests on each platform.
- ~10% slower CI per run (worth it).
- Discipline: actually writing the test first. The only way this works.

## What it does NOT mean

- We are NOT pursuing 100% coverage. Pure functions and protocol contracts first; UI snapshots second; never aim for "every line touched".
- We are NOT going to retroactively backfill tests for old code. The rule applies forward. Old code gets tests when it changes.
- We are NOT replacing manual QA. Smoke-testing on a real device still matters for things tests can't catch (keyboard behavior, screen-size-specific layouts). But the load shifts: tests catch logic, manual QA catches *feel*.

## Next steps (after this doc is approved)

1. Add iOS XCTest target + first 3 tests (~half day, one PR).
2. Add Android JUnit broker + first 2 tests (~half day, one PR).
3. Wire CI gates (separate small PR so it's reversible).
4. Adopt the rule. Watch what happens.
