# Handoff — iOS terminal crash + OAuth/usage follow-ups

_Session: 2026-05-30. App build under test: `02f5fa6` = **v0.0.60** (origin/main tip)._

This captures the investigation of three reported v0.0.60 issues (terminal
crash, missing usage card, OAuth login hang), what shipped, and the prioritized
work left to pick up.

---

## ✅ Shipped this session

**PR #281 (merged to `main`, all 5 CI checks green)** — terminal use-after-free fix.

- File: `apps/ios/Sources/Shared/GhosttyTerminalView.swift`, `GhosttyRenderView.deinit`.
- Change: free the libghostty surface on the **next** main-runloop turn instead of
  synchronously in `deinit`:
  ```swift
  #if canImport(GhosttyVT)
  if let term = terminal {
      terminal = nil
      DispatchQueue.main.async { term.teardown() }
  }
  #endif
  ```
- Why: `deinit` can run *inside* a CoreAnimation commit; freeing the surface
  mid-commit is the UAF. The layer is already detached by `willMove(toWindow:)`,
  and `GhosttySurface.teardown()` is idempotent, so deferring one turn lets the
  in-flight transaction commit first.
- ⚠️ **CI-green only — NOT device-verified.** Exercise the terminal tab +
  tab-switching on a `main` build to confirm the crash is gone.

---

## Confirmed findings

### 1. Terminal crash — root cause (all three Sentry issues are ONE bug)
Every crash stack goes through `CA::Context::commit_transaction` → libghostty
against a **freed** surface:
- `APPLE-IOS-S` → `apprt.surface.Mailbox.push` (KERN_INVALID_ADDRESS)
- `APPLE-IOS-Q` / `APPLE-IOS-P` → `object.Object.getProperty…` sending `bounds`
  to a freed object reused as a tagged `NSNumber` (`0xf000…`)

`6a5de60`'s "edit-menu" attribution for Q/P was a red herring — the real fault is
the same teardown UAF as S. `3dfc9c9` detached the layer in `willMove` but still
freed synchronously in `deinit`; PR #281 closes that window.

**Trigger amplified by the neon rework:** `c9c1a6b` (#275) did **not** touch
`GhosttyTerminalView.swift`. It reskinned the LitterUI screens and added live
theme propagation. The churn comes from `LitterProjectView` recreating
`GhosttyTerminalTab` on every tab switch (see follow-up P1).

### 2. Build number is hardcoded → Sentry can't distinguish builds
`apps/ios/project.yml`: **`CURRENT_PROJECT_VERSION: "13"`** is hardcoded, so every
build (v0.0.57…v0.0.60) uploads as `sh.nikhil.swekitty@0.0.1+13`. Builds are only
distinguishable via the About-screen git SHA (`BuildInfo.swift`), which the
release workflow stamps. This is why "+13" looked like an old build when it
actually includes v0.0.60.

### 3. Broker is NOT stale
Running broker `/root/.swe-kitty/swe-kitty-broker-latest` (built 2026-05-30 16:15,
~v0.0.58) already contains the OAuth handlers (`start_agent_login`,
`agent_login_url`/`_failed`, "oauth: server-side login manager wired") and usage
emission (`total_input_tokens`, `total_cost_usd`, `context_window_tokens`, …).
A broker redeploy will NOT fix OAuth or the usage card.

### 4. OAuth hang — root cause (app-side, iOS)
`LitterAgentLoginSheet.startLogin` builds `AgentLoginCoordinator(transport:)` with
**no `presentationProvider`**, and the sheet reads coordinator state only once
(200 ms after start). So when the broker returns the URL:
- `AgentLoginCoordinator.handleAgentLoginURL` hits
  `guard let presentationProvider else { return }` → **browser never opens**, and
- the sheet never re-reads state → **stuck on "Waiting…"** forever (no timeout).

Routing exists (`SessionStore.routeAgentLoginViewEvent`, FFI `startAgentLogin`).
A working anchor pattern already exists in `OAuthClient.swift:254/405`
(`ASWebAuthenticationPresentationContextProviding` / `presentationAnchor(for:)`).

### 5. Usage card — pipeline is intact, hides until usage reported
Broker emits usage → core threads it (`core/src/session.rs:44–158`) → iOS reads it
(`SessionStore.swift:1688–1693`) → `LitterSessionInfoView.usageCard` renders. The
card **hides entirely until a turn has reported usage**. The screenshot was a
brand-new "New Conversation" (1 turn), so most likely no completed turn had
reported usage yet. Re-check after a Claude turn finishes; only chase a bug if it
stays blank then. (Also listed as a known gap in the Neon v2 design handoff.)

---

## Follow-up plan (prioritized)

### P1 — Keep `GhosttyTerminalTab` mounted across tab switches (the real cure)
Removes the teardown churn at the source (defense beyond PR #281).
- File: `apps/ios/Sources/LitterUI/Views/LitterProjectView.swift`.
- Today `ChatView` is kept mounted (opacity-gated, ~line 262); the terminal goes
  through `liveSecondaryContent`'s `switch tab` (~line 273–297) so it's recreated
  each switch.
- Do: mount `GhosttyTerminalTab`/`TerminalTabXterm` as an always-present,
  opacity-gated layer (mirror the chat pattern: `.opacity`, `.allowsHitTesting`,
  `.accessibilityHidden`, `.zIndex`) instead of inside the `switch`.
- Risk: view-tree restructure; verify layout + PTY grid on device. Android parity:
  check `apps/android` terminal tab mounting too.

### P2 — OAuth login: finish the iOS flow (+ Android parity)
- iOS:
  1. Pass a `presentationProvider` (key-window anchor; reuse `OAuthClient`'s
     `presentationAnchor(for:)`) into `AgentLoginCoordinator`.
  2. Make `LitterAgentLoginSheet` observe coordinator state transitions (not the
     one-shot 200 ms read) so it advances past "Waiting…".
  3. Add a ~20 s timeout on `.waitingForBrokerURL` → `.failed` with a clear
     message, so a dropped/late broker response fails gracefully.
- Android: `apps/android/app/src/main/kotlin/sh/nikhil/swekitty/auth/AgentLoginCoordinator.kt`,
  `ui/AgentLoginSheet.kt`, `auth/SessionStoreAgentLoginTransport.kt` — verify the
  Custom-Tabs launch + add the matching timeout/state surfacing.

### P3 — Stamp `CURRENT_PROJECT_VERSION` per release
Make crashes attributable in Sentry.
- File: `.github/workflows/release-ios.yml` — pass
  `CURRENT_PROJECT_VERSION=${{ github.run_number }}` (or similar monotonic value)
  to the `xcodebuild archive` step, overriding the hardcoded `"13"` in
  `apps/ios/project.yml`.

### P4 — Usage card verification
Confirm a completed Claude turn populates `SessionStatus.totalInputTokens` etc. on
the live broker; if the card stays blank after a finished turn, trace
broker emission → `core/src/session.rs` merge → iOS `SessionStatus` shape.

---

## Sentry quick-reference
- Triage script: `scripts/sentry-check.sh` (org `swe-kitty`, projects
  `apple-ios`,`android`; auth via `SENTRY_AUTH_TOKEN` or
  `/root/.config/sentry/auth-token`).
- Latest event for an issue:
  `GET /api/0/organizations/swe-kitty/issues/<id>/events/latest/` (the
  org-level `/events/` query returns `samples=0` for this token scope).

## Notes
- Mobile is CI-compile-only on this box (no Mac/Android SDK). Every iOS/Android
  fix here ships unverified → flag **needs on-device verification**; batch one
  release per device-test session.
- This box **is** the VPS (103.107.51.48); the broker runs locally. Never
  `pkill -f swe-kitty-broker` (kills your own shell) — kill by PID.
