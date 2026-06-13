# Verify Checklist

Merged and released features awaiting the owner's on-device verification,
grouped by release version (newest first). Each item notes whether it needs
app testing on a device or broker-behavior confirmation.

When an item is verified, move it to [DONE.md](DONE.md). When cutting a
release, the section for that version is the device-test punch list.

---

## v0.0.153

Stage-2 of the accounts work: per-box account status + honest per-box sign-out, replacing the confusing "Manage" affordances. iOS PR #567, Android PR #568. App-only (no broker redeploy).

- **1 · Per-box account status (two-line rows)** — each provider row in the Agent-accounts sheet (and the Settings account rows) now shows your phone sign-in status on line 1 and the CONNECTED box's status on line 2 ("Ready on <box>" / "Not on <box> · auto-pushes on connect"). The misleading device-global "signed in" label is gone. Verify: connect a box without Claude → the row shows "Not on <box>"; after auto-propagate/sign-in it flips to "Ready on <box>". [iOS+Android, on-device]
- **2 · ⋯ menu replaces the "Manage" popover** — the per-provider trailing is now a single ⋯ / overflow menu (Re-authenticate · Remove from phone · Remove pushed credential from this box). The old speech-bubble "Manage" popover in Settings is gone. Verify: tap ⋯ on a provider → the three actions appear and read clearly. [iOS+Android, on-device]
- **3 · Per-box sign-out (honest wording)** — "Remove pushed credential from this box" calls the broker clear endpoint and removes ONLY the app-pushed credential; it deliberately does NOT revoke the box owner's own shell login (~/.claude/.credentials.json). Verify: on a box with a pushed cred, use "Remove pushed credential from this box" → line 2 flips to "Not on <box>"; the box owner's own CLI login is untouched. [iOS+Android+broker, on-device]

---

## v0.0.152

Per-box credential auto-propagate — the fix for "Claude says signed in but a session on another box returns 401". Broker PR #563 (redeployed v0.0.152, endpoints live), iOS PR #565, Android PR #564. The broker also gained a per-box credential CLEAR endpoint (`POST /api/agent/credentials/clear`) used by the upcoming Stage-2 sign-out UI. Stage-2 accounts UI (per-box status + sign-out) is a separate follow-up.

- **1 · Credentials auto-propagate to every box you connect** — the app now pushes your stored Claude/ChatGPT credential to a box on connect via the new broker `POST /api/agent/credentials`, so a box added after sign-in (e.g. an SSH box) gets the credential instead of returning `API Error: 401`. Verify: with Claude signed in on the phone, connect a box that never had Claude set up → start a Claude session → it works (no 401). [iOS+Android+broker, on-device]
- **2 · 401 safety net** — if an agent auth 401 still occurs mid-session, the app re-pushes the credential to that session's box and shows a "Sign in on this box" affordance instead of a dead error. Verify: force a 401 (box with no/expired cred) → app recovers or shows the sign-in CTA, not a bare error. [iOS+Android, on-device]
- **3 · Readiness reflects pushed credentials (broker)** — `/api/capabilities` `agents.<name>.signed_in` is now true when the box holds an app-pushed credential, not only when a host-login file exists. Verify: a box that only has an app-pushed cred shows the agent as signed-in/ready. [broker, on-device]

---

## v0.0.151

Quick fixes for issues found device-testing v0.0.150. iOS PR #561, Android PR #560. No broker change (no redeploy).

- **1 · Onboarding "PAIRED" eyebrow centered (iOS)** — on the Done/"You're in" screen the green PAIRED label was flush to the left screen edge while the rest was centered; now centered. (Android has no Done screen — N/A.) Verify: finish onboarding → "PAIRED" sits centered above "You're in." [iOS, on-device]
- **2 · "Replay walkthrough" opens at Welcome, not the last step (iOS)** — Settings → Replay walkthrough was landing on the Done step for an already-paired user (a stale-presentation race); now presented via `.fullScreenCover(item:)` so it reliably opens at Welcome (and "Add a machine" at Install). Android was already correct. Verify: Settings → Replay walkthrough → opens on Welcome; Add a machine → opens on Install. [iOS, on-device]
- **3 · SSH boxes no longer show a misleading "offline" at rest (iOS+Android)** — an SSH/tunnelled box's address is a localhost tunnel port that only listens while connected, so the at-rest reachability probe always failed → "offline". Now loopback boxes skip the probe and show a neutral "SSH · tap Connect" + the real SSH host instead of 127.0.0.1:<ephemeral port>. Verify: with an SSH box not connected, its row shows "SSH · tap Connect" (not "offline") and its real host. [iOS+Android, on-device]

---

## v0.0.150

Fixes for bugs the owner found while device-testing the v0.0.149 (R3) build.
iOS PR #558, Android PR #557, broker PR #556. The broker fix is LIVE (redeployed
v0.0.150, verified: `/api/capabilities` reports v0.0.150 and the claude catalog
no longer lists the dismissed `claude-fable-5` model).

- **1 · Onboarding can now be exited** — the walkthrough had NO dismiss control,
  so Settings → "Replay walkthrough" / "Add a machine" trapped the user (only
  escape was re-pairing; "I know my way" just toggled verbosity). Added a Close
  (X) in the top bar that finishes/dismisses. iOS: shown for replay/addMachine
  entries. Android: `onFinish` was never even wired — Close now calls it at every
  step. Verify: Settings → Replay walkthrough → X returns to the app without
  re-pairing; first-run gate unchanged. [iOS+Android, on-device]
- **2 · Session Info "Box" row shows the renamed box name + IP** — was the raw
  `host:port · broker`; now renders `Name (host:port)` when the box is renamed
  (owner wanted both name and IP). Verify: rename a box → Session Info → Details
  → Box shows `MyName (1.2.3.4:1977)`. [iOS+Android, on-device]
- **3 · Model picker drops dismissed models after a CLI upgrade** — the broker
  model-catalog cache only re-probed on a 6h timer and never invalidated when the
  agent binary changed, so an upgraded `claude` kept serving a dismissed model
  (Fable). Cache is now binary/version-aware (fingerprint = resolved symlink +
  size/mtime) and re-probes immediately on a CLI change. LIVE + verified on the
  box (Fable gone). Verify on device: model picker lists only models the box's
  current claude actually serves. [broker, on-device]
- **4 · Per-box "Sign in" actually signs into that box (iOS)** — the readiness
  "Sign in" CTA opened the global accounts sheet (already "signed in"), a
  dead-end; it now launches the real claude/codex OAuth flow targeting the
  connected box, and the per-provider dot reflects the connected box's readiness.
  (Android already routed correctly; its dot now also reads box readiness.)
  Verify: on a box where claude isn't signed in, tap Sign in → real login →
  credential lands on that box → session starts. [iOS+Android, on-device]
- **5 · Duplicate choice cards de-duplicated** — a claude AskUserQuestion card
  rendered twice. iOS now collapses duplicate `pending_input` cards (same prompt
  + options); Android additionally drops the plain-text echo of the question
  (the iOS `dropPendingInputEchoes` pass it was missing). Verify: trigger an
  AskUserQuestion → exactly one card. [iOS+Android, on-device]
- **6 · Answered choice card shows the selection (iOS)** — after picking an
  option the card stayed in the urgent "NEEDS YOUR INPUT" state; it now flips to
  ANSWERED, checks the chosen row, shows "Sent · <answer>", and persists the
  answered state across reopen. (Android already did this.) Verify: answer a
  card → it shows your choice, not a pending prompt; reopen → still answered.
  [iOS, on-device]
- **7 · Usage strip expand/collapse animates (iOS)** — the strip lives in a List
  row where `.transition` is dropped; the expand is now an animatable
  clip-height + opacity under a 0.28s ease so the detail reveals smoothly and the
  chevron rotates. Verify: tap the usage strip → smooth eased expand/collapse.
  [iOS, on-device]

> Deferred (NOT in this build): codex auto-mode "can't do interactive prompt"
> (needs exact error/repro), broker auto-update-on-reconnect (needs focused
> root-cause), Live-Activity visual polish (needs a target mock).

---

## v0.0.149

Round-3 design handoff: ten UI/IA + behavior fixes (iOS PR #550, Android PR
#552), actionable-approval backend (broker PR #549, relay PR #551).

> **DEPLOYS HELD — do these first (in this order), approvals are inert
> until both are done:**
> 1. Relay: `cd relay && export CLOUDFLARE_API_TOKEN=<your token> && npx
>    wrangler deploy` (no CF token lives on the box; the deployed relay 400s
>    the broker's new approval/input push categories until updated).
> 2. Broker: `/broker-redeploy` (held back deliberately — redeploying before
>    the relay would break pending-input pushes outright).

- **1 · Onboarding entry intents** — Settings now has "Replay walkthrough"
  (starts at Welcome) and "Add a machine" (starts at Install); neither can land
  on the "You're in" Done screen. Verify both entries + normal first-run gate
  unchanged. [iOS+Android, on-device]
- **2 · Agent accounts sheet** — X to close (was Cancel), one row per provider
  with signed-in status dot and Manage/Sign-in trailing, Done CTA. Verify
  Claude paste-code + Codex loopback flows still work end-to-end. [iOS+Android,
  on-device]
- **3 · Add via SSH restyle** — Conduit cards + mono section labels, API keys
  behind a disclosure (collapsed), X to close, inline host validation hint.
  Verify a real SSH add still bootstraps. [iOS+Android, on-device]
- **4 · Boxes list** — live state at rest on every row (active: green +
  latency; others: async reachability probe), ACTIVE badge, per-row Connect
  always tappable (switches without manual disconnect), long-press/swipe
  rename, box name rendered app-wide (Home, Runs-on, chat header), title
  "Boxes". NOTE: true simultaneous N-box connections was design fiction in the
  handoff — deferred to backlog (architect-scale SessionStore refactor).
  [iOS+Android, on-device]
- **5 · Usage strip animation** — expand/collapse eases (~0.28s), detail
  fades+slides, chevron rotates 180°; percentages unchanged. [iOS+Android,
  on-device]
- **6 · New-session declutter** — single "Runs on" line (named box + state +
  Change › that actually switches) replaces the dead box list; only enabled
  agents shown (default claude+codex; Settings → Agents toggles, last one
  can't be disabled). [iOS+Android, on-device]
- **7 · Model picker** — Conduit-styled sheet (name + context/price caption,
  RECOMMENDED badge, checkmark; Android RadioButton bottom sheet) replaces the
  system menu; Fast-mode toggle only when supported. [iOS+Android, on-device]
- **8 · Chat retry** — failed sends show a real state machine (tap → retrying
  spinner → delivered/failed; Android adds Snackbar+RETRY). iOS mechanism
  pre-existed (device feedback predated it) — verify it works on-device this
  time. [iOS+Android, on-device]
- **9 · Actionable approvals** — pending approvals push with category
  "approval" + summary body; Approve/Deny notification actions resolve via
  POST /api/session/approval WITHOUT opening the app; in-app Approve/Deny +
  per-session auto-approve (in-memory, audited). NEEDS the relay + broker
  deploys above. Verify: lock-screen Approve unblocks codex; Deny declines;
  404 fallback opens the app. [iOS+Android+broker+relay, on-device]
- **10 · Arm-B tool grouping** — chat arm B (Signature) coalesces 2+
  consecutive tool calls into one collapsible cluster ("3 commands · all exit
  0"); single calls inline; arm A untouched. [iOS+Android, on-device]

---

## v0.0.148

Reliability + new-box onboarding batch. All the SSH-bootstrap / box / chat /
onboarding fixes from this round, shipped in one build.

- **Broker auto-updates on reconnect** — the bootstrap reuse path now compares a
  version marker and re-installs the broker binary when the box is running a
  stale version, so future broker fixes reach existing boxes on reconnect with
  no manual redeploy. PR #539. REQUIRES nothing on the box. Verify: reconnect an
  older SSH box → broker silently updates to the app's version. [broker-script
  via app/core, on-device]
- **Home row shows the real host** — a connected SSH box's Home row subtitle
  shows its real host instead of `127.0.0.1`/forwarded port. PR #540. Verify:
  add an SSH box → Home row subtitle shows root@host, not 127.0.0.1. [app,
  on-device]
- **Box switch re-bootstraps SSH boxes** — switching to a saved SSH box routes
  through the re-bootstrap/connect path (was failing to connect to a second box
  after the first). PR #541. Verify: with two SSH boxes, Settings → switch
  between them → each connects and loads its sessions. [app, on-device]
- **Live Activity ends on archive/delete** — archiving or deleting a session now
  ends its Live Activity instead of leaving it stuck on the lock screen. PR #542.
  Verify: start a session (LA appears) → archive it → LA disappears. [iOS,
  on-device]
- **Subagent vs. main-agent classification + worktree branch** — assistant/user
  prose is no longer mislabeled as SUBAGENT (heuristic moved below the role
  check and tightened to anchored phrasing); live git state reads the agent
  process's real cwd via /proc so an agent working in a worktree shows the
  correct branch instead of `main`. PR #543. Verify: a main-agent turn shows as
  the main agent (not subagent); a session whose agent cd'd into a worktree
  shows that worktree's branch. [broker+core, on-device]
- **Elicitation deadlock fixed (duplicate input / stuck queue)** — answering an
  AskUserQuestion / approval prompt mid-turn no longer routes to the turn queue
  (which stayed blocked waiting on the answer) → no more duplicate input box and
  no stuck queue. PR #544. Verify: trigger an AskUserQuestion → answer it → the
  turn proceeds, single input, queue not stuck. [broker, on-device]
- **Codex pending card no longer re-arms on reopen** — the pending-input card is
  no longer persisted to the transcript, so reopening a codex session doesn't
  re-show / re-fire a stale prompt. PR #545. Verify: answer a codex prompt →
  leave and reopen the session → no duplicate/stale prompt. [broker, on-device]
- **Removed the useless "This device" / local row** — agents never run on the
  phone in conduit's model; the non-actionable local placeholder is gone (Boxes
  list = only real boxes). PR #546. Verify: Home shows only real boxes, no "This
  device" row. [app, on-device]
- **New-box preflight + clear failure surfacing** — the SSH bootstrap now probes
  OS/arch/curl-or-wget/writable-HOME and verifies the installed broker actually
  executes (arch mismatch / noexec / security policy), surfacing a specific
  error (UnsupportedPlatform / CurlMissing / BrokerExecFailed / HomeUnwritable /
  BrokerInstallFailed) instead of a cryptic health-timeout; readiness gained a
  git-present probe. PR #547. Verify: add a normal Linux box → still works; the
  failure messages are exercised only on odd hosts. [core+broker-script+app,
  on-device]
- **Onboarding new-box UX polish** — (1) the onboarding Install step's "Add via
  SSH" now actually opens the SSH login sheet (was a dead-end); (2) the SSH
  add-box card is de-jargoned ("Add via SSH" / plain subtitle, was "SSH
  bootstrap / cold-start a broker"); (3) the session row shows the live
  "⏳ Installing <agent>…" message while a box installs the chosen agent on first
  use; (4) readiness rows distinguish auto-installing agents ("installs on first
  use", neutral) from genuinely-missing infra (red "not installed"). PR #548.
  Verify: onboarding → Add via SSH opens the sheet; first session on a fresh box
  shows the install hint; readiness shows agents as "installs on first use".
  [iOS+Android, on-device, tablet+phone]

---

## v0.0.147

- **Forget + re-add an SSH box now works** — the bootstrap reuse path returns
  the broker's LIVE token (read from the systemd unit) instead of the app's
  freshly-minted preToken, fixing `Auth(Code 1)` → Home offline / empty
  directory / no-session after forget+re-add. PR #535. Verify: forget an SSH
  box, re-add it → it connects, lists the directory, and starts a session.
  [broker-script via app/core, on-device]
- **New-session picker gated to the connected box** — box rows other than the
  connected box are non-selectable (switch in Settings) so readiness, the
  directory browser, and the create target are all coherent (no more "picked
  box A, saw box B"). PR #536. Verify: with multiple boxes, open new-session
  picker → only the connected box is selectable. [app, on-device, tablet+phone]
- **SSH auth self-heal** — an Auth error on an SSH box now triggers an
  automatic re-bootstrap/reconnect (single-flight, bounded) instead of the
  wrong "Pairing expired — scan a new QR" message; token-paired boxes keep the
  QR message. PR #536. Verify: provoke an auth error on an SSH box → it
  self-heals and reconnects (no QR prompt). [app, on-device]
- **Concurrent multi-box (experimental, first cut)** — behind
  `FeatureFlags.concurrentMultiBox` (DEFAULT OFF; toggle Settings → Labs →
  Debug → Transport). When ON: connect multiple boxes at once, sessions
  aggregated/grouped per box, ops routed to the owning box's connection. Flag
  OFF = no change (byte-equivalent). SSH/loopback boxes only; per-box
  OAuth/readiness deferred. PR #537 (iOS). Verify: flag ON → connect two boxes
  → both boxes' sessions show live and sends go to the right box.
  [iOS, experimental, on-device]

---

## v0.0.146

- **On-demand per-agent install** — starting a session with an agent that isn't
  on the box now installs ONLY that agent (claude/codex) on the fly, showing
  `⏳ Installing… → ✅ installed`, then starts; the bootstrap no longer
  eager-installs anything. PR #531. REQUIRES BROKER REDEPLOY. Verify: on a box
  without codex, start a codex session → it installs then runs. [broker, on-device]
- **Box UI — real host + filtered sessions + agent state** — a connected SSH box
  shows its real host (root@host) instead of 127.0.0.1; Box-health "sessions
  here" is filtered to that box; agents show "not installed on this box" vs
  account-signed-in. PR #530. Verify: connect a box → box header shows correct
  host; sessions list is scoped to that box; agent rows reflect install state vs
  sign-in state. [app, on-device, tablet+phone]
- **Box-switch loads the new box's sessions** — switching boxes now loads the
  switched-to box's sessions (was stuck showing the previous box), while keeping
  other boxes' sessions grouped/dimmed. PR #533. Verify: connect two boxes,
  switch between them → each switch immediately shows the target box's sessions.
  [app, on-device, tablet+phone]
- **Onboarding guide surfaced** — the onboarding guide is now reachable via a
  "New here?" card on the no-boxes Home state and a Settings → "How it works"
  row, with content covering add-box → auto-bootstrap → on-demand agent install.
  PR #532. Verify: fresh install (no boxes) → "New here?" card visible on Home;
  Settings → "How it works" opens the guide. [app, on-device, tablet+phone]

---

## v0.0.145

- **SSH self-healing box setup (PATH + idempotent re-add)** — the SSH-bootstrap
  broker unit now sets `PATH` including `~/.local/bin`, so agent CLIs
  (claude/codex) installed there are found by the broker (fixes "exec: claude:
  executable file not found" → sessions wouldn't start). The bootstrap
  idempotently rewrites a stale unit (missing PATH) on re-add, so an existing
  box self-heals on reconnect with no manual box commands. PR #526. Verify:
  reconnect a previously-broken SSH box → claude sessions start without touching
  the box. [broker-script via app/core, on-device]
- **SSH tunnel self-heal (auto-reconnect)** — the russh tunnel now uses a tighter
  keepalive (~45–60 s dead-peer detection) and the app auto-reconnects when the
  tunnel drops (backoff + single-flight + persisted SSH creds), instead of
  failing with "Connection refused" until a manual re-add. PR #527. Verify: drop
  the tunnel (background app / network switch) → it reconnects on its own and
  sessions/folder-listing resume. [core+app, on-device, tablet+phone]
- **SSH Sentry quota hygiene** — the forced ssh connect-attempt/blocked/
  bootstrap-success captures (added when telemetry was dark) are demoted to
  breadcrumbs; genuine failures still capture as events. PR #525. [app]

---

## v0.0.144

- **claude missing-CLI now surfaces an error** — when the `claude` CLI isn't on
  the box, the session now shows `⚠️ claude: failed to start: …` in chat (like
  codex) instead of hanging silently on "ASSISTANT". PR #521. REQUIRES BROKER
  REDEPLOY. Verify: remove or rename the `claude` binary on a box → session
  shows the error message in chat immediately rather than hanging. [broker, on-device]
- **Box-grouped sessions + send-gating** — Active Sessions are grouped under box
  headers; the connected box's sessions are live, other boxes' sessions are
  dimmed and tapping one switches to that box first; sends are gated to the
  session's box, eliminating the `UnknownSession`/"chat send gave up after
  retries" failures. PR #522. Verify: open the session list with multiple boxes
  → sessions are grouped by box, non-active boxes are dimmed; tap a session on a
  different box → box switches before opening the session; send a message →
  verify no `UnknownSession` error. [app, on-device, tablet+phone]
- **Pairing-flow "Continue" first-tap responsiveness** — the post-pair
  agent-picker "Continue" button now shows an immediate spinner + single-flight
  on the first tap (was unresponsive until spam-tapped). PR #522. Verify: pair a
  new box → tap "Continue" once → spinner appears immediately and the flow
  proceeds without requiring repeated taps. [app, on-device]
- **Live Activity background-start guard** — the app no longer calls
  `Activity.request` from the background (the ActivityKit `.visibility` error),
  and the LA-failure is demoted to a breadcrumb (quota hygiene). PR #523.
  Verify: background the app, start a session → no `.visibility` ActivityKit
  crash/error; Sentry shows a breadcrumb rather than a full event on LA failure.
  [iOS, on-device]

---

## v0.0.143

- **Codex needs-input marker-leak fix** — the `[[conduit:needs-input]]` sentinel
  no longer renders as a duplicate raw chat bubble; the live chat path now strips
  it (and dedupes against the typed card). PR #518. Verify: trigger a codex
  needs-input prompt → the sentinel does not appear as a raw bubble in the chat;
  only the typed card shows. [app, on-device]
- **Codex plan mode** — the broker injects a planning `developerInstructions`
  when plan mode is set, so codex proposes a plan instead of acting (read-only
  sandbox alone only gated writes); broker logs the applied
  permission_mode/sandbox. Broker has ALREADY been redeployed with this change.
  PR #517. Verify: start a codex session in plan mode → codex proposes a plan
  before making changes rather than acting immediately. [broker, on-device]

---

## v0.0.142

- **Live git state + worktree name per session** — session Info + rail show
  current branch, ●uncommitted count, ↑/↓ ahead-behind, and the worktree name;
  broker computes live (2s cache). PR #512. Verify: open a session on a repo
  with uncommitted changes + an ahead/behind count → Info screen and session
  rail both show branch, ● count, and ↑/↓ numbers correctly; worktree name
  appears when the session is in a worktree. [app, on-device, tablet+phone]
- **Tappable PR/MR outcome chip** — the PR chip opens the live PR/MR web link
  (GitHub via gh, GitLab via glab/remote); chip is read-only when no PR exists.
  PR #513. Verify: a session with an open PR shows a tappable chip → tap opens
  the correct URL in the browser; a session with no PR shows a non-tappable
  chip. [app, on-device]
- **Real Buy-Me-a-Coffee link** — Settings donation link now points to
  buymeacoffee.com/conduitapp. PR #514. Verify: Settings → donate row →
  opens buymeacoffee.com/conduitapp in the browser. [app, on-device]
- **Live SSH bootstrap progress + ECONNRESET hardening** — add-box shows
  per-phase progress (connecting → handshake → auth → download → start →
  tunnel → ready) via a core SshProgressDelegate; single-flight guard +
  one-shot ECONNRESET retry; failure now surfaces even if the sheet was
  dismissed. PR #515. Verify: add a box via SSH → progress phases display in
  sequence; kill the connection mid-way → error surfaces in the UI (not lost
  silently). [app, on-device]
- **SSH add-box broker-download fix (THE add-box fix)** — bootstrap now
  downloads the broker from the versioned release URL (all releases are
  prereleases, so /latest/ 404'd → broker never installed → ERR13 crash-loop);
  verify-before-unit gives a clean ERR16; app passes CONDUIT_VERSION. PR #516.
  Verify: add a fresh box via SSH with no broker installed → bootstrap
  completes without ERR13; session connects successfully. [iOS+Android+broker-script, on-device]

---

## v0.0.141

- **Fast-mode toggle (actionable)** — the read-only "Fast mode available" label
  is now an actionable Toggle (iOS) / Switch (Android) in the new-session picker
  + fork sheets; turning it on launches claude with `--settings '{"fastMode":true}'`
  (core→broker). PR #509. Verify: on a claude model that advertises fast mode,
  the toggle appears, flips, and a forked/new session honors it.
  [app, on-device, tablet+phone]
- **SSH host-key prompt deadlock fix** — the TOFU "unknown host key" prompt is
  now an alert that presents OVER the Add-via-SSH sheet (previously a root
  `.sheet` that couldn't present over it, so first-connect hung on "Starting
  server" forever). Connect is disabled while bootstrapping; a 120s host-key
  timeout prevents any eternal hang; `ssh_hostkey` breadcrumbs added. PR #510.
  Verify: add a box via SSH to a NEW host → the host-key alert appears → Trust
  & Connect → the session connects (no infinite "Starting server"). [iOS, on-device]

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
