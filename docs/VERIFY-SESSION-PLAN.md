# Verify Session Plan

Consolidated, deduplicated, risk-ordered test script for clearing the ~61
merged-but-never-device-verified release sections in
[VERIFY-CHECKLIST.md](VERIFY-CHECKLIST.md) (v0.0.139 → v0.0.216) in one (maybe
two) device sessions.

**CI green ≠ device-verified.** Mobile is CI-compile-only on the dev box (no
Mac/Xcode, no Android SDK) — every item below was only proven to *compile* and
pass unit tests, never exercised on a real device.

**How to use this doc:**
1. Run **Part A** first — ~12 flagship flows, each touching many release
   sections at once. This is the highest-value 80% of the surface area.
2. Run **Part B** for anything Part A didn't reach, grouped by feature surface.
3. Run **Part C** from a shell on the box during the same session (no UI
   needed) — broker-behavior-only checks.
4. Run **Part D** any time — the shared-agent-credential lineage design is
   now the ONLY path (the flag was removed; env var ignored), so there is no
   separate flip-on step left to gate this on.
5. **Any failure:** screenshot + one-line note next to the item, keep going —
   don't block the rest of the session on one red item.
6. **On completion:** for every checked item, move its bracketed source
   section(s) from `VERIFY-CHECKLIST.md` to [DONE.md](DONE.md). Leave failed
   items in the checklist with a note. Sections in the **Skipped as obsolete**
   appendix can move straight to a "won't verify — superseded/removed" note
   without device time.

Do both iOS and Android for every item unless the item says otherwise. Where a
flow calls out phone vs tablet, do both form factors on at least one platform.

---

## Part A — flagship smoke flows (do these first)

- [ ] **A1. New session with model/effort override.** Start a session, pick a
  non-default model + effort (incl. Gemini if enabled) via the picker, confirm
  Box Readiness shows the credential-source subtitle, complete a turn, open
  Session Info → confirm the live Model row matches what you picked.
  Expected: picker lists the live catalog (no stale/dismissed models), the
  chosen model actually runs, Session Info reflects it.
  [v0.0.216 #900 (Gemini override); v0.0.213 #874 (Session Info model row);
  v0.0.205 #788 (credential-source subtitle); v0.0.150 #4 (model picker drops
  dismissed models); v0.0.141 #509 (fast-mode toggle); supersedes v0.0.149 #7,
  v0.0.136 model-catalog richness]

- [ ] **A2. Stream a thinking-heavy Claude reply.** Send a prompt that makes
  Claude think at length. While it streams: cycle the Debug-menu (7-tap
  version) Working-Indicator picker through all 6 styles (A–F); confirm the
  "Thinking…" disclosure expands with real reasoning and the indicator peek
  shows a live reasoning line; confirm the rail draws continuously downward
  with no stutter/overshoot/restart, inline markdown renders live, the caret
  sits with a small gap and doesn't jiggle; toggle Reduce Motion → calm/static
  end-state. Background mid-stream, foreground → animations resume and the
  streamed message isn't wiped.
  Expected: all 6 styles selectable and persist across launch; thinking block
  shows real content; rail never freezes/overshoots/restarts.
  [v0.0.212 #857, #855, #848; supersedes v0.0.211 #845, #842; v0.0.210 #829,
  #827, #835(ts-sort, see A3); v0.0.209 #821/#822/#824; v0.0.207 #815; v0.0.206
  #810; v0.0.205 #790/#791; v0.0.204 #770/#771]

- [ ] **A3. AskUserQuestion end-to-end.** Trigger an AskUserQuestion (multi-
  option and free-text). Answer it: confirm no duplicate plain-text bubble,
  the card collapses to a green `✓` chip in chronological place (not bottom),
  no stray `[[conduit:resolved]]` text ever renders, the answer isn't queued
  behind a "Queued Next" gate, and the chip survives close+reopen. Answer one
  from the Approvals panel (option buttons, not generic Approve/Deny) and one
  from the lock-screen Live Activity while backgrounded — confirm the LA
  leaves "needs you" state and the in-app card reconciles without opening the
  app. If a physically paired Apple Watch is available, answer from the wrist.
  Expected: exactly one card per question, correct ordering, no leaked
  markers, LA/Watch answers reconcile app state.
  [v0.0.211 #843; v0.0.212 dedup (folded); v0.0.210 #835 (iOS ts-sort);
  v0.0.205 #799/#798/#789; v0.0.196 #743 (Watch); v0.0.195 #744; v0.0.194
  #738-741; v0.0.193 #737; v0.0.192 #734/#735; v0.0.156 #576 (LA reconcile);
  v0.0.150 #5/#6; v0.0.149 #9 (actionable approvals); v0.0.139 codex extra-
  approval cards]

- [ ] **A4. Broker-restart mid-chat.** With a session open and the agent
  actively working, queue a second message ("Queued Next"), then restart the
  broker. After reconnect: composer returns to Send (not stuck on Stop), the
  queued message auto-delivers under its ORIGINAL bubble without any tap, the
  agent replies exactly once (no duplicate turn), the prior transcript is
  still visible (not empty), and the session's git/model/branch state is
  intact. Repeat with the agent mid-turn when the broker restarts (not idle).
  Expected: no stuck turn-active, no stranded queue entry, no dup reply, full
  transcript survives.
  [v0.0.213 #878, #873, #866, #865, #872(no-op); v0.0.212 #851; v0.0.196 #752
  (agent memory persists); v0.0.182 #700 (transcript replay); v0.0.156 #577
  (durable send — see A5); v0.0.152 credential propagation still holds]

- [ ] **A5. Durable send survives a force-kill.** Send a message, then
  immediately force-quit the app. Reopen: the bubble was faded/dotted, then
  resolves to solid once the broker acks (no loss, no duplicate delivered to
  the agent).
  [v0.0.213 #878; v0.0.156 #583; v0.0.196 #751; v0.0.203 #769; supersedes
  v0.0.137 #479 (optimistic-send persistence), v0.0.149 #8 (chat retry)]

- [ ] **A6. Background/foreground churn.** Open 2+ sessions, background the
  app for 60+ seconds (device shouldn't heat up — WS paused), foreground:
  content is fresh within ~1–2s, the "Reconnecting" banner does NOT flash for
  genuinely-fine connections (only appears after ~4s if actually dead),
  animations (dot/rail/spinner) resume rather than staying frozen, and a
  push-driven Live Activity update arrived while backgrounded (trigger a turn
  end while the app is backgrounded, confirm the lock-screen LA updated via
  APNs, not just on foreground).
  [v0.0.213 #875, #869, #871; v0.0.195 #746; v0.0.209 #824; v0.0.139 #500/#501
  (push-driven LA)]

- [ ] **A7. Agent handoff (Claude ↔ Codex).** Complete a Claude turn, "Switch
  to Codex" from the title menu, send a normal message, confirm context
  continuity (Codex knows what Claude was doing); switch back to Claude,
  confirm it remembers its ORIGINAL thread (not the handoff text as new
  history). Confirm the row is disabled while a turn is running or an
  AskUserQuestion is pending, and that a forced target-startup failure leaves
  the session on the old agent (rollback), not stranded.
  [Next-release-pending / v0.0.213 transactional handoff (no PR#)]

- [ ] **A8. Multi-box switching.** Connect two boxes, switch between them
  several times: no connected→disconnected flicker, each box's Home row shows
  its OWN session count (not the mixed total), every Active-Sessions row is
  badged with its box name, History rows keep a stable per-box label, and
  each box's Agent-accounts row shows correct per-box sign-in status
  independently.
  [v0.0.186 #711 (session-safe auto-update — see A9 too); v0.0.156 #575;
  v0.0.154 #570/#571; v0.0.153 #567/#568; v0.0.152 #563-565; v0.0.148 #522;
  v0.0.147 #536; v0.0.144 #522; supersedes v0.0.137 #472]

- [ ] **A9. Broker auto-update + session-safe restart.** Connect a box running
  an older broker with NO live sessions → it updates silently. Then connect
  one WITH a live session running → a warning banner/dialog appears before
  restarting, and sessions auto-resume snapshotted state after.
  [v0.0.186 #711; supersedes v0.0.154 #570 ("finally working"), v0.0.148 #539]

- [ ] **A10. Full pipeline run.** Build a multi-step pipeline via the
  block-stack Builder with per-block model/effort/permission-mode/
  instructions, an **If/Else** block (condition on `prev_output`/exit
  status), a **Loop** block (2 iterations), and a **Fan-out** step (2 runs,
  different agent types). Run it: confirm topology rail shows fork/repeat
  glyphs, Monitor shows live per-step + per-iteration + per-run state,
  awaiting-pick panel appears when fan-out runs settle → Pick a winner →
  pipeline continues; hit a gate → review/edit the computed handoff → Continue
  with the edit reflected in the next step's prompt; fail a step → Retry with
  an edited prompt (retry-N chip appears); Save the pipeline as a template,
  reload it, confirm all fields (incl. control-flow blocks) survive; confirm
  a claude (stream-json) step actually ADVANCES past its step (TurnComplete
  fix) instead of hanging; reopen via the Home banner card and the command-
  palette "Pipelines" entry after dismissing the Monitor sheet; confirm
  completed steps' agent processes are NOT left running (check process count
  on the box).
  Expected: every block type renders/executes correctly across phone+tablet,
  iOS+Android; no orphaned processes; gate/resume/template state all round-
  trip.
  [v0.0.216 #901/#902, #899; v0.0.215 #895, #891 (root-mirrored flags — if
  this is missing, per-block config silently gates OFF); v0.0.214 #888/#889,
  #881 (process reap); v0.0.213 #862/#863, #859/#861, #852/#853; v0.0.204
  #774, #776/#777 (FanOut compare — also exercise Open / Commit & PR from the
  awaiting-pick compare view); v0.0.190 #726/#727 folded into Mono-block, N/A
  here]

- [ ] **A11. Found Sessions (discover/resume/branch/watch).** On a box where
  you've started a Claude/Codex session BY HAND over SSH: open box detail →
  the "Started outside Conduit" card shows a count → open the sheet → resume
  an IDLE row (full prior context, agent replies) → View a row read-only (no
  composer, "read-only" chip) → on a RUNNING row, Branch a copy (new worktree,
  terminal session untouched) and Watch live (read-only tail, "not driving"
  banner, Branch-from-watch works) → Hide a row (persists, 4s undo).
  [v0.0.167 #624/#625; v0.0.165 #620/#621/#622; v0.0.164 #616/#617/#618;
  v0.0.163 #614; v0.0.162 #610/#611; v0.0.161 #606/#607/#608; v0.0.160
  #602/#603/#604 — this one flow supersedes ALL of v0.0.160 through v0.0.167's
  Found Sessions bug-fix iterations]

- [ ] **A12. Archive + memory + bulk delete.** Have a long-chat session (many
  turns), archive it → History shows "Ended" not "Running", opacity is
  dimmed, memory drops (Sentry chat-count breadcrumbs at 100/500/1000 if
  reachable); reopen the archived session → transcript still loads (re-fetched
  via HTTP). Archive 2+ sessions → a trash icon appears in History's top bar →
  confirm → bulk-delete removes them permanently.
  [v0.0.203 #775, #765; v0.0.159 #599/#600 (full-swipe = Archive/Delete on
  iOS); supersedes v0.0.202 #763 (GC eviction — spot-check only, needs a
  7-day-old session, see Part B)]

---

## Part B — feature-specific checks by surface

### Pipelines/harness (residual, beyond A10)
- [ ] B1. Delete a saved pipeline template with the delete-confirm dialog.
  [v0.0.213 #859/#861]
- [ ] B2. Confirm Gemini appears in the Builder's agent list with its model
  row correctly hidden (Gemini doesn't take a model override in the picker
  UI, per plan). [v0.0.214 #888/#889 §8.3]
- [ ] B3. Global concurrency cap: start enough fan-out runs to exceed
  `CONDUIT_MAX_CONCURRENT_AGENTS` (default 3) and confirm excess runs queue
  instead of all spawning at once. [v0.0.216 #901]

### Chat/composer
- [ ] B4. **Command-run "Mono block".** Run a single shell command → inline
  mono block with a checkmark (not "exit 0" text); run 10+ commands → collapse
  to a summary ledger with a live ticker + progress rule during the run,
  quiet "N ran clean — show all"; include a failing command → auto-expands,
  red exit code + stderr tail, no middle-truncation (only end-truncation).
  Confirm this is default ON (no Settings toggle needed).
  [v0.0.201 #760 (default-ON — supersedes v0.0.190 #726/#727 flagged version,
  v0.0.193 #737 tool-cluster collapse, v0.0.182 #693/#694 "Show command
  detail" — REMOVED, see obsolete appendix, v0.0.156 #576 Arm-B collapse,
  v0.0.149 #10 Arm-B grouping)]
- [ ] B5. `/clear` on a live Claude session → confirmation message, no stray
  "(no content)" bubble, agent forgets prior turns. `/clear` on a Codex
  session → fresh thread, same forgetting behavior.
  [v0.0.212 #849, v0.0.211 #844]
- [ ] B6. Peer-session message: from one session's agent, send a message to
  another live session (see Part C for the CLI half) → confirm it renders as
  a labeled PEER MESSAGE card (not a raw "YOU" bubble) with header-tap
  navigation to the sender session. [v0.0.215 #892; v0.0.214 #884]
- [ ] B7. Long-press a sent user bubble → Copy → full message on clipboard
  (not per-character selection). [v0.0.205 #786]
- [ ] B8. iOS: swipe from the left edge in a chat's messages area → navigates
  back. [v0.0.182 #698]
- [ ] B9. iOS: drag the messages list down to dismiss the keyboard → composer
  tracks the keyboard edge live through the whole drag (note: only the
  drag-dismiss is claimed fixed; the resting position was a documented
  follow-up — check whether it still gaps). [v0.0.186 #712]
- [ ] B10. Voice: speak, pause 10+ seconds, speak again → transcription
  continues (not stuck); mic button visible alongside Stop while the agent is
  working and the composer is empty. [v0.0.196 #749]
- [ ] B11. A command whose output contains a markdown checklist (e.g.
  `gh pr create` with a "## Test plan") renders as a normal command, NOT a
  PLAN card. [v0.0.182 #699]
- [ ] B12. Renaming a session (title menu → Rename, and from Session Info)
  on both iOS and Android: keyboard/auto-focus, validation hint, disabled
  Save on invalid input — check phone + tablet. [v0.0.214 #882]

### Home/sessions list
- [ ] B13. Pull down on the Home sessions list → spinner appears → a session
  started on another device/box (or directly on the box) appears after
  refresh completes. [v0.0.199 #756; v0.0.196 #750 (cross-device discovery) —
  this is the newer/broader behavior, test that specifically]
- [ ] B14. Spot-check: a session on-disk for 7+ days that the broker has
  GC'd is evicted from local History on next reconcile (hard to trigger live
  in one sitting — spot-check the code path or skip if no aged session is
  available). [v0.0.202 #763]
- [ ] B15. iOS: full-swipe on a History row commits Delete (still confirms);
  full-swipe on Home commits Archive; full-swipe in Settings → Boxes commits
  Forget box. [v0.0.159 #599]

### Live Activities / push
- [ ] B16. Lock/background the device, trigger an approval-requiring action →
  the Turn Live Activity appears on the lock screen with the app fully
  closed (push-to-start); Approve from the lock screen unblocks the agent and
  dismisses the card; foreground the app → exactly one card (no duplicate).
  [v0.0.156 #581/#582; v0.0.216 #898 (re-arm the update-token observation on
  every foreground, not just launch)]
- [ ] B17. With the app foregrounded on the home screen, trigger a turn end
  → NO spurious push fires; let 60s elapse, trigger a turn end → push fires
  normally. [v0.0.201 #759; supersedes v0.0.182 #696 owner-presence gate]
- [ ] B18. Trigger a multi-turn run → no intermediate "done" push while turns
  are still flowing; when the agent genuinely stops, the push body is
  AI-rewritten (not a raw truncated dump); lock the screen and start a
  session → the LA appears at turn-start, not turn-end.
  [v0.0.186 #713]
- [ ] B19. End a session → its "done"-state Live Activity disappears from the
  lock screen within ~5 minutes (not ~4 hours). [v0.0.192 #734]
- [ ] B20. iOS: watch for the Sentry `CALayer bounds contains NaN` crash
  during a keyboard-show + chat-scroll sequence — no targeted repro, just
  don't crash. [v0.0.216 #897]

### SSH add-box / bootstrap
- [ ] B21. **Add a brand-new box via SSH end-to-end.** A host key you've
  never trusted → the TOFU verify card renders INLINE in the same Add sheet
  (not a separate dismissing alert) → Trust & continue → a blocking
  install-progress overlay shows staged dots (connecting → securing →
  authenticating → tunnel → installing → starting) → box comes online → an
  agent session starts (installs on-demand if the CLI isn't present yet,
  showing "⏳ Installing…"). Force a failure (bad host/kill mid-install) → a
  specific error + Retry persists the box in Settings as "Add failed",
  retryable with prefilled fields.
  [v0.0.158 #595/#594; v0.0.156 #580; v0.0.146 #531; v0.0.145 #526; v0.0.142
  #515/#516; v0.0.140 #507; v0.0.157 #588 checksum verify; supersedes v0.0.140
  #510 host-key-deadlock fix (superseded by inline TOFU), v0.0.149 #3 SSH
  restyle]
- [ ] B22. `curl -fsSL https://conduit.kaopeh.com/install.sh | sh` on a fresh
  box → installs and starts successfully (no 404, no prerelease issue); the
  onboarding "Add a box" screen shows this exact URL for both the mac/linux
  and VPS variants. [v0.0.208 #817 (newest URL); supersedes v0.0.200 #758,
  v0.0.199 #755/#754]
- [ ] B23. Reconnect a previously-SSH-broken box (missing PATH) → claude/codex
  sessions start without touching the box manually. [v0.0.145 #526]
- [ ] B24. Drop the SSH tunnel (background/network switch) → auto-reconnects
  on its own; folder listing and sessions resume. [v0.0.145 #527]
- [ ] B25. Forget an SSH box, re-add it → connects, lists directory, starts a
  session (no `Auth(Code 1)`). [v0.0.147 #535]

### Settings
- [ ] B26. Settings has no push-notification section; Conversation settings
  only shows Collapse Turns + Reply Haptics (Mono block toggle also removed
  now that it's default-on, see B4); Settings → Agents shows real logo
  circles. [v0.0.203 #768]
- [ ] B27. Tap the About version 7× → Debug menu unlocks; Settings has a
  single "Add a box" (no separate Replay-walkthrough/Add-machine rows at the
  top level — they're reachable via onboarding entry, see B41); no A/B
  conversation-style picker (permanently Signature/Mono-block).
  [v0.0.167 #624/#625 item 4]
- [ ] B28. Provider ⋯ menu → Re-authenticate launches OAuth directly (no
  intermediate "Manage" sheet); the label reads "Manage" at the top level.
  [v0.0.156 #575]
- [ ] B29. Per-box account status: connect a box without Claude configured →
  row shows "Not on <box>"; after auto-propagate/sign-in it flips to "Ready
  on <box>"; "Remove pushed credential from this box" clears only the
  app-pushed cred (box owner's own CLI login untouched).
  [v0.0.153 #567/#568; v0.0.152 #563-565]
- [ ] B30. Open Session Info (ⓘ) on a live session → Terminal row shows the
  FULL copyable `CONDUIT_TOKEN=… conduit-broker chat <id>` command (not
  middle-truncated); tap to copy → paste on the box → attaches and shows the
  live chat. [v0.0.202 #761; v0.0.199 #757]
- [ ] B31. Session Info → tap "Recap" on a completed session → sheet opens
  with identity/what-changed/file-stats/commands/duration/tokens; a running
  command-bar shows an animated cyan sheen sweep. [v0.0.202 #762]
- [ ] B32. Session Info → Details → Box row shows `Name (host:port)` after
  renaming a box. [v0.0.150 #2]
- [ ] B33. Session Info → live git state (branch, ● uncommitted count, ↑/↓
  ahead-behind, worktree name); tappable PR/MR outcome chip opens the real
  browser URL. [v0.0.142 #512/#513]
- [ ] B34. Session Info → subagents: active ones always visible inline,
  done/failed ones collapse under a tappable "Earlier agents (N)" row.
  [v0.0.196 #748; supersedes v0.0.138 #490-492 base panel]
- [ ] B35. Codex plan mode: start a codex session in plan mode → it proposes
  a plan before acting, not immediately. [v0.0.143 #517]
- [ ] B36. DiffReview on a session with real changes → "Commit & push" (msg
  input → SHA shown) and "Open PR" (title+body → URL shown, opens in
  browser) both work against the broker git endpoints.
  [v0.0.203 #764/#766]
- [ ] B37. Settings → donate row opens buymeacoffee.com/conduitapp.
  [v0.0.142 #514]

### Onboarding / demo mode
- [ ] B38. **Demo mode end-to-end.** Fresh install → onboarding → "Explore
  without a server" → demo home (2 sessions) → open session 1 ("Build a
  to-do app") → confirm it shows EVERY card type in order: plan roadmap,
  tools, code block, diff, subagent edge-case, handoff (claude›codex),
  pending-input → open Session Info → real Usage ring/tokens/Recap, no
  Fork/End/Compact → open Changes → real diff renders read-only, no
  commit/Open-PR controls → gear → change theme/font (previews live) → Exit
  Demo → real app's appearance is UNCHANGED (snapshot/restore).
  [v0.0.212 #850; v0.0.211 #846, #841, #840; v0.0.197 #753 (base demo mode)]
- [ ] B39. Fresh install (delete + reinstall): brief splash → onboarding
  wizard directly, no flash-before-splash, no Settings-page pop. Returning/
  paired launches unaffected. [v0.0.159 #597/#598]
- [ ] B40. Android: first-run onboarding welcome matches iOS — trailing `›`
  chevron, no `×` on first run, logo tile, teal `>conduit`, teal "Enter a
  code" row. [v0.0.208 #818]
- [ ] B41. Settings → Replay walkthrough → opens at Welcome (not Done); X
  closes without re-pairing; Add a machine → opens at Install.
  [v0.0.151 #561; v0.0.150 #1 (Close/X control exists at all — supersedes,
  was previously untestable since there was no exit)]

### Android-specific
- [ ] B42. On the same Wi-Fi as a broker, Android auto-discovers it via mDNS
  (no manual IP entry). [v0.0.168 #628]
- [ ] B43. Android phone: back-from-chat → Home; swipe a session row →
  archive + Undo Snackbar; start a session even when directory listing
  fails; landscape phone does NOT trigger the tablet 3-pane layout.
  [v0.0.168 #632]
- [ ] B44. Android cards render at 14dp corner radius (not the old 20/22dp);
  `ConduitActionPill`/`ConduitChip` render correctly on Home, AgentPicker,
  and FoundSessions sheets (no visual regression vs iOS reference).
  [v0.0.205 #792-#807 batch]

### Tablet layouts
- [ ] B45. New-session picker + fork sheet on tablet: fast-mode badge/toggle
  renders correctly (not just phone). [v0.0.138 #494]
- [ ] B46. Chat composer + Queued-Next width caps correctly on tablet (not
  full-bleed). [v0.0.138 #494]
- [ ] B47. Command-run Mono block (B4) checked on BOTH phone and tablet
  layouts, both platforms. [v0.0.201 #760]
- [ ] B48. Demo mode (B38) checked on iOS + Android phone AND tablet.
  [v0.0.197 #753]

---

## Part C — broker-behavior checks (shell, same session)

- [ ] C1. From one live session's agent shell: `conduit-broker chat --list`
  then `chat send <other-session-id> "hello"` → confirm delivery in the
  other session's transcript on the phone (see B6 for the app-side card).
  [v0.0.214 #884]
- [ ] C2. `conduit-broker chat <session-id>` from an SSH shell on the box →
  attaches to a live session's chat and can send. [v0.0.182 #695]
- [ ] C3. `scripts/conduit-backup.sh /tmp/test-backup.tar.gz.gpg` → passphrase
  prompt, encrypted file written; decrypt + inspect `manifest.txt` → tier-1
  items staged. [v0.0.139 #498]
- [ ] C4. Long-running Claude session near token-refresh boundary → restart
  the broker → confirm via `daemon.log` / a follow-up turn that the CLI-
  refreshed token was NOT clobbered by a stale re-materialize.
  [v0.0.205 #787]
- [ ] C5. On a box with NO `codex` installed, start a codex session → it
  installs on the fly (`⏳ Installing… → ✅ installed`) then runs.
  [v0.0.146 #531]
- [ ] C6. Fresh bare-VPS box (no `/workspace` dir) → agent spawns rooted at
  `$HOME`, not a missing path. [v0.0.195 #747]
- [ ] C7. `curl` the app's own auth token against `/api/session/{id}/git/commit`
  and `/git/pr` directly on a dirty worktree → commit lands / PR opens (cross-
  check against B36's UI path). [v0.0.203 #764]

---

## Part D — shared-agent-credential lineage

The `CONDUIT_SHARED_AGENT_CREDS` flag has been REMOVED — this design
(`broker/internal/session/credseed.go`) is now the ONLY credential path,
unconditionally. It shipped behind the flag in PR #732, was flipped on the
live box 2026-07-06, passed live verification (item 1, the operator-logout
regression check, below), and the legacy per-session-copy apparatus was
deleted once verified. Items D1–D4 below (live items 2–4 from
[PLAN-AGENT-CREDENTIAL-LINEAGE.md §10](PLAN-AGENT-CREDENTIAL-LINEAGE.md#10-test-plan))
remain useful regression checks for this app-side pass.

- [ ] D1. **Login-less SSH box, app-push seeding.** Fresh box, no host login.
  Push the credential blob from the app → the canonical file is seeded from
  the blob → a session runs on the pushed account. Switch accounts in the
  app → the next turn picks up the NEW account (re-seed, not stuck on the
  old one). [PLAN-AGENT-CREDENTIAL-LINEAGE.md §10 live item 2; also exercises
  v0.0.210 #830 model-catalog-uses-shared-cred fix — confirm the model
  picker shows entitlements for the pushed account, e.g. Fable, once probed
  under the shared-cred env]
- [ ] D2. **Resume across distinct cwds under the shared dir.** Start a
  Claude session and a Codex session in two DIFFERENT working directories.
  Confirm `--resume` / `exec resume` finds the correct PER-CWD transcript
  from the shared `projects/`/`sessions/` tree and the two sessions do not
  cross-contaminate each other's history.
  [PLAN-AGENT-CREDENTIAL-LINEAGE.md §10 live item 3; v0.0.205 #785 (resume
  under shared dir after broker restart) folds in here]
- [ ] D3. **Codex refresh storm.** Run several concurrent codex sessions
  until their tokens expire together → confirm self-healing within seconds
  (no permanent logout) — the documented worst case for the no-lock provider.
  [PLAN-AGENT-CREDENTIAL-LINEAGE.md §10 live item 4]

---

## Skipped as obsolete

Surfaces that were later removed or fully replaced — no device time spent;
move their sections straight to a "won't verify — superseded" note.

- **"Show command detail" Settings toggle** (v0.0.182 #693/#694) — the
  toggle itself was REMOVED in the v0.0.203 Settings cleanup; behavior is
  now default-on Mono block (B4).
- **Push-notification Settings section** (predates v0.0.203) — section
  removed outright in v0.0.203 #768; nothing to verify.
- **Labs A/B conversation-style picker** (referenced throughout v0.0.149–
  v0.0.156 as "Arm A" vs "Arm B") — graduated/removed in v0.0.167 #624/#625;
  only one style (Signature/Mono block) exists now.
- **"This device" / local-agent row** (v0.0.148 #546) — removed outright;
  agents never run on-phone in conduit's model (see memory:
  local-agents-feasibility).
- **Separate "Replay walkthrough"/"Add a machine" top-level Settings rows as
  first introduced** (v0.0.149 #1) — consolidated into a single "Add a box"
  entry point in v0.0.167 #624/#625 (still reachable via onboarding intents,
  see B41).
- **Onboarding "Add via SSH" as a dead-end / old SSH-restyle appearance**
  (v0.0.149 #3, v0.0.148 dead-end bug) — fully superseded by the current
  inline-TOFU flow (B21).
- **Old boxes-list without live-state-at-rest** (v0.0.149 #4) — superseded
  by every subsequent box-switching fix (A8, A9); the "true simultaneous
  N-box connections" idea in that same item was flagged design-fiction and
  moved to ROADMAP.md backlog, not shipped.
- **Earlier unverified items (pre-v0.0.136): "Device-bug #28" and
  "Device-bug fixes #261–#264"** — no surviving description of what these
  were; too vague to construct a test. Drop, or re-file as fresh issues if
  the symptom recurs.

**Also excluded (not obsolete, just no device action to take):** CI-only
fixes (Appetize tooling, iOS release-signing/notification-extension fix, CI
test-flake stabilization), docs-only PRs (plan docs, lint-only commits), and
core/broker unit-test-only fixes explicitly marked "no device verification
needed" in their checklist entries (core handoff-classifier tightening, the
opencode 2-min silence timeout, broker-only Sentry-quota demotions). These
still move to DONE.md — they just don't need a device.
