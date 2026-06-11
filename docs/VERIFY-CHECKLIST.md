# Verify Checklist

Merged and released features awaiting the owner's on-device verification,
grouped by release version (newest first). Each item notes whether it needs
app testing on a device or broker-behavior confirmation.

When an item is verified, move it to [DONE.md](DONE.md). When cutting a
release, the section for that version is the device-test punch list.

---

## v0.0.140

- **SSH add-box connect no longer hangs (broker-first bootstrap)** — broker
  starts first on the remote box (bound `127.0.0.1:1977`, reachable only via the
  SSH tunnel) and emits OK before any agent install. Agent install is now
  best-effort and time-bounded (`AGENT_INSTALL_TIMEOUT_S=180`; all curl calls
  bounded). Script embedded in core via `include_str!` — no broker redeploy
  needed. PR #507. [app+bootstrap, on-device] Verify: add a box via SSH private
  key to a VPS with NO claude/codex installed → "Starting server" completes and
  the session connects; readiness then flags agent-not-installed.
- **SSH add-box sheet keyboard** — keyboard dismisses on scroll and a Done
  toolbar button ensures the Connect button is always reachable. PR #506.
  [iOS, on-device]

---

## v0.0.139

- **Push-driven Live Activities** — iOS Live Activities now updated via APNs
  push while the app is backgrounded (PRs #500 iOS / #501 broker+relay). Verify
  a running turn advances the lock-screen LA without the app in the foreground.
  [iOS, on-device]
- **UnifiedPush ntfy Android surface** — ntfy-backed UnifiedPush now wired into
  Android; push notifications arrive without Firebase. PR #499. Verify a push
  notification arrives via ntfy on a device without GCM/FCM. [Android, on-device]
- **SSH forced-capture + add-box fixes** — SSH sessions now capture the terminal
  even when another process holds the PTY; add-box em-dash/smart-quote
  corruption fixed, disabled-reasons shown inline. PR #502. [app, on-device]
- **Sentry quota hygiene** — `beforeSend` denylist suppresses noisy
  diagnostic/disconnect noise as breadcrumbs rather than events; real errors
  still captured. PR #504. Verify a real error still reaches Sentry and that
  noisy diag events no longer appear as full events in the quota. [app, on-device]
- **VPS backup helper** — `scripts/conduit-backup.sh` + `docs/BACKUP-RECOVERY.md`.
  Verify: `scripts/conduit-backup.sh /tmp/test-backup.tar.gz.gpg`
  (passphrase-prompt must appear; encrypted file written; decrypt + inspect
  `manifest.txt` confirms tier-1 items staged). PR #498. [script, local run]
- **Codex extra-approval/elicitation cards** — confirmed already rendered
  app-side (verify-only, no build needed). Verify a codex
  `item/fileChange/requestApproval`, `item/tool/requestUserInput`, and
  `mcpServer/elicitation/request` each surface a tappable card in the app.
  [app, on-device, verify-only]

---

## v0.0.138

- **Subagent "Agents" panel in the Information tab** — debug-gated (default
  OFF); shows claude subagents (#490 iOS / #491 Android / #492 broker+core) and
  codex subagents via collab threads (#495). [app, on-device]
- **ACP backend + gemini-cli selectable as an agent** — broker-side ACP
  protocol handler; gemini-cli now appears in the agent picker. PR #488. Verify
  a gemini session starts and streams. [broker, on-device]
- **opencode real-provider via env_passthrough + host-cred mirror** — opencode
  reads host API keys / configured providers; OAuth-only users still fall back
  to Zen. PR #485. Verify opencode session starts against real provider when key
  present. [broker]
- **`--with-ntfy` bootstrap + `features.ntfy_url` advertise** —
  `remote-bootstrap.sh --with-ntfy` installs ntfy alongside the broker and the
  broker advertises the endpoint in capabilities. PR #484. Android UnifiedPush
  auto-configure is a future follow-up. [bootstrap/broker]
- **Android parity fixes** — fast-mode badge in new-session picker,
  broker-update banner on tablet, chat/Queued-Next width caps on tablet, steer
  button label+icon, retrying-badge color, styled fast-mode capsule, readiness
  checkmark, retry button semantics. PR #494. [app, tablet+phone]
- **SSH add-box fix + instrumentation** — private-key field smart-dash/quote
  corruption fixed (em-dash bug), inline "why disabled" reasons, PEM-format +
  encrypted-key warnings, `ssh_addbox` breadcrumb trail; iOS+Android. PR #496.
  [app, on-device]

---

## v0.0.137

- **"Queued Next" steer UI** — codex turns get a ↳Steer injects mid-turn into the
  running turn; claude and others show "Queued" and auto-send on turn completion;
  send button shows steer glyph during a codex turn; gated on
  `capabilities.supports.steer`. PRs #481 / #482 / #483. [app, on-device]

---

## v0.0.136

- **Optimistic-send pending/failed bubbles persisted across kill** — unsent
  messages survive app kill and are retried on relaunch. PR #479. [app, on-device]
- **Codex model-row dedupe + recents capped at 3** — picker no longer shows
  duplicate model rows; recently-used list capped at 3 entries. PR #476. [app,
  on-device]
- **Connection-health banner + post-pair readiness checklist** — broker
  post-connect `/api/capabilities` readiness block; app banner and checklist UI.
  PR #466. [app, on-device]
- **Multi-box push registration** — device token registered with all paired boxes,
  not just the active one. PR #472. [app + push; verify push arrives from a
  non-foreground box]
- **Codex `turn/steer` server-side auto-steer + `turn/start` fallback** — broker
  auto-steers a running codex turn when steer arrives; falls back to turn/start
  if steer unsupported. PR #480. [broker behavior]
- **Choice-card awareness-prompt nudge** — agents receive a prompt nudge to emit
  choice cards at appropriate points. PR #478. [agent behavior; verify nudge
  fires and agent responds with a choice card]
- **Codex extra approval/elicitation server-request handling** — broker routes
  `item/fileChange/requestApproval`, `item/tool/requestUserInput`, and
  `mcpServer/elicitation/request` to the app. PR #473. [broker; verify card
  appears in app for each type — see also Now backlog item]
- **opencode 2-min silence timeout** — broker kills an opencode turn after 2 min
  of silence instead of 10 min. PR #471. [broker behavior]
- **Model-catalog richness — usage hints + fast-mode availability label** —
  `/api/capabilities` carries usage-rate hints and `supportsFastMode`; picker
  shows them. PR #475. [app, on-device]
- **Broker-version ldflag** — `/api/capabilities` reports the real semver tag
  (not `"dev"`) for broker binaries built by CI. PR #474. [broker readiness;
  verify About / readiness shows real version]

---

## Earlier unverified items (pre-v0.0.136)

The following were flagged "needs on-device verification" and have not been
confirmed verified. Move each to DONE.md once confirmed.

- **Device-bug #28** — [original issue; verification status unknown — confirm
  and move to DONE.md or re-open]
- **Device-bug fixes #261–#264** — [original issues; verification status unknown
  — confirm and move to DONE.md or re-open]
