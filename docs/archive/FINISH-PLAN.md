# conduit finish plan

> ARCHIVED 2026-06-10 — superseded; see docs/ROADMAP.md.

Prioritised work remaining after the 2026-05-29 session (PRs #261–#264 in
review). Phases are sequenced by verifiability: CI-only work first, then
device-test batches, then feature completions, then parked futures.

---

## Top 5 high-impact bets

1. **Push notifications end-to-end** — the "dev tool → product" leap; broker
   APNs/FCM senders + client token registration is the last gap.
2. **Snapshot-test goldens on the next Mac session** — record iOS goldens once;
   every later visual regression is caught in CI.
3. **Flip `experimentalNativeTerminal` on after device-verify** — retire
   xterm.js and ship the native renderer as the default.
4. **BadgeStack + status-dot semantics together** — home becomes a live
   dashboard showing running-agent counts and real connection health.
5. **Delete OAuth v1 + finish Rust-store read path in one cleanup PR** —
   removes dead code on both ends and completes the Rust-first refactor.

---

## Phase 1 — CI-verifiable, ship without a device

These can be written, tested, and merged from the dev box alone.

- [ ] **Rust core end-to-end protocol test.** Fake WS server in
  `core/tests/`; assert `ChatEvent`/`SessionStatus` round-trip. Size S.
- [ ] **Codex `command_execution` tool cards.** Broker currently drops these
  items (`broker/internal/session/codexstream.go`); map them to a typed tool
  `ChatEvent` so codex tool calls appear in chat. Size M.
- [ ] **Delete OAuth v1 (dead path).** Both providers reject the
  `conduit://` custom-scheme redirect. Remove `OAuthClient.swift`
  (`apps/ios`), `set_agent_credentials` + UDL bindings in core. Size S.
- [ ] **Push-notification client-side token registration.** Broker WS handler
  already accepts `register_push_token`; wire iOS
  `UNUserNotificationCenter` device token → broker. Compiles in CI; APNs
  delivery needs a device for true e2e. Size S.

---

## Phase 2 — Device-test batch #1

Run as a single release session per repo policy (one release per device cycle).

- [ ] Verify **#261** — QR-from-gallery decode + Licenses z-order (Android).
- [ ] Verify **#262** — Agent starts in user-selected `cwd` (both platforms).
- [ ] Verify **#263** — iOS Liquid Glass home buttons (device-bug #28).
- [ ] Verify **#264** — Android glass home buttons (device-bug #28).
- [ ] **Ghostty default flip.** Confirm native terminal on device, then set
  `experimentalNativeTerminal` default ON and retire xterm.js.
- [ ] **Status dot.** Drive from live WS health + heartbeat ping/pong; fix
  stale-green (#23) and unify running/attached/stopped semantics (#27). Both
  platforms.
- [ ] **Live Activity widget.** Add widget provisioning profile to
  `release-ios.yml` + re-enable the embed in `project.yml`; verify Dynamic
  Island / lock-screen card.
- [ ] Cleanup verification: version stamp #25, mic button wired #26, glass #28.

---

## Phase 3 — Feature completions (parallelisable)

- [ ] **Push notifications — broker senders.** APNs + FCM concrete senders in
  `broker/internal/push/`; fire on turn-complete and pending-input events.
  Size L.
- [ ] **Codex chat polish.** Partial-message live typing + approval/sandbox-
  bypass affordance. Size M.
- [ ] **Rust-store read path.** Make both apps read from the shared Rust
  reducer (`core/src/store/`) and drop their private reducer maps. Currently
  write-only; guarded by existing parity tests. Size M.
- [ ] **Conduit parity components.**
  - `BadgeStack` (per-server running-agent badges) on `ServerPill`.
  - Conduit-faithful `SessionsScreen` rebuild.
  - `VoiceDictation` phase colours + real audio levels.
  - `SessionInfo` charts (activity-by-day, model breakdown).
- [ ] **Testing foundations.** Record iOS snapshot goldens on first Mac
  session; bootstrap Android unit tests (JUnit / Robolectric / Roborazzi).

---

## Phase 4 — Parked / future

Not scheduled; too large to ship safely from a CI-only box or requires
infrastructure not yet in place.

- **Android M3 Expressive modernisation.** Compose BOM 2024.09 → 2026.05,
  `MaterialExpressiveTheme` (spring motion), Haze backdrop blur on the bottom
  bar (real blur API 31+, tonal fallback ≤30), `ButtonGroup` /
  `FloatingActionButtonMenu`. Needs a local Android build — too large to ship
  blind from CI only.
- **Pinch-to-zoom home.** Gesture-driven server grid zoom.
- **Per-chat wallpaper.** Per-session background image.
- **UIKit composer** with @/$/slash autocomplete.
- **Voice rail B** — realtime WebRTC (rail A push-to-talk shipped).
- **Onboarding coachmarks.**
- CarPlay / Catalyst excluded from scope.
