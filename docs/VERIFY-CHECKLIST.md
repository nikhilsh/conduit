# Verify Checklist

Merged features awaiting the owner's on-device verification. The top section,
**Next release (pending)**, accumulates every merge that has NOT yet shipped —
they all go out together in the next tag, so they share ONE heading (do NOT mint
a new `vX.Y.Z` per merge). Sections below it are already-released tags, newest
first. Each item notes whether it needs app testing on a device or
broker-behavior confirmation.

When an item is verified, move it to [DONE.md](DONE.md). When `/cut-release`
cuts the next tag, rename **Next release (pending)** to that version and open a
fresh empty pending section above it; the just-stamped section is that release's
device-test punch list.

---

## Next release (pending)

_Merged but NOT yet released — these all ship together in the next tag.
`/cut-release` stamps this section with the real version and opens a fresh empty
pending section above it. Newest merge first._

**Real Claude thinking shown in the app — iOS + Android. PR #857.**

- Consumes the broker's `thinking_streaming` (PR #854): a **collapsible "Thinking…"
  disclosure** (collapsed by default, dimmed mono, above the streaming prose) plus
  an **indicator peek** — while `turnPhase == "thinking"`, the latest thinking line
  (last non-empty, capped ~80 chars) replaces the working indicator's canned verb
  across ALL styles (incl. the new E/F). Ephemeral (clears at turn end; no
  transcript persistence). Needs the broker redeployed (#854) to see it live.
  [iOS + Android, **needs on-device verify**: drive a thinking-heavy Claude prompt
  → the indicator shows real reasoning + a "Thinking…" block you can expand]

**Two combined working-indicator styles (B+D) — iOS + Android. PR #855.**

- Adds styles **E "Packets @ prompt"** (D's terminal card + shell header with B's
  flowing-packet pipe as the `$` command line + dim verb) and **F "Piped prompt"**
  (D's card + header, a full-width packet-pipe row, then `$ verb▌`). Selectable in
  the Debug-menu working-indicator toggle alongside A–D. Extracted the packet pipe
  into a shared `PacketPipe` atom (both platforms). [iOS + Android, **needs
  on-device verify**: unlock Debug menu (tap version 7×) → Working indicator →
  flip E/F; check pipe sizing/legibility on Ice + Synth palettes; 6-label picker]

**Real Claude thinking is streamed instead of discarded — broker. PR #854.**

- The broker parsed Claude's reasoning blocks but threw the text away (only a
  `"thinking"` phase signal). Now it carries `ThinkingText` and publishes a
  `thinking_streaming` view_event (accumulated reasoning, sharing the turn's
  `turnTS`), reset at turn end. Ephemeral (no transcript persistence, no core
  schema change). This is the enabling half; the app UI (collapsible block +
  indicator peek) is a separate PR. [broker, **redeploy required**;
  broker-behavior confirm: a thinking-heavy prompt emits `thinking_streaming`]

**Queued-Next messages no longer strand — iOS + Android. PR #851.**

- "Queued Next" entries used to pop ONLY on a broker status frame flipping
  `turn_active` false; a missed/late frame stranded them forever. Added a second
  trigger: when the assistant's reply lands (proof the turn ended), flush the
  oldest queued entry too — delivered via a `bypassTurnGate` even if the stale
  `turn_active` is still true. Idempotent with the status-frame path (broker also
  dedups). [iOS + Android, **needs on-device verify**: send a message while the
  agent is working, then confirm it auto-sends when the reply arrives — not
  stranded in Queued Next]

**Pipeline gate handoff preview + editable handoff + named step branches — broker + apps. PRs #852 + #853.**

- **Gate handoff preview (broker)** — on entering `AWAITING_GATE`, the broker
  computes the next step's `{{prev}}` (HANDOFF-OUT + last assistant text per
  `input_from_prev`) plus the gated step's output and persists them as a `gate`
  object in pipeline.json, served by `GET /api/pipeline/{id}`; `input.md` is
  written at gate entry for audit. Cleared on continue/cancel/fail. [broker,
  **redeploy required**]
- **Editable handoff (broker)** — `POST /api/pipeline/{id}/continue` accepts an
  optional `{"prev": "..."}` body; the amended text is what actually spawns the
  next step (spawn reuses the persisted/amended `gate.prev` instead of
  recomputing). Empty/absent body = unchanged. [broker, **redeploy required**]
- **Named step branches (broker)** — pipeline steps run on
  `pipeline-<id>-step-<k>` worktree branches via `CreateOptions.Branch` (Gap A
  seam) instead of default session branches. [broker, **redeploy required**]
- **`pipeline_gate_preview` capability** — new flag in `/api/capabilities`;
  apps gate the new UI on this exact flag (old brokers keep prior behavior).
  [broker]
- **Gate preview + edit UI (iOS + Android)** — Monitor gate section shows the
  computed handoff in a capped scrollable mono block (falls back to step output
  when `prev` is empty), with an "Edit handoff" field; Continue sends the
  amended `prev` only when actually edited. Telemetry breadcrumbs on preview
  shown / handoff edited / continue-with-edit. [iOS + Android, **needs
  on-device verify**: run a gated pipeline, review the handoff at the gate,
  edit it, confirm the next step's prompt reflects the edit]

**Demo session 1 showcases every card type (plan / subagent / handoff added) — iOS + Android. PR #850.**

- The plan / subagent / handoff cards existed only in demo session 2, so the
  first session opened ("Build a to-do app") never showed them (reported: "I've
  never seen plan or subagent"). Session 1 is reworked into one flagship story
  that hits every card type in order — plan roadmap → tools → code block → diff →
  subagent edge-case audit → handoff (claude › codex) → pending-input. No
  renderer change (the read-only ChatView/ChatPage already handled all kinds);
  demo-content only, iOS + Android mirrored value-for-value. [iOS + Android,
  **needs on-device verify**: enter demo → open the first session → plan,
  subagent, and handoff cards all render alongside code / diff / pending-input]

**`/clear` gated on its own capability + send-routing diagnostics — iOS + Android. PR #849.**

- Follow-up to the "no replies after `/clear`" device report (#844 verify). The
  claude CLI + broker stream path was proven healthy via live repro (fresh /
  resume / resume-of-cleared all reply), so the failure is client-side routing —
  not the agent. Two changes: (1) `/clear`'s "supported?" check read
  `supports.compact` instead of `supports.clear` on both apps (which didn't even
  model the `clear` capability the broker sends since #844) — now gated
  per-command with a compact fallback for old brokers; (2) a `chat / send
  routing` breadcrumb on every send records `turn_active`/`pending_ask`/
  `has_client`/`is_slash` so the next occurrence is self-diagnosing in Sentry.
  [iOS + Android, **needs on-device verify**: `/clear` still works on a claude
  session; and if "no replies after /clear" recurs, the Sentry breadcrumb shows
  which branch swallowed the message. Broker turn-end status-broadcast ordering
  is a documented, unfixed suspect.]

**Streaming rail continuously draws down (looping), not once — iOS + Android. PR #848.**

- The streaming spine rail drew down once (eased grow as the message got taller)
  then only the gradient flowed. Now the visible rail length is driven by a
  looping `drawFraction` (0 → 1, ~1.3s, repeat), so the rail perpetually redraws
  itself downward from the mark head — sweep to full height, snap back, repeat.
  iOS `StreamingSpineView` uses a `startDraw` Task-loop (re-kicked on foreground);
  Android `ChatPage.StreamingSpineRow` uses a `rememberInfiniteTransition`. Reduce
  motion pins it to a static full-height rail; the greedy-height fix is preserved.
  [iOS + Android, **needs on-device verify**: stream a reply → the rail keeps
  drawing itself downward the whole time (not a one-shot). Note: each cycle snaps
  back to the mark head before redrawing (the chosen "repeating draw" — tune
  cadence/hold if the reset reads as flickery)]

---

## v0.0.211

**Read-only Changes / diff review in demo mode — iOS + Android. PR #846.**

- The demo project shell gains a "Changes" affordance that opens the real
  diff-review screen in a new `readOnly` mode. When `readOnly` is set the commit
  bar (Commit & push / Open PR) is not mounted, and since the Open-PR sheet is
  only triggered from inside that bar, no broker git call (`/git/commit`,
  `/git/pr`) is reachable. Renders the seeded demo diff (colorama edit) from the
  demo session store; the second demo session has no diff and shows the empty
  state. Default `readOnly=false` leaves real sessions unchanged. [iOS + Android,
  **needs on-device verify**: demo → open a session → Changes → the diff renders
  with NO commit / Open-PR controls]

**Streaming spine rail no longer overshoots the prose — iOS. PR #845.**

- The iOS streaming spine's rail used `.frame(maxHeight: .infinity)` (there is no
  SwiftUI equivalent of Android's `Height(IntrinsicSize.Max)`), which made the
  whole `StreamingSpineView` vertically greedy; placed in the chat transcript
  VStack it ate the leftover viewport height and the cyan→green rail ran far
  below the last prose line. `.fixedSize(horizontal: false, vertical: true)` pins
  the spine to its intrinsic (prose) height so the rail ends at the message.
  Android already uses `IntrinsicSize.Max` and is unaffected. [iOS, **needs
  on-device verify**: stream a long assistant reply → the left rail ends at the
  last prose line, not the bottom of the screen]

**Streaming rail flows continuously (was one-shot) — iOS + Android. PR #842.**

- The flowing-gradient rail animation was a one-shot `repeatForever` that played
  once and dropped on re-render / backgrounding; reworked to a task-loop so the
  rail sweeps downward continuously for the whole turn. [iOS + Android, **needs
  on-device verify**: during a streaming turn the rail keeps flowing (does not
  freeze after the first pass or after foregrounding)]

**Demo mode seeds the session store → real Usage / Recap / Activity — iOS + Android. PR #841.**

- Entering demo now seeds the SessionStore (sessions, `conversationLog`,
  `statusBySession` with context tokens + token totals, lifecycle = live),
  cleared on exit, so the REAL Session Info sheet renders authentic Usage
  (context ring + token line), Activity, and Recap for the demo sessions instead
  of empty state. A new `readOnly` flag on Session Info hides broker-coupled
  actions (rename, fork, end, compact, limits card, terminal-attach) in demo.
  Entry: an info button in the demo project shell. [iOS + Android, **needs
  on-device verify**: demo → open a session → info → Usage ring + tokens
  populated, Recap opens, and there is no Fork / End / Compact]

**Demo mode appearance sheet (session-only, no persistence leak) — iOS + Android. PR #840.**

- A gear on the demo home shell opens the real Appearance sheet; theme / font /
  palette / glow / text-size changes preview live but are snapshotted on demo
  entry and restored on demo exit so they never leak into the real app. The
  snapshot covers every property each platform's sheet can mutate. [iOS +
  Android, **needs on-device verify**: demo → gear → change theme/font → exit
  demo → the real app's appearance is unchanged]

**Answered questions no longer stick as "needs answer"; answers deliver instead of queueing — iOS + Android. PR #843.**

- Three linked pending-ask bugs. (A) `hasPendingAsk` required the `pending_input`
  to be the strict last non-user transcript item, so any streamed assistant text
  after the question made a tapped answer fall through to the "Queued Next" gate
  — where it was sent as a NEW turn and never resolved the blocked question
  (root cause of the stuck "needs answer"). Now it finds the last non-user
  `pending_input`, ignoring trailing assistant/tool items, and clears once a user
  reply follows. (B1) the Home "needs you" banner and (B2) the lock-screen Live
  Activity ignored the `[[conduit:resolved]]` marker — the banner stayed lit and
  the card showed the raw marker text as the prompt while remaining "pending"
  forever. Both are now resolution-aware; the Live Activity flips out of pending
  and idle-closes. [iOS + Android, **needs on-device verify**: (1) answer an
  AskUserQuestion — the answer sends immediately (not "Queued Next") and the
  question resolves; (2) an already-answered question shows NO home banner and NO
  lock-screen "CLAUDE IS ASKING"; (3) the lock-screen card never shows
  `[[conduit:resolved]]…` text]

**`/clear` works for Claude and Codex — broker. PR #844.**

- `/clear` previously reached Claude but returned a stray "(no content)" bubble
  and did nothing visible; Codex had no handling. Now: Claude pass-through resets
  context (the CLI rotates to a fresh `session_id`, already re-latched by the
  broker for `--resume`), the synthetic "(no content)" line is suppressed, and a
  "✓ Context cleared — starting fresh." confirmation is posted. Codex has no
  `/clear` RPC, so the broker starts a fresh thread (`thread/start`) and drops
  the old `codex_thread_id`. History stays on screen; only the agent's memory
  resets. Also exposes a `supports.clear` capability and clears the lock-screen
  Live Activity the instant an ask is answered. **Needs broker redeploy to go
  live.** [**broker-behavior confirm**: `/clear` on a Claude session → agent
  forgets prior turns, confirmation shown, no stray bubble; `/clear` on a Codex
  app-server session → fresh thread, agent forgets prior turns; codex
  same-process `thread/start` reset behaves (capture-flagged: not previously
  live-verified)]

---

## v0.0.210

**Streaming rail draws downward as the message grows — iOS + Android. PR #829.**

- The working-spine rail's length now eases/draws downward (easeOut ~0.35s) as the streamed message grows, instead of snapping to the new height each token; the flowing gradient runs inside the drawn portion. Reduce-motion snaps to full length. Builds on the full-height fill + fixed-tile no-stutter fixes (v0.0.209). [iOS + Android, **needs on-device verify**: streaming reply → rail draws down smoothly as text arrives, spans full content once settled]

**User AskUserQuestion answers sort below the agent reply — iOS. PR #835.**

- iOS-only chat ordering bug: `conduitConversationTsEpoch` parsed `ts` with
  `ISO8601DateFormatter`, which accepts only 3-or-0 fractional-second digits,
  but the broker stamps user prompts with `time.RFC3339Nano` (variable 1–9
  fractional digits). Unparseable → `.greatestFiniteMagnitude` → the item sorts
  to the BOTTOM (agent reply rendered above the user's prompt). Surfaced on
  AskUserQuestion free-text answers because that path (`answerPendingInput`)
  creates no app-stamped optimistic echo to mask the broker ts. Android is
  immune (`Instant.parse` handles nanoseconds). Fix normalizes the fractional
  group to 3 digits before the ISO8601 parse; empty-ts-sorts-newest contract and
  the memoization cache/lock are preserved. [iOS, **needs on-device verify**:
  answer an AskUserQuestion with a free-text "Other" answer → your bubble appears
  ABOVE the agent's reply, not below it]

**App-themed working indicator — iOS + Android. PR #827.**

- **Four working-indicator styles behind a debug toggle (#827, iOS + Android)** — the legacy pre-output `WORKING…` label + single pulsing dot at the head of an assistant turn is replaced by `ConduitUI.WorkingIndicator` (iOS, source of truth) / `ConduitWorkingIndicator` (Android mirror), rendering one of four app-themed styles: **A · spine** (breathing mark + flowing cyan→green rail + agent names the step + caret), **B · packets** (agent avatar + capsule pipe with packets flowing), **C · mark** (breathing mark + shimmer sweep), **D · prompt** (shell-prompt card). All four ship at once, switchable at runtime from the debug menu (`debug.workingIndicatorStyle`, default `spine`) so each can be lived-with on-device before a default is picked. Animation periods pinned identical across platforms; every color via `neon.*`; reduce-motion shows the calm end-state; the streaming/typing (3-dot) branch is unchanged. [iOS + Android, **needs on-device verify**: chat head shows the new indicator (no `WORKING…` label); debug-menu picker switches all four styles and the choice persists across launch; reduce-motion → calm/static]

**Model-catalog probe uses the shared-agent-creds account — broker. PR #830.**

- Under `CONDUIT_SHARED_AGENT_CREDS`, the dynamic model-catalog probe
  (`modelcatalog.go`) spawned `claude`/`codex` with the broker's bare env (no
  `CLAUDE_CONFIG_DIR`/`CODEX_HOME`), so it authenticated as the box-owner host
  login `~/.claude` instead of the `agent-cred/.claude` account that sessions
  actually run under. Those are different accounts with different model
  entitlements — the picker omitted models the sessions can run (e.g. Claude
  **Fable** / `claude-fable-5[1m]`). Fix threads `extraEnv []string` through the
  `AgentBackend.CatalogProbe` interface and computes it via
  `resolveSharedCred` + `sharedCredEnvFrom`, gated on `sharedAgentCredsEnabled()`
  (nil/unchanged when the flag is off). [broker, **needs broker redeploy + confirm**:
  after redeploy, `/api/capabilities` claude models include `claude-fable-5[1m]`
  and the app model picker shows Fable]

---

## v0.0.209

**Streaming-turn spine polish — iOS + Android. PRs #821, #822, #824.**

- **Rail fills full height + no stutter (#821, iOS)** — the working rail now spans the full message height (restored GeometryReader sizing) and uses a fixed tile stack so streamed-message growth can't rebuild/stutter it; smooth downward flow preserved. [iOS, **needs on-device verify**: long streaming message → rail spans full height, flows down smoothly]
- **Inline markdown renders live while streaming + mark-head brand glow (#822, iOS + Android)** — the streaming spine renders `**bold**` / `*italic*` / `` `code` `` live using the same parser as settled messages (unclosed markers stay literal until closed); the conduit mark on the thinking rail now glows (BRAND.md §3 — was disabled on iOS). [iOS + Android, **needs on-device verify**: mid-stream markdown renders styled not raw; mark glows]
- **Animations resume on foreground + streamed chat survives reconnect (#824, iOS + Android)** — `repeatForever` animations (typing dot, rail, spinner, sheen, blink) restart on foreground/phase-change instead of freezing after minimize/back (iOS); a replayed prior-turn message on WS reconnect no longer wipes the in-progress streaming spine/phase (turn-ts guard; unit tests added). [iOS + Android, **needs on-device verify**: (a) background→reopen mid-turn — dot + rail keep animating; (b) nav away→back mid-stream — spine + phase persist, chat not dead]

**Appetize screenshots now capture the connected UI via demo mode — CI tooling. PR #823.**

- `tools/appetize-screenshots/tests/tour.spec.ts` drives the App Store **demo
  mode** (`activateDemo()` — a simulated box + agent replies, no broker): boot →
  onboarding → tap "Explore without a server" → **demo home** (session list) →
  tap "Build a to-do app" → **demo chat** (agent replies + tool cards). Captures
  6 PNGs (onboarding/home/chat × iOS/Android). Already verified end-to-end on
  branch run 28534284733 (all taps landed, both platforms). This unblocks
  screenshotting the real chat/home UI that previously needed a live broker.

---

## v0.0.208

**Android onboarding parity — welcome + top bar aligned to iOS. PR #818.**

- Five welcome/top-bar spots where Android had drifted from the iOS source of
  truth (`ConduitOnboardingView.swift`), fixed in `OnboardingScreen.kt`:
  primary-button trailing `›` chevron; `✕` close gated to Settings-launched
  replay/addMachine entries (hidden on first-run, matching iOS); `ConduitMark`
  wrapped in the 96dp rounded tile; two-tone `>conduit` wordmark (`>` in codex);
  two-tone "Enter a code" row (question faint, CTA codex). Found and
  screenshot-verified via the appetize.yml pipeline. [Android, **needs
  on-device verify**: first-run onboarding welcome matches iOS — trailing
  chevron, no ×, logo tile, teal `>`, and teal "Enter a code"]

**Onboarding install command uses the real conduit.kaopeh.com/install.sh — iOS + Android. PR #817.**

- The onboarding "add a box" screen told users to run `curl -fsSL https://conduit.sh | sh`, but `conduit.sh` does not resolve (connection refused) — the command failed for everyone who pasted it. Replaced with the vanity URL the website actually serves (`https://conduit.kaopeh.com/install.sh`, HTTP 200) for the mac/linux command and the VPS `ssh` variant, both platforms. [iOS + Android, **needs on-device verify**: Onboarding → add a box → the copied command uses conduit.kaopeh.com/install.sh and installs successfully]

---

## v0.0.207

**Streaming caret + rail refinements — iOS + Android. PR #815.**

- **Caret gap + no width jiggle (iOS + Android)** — the streaming caret sat flush against the last character and swapped block↔space on blink (jiggling the text width). Now a thin space precedes it and the block glyph stays in layout, blinking via color (accent ↔ clear). Reduce-motion: no caret. [iOS + Android, **needs on-device verify**: caret has a small gap after the last char and the text doesn't jiggle as it blinks]
- **Rail flow no longer erratic (iOS + Android)** — the working-rail animation was keyed on the rail height, which changes as prose streams in, so it kept restarting. Reworked to a fixed-period tile (iOS stacked gradient tiles; Android `TileMode.Repeated` brush) that is height-independent → smooth downward flow, no restart. Reduce-motion: static. [iOS + Android, **needs on-device verify**: left rail flows downward smoothly with no stutter while prose streams]

**Appetize build + screenshot pipeline — CI tooling (manual workflow). PRs #811, #814.**

- **`appetize.yml` (manual `workflow_dispatch`)** — uploads the unsigned
  iOS-Simulator `.app` + Android debug `.apk` to Appetize.io (direct `curl`, no
  third-party action) so a running build can be poked from a phone. App links
  print to the run summary; secret `APPETIZE_TOKEN` + repo vars
  `APPETIZE_IOS/ANDROID_PUBLIC_KEY` pin stable `appetize.io/app/<key>` URLs.
  Already verified live end-to-end (both apps created, run 28515551636 green).
  [**verify**: `gh workflow run appetize.yml --ref main` → open the two app
  links on a phone and confirm each build launches]
- **`screenshots` job (`@appetize/playwright`)** — after upload, drives each
  build's onboarding screen and uploads an `onboarding-screenshots` PNG
  artifact (publicKey-only sessions; device/OS auto-picked for the iOS-26 min
  target). [**verify**: run the workflow → download the artifact → the two
  onboarding PNGs render the real UI]

---

## v0.0.206

**Streaming-turn animation fixes — iOS + Android. PR #810.**

- **Thinking/working dot pulse (iOS + Android)** — the single "working…/thinking…" dot was driven off a 0.3s 3-phase timer with a mismatched 0.6s animation, so it stuttered. Now a dedicated continuous pulse (scale 0.55↔1.0, opacity 0.4↔1.0, ~0.8s `repeatForever(autoreverses:)` / `infiniteRepeatable` Reverse). 3-dot "writing" state unchanged; reduce-motion static. [iOS + Android, **needs on-device verify**: trigger a turn → the pre-token dot pulses smoothly]
- **Rail flows downward (iOS + Android)** — the working-state rail gradient scrolled **up**; now two identical stacked accent→green cycles animate so the pattern flows **downward** and wraps seamlessly. Reduce-motion static. [iOS + Android, **needs on-device verify**: while the agent works, the rail bar flows down, not up]
- **Streaming caret trails the last character (iOS + Android)** — the caret was pinned to the far right of the last line (full-width Text); now composed inline into the text run (block glyph `▌` in accent, blinking) so it sits right after the last streamed character and wraps naturally. Reduce-motion: no caret. [iOS + Android, **needs on-device verify**: caret sits at the end of the streaming text, not the right margin]

---

## v0.0.205

**Shared component library — rule + iOS/Android primitives + Android screen migrations. PRs #792, #797, #795, #793, #794, #802, #800, #803, #804, #805, #807.**

The design system ("SWE Kitty" project) is now enforced in-repo: a `CLAUDE.md`
rule plus a real component library on both platforms, with the Android screens
migrated to compose from it. iOS is the source of truth; Android mirrors it
value-for-value.

- **CLAUDE.md rule (PRs #792, #797)** — new `Compose, Don't Hand-Roll` principle
  row + `## Design: compose from the component library` section (verbatim from
  the handoff's `LANDING-IN-GITHUB.md`): every screen composes from the library,
  never a raw color/radius literal; extend the library, don't fork inline; iOS
  source of truth, Android + design project mirror in lockstep. [docs — no device aspect]
- **Android `ui/components` package (PR #795)** — new
  `sh.nikhil.conduit.ui.components` mirroring iOS `ConduitUI/Components/`:
  `ConduitCard`, `ConduitRow` + `nav/value/toggle` factories, `ConduitChip`,
  `ConduitStatTile`, `ConduitButton`. Extended `glassRoundedRect` with an
  optional `tint`. Pure-logic tests. [Android — needs on-device verify]
- **Card radius 20/22 → 14 (PR #793)** — Android had TWO stale card-radius
  tokens (`NeonTheme.RADIUS_DP` 20f, `ConduitTheme.cardCornerRadiusDp` 22f) both
  claiming to match iOS; both dropped to 14 to match iOS `ConduitUI.Card`.
  [Android — needs on-device verify: cards render 14dp corners]
- **iOS `StatTile` + `ActionButton` (PR #794)** — extracted the recap metric
  tile + full-width text button into `ConduitUI/Components/`; refactored
  `ConduitSessionRecapView` onto them. NOTE: the button shipped as
  `ConduitUI.ActionButton`, NOT `Button` — a `ConduitUI.Button` shadowed
  `SwiftUI.Button` module-wide (the namespace is a nested `enum`) and broke the
  build; CI caught it. [iOS — needs on-device verify: Recap tiles + Export/Share
  pills render unchanged]
- **`ActionPill` + Chip leading-icon (PR #802)** — new `ConduitActionPill`
  (`.soft` status badge / `.solid` filled CTA) on both platforms — the small
  tappable/status pill that was hand-rolled on BOTH iOS (`ConduitHomeView`
  `.background(Capsule().fill(...))`) and Android; plus a `leadingIcon` slot on
  Android `ConduitChip` (iOS `Chip` already had `systemImage`). [iOS + Android —
  needs on-device verify]
- **Android screen migrations** — replaced hand-rolled cards/rows/chips/pills
  with the library, diffed against each iOS reference. Stateful cards left on
  the sanctioned `neonCardSurface` token modifier (iOS does the same).
  - **HomeScreen (PRs #800, #803)** — box-name badge → `ConduitChip(leadingIcon)`;
    "ACTIVE / Open guide / Connect / Review" pills → `ConduitActionPill`. [Android
    — needs on-device verify; note: "Connect" was a translucent accent fill, now
    `.solid` — confirm against iOS]
  - **AgentPickerSheet (PR #804)** — effort/mode/RECOMMENDED chips → `ConduitChip`;
    Recent/Folder rows → `ConduitRow`; dropped M3 `FilterChip`/`Surface`. [Android
    — needs on-device verify]
  - **FoundSessionsSheet (PR #805)** — Resume/Branch/View/Watch actions → `ConduitActionPill`;
    full-width CTAs → `ConduitButton`; read-only chip → `ConduitChip`. Disabled/loading
    buttons kept on M3 (`ConduitButton` has no `enabled=false`). [Android — needs
    on-device verify: Resume/Branch behavior unchanged]
  - **ChatPage (PR #807)** — assessed 4826 lines; correctly left bespoke (animated
    bubbles/tool-cards/streaming/typing UI don't map to generic components); only
    3 dead imports removed. [Android — no meaningful device aspect]

_Follow-up (not in this batch): mirror `ActionPill` + Chip-icon into the design
project's `conduit-primitives.jsx` to keep the three in lockstep._

**Chat transcript fixes: answered-chip ordering + first-message ack — iOS + Android. PRs #799, #798.**

- **Answered AskUserQuestion chip sorts in place (PR #799)** — a live `pending_input` card is created with an empty `ts`, which `sortedByConversationTs` deliberately sorts NEWEST (empty/unparseable ts → `.greatestFiniteMagnitude` / `Long.MAX_VALUE`). That's correct while the card is unanswered, but on answer it collapses to the `✓` chip and its `ts` was never backfilled — so once later assistant turns arrived the chip stayed pinned to the bottom ("my answer is below your response"). Fix: `resolvePendingInput` backfills the card `ts` to an anchored epoch (max known parseable epoch + ε) when empty/unparseable; extracted a shared `anchorEpoch` helper reused by `answerPendingInput`. Unit tests both platforms (Android seeds via a new `internal seedConversationLogForTest` seam). [iOS + Android, **needs on-device verify**: trigger an AskUserQuestion, answer it, keep chatting — the ✓ chip must stay in chronological place, not jump to the bottom]
- **First-message dotted bubble now clears (PR #798)** — `drainSentNormal` (clears the sent-but-unacked bubble when an assistant reply proves broker receipt) required `sent=true`, but `markSent` runs async after the WS write. For the FIRST message the broker often replies (fires an `AskUserQuestion`) before `markSent` lands, so the entry stayed `sent=false`, was skipped, and the bubble stuck faded forever. Fix: drain non-failed `.normal` entries regardless of `sent` — a reply is itself proof of receipt; the broker dedups any resend by `client_msg_id`. Unit tests both platforms. [iOS + Android, **needs on-device verify**: start a fresh session, send a first message that triggers an AskUserQuestion — the user bubble should go solid, not stay dotted]

---

**Tighten handoff classifier to first line only — core. PR #801.**

- **core**: `looks_like_handoff` was scanning the full message body, so any long assistant reply that *discussed* handoffs mid-text (e.g. a technical analysis quoting "Handing off to app-engineer: …") was misclassified as `kind == "handoff"`, producing a false "Now → conversation" agent-avatar card. Fix: only check the first non-empty line — real handoff declarations always lead the message. HTML briefs (`data-section="handoff"`) still match unconditionally. Regression test added. [no device verify needed — pure logic fix with unit test coverage]

**Drop multi-question AskUserQuestion echo bubbles — iOS + Android. PR #789.**

- **iOS + Android**: When a user answers a multi-question `AskUserQuestion`, the app joins per-question answers with `\n`. `dropPendingInputEchoes` previously only matched single-option echoes (`c in pendingOptionSet`), so the newline-joined answer slipped through as a plain user bubble alongside the collapsed chip. Fix: split by `\n` and drop if every non-empty line is in `pendingOptionSet`. Unit tests added on both platforms. [iOS + Android, **needs on-device verify**: trigger a multi-question AskUserQuestion, answer it — confirm no duplicate plain bubble appears next to the chip]

---

**Streaming assistant turn on the spine + typed-step tool ledger — iOS + Android. PRs #790, #791.**

- **iOS (PR #790, merged)**: Replaces the legacy bare "ASSISTANT" label + full-bleed streaming text with Direction C — arm-B (the permanent default) now puts the in-progress turn on the conduit spine. While streaming: mark head breathes (accent↔green glow, 2.1s), rail gradient flows downward (1.4s), and a blinking caret trails the text. When tools run, the new typed-step `ToolLedger` renders live inside the spine (pencil+filename for edits, `$`+command for runs/reads, amber pulse dot for in-flight step, rowin fade-in per row). When tools finish it collapses to the one-line footnote (`N steps · ✓ passed`). No "ASSISTANT" label; text always indented past the rail. Two new NeonTheme tokens added: `ghost` (rgb 160,184,224 @ 0.24) and `lineSoft` (rgb 160,184,224 @ 0.12), with unit test pins. New file: `StreamingSpineView.swift`. [iOS, **needs on-device verify**: start a Claude task → watch streaming turn breathe on the spine; watch ledger rows tick in live then collapse; verify done state settles cleanly; test reduced-motion (all animations stop)]
- **Android (PR #791, merged)**: Same Direction C redesign — spine-based streaming overlay, `ToolLedger` composable replacing old `NeonMonoCommandCluster` family, matching NeonTheme token additions (`ghost`, `lineSoft`) and unit test pins. [Android, **needs on-device verify**: same verification as iOS above]

_Diff-chip follow-up: `ViewEventFile` in core carries only `path+rev` — no add/del line counts. Edit rows show pencil+filename; the `+N/−N` chip is omitted until core/broker adds line-delta fields._

---

**Credential source subtitle in box readiness checklist — iOS + Android + broker. PR #788.**

- **Broker**: `AgentReadiness` now includes `credential_source` (`"env"` / `"box"` / `"app"`) in `/api/capabilities`. Old brokers omit the field; clients handle nil gracefully.
- **iOS + Android**: readiness row shows a small dim subtitle when signed in — `"API key on box"`, `"Signed in on box"`, or `"Via Conduit app"`. [iOS + Android, **needs on-device verify**: open New Session → Box Readiness — each signed-in agent should show the source line below its name]

---

**Long-press user bubble copies whole message — iOS + Android. PR #786.**

- **iOS**: `.contextMenu { Button("Copy") }` on `ConduitUserBubble` — long-press shows "Copy" menu that copies full message text to clipboard (replaces per-character text-selection handles). [iOS, **needs on-device verify**: long-press a sent bubble → "Copy" appears → pastes full message]
- **Android**: `.pointerInput` + `detectTapGestures(onLongPress)` on the user bubble Box — long-press silently copies full content to clipboard. [Android, **needs on-device verify**: long-press a sent bubble → full message on clipboard]

**Anthropic credential refresh fix — iOS + Android + broker. PR #787.**

- **App (iOS + Android)**: `propagateStoredAgentCredentials` now checks `expiresAt` before pushing to the broker. If within 5 min of expiry, calls the new `refreshAnthropicCredential()` on `OAuthClient` (grant_type=refresh_token → same Anthropic token endpoint), saves fresh tokens locally, pushes those instead. Falls back to stale on failure. [iOS + Android, **needs on-device verify**: let token age near expiry, reconnect to box — should push fresh tokens not 401]
- **Broker**: `absorbCanonicalIfFresher()` in `ensureSharedCred` — before re-materializing the stored blob to `agent-cred/.claude/.credentials.json` on restart, compares `expiresAt`; if the on-disk file is fresher (Claude CLI refreshed it), absorbs disk data into the encrypted store and skips the overwrite. Prevents broker restart from clobbering CLI-refreshed tokens with the original (now-rotated) refresh_token. [broker, **redeploy required**; verify: long-running session → broker restart → Claude retains auth without 401]

---

**Restore --resume after broker restart when CONDUIT_SHARED_AGENT_CREDS is on. PR #785.**

- **`chatConversationOnDisk` didn't check the shared config dir** — when `CONDUIT_SHARED_AGENT_CREDS` is on, Claude writes conversations to `CLAUDE_CONFIG_DIR=<conduitRoot>/agent-cred/.claude/` not the per-session `agent-home/.claude/`. Recovery was checking the (always-empty) per-session dir, clearing `resumeID`, and Claude spawned amnesiac — transcript rendered fine in UI but Claude had no memory. Fixed by also globbing the broker-owned config dir for the specific latched session id. [broker, **redeploy required**; verify: restart broker mid-session, send a new message — Claude should continue with context]

---

**Thinking vs typing indicator fix — broker + iOS + Android. PR #784.**

- **Broker emits `thinking` at turn start** — `chatProcess.Send` now sets `turnPhase="thinking"` and publishes a `turn_phase:"thinking"` view_event immediately when the user sends a message, before the first token arrives. Fixes the indicator showing three bouncing dots ("typing") instead of the single pulsing dot ("thinking") during the pre-first-token wait on large contexts. [broker, **redeploy required**]
- **iOS + Android mirror `turn_phase` from status frame** — `ingestStatus` now propagates `status.turnPhase` into `turnPhaseBySession` so reconnecting clients show the correct indicator immediately without waiting for a view_event replay. [iOS + Android, needs-device-verify: send a message, background the app mid-think, reopen — should show "thinking" dot not three dots]

---

**Command run block — collapse threshold + checkmark exit (iOS + Android). PR #779.**

- **Mono tool-bundle collapse threshold 1 → 9** — runs of ≤9 items always expand inline; runs of 10+ collapse into the ledger block. `CommandRunBlockLogic.collapseThreshold = 9` / `shouldCollapse(count:)` shared between production code and tests. Android `MONO_COLLAPSE_THRESHOLD` raised to match. [iOS + Android, needs-device-verify]
- **"exit 0" → "✓"** — inline block shows a checkmark instead of the "exit 0" text label. Android parity. [iOS + Android, needs-device-verify]
- **Mono Command Block settings toggle** — new toggle in Settings (iOS + Android); default OFF. [iOS + Android, needs-device-verify]
- **Telemetry breadcrumbs** — mono-block render breadcrumb on appear. [iOS + Android]

**Shared credential lineage — MaterializeCanonical + startup seed + env strip (broker). PR #780.**

- **`MaterializeCanonical`** — new `credentials.Store` method writes the credential blob directly into the provider-native config dir (not under a per-session HOME subtree); used by the `CONDUIT_SHARED_AGENT_CREDS` flag-ON path. [broker, **redeploy required**]
- **`SeedSharedCredentialsAtStartup`** — broker seeds the canonical credential files at startup so broker-side fetchers can read them before the first session spawns. [broker, **redeploy required**]
- **Env strip in `lifecycle.go`** — `CLAUDE_CONFIG_DIR` and `CODEX_HOME` are stripped unconditionally from inherited env before re-injection, preventing stale deployment values from leaking into sessions. [broker, **redeploy required**]
- **`cleanupAgentHomeCredentials` no-op under flag-ON** — skips credential removal when `CONDUIT_SHARED_AGENT_CREDS=1` since no per-session credential copy exists. [broker]
- **Test fixes** — `TestSharedCreds_FlagOff_CodexHomeIsPerSession` checks `sharedCredConfigEnv == nil` instead of asserting `CLAUDE_CONFIG_DIR` absent (which was wrong); `TestCleanupAgentHomeKeepsConversations` pins `CONDUIT_SHARED_AGENT_CREDS=""` to exercise the flag-OFF path in envs where flag is live. [broker]

---

## v0.0.204

**Sequential agent pipeline — broker. PR #774.**

- **Pipeline REST API** — `POST /api/pipeline` (create), `GET /api/pipeline/{id}` (status), `POST /api/pipeline/{id}/continue` (gate), `DELETE /api/pipeline/{id}` (cancel), `GET /api/pipelines` (list). Full state machine: queued → running → awaiting-gate → done/failed. Each step runs in its own session worktree; handoff via HANDOFF-OUT. `Pipeline: true` in capabilities. [broker, **redeploy required**]

**Chat streaming + turn_phase — broker. PR #770.**

- **`chat_streaming` view_event** — broker streams per-token content chunks to connected clients as the agent writes; each event carries a `content` string delta and the session `id`. [broker, **redeploy required**]
- **`turn_phase` view_event** — broker emits `writing` / `working` / `thinking` phase transitions; clients use this to drive the typing indicator. [broker, **redeploy required**]

**FanOut compare + Pipeline Builder/Monitor (iOS + Android). PRs #776 + #777.**

- **FanOut compare view (iOS + Android)** — `ConduitFanOutCompareView` / `FanOutCompareScreen` shows per-run diff stats (`N files · +X −Y`), expandable `diff_stat` mono block, `agent_summary` (1–2 lines), and **Open** / **Commit & PR** action buttons. Failed runs render greyed with error reason. `onCompare` wired in host via tracked session IDs derived from live session store. [iOS + Android, needs-device-verify; broker `POST /api/fanout/compare` required]
- **Pipeline Builder (iOS + Android)** — `ConduitPipelineBuilderView` / `PipelineBuilderScreen`: create a multi-step pipeline (title, task, ordered steps with agent type / role / prompt template / gate toggle). "Start pipeline" calls `POST /api/pipeline`. [iOS + Android, needs-device-verify; broker pipeline endpoints in #774 — redeploy required]
- **Pipeline Monitor (iOS + Android)** — `ConduitPipelineMonitorView` / `PipelineMonitorScreen`: vertical stepper showing each step's live state (queued / running / awaiting-gate / done / failed); polls `GET /api/pipeline/{id}`; **Continue** button on gate; **Open session** on failure. [iOS + Android, needs-device-verify]
- **Gap A named-branch sessions (iOS + Android)** — FanOut tracks launched session IDs by branch name; `onCompare` receives populated run list for the compare endpoint. [iOS + Android, needs-device-verify]

**Chat streaming overlay + turn_phase indicators (iOS + Android). PR #771.**

- **Streaming chat overlay** — partial assistant content appears live as tokens arrive via `chat_streaming` view_events; a streaming overlay row renders in the chat list and is cleared when the final assistant reply lands. [iOS + Android, needs-device-verify; broker `chat_streaming` support merged in #770 — redeploy required]
- **turn_phase typing indicator** — TypingIndicatorRow/ConduitTypingIndicator shows distinct animated states: single pulsing dot for "working"/"thinking", staggered three-dot bounce for "writing"/default. Typing dots suppressed while streaming overlay text is visible. [iOS + Android, needs-device-verify]

---

## v0.0.203

**Settings cleanup for App Store prep (iOS + Android).** PR #768.

- **Remove push-notification section** — the Settings push-notification section (test push, registration state) is removed from both iOS and Android. [iOS + Android, needs-device-verify]
- **Slim down Conversation settings** — "Show command detail" and "Command-run Mono block" toggles removed; only Collapse Turns + Reply Haptics remain. [iOS + Android, needs-device-verify]
- **Agent icons use AgentAvatar** — Settings > Agents now shows proper logo circles (Claude/Codex marks, monogram fallback) instead of generic SF Symbols / Material icons. [iOS + Android, needs-device-verify]

**Memory leak fix — free per-session state on archive/delete + Sentry memory checks (iOS + Android).** PR #775.

- `archive()` and `permanentlyDelete()` now call `clearSessionState`, freeing `chatLog`, `conversationLog`, `hydratedChat`, terminal buffers, and 13 other per-session dicts immediately. History re-fetches transcript via HTTP on first open. Verify: archive sessions with long chats → memory drops; re-opening archived session still shows transcript. [iOS + Android, needs-device-verify]
- Sentry breadcrumbs at chat-count milestones (100/500/1000) and memory-warning captures (`applicationDidReceiveMemoryWarning` / `onTrimMemory`). Verify in Sentry after a long session. [needs-device-verify]

**Pending chat reconciliation — dotted bubble clears when reply arrives (iOS + Android).** PR #769.

- When the broker starts streaming an assistant reply, any `sent=true` pending-chat entries for that session are immediately cleared (bubbles go solid) without waiting for the `chat_ack`. Verify: send a message → while the reply streams in, the user message bubble should go solid, not stay dotted. [iOS + Android, needs-device-verify]

**DiffReview "Commit & push" / "Open PR" now functional (iOS + Android + broker).** PRs #764 + #766.

- **Broker git endpoints (PR #764)** — adds `POST /api/session/{id}/git/commit` (stages all, commits with message, optional push; returns sha) and `POST /api/session/{id}/git/pr` (runs `gh pr create`; returns URL). Both run in the session workdir, auth-gated, return `{ok, stdout/stderr}`. Verify on broker: call both endpoints via curl on a live session with a dirty git tree; confirm commit lands and PR opens. [broker, needs-verify; **broker redeploy required**]
- **DiffReview app wiring (PR #766)** — "Commit & push" and "Open PR" buttons in the DiffReview sheet are no longer stubs. Tapping "Commit & push" shows a commit-message input then calls the broker endpoint and shows the resulting SHA. Tapping "Open PR" shows title+body fields, calls the endpoint, and shows the PR URL with an open-in-browser action. Buttons are disabled during inflight requests. Verify: open DiffReview on a session with changes → commit → SHA shown; → Open PR → URL shown. [iOS + Android, needs-device-verify; broker redeploy required]

**Archived session opacity + bulk delete (iOS + Android).** PR #765.

- **Archived session opacity (PR #765)** — archived/ended sessions now render at 0.62 opacity in the History list on both platforms, visually distinguishing them from active sessions (design spec compliance). Verify: open History — ended sessions appear dimmed vs active ones. [iOS + Android, needs-device-verify]
- **Bulk delete archived sessions (PR #765)** — a trash icon in the History screen top bar (shown only when archived sessions exist) triggers a confirmation dialog then permanently deletes all archived sessions. Verify: archive 2+ sessions → trash button appears → tap → confirm → sessions gone. [iOS + Android, needs-device-verify]

---

## v0.0.202

**GC'd sessions evicted from local history on reconcile (iOS + Android).** PR #763.

- **Broker-GC'd session eviction (PR #763)** — `SavedSessionsStore` (device-local `saved-sessions.json`) kept every session ever seen with no TTL; sessions GC'd on the broker (> 7 days old) remained visible indefinitely. Fix: in `reconcileLiveSessions()`, after the demote loop, any `.exited` SavedSession whose ID is not in the broker's current `running ∪ recoverable` set is evicted from local storage. Only runs when `fetchLiveSessions()` succeeded so the broker's view is current. Verify: reconnect to a box — sessions older than 7 days should no longer appear in the Sessions list. [iOS + Android, needs-device-verify]

**Terminal row: full command now visible (iOS).** PR #761.

**Recap screen wired into Session Info + running bar sheen (iOS + Android).** PR #762.

- **Recap navigation (PR #762)** — `SessionRecapView` (iOS) and `SessionRecapScreen` (Android) were fully built but not reachable. Added a "Recap" button to the Session Info action row (⓪ icon); tapping it opens the Recap sheet showing session identity, what changed, file stats, commands run, and duration/tokens. Verify: open Session Info (⓪) on a completed session → tap "Recap" → sheet opens with real session data. [iOS + Android, needs-device-verify]
- **Running command bar sheen (PR #762)** — the progress bar during a command-run RUNNING state now shows an animated cyan sheen sweep (1.5s linear infinite), matching the design spec's RunC `sheen` prop. Verify: trigger a multi-command run while watching the chat → progress bar shows a moving highlight sweep. Respects Reduce Motion. [iOS + Android, needs-device-verify]

- **Terminal attach command unwrapped (PR #761)** — the Terminal row in Session Info was showing `CONDUIT_TOKEN=<tok>…<end-of-session-id>` (middle-truncated, 2-line limit) making it look like only the token. Removed `lineLimit(2)` and `.truncationMode(.middle)` so the full `CONDUIT_TOKEN=… conduit-broker chat <id>` command wraps across as many lines as needed. Verify: open the ⓘ sheet on a live session → Terminal row shows the complete command (both the `CONDUIT_TOKEN=…` env var and the `conduit-broker chat <id>` suffix are visible); tap to copy → paste in terminal and confirm it connects. [iOS, needs-device-verify]

---

## v0.0.201

**§10/§10b command-run Mono block — now default ON (iOS + Android).** PR #760.

- **Command-run block default-on (PR #760)** — flips `chat.commandRunBlock` to `true` on both iOS and Android. Single-command runs render as an always-expanded flat mono block: "run" header + command row + exit-0/N-failed status. Two or more commands collapse to the summary ledger (§10b). Verify: run a single shell command — it renders inline; run multiple commands — they collapse with failures surfaced. Check phone and tablet. [iOS + Android phone + tablet, needs-device-verify]

**Device presence heartbeat — push-suppression fix (iOS + Android + broker).** PR #759. — push-suppression fix (iOS + Android + broker).** PR #759.

- **Device presence heartbeat (PR #759)** — spurious push notifications fired when the app was on the home screen with the session WS closed (background throttle, PR #746): `OwnerDeviceConnected()` returned false so pushes fired even with the app visible. Fix: new `POST /api/device/presence` broker endpoint + `PresenceTracker` (60s TTL); push gate now suppresses when the owner device has an active WS connection **or** a heartbeat was recorded within 60s. iOS/Android apps POST the heartbeat on every foreground transition (`scenePhase == .active` / `onResume`). Also: `install.sh` now auto-detects and restarts the systemd `conduit-broker` service after a binary install. Verify: (a) with app foregrounded on home screen, trigger a turn end — no push notification should fire; (b) let 60s elapse after last foreground, trigger turn end — push fires normally; (c) `install.sh` on a bootstrapped box with active systemd unit — binary moved and service restarts automatically. [iOS + Android + broker, needs-device-verify; broker redeploy required]

---

## v0.0.200

**install.sh prerelease 404 fix.** PR #758.

- **install.sh resolves latest tag via GitHub API (PR #758)** — `curl … install.sh | sh` failed with 404 when downloading the broker binary because the script used `/releases/latest/download/` which GitHub only resolves for non-prerelease releases. All conduit releases are prereleases. Fixed by querying `api.github.com/repos/.../releases?per_page=1` to resolve the current tag, then using the versioned `/releases/download/<tag>/` URL. Also updated header usage comments to reference `conduit.kaopeh.com/install.sh`. [broker-only script change — no app verify needed; verify: `curl -fsSL https://conduit.kaopeh.com/install.sh | sh` installs successfully]

---

## v0.0.199

**Broker-update banner install URL fix (iOS + Android).** PR #754.

- **Broker-update banner install URL (PR #754)** — the "Copy install command" button for token-paired boxes showed `curl -fsSL https://conduit.nikhil.sh/install.sh | sh`, a URL that returns 404. Replaced with the versioned GitHub releases URL (`https://github.com/nikhilsh/conduit/releases/download/v{appVersion}/install.sh`) derived from the app's own version at runtime. Verify: on a token-paired box with a stale broker, the banner appears and the copied install command downloads and runs successfully. [iOS + Android, needs-device-verify]

**Pull-to-refresh on home screen sessions list (iOS + Android).** PR #756.

- **Pull-to-refresh on home screen (PR #756)** — the main home screen sessions list had no pull-to-refresh gesture; the feature only worked on the Sessions history screen. Added `.refreshable` to `homeList` in `ConduitHomeView.swift` (iOS) and wrapped the sessions `Box` in `PullToRefreshBox` in `HomeScreen.kt` (Android), using the same `reconcileLiveSessions`/`refreshLiveSessions` wiring already present in SessionsScreen/HistoryScreen. Verify: pull down on the home screen — spinner appears and newly started sessions (e.g. from a terminal on the box) appear in the list after the refresh completes. [iOS + Android, needs-device-verify]

**Terminal attach command in session info sheet (iOS + Android).** PR #757.

- **Copyable terminal attach row (PR #757)** — session info (ⓘ) sheet now shows a "Terminal" row in the Details section with a tap-to-copy `conduit-broker chat <session-id>` command. For SSH-paired boxes the full one-liner is `ssh user@host 'CONDUIT_TOKEN=… conduit-broker chat <id>'`; for token-paired boxes the command omits the SSH prefix (user must already be on the box). Verify: open the ⓘ sheet on a live session → Terminal row visible → tap to copy → paste in terminal → attaches to the running session and shows the chat. [iOS + Android, needs-device-verify]

**Website: install.sh served at conduit.kaopeh.com/install.sh.** PR #755.

- **Website install.sh vanity URL (PR #755)** — `conduit.kaopeh.com/install.sh` previously returned 404. The website build now downloads `install.sh` from the current release's GitHub assets and writes it to `out/install.sh`, so `curl -fsSL https://conduit.kaopeh.com/install.sh | sh` works after each website redeploy. [website deploy needed — no app changes]

---

## v0.0.198

**iOS release signing fix: notification service extension.** No PR (direct main commit).

- **Notification service extension signing (direct commit)** — `ConduitNotificationService.appex` was not included in the provisioning profile setup for ad-hoc and App Store release builds, causing `ValidateEmbeddedBinary` failures since v0.0.196. Created `sh.nikhil.conduit.notificationservice` provisioning profiles (ad-hoc + App Store), added CI secrets, updated `release-ios.yml` and `release-testflight.yml` to install the profile, and updated `inject-release-signing.py` to patch the extension to manual signing. [CI-only fix — no on-device verification needed]

---

## v0.0.197

**Apple App Store reviewer demo mode (iOS + Android).** PR #753.

- **App Store reviewer demo mode (PR #753)** — adds an in-process "Try Demo" path so Apple App Store reviewers can explore the app without a real VPS/broker. A "Explore without a server" CTA on the onboarding welcome screen activates demo mode: fake sessions ("Build a to-do app", "Fix authentication bug") with scripted chat history, disabled composer with real-server CTA. iOS phone + tablet and Android phone + tablet. No network calls. "Exit Demo" button in top-right returns to onboarding. Verify: fresh install (no saved servers) → onboarding → "Explore without a server" → fake home with 2 sessions → tap a session → scripted chat visible → disabled composer shows message → "Exit Demo" → returns to onboarding. [iOS + Android, on-device]

---

## v0.0.196

**Apple Watch ask notification actions + subagents earlier-agents collapse + voice pause fix + pull-to-refresh sessions + pending-chat reconnect fix + persistent agent memory.** PRs #743 (iOS + broker + relay), #748 (iOS + Android), #749 (iOS + Android), #750 (iOS + Android), #751 (iOS + Android), #752 (broker).

- **Pull-to-refresh sessions list to discover sessions from other devices (PR #750)** — pulling down on the sessions list triggers a refresh that fetches sessions started on other devices/boxes, making cross-device session discovery available without an app restart. Verify: start a session on another device → pull to refresh the sessions list → new session appears. [iOS + Android, on-device]
- **Apple Watch: answer AskUserQuestion from wrist (PR #743)** — when Claude fires `AskUserQuestion`, the push notification now surfaces on Apple Watch with the option labels as tappable action buttons. Relay forwards `options[]` + `mutable-content:1`; broker sends `ask` push category with a new `POST /api/session/answer` endpoint; iOS `ConduitNotificationService` extension dynamically registers the category so Apple Watch shows the actual option text. **Requires relay deploy before broker redeploy.** Verify: trigger AskUserQuestion → notification arrives on Apple Watch with option buttons → tap one → Claude continues. [iOS + Apple Watch, on-device; broker + relay deployed]
- **Session info (i) menu: earlier agents collapse (PR #748)** — done/failed subagents fold under a tappable "Earlier agents (N)" row with a chevron; active (working) agents always visible inline. Verify: run a multi-agent task → open (i) → finished agents collapsed by default → tap "Earlier agents" → expands → tap again → collapses. [iOS + Android, on-device]
- **Voice pause fix + mic visible during active turn (PR #749)** — iOS voice transcription now restarts on all recognition errors (not just `kAFAssistantErrorDomain`), fixing voice stopping after pauses caused by audio-session interruptions or unrecognised rate-limit codes. Mic button also shown alongside Stop when the agent is working with an empty composer (iOS + Android). Verify: speak → pause 10+ seconds → speak again → voice continues; start agent turn → composer empty → mic + Stop both visible. [iOS + Android, on-device]
- **"Not sent" bubble fix on Rust-layer auto-reconnect (PR #751)** — messages that arrived at the broker but whose `chat_ack` was lost during a Rust-layer per-session reconnect stayed stuck in faded "sent-but-unacked" state indefinitely. Fixed by calling `flushPendingChats` on `on_connection_health(Connected)` so unacked messages are re-delivered (broker deduplicates via `client_msg_id`). Verify: send a message → observe the bubble goes solid (not stuck faded). [iOS + Android, on-device]
- **Persist agent memory across sessions (PR #752)** — broker now symlinks `.claude/projects` inside each agent's ephemeral home to a stable store at `<conduitRoot>/agent-state/<provider>/<slug>/projects`, so Claude's project memory survives session restarts. `cwdToClaudeSlug` is the inverse of `claudeSlugToCWD` (cross-referenced to prevent drift). Broker-only fix; live via redeploy. [broker — live]

---

## v0.0.195

**WS background throttle + approvals/resolved bubble fixes + agent cwd fix.** PRs #744 (iOS + Android), #746 (iOS + Android), #747 (broker).

- **Approvals pending-ask detection fixed (PR #744)** — Rust core was stripping `[[conduit:needs-input]]` before the app's content check ran, so the Approvals sheet never showed answer-option buttons. Fixed by checking `pending_options` (broker-side list, not content) instead of content substring match. Verify: trigger an AskUserQuestion → open Approvals → option buttons appear and tapping one resolves the card. [iOS + Android, on-device]
- **Resolved-marker raw bubble on reconnect fixed (PR #744)** — dedup fingerprint logic only stripped `[[conduit:needs-input]]` but not `[[conduit:resolved:…]]`, so the raw marker appeared as a message bubble on WS reconnect. Now stripped from the fingerprint. Verify: answer a card, close and reopen the app → no raw `[[conduit:resolved:…]]` bubble in chat. [iOS + Android, on-device]
- **WS background throttle — reduce device heat (PR #746)** — Rust `session_worker` is paused (WS closed, no heartbeat) when a session is not visible in the UI. Resumes immediately on foreground/navigate-back. All sessions paused when app backgrounds, resumed on foreground. Verify: open multiple sessions → put app in background for 30 s → check device temperature is lower vs. before; foreground → sessions reconnect and chat works. [iOS + Android, on-device]
- **Agent workdir now defaults to `$HOME` (PR #747)** — embedded agent TOMLs had `workdir = "/workspace"` which doesn't exist on bare-VPS setups, causing agents to spawn inside their own session directory (`/root/.conduit/sessions/<id>/work`) instead of the user's home. Now expands `$HOME` at spawn time; falls back to `os.UserHomeDir()` if workdir is unresolvable. Broker-only fix; live via redeploy. [broker — live]

---

## v0.0.194

**Chat ticker + ask-queue fixes + chip persistence + approvals UX.** PRs #738 (iOS + Android), #739 (iOS + Android), #740 (iOS + Android), #741 (iOS + Android), #742 (core Rust).

- **Answered pending-input chip survives view close+reopen (PR #738)** — `answeredPendingFingerprints` moved from ephemeral `@State`/`remember{}` to `SessionStore` (keyed by sessionID), so the green chip stays after dismissing and reopening chat. Verify: answer an AskUserQuestion card → dismiss chat → reopen → chip still shows `✓ [answer]`, not the full NEEDS YOUR INPUT card. [iOS + Android, on-device]
- **Approvals panel: AskUserQuestion renders options as tappable choices (PR #741)** — when the pending item has `[[conduit:needs-input]]`, the Approvals sheet shows each answer option as a button instead of generic Approve/Deny. Tapping sends the answer via `sendChat`. Verify: trigger an AskUserQuestion from a running agent → open Approvals → see option buttons → tap one → card resolves with "Sent: …". [iOS + Android, on-device]
- **Tool cluster expand resets on stream (PR #739)** — iOS: removed count from `toolgroup-{id}-{count}` row ID so SwiftUI preserves `@State` across streaming. Android: keyed `remember` on `items.firstOrNull()?.id` not full items. [iOS + Android, on-device]
- **AskUserQuestion answer echo + queue (PR #739)** — removed duplicate YOU bubble when answering a pending-input card; `hasPendingAsk` now checks `resolvedPendingInputIDs` so the queue is drained; multi-option chip joins answers with `·`. [iOS + Android, on-device]
- **Running ticker resets to 0 on chat open (PR #740)** — `MonoRunningTicker` (iOS) and `CommandRunTicker` (Android) now seed elapsed time from the first item's `ts` instead of starting at 0; reopening a chat shows the correct elapsed time. [iOS + Android, on-device]
- **Tool cluster count never updates (PR #742, core)** — `classify_status` was applying content-text heuristics ("running", "pending", "failed") to tool call content, misclassifying bash commands that contained those words as substrings. Tool items now always classify as `done`/`failed` based on exit code only. Requires broker redeploy? No — app-side Rust core fix only. [iOS + Android, on-device]

---

## v0.0.193

**Pending-input dedup + tool cluster collapse.** PRs #736 (broker), #737 (iOS + Android + broker).

- **Broker: no duplicate answer bubble after re-broadcast (PR #736)** — broker no longer re-broadcasts a resolved `pending_input` event over WS on reconnect; previously caused a second answer bubble to appear. Broker-only fix; auto-ships via redeploy. [broker — live]
- **Pending-input merge dedup: resolved past wins over unanswered live (PR #737)** — if the transcript already has a resolved answer for a pending-input card and a live re-emission of the same card arrives (broker re-broadcast), the resolved card wins and the unanswered duplicate is suppressed. Prevents ghost unanswered cards appearing mid-conversation. iOS + Android parity with tests. [iOS + Android, on-device]
- **Tool cluster cards collapse to compact footnote by default (PR #737)** — when "Show command detail" is ON, individual tool cluster cards now start as the muted compact footnote ("ran N commands") and expand to the full card on tap — same as the flag-off appearance. Tap the expanded card header to re-collapse. [iOS + Android, on-device]

---

## v0.0.192

**LA zombie + chat UX fixes.** PRs #734 (relay + iOS), #735 (iOS + Android).

- **LA zombie on lock screen (PR #734)** — relay `apns.ts` sets `dismissal-date = now + 5 min` on `event=end` Live Activity pushes; without it Apple defaults to ~4 hours. In-process `doneLingerInterval` also reduced 15 min → 5 min. Verify: end a session → the done-state LA disappears from the lock screen within ~5 minutes. [iOS, on-device]
- **Answered AskUserQuestion card collapses to chip (PR #735)** — once you tap an option, the full NEEDS YOUR INPUT card shrinks to a compact green pill (e.g. `✓ Fix both`). Rehydrated answered cards (close+reopen) also show the chip. iOS + Android parity. Verify on iPhone + iPad + Android. [iOS + Android, on-device]

---

## v0.0.191

**Shared-agent-credential lineage — "never fork the OAuth refresher" (broker, behind `CONDUIT_SHARED_AGENT_CREDS`, default OFF).** PR #732 (design doc + broker). Broker-only; no app change → iOS/Android parity preserved by construction (WS contract unchanged). Tag cut at `2e263e98`. **Ships DORMANT — the flag is OFF in this release, so production behaviour is byte-for-byte identical to v0.0.190; nothing is fixed for the owner yet.** Full design in [PLAN-AGENT-CREDENTIAL-LINEAGE.md](PLAN-AGENT-CREDENTIAL-LINEAGE.md).

- **Root cause (the logout):** PR #126 (`bbae5e7a`) gave every session a PRIVATE on-disk copy of the operator's single OAuth login (host + one per session). Anthropic/OpenAI rotate refresh tokens single-use, so the first session to refresh invalidates every other copy of the lineage — including the operator's host login → the box gets logged out. Live-confirmed this session via `~/.claude/daemon.log` ("proactive refresh failed, signalling re-auth required") + a diverged refresh token in a session's `agent-home/.claude/.credentials.json`.
- **Fix shape (flag ON):** stop forking. Point every session at ONE canonical config dir per provider via the CLI's own relocation env var (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`). Option A = the operator's real `~/.claude`/`~/.codex` (read-through, zero copy) when a host login exists; Option B = a broker-owned dir seeded once from the app-pushed blob otherwise (login-less SSH-bootstrap path). The agent CLIs' own cross-process refresh coordination then governs every refresh — the host login is never stranded. Provider-agnostic; only the rotating-token providers (anthropic/openai) are relocated, opencode/gemini (non-rotating env keys) untouched.
- **What's verified already:** flag-OFF path is byte-for-byte unchanged (old logic preserved verbatim as the else-branch; `commandEnv` env-injection is a no-op when the map is empty; watchdog re-mirror only skipped under the flag). CI green on all six checks. Local broker gates (gofmt/vet/`go test ./internal/session/... ./internal/credentials/... ./internal/ws/...`) pass.
- **PENDING — supervised flag-ON live verification (do NOT flip unattended):** deploy the new broker, set `CONDUIT_SHARED_AGENT_CREDS=1`, and confirm on the box: (a) two concurrent sessions + the host login survive a token refresh with NO logout (the original bug); (b) Option A sessions read `~/.claude` directly and the broker writes NOTHING into the host dir; (c) codex parity (no cross-process lock — loser self-heals by re-reading the shared file); (d) **the re-seed-clobber concern** — a new Option-B session start re-runs `store.Materialize(blob)`; verify it does NOT overwrite an already-refreshed shared credential with a stale single-use blob. [broker — supervised on-box]

---

## v0.0.190

**§10/§10b command-run rework (flagged) + AskUserQuestion duplicate-card hardening.** PRs #726 (iOS/iPad), #727 (Android), #725 (iOS+Android). App-only — no broker change, no redeploy. Tag cut at `229174b6`.

- **1 · §10/§10b command-run "Mono block" — behind `chat.commandRunBlock` (default OFF)** — a contiguous command run renders as a flat mono code surface: an aligned `$ command` grid where success is a single muted trailing check, the exit code shows ONLY on failure (red) with the stderr tail inline, and commands truncate at the END only (kills the old middle-merge "…pro…yml | awk" bug). A run of ≥10 commands collapses to one summary line with failures surfaced inline + a quiet "N ran clean — show all" and an expandable height-capped All/Failed ledger; while the batch runs, a minimal-inline ticker shows the live command + elapsed timer + a determinate progress rule (never an indeterminate spinner; respects reduced-motion). iOS/iPad PR #726, Android PR #727. To verify: Settings → Labs → enable "Command-run Mono block", then run several shell commands (and a 10+ command batch incl. a failure). [iOS+Android phone+tablet, on-device]
- **2 · AskUserQuestion duplicate-card hardening** — the pending-input dedup now keys on *marker-stripped* content with the answered (`[[conduit:resolved]]`) card winning, so an original card plus the broker's re-published resolved card always collapse to one (closes a codex raw-path duplicate and limits version-skew damage). PR #725. NOTE: the leaked-marker + duplicate + never-answered card the owner hit on v0.0.188 was a version skew — the live broker emits the `[[conduit:resolved]]` marker (#721) but 188 predates the client strip/consume; #721 shipped in v0.0.189, so updating past 188 fixes the reported symptom and this PR hardens it further. [iOS+Android, on-device]

---

## v0.0.186

**Session-safe auto-update + keyboard scroll-dismiss + push notification overhaul.** PRs #711 (iOS+Android), #712 (iOS), #713 (broker). Broker REDEPLOYED (v0.0.186 live).

- **1 · Session-safe broker auto-update (PR #711)** — the silent broker auto-update is now gated on live-session presence: zero live sessions → silent restart; live sessions present → banner warn + confirm before restart, then auto-resume the snapshotted sessions after. Retires the dead `v0.0.120` version floor in favour of a real broker-vs-app version compare. Verify on iOS + Android: (a) connect a box with an older broker and no live sessions → broker updates silently; (b) connect with a live session running → a warning banner/dialog appears, confirm → broker restarts → sessions auto-resume. [iOS+Android, on-device]
- **2 · iOS keyboard interactive scroll-dismiss (PR #712)** — live `UIKeyboardLayoutGuide` + `CADisplayLink` inset tracker replaces the notification-driven inset so the composer follows an interactive scroll-dismiss in real time. NOTE: a follow-up resting-position fix is in progress on branch `ios/keyboard-resting-inset` — verify only the drag-dismiss behaviour here, not the final resting height. Verify on iOS: open a chat → drag the messages list down to dismiss the keyboard → the composer tracks the keyboard edge throughout the drag with no gap. [iOS, on-device; resting-position pending follow-up]
- **3 · Push notifications: genuine-stop timer + AI body + Live Activity turn-start (PR #713)** — turn-end pushes are deferred behind a cancellable 20 s "genuine stop" timer (a new agent turn cancels it, preventing spurious mid-work notifications); the notification body is AI-rewritten via the session's `aiGen` provider (Haiku / `codex exec`, falls back to truncated preview); and the Live Activity is now started at turn-start rather than end. Verify: (a) trigger a multi-turn agent run → no intermediate "done" push arrives while turns are still flowing; (b) when the agent genuinely stops, a push arrives with an AI-written summary body; (c) lock the screen and start a session → the Live Activity appears at turn-start. [broker — live; iOS LA on-device]

---

## v0.0.182

**Chat-noise + keyboard + SSH-chat-takeover + broker-restart-chat round.** PRs #693/#694 (Show command detail toggle, iOS+Android), #699 (plan-card misclassification, core+Android), #697 (iOS keyboard), #698 (iOS edge-swipe-back), #695 (broker `conduit-broker chat` Phase 1), #696 (broker owner-presence push-gate Phase 2), #700 (broker replays chat transcript on WS reattach). Broker REDEPLOYED.

- **1 · Agent commands hidden by default ("Show command detail")** — chat collapses every contiguous tool/command run (incl. lone commands) into a muted "ran N commands" footnote; tap to expand, or flip Settings → Conversation → "Show command detail" on for full command cards. Failures still surface (`ran N commands · M failed`, fail tint, auto-expand). Verify on iOS + Android (phone + tablet). [iOS+Android phone+tablet, on-device]
- **2 · Commands with a checklist body no longer render as PLAN cards** — a `gh pr create` whose body has a markdown checklist (`- [x]`) was wrongly shown as a PLAN card (looked like a duplicate on retry). Now only genuine plan/todo tools or assistant prose become plan cards. Verify: a command whose output has a `- [ ]` list shows as a normal command. [iOS+Android, on-device]
- **3 · Keyboard tracks the system spring + keeps last message visible** — composer animates with the keyboard's real spring curve (was easeInOut → laggy) and scrolls the last message into view on keyboard-up. Verify on iOS. [iOS, on-device]
- **4 · Edge-swipe-back works from the chat messages area** — PR #698. Verify on iOS: swipe from the left edge in a chat → navigates back. [iOS, on-device]
- **5 · `conduit-broker chat <session-id>` CLI (SSH chat takeover, Phase 1)** — view + drive a live session's chat from an SSH terminal on the box. Verify on the box: `conduit-broker chat <id>` attaches and can send. [broker — live]
- **6 · Owner-presence push-gate (Phase 2)** — alert pushes suppressed only when an owner-device client is attached, not any subscriber (e.g. the SSH chat CLI). Verify: a backgrounded phone still gets pushes while a non-owner SSH client is attached; no double-notify for the single-phone case. [broker — live; app-side on-device]
- **7 · Chat history survives a broker restart** — on WS reattach the broker now replays the persisted transcript (last 200 msgs) to the client, so reopening a session after a broker restart shows the prior conversation instead of an empty chat. Ships via broker redeploy (no app update). Verify: after a broker restart, reopen a session → the previous conversation is there. [broker — live]

---

## v0.0.168

**Android stabilization + mDNS multicast + resume recap fix.** PRs #628 (Android mDNS permissions + usage-strip), #632 (Android stabilization), #633/#638 (broker recap digest + IS_SANDBOX), #634 (CI test stabilization). Broker REDEPLOYED (recap is broker-side, live now). Website redeployed to conduit.kaopeh.com with v0.0.168 links.

- **1 · LAN auto-discovery works on Android (mDNS multicast)** — Android was missing the `CHANGE_WIFI_MULTICAST_STATE` and `ACCESS_WIFI_STATE` permissions and the `WifiManager.MulticastLock` acquire/release, so mDNS broker discovery never fired on Android over Wi-Fi. PR #628 adds the permissions and the lock, plus a smoother usage-strip expand animation. Verify: on Android on the same Wi-Fi as a broker, open the app → the broker is discovered automatically (no manual IP entry); the usage strip expands/collapses smoothly. [Android, on-device]
- **2 · Android stabilization: back navigation, swipe-to-archive, dir-list fallback, phone-landscape layout** — four compounding issues fixed in PR #632: (a) back-from-chat now returns to Home (BackHandler wired); (b) Home session rows support swipe-to-archive with a undo Snackbar; (c) a session can start even when the directory listing fails (dir-list is non-blocking); (d) phone-landscape no longer triggers the tablet 3-pane layout (form-factor detection tightened). Verify on an Android phone: back from a chat → Home; swipe a session → archive + Snackbar appears with Undo; start a session when the dir listing errors out → session still opens. Verify on an Android tablet: landscape layout uses the correct pane count. [Android phone + tablet, on-device]
- **3 · Resume recap now works on large sessions (broker — verified live)** — the v0.0.167 recap timed out on sessions with many turns (>~150) because the broker passed the full transcript to `claude --resume` for re-ingest, which could take minutes. PR #633 switches to a digest-based approach (no full re-ingest) and PR #638 sets `IS_SANDBOX=1` so the one-shot claude invocation is not refused under root. VERIFIED LIVE on the box: a 21,235-line session produced an agent-written recap in ~13s (not the deterministic fallback). App-side: verify the recap system message appears at the top of a resumed Found Session. [broker — live; app-side on-device]
- **4 · CI test stabilization** — PR #634 fixes a FeatureFlags style-B test and a single-flight test flake. CI-only change; no device verification needed. [released, no device aspect]

---

## v0.0.167

**UI polish + experiment graduation (iOS+Android, phone+tablet).** PRs #624/#625 (resume sheets, host-key, add-box, SSH theme), #626 (broker recap), #627 (usage anim), #629/#630 (flags). Broker REDEPLOYED (recap).

- **1 · Resume/Branch lands directly in the chat (no leftover sheets)** — after Resume/Branch, the Found-Sessions + Box-Health sheets now auto-dismiss so you land on the chat. Verify: discovery → Resume → you end up in the chat, not stacked sheets. [iOS+Android, on-device]
- **2 · Resumed chat shows a recap** — the chat opens with a "Resumed from your terminal — picking up where you left off" message (agent-written when fast enough, else a generic note). Verify: resumed chat isn't blank. [broker, live]
- **3 · Host-key card is opaque + SSH-add matches the app** — the "Verify server identity" card no longer shows the form bleeding through; the Connect/Trust buttons use the neon palette. [iOS+Android, on-device]
- **4 · Settings: single "Add a box"; Labs/Debug graduated** — "Replay walkthrough" + "Add a machine" gone (one "Add a box"); conversation style is permanently B (Signature); the Labs A/B picker is gone; the Debug menu is hidden behind a 7-tap unlock on the About version; the Agents section always shows in session Info. Verify: Settings is decluttered; tap the version 7× to reveal Debug. [iOS+Android, on-device]
- **5 · Smooth usage-strip animation** — the Home top usage bar (claude/codex %) expands/collapses smoothly (no jank). Verify: tap it open/closed. [iOS; Android was already smooth]

---

---

## v0.0.165

**Found Sessions Resume actually works now.** Resume opened an empty chat that never replied — three compounding bugs, all fixed. Broker PRs #620 (stage transcript) + #621 (excerpt), iOS+Android PR #622 (join WS). Broker REDEPLOYED. The WS-join (#622) is app-side → needs v0.0.165 installed.

- **1 · Resumed agent actually loads the conversation (broker)** — the broker runs each agent in an isolated per-session home, but the external session's transcript lives in the user's real ~/.claude / ~/.codex, so `claude --resume` / codex `thread/resume` found "No conversation" and the agent exited status 1 (empty chat, no reply, both agents). The broker now STAGES the external transcript into the session's agent-home before launch. Verified live: the resumed claude agent now spawns with `--resume <id>` and stays alive. [broker — live]
- **2 · App joins the resumed session over WebSocket (iOS+Android)** — adopt created + navigated to the session but never called `joinSession`, so the app wasn't attached: typing returned broker `UnknownSession` + "chat send failed" (Sentry-confirmed) and no stream arrived. Adopt now goes through `attachLiveSession` (opens the WS). Verify: Resume an idle found session → it opens into a live chat; type a message → the agent replies with full prior context. [iOS+Android, on-device]
- **3 · Resumed chat shows an excerpt so it reads as a continuation (broker)** — `--resume` loads history into the agent's memory but doesn't reprint it, so the chat opened blank (looked like a new session). The broker now seeds the resumed session's conversation with the last 10 prior messages + a "Resumed from your terminal — N earlier turns" note. Verified live (11 entries seeded). Verify: the resumed chat opens showing recent prior messages + the resumed note, then live turns append. [broker — live]

---

## v0.0.164

**Found Sessions UX fixes** — Resume now actually opens the session, the discovery sheet is instant + has a loading indicator, and the broker caches the scan. iOS PRs #616 (sheet) + #618 (resume open), broker PR #617 (cache, redeployed live). Found via on-device testing.

- **1 · Resume/Branch actually opens the session (iOS)** — resuming or branching a found session created the Conduit session on the broker (discovery count dropped) but the app never opened it: it didn't appear in Active Sessions and the app didn't navigate to its chat (`adoptFound` only set `selectedSessionID` without stamping the box, marking it live, refreshing, or persisting — unlike `createSession`). Now adopt mirrors createSession's full open. Verify: discovery → a session → Resume → after the progress it lands in the chat with full context, and the session shows under "Sessions here" / Active Sessions. [iOS, on-device]
- **2 · Discovery sheet shows instantly + a loading indicator (iOS)** — tapping the entry card opened a sheet that re-fetched from scratch and showed "0 sessions found" for ~6-10s before populating. Now the sheet is seeded with the list the box-detail card already loaded (instant), refreshes silently, and a cold open shows a spinner + "Scanning sessions on {box}…" instead of the empty state. Verify: tap the card → the list appears immediately (no empty flash); a first-ever open shows a spinner, not "0 found". [iOS, on-device]
- **3 · Broker caches the discovery scan (45s TTL)** — discovery re-scanned ~238 transcripts (~6s) on every call. The broker now caches the raw scan for 45s (dedup/floor/filter/sort still applied per-call, so adopt reflects immediately). Verified live: cold 6.4s → warm 1.4ms. Verify: the entry card + sheet feel instant on repeat opens. [broker — live now]

---

## v0.0.163

**Found Sessions discovery actually works on iOS now.** The card was hidden on every connected box because of an iOS URL bug, not the feature. iOS PR #614. App-only — no broker change, no redeploy.

- **1 · "Started outside Conduit" card appears + lists sessions (iOS)** — iOS `getJSON` was assigning a query-bearing path to `URLComponents.path`, which percent-encoded the `?` to `%3F` (`/api/sessions/discovered%3F`), 404ing on the broker; the discovery probe got nothing so the card stayed hidden (capabilities/host-metrics have no query, which is why HEALTH rings showed but the card didn't). Confirmed via packet capture of the device. Fixed: `getJSON` splits path/query properly, the no-filter probe no longer emits a stray `?`, and the request timeout is bumped 10→25s (the scan takes ~6s). This also un-breaks **View transcript** (same code path). Verify on the dev box (David): open box detail → the card appears with a count → the sheet lists your hand-started Claude/Codex (and `claude agents`) sessions; tap one's View → the transcript loads. [iOS, on-device]

---

## v0.0.162

**Found Sessions fixes** — the entry card was invisible on connected boxes, and discovery was cluttered with one-shots. iOS PR #610 (visibility), broker PR #611 (quality floor). Broker REDEPLOYED (floor live: discovery went 238 → 111 on the dev box; min turn_count now 2, no one-shots leaked; caps discovery/fork/watch all live, token unchanged).

- **1 · "Started outside Conduit" card now appears on connected boxes** — it was being skipped: the iOS box-detail discovery probe was gated on the WS harness being linked at the instant the screen opened, so on first open it was skipped and never retried (host-metrics weren't gated, which is why HEALTH rings showed but the card didn't). The probe now runs whenever the box advertises `session_discovery` (it's a plain HTTP call, like host-metrics) and re-probes when the box finishes connecting. Verify on the dev box (David): open box detail → "STARTED OUTSIDE CONDUIT" appears with a count → the sheet lists your hand-started Claude/Codex (and `claude agents`) sessions. (Was the v0.0.161 bug where only the Conduit-started session showed.) [iOS, on-device]
- **2 · Discovery no longer cluttered with trivial one-shots** — ~half of on-disk sessions are single-turn (quick Qs / tests / aborted starts). The broker now applies a quality floor: sessions with <2 turns (Claude exchange pairs / Codex turns) are excluded from discovery, so the count and "All" view stay meaningful (dev box: 238 → 111). They're untouched on disk and still CLI-resumable. Verify: the entry-card count and the sheet show substantial sessions, not a wall of 1-turn entries. [broker — live now; visible in any app build with Found Sessions]

---

## v0.0.161

**Found Sessions — Branch (fork) enabled + Flow B "Watch live".** Broker fork+watch PR #606, iOS Watch UI #608, Android Watch UI #607. Broker REDEPLOYED (v0.0.161 binary: `session_discovery`+`session_fork`+`session_watch` all live, token unchanged, since_ts endpoint verified). NOTE: because Branch un-gates on the live broker capability, **Branch already works on v0.0.160 too** now that the broker is redeployed — but the Watch live UI is new in v0.0.161.

- **1 · Branch a copy (fork) now works** — on a RUNNING found session, "Branch a copy" forks the conversation from its latest saved point onto a NEW git worktree (branch `conduit/fork-<short>`) and opens it as a Conduit session; the terminal session keeps running, untouched. Verify: on a running hand-started session, Branch a copy → a new Conduit chat opens with the prior context on a fresh worktree; your terminal session is unaffected; nothing on the box is mutated. (Claude uses `--fork-session`; Codex uses thread fork / resume-into-new-worktree.) [iOS+Android, on-device — needs a running hand-started session in a git repo]
- **2 · Watch live (Flow B) — read-only tail of a running session** — a RUNNING row now offers "Watch live": a read-only mirror that tails the session's transcript (polls the broker every ~2.5s for new turns), with a persistent "You're watching — not driving" banner and a single live pulse dot. You are NEVER driving it. Verify: Watch live on a running session → new turns from the terminal session appear within a few seconds; the banner + pulse are present; there is no composer/input. [iOS+Android, on-device]
- **3 · Branch from watch** — the Watch screen's only CTA is "Branch a copy to take control" → the Branch flow (#1). Verify: from Watch live, tap Branch a copy → it forks into a drivable Conduit copy; the watched terminal session is untouched. [iOS+Android, on-device]
- **4 · Watch failure/edge states** — stream stalls / box drops → "stream paused — reconnecting" (last frames kept, keeps retrying, Branch still offered); the watched session ending → "session ended" with View full transcript + Branch from last point. Reduced-motion → the pulse is static. Verify: background the box / kill the watched session mid-watch → the correct paused/ended state appears, never a hang. [iOS+Android, on-device]

---

## v0.0.160

**Found Sessions** — discover + resume agent sessions started OUTSIDE Conduit (by hand in a terminal). Broker PR #602, iOS #603, Android #604. Per the SWE-Kitty-3 design handoff (Direction A · Calm/Contextual). Broker REDEPLOYED to the dev box (v0.0.160, `session_discovery` live, smoke-tested against 238 real sessions; token unchanged, no re-pair). Fork ships GATED (`session_fork:false`) — Branch CTA shows its unavailable state for now (real fork lands next). Whole feature capability-gated, ships dark on boxes without the broker support.

- **1 · Discover & resume sessions started outside Conduit** — in box detail, under "STARTED OUTSIDE CONDUIT", a "Continue a session" card shows a count when the box has Claude/Codex sessions you started by hand. Tap → a discovery sheet (provenance banner, search, Recent/By folder/All filters, grouped by repo) listing them with agent, repo·branch·turns, and an IDLE/RUNNING/IN-CONDUIT chip. Verify on a box where you've started a `claude`/`codex` session directly over SSH: the card appears with a count; the sheet lists your real sessions with correct repo/branch/running-state. [iOS+Android, on-device — needs a box with hand-started sessions]
- **2 · Resume an idle session** — tap Resume on an IDLE row → a stepped "Resuming…" progress (Reading transcript → Re-ingesting N turns → Restoring tree → Handing off) → it opens as a normal Conduit chat with full prior context. Verify: resume a hand-started idle session → the agent continues with its full history, you can chat. [iOS+Android, on-device]
- **3 · View transcript (read-only)** — View on any row opens the conversation read-only (persistent "read-only · not resumed" chip), with Resume/Branch offered at the bottom. Verify: View shows the real transcript; no composer; the chip is unmistakable. [iOS+Android, on-device]
- **4 · Running rows never offer Resume; Branch is gated this build** — a RUNNING session (live in your terminal) offers "Branch a copy" (not Resume). In v0.0.160 the broker advertises `session_fork:false`, so the Branch CTA shows its unavailable/"not yet on this box" state — it must NEVER take over the live session. Verify: a running row shows Branch (disabled), never Resume; nothing you do touches the terminal session. (Real Branch lands in the next build.) [iOS+Android, on-device]
- **5 · Hide / overflow / empty / offline** — row ⋯ → View · Copy resume command · Hide (4s undo, persists per box, removes from list only — deletes nothing). Empty and offline states explain themselves. Verify: Hide removes a row and persists; the sheet's empty/offline states read correctly. [iOS+Android, on-device]

---

## v0.0.159

App polish round: fresh-install launch sequencing, archived-session status, and full-swipe gestures. iOS PRs #597 (launch) + #599 (archive/swipe), Android PRs #598 (launch) + #600 (archive). App-only — no broker change, CI-compile-only → on-device verification.

- **1 · Fresh-install launch is clean (splash → onboarding, no Settings flash)** — on a brand-new install the launch used to flash onboarding, then the splash for ~1.5s, then land on Settings. Three fixes: Home no longer auto-opens Settings when the device is unpaired (onboarding owns first-run); the onboarding cover now presents only AFTER the splash finishes (it was rendering above the splash); and the splash dismisses quickly (~0.55s) on a fresh install instead of holding the full 1.5s (nothing to connect to). Verify on a FRESH install (delete + reinstall): you see a brief splash → the onboarding wizard, with no onboarding flash-before-splash and no Settings page popping up. Returning/paired launches unchanged. [iOS+Android, on-device]
- **2 · Archived sessions show "Ended", not "Running"** — archiving a session ends it on the broker (process killed) but the History row kept its last `live` status and rendered "running". The row is now marked exited on archive, so History shows "Ended". (Archive remains end + read-only transcript by design; resume stays a separate effort.) Verify: archive an active session → open History → its chip reads Ended/closed, never Running. [iOS+Android, on-device]
- **3 · Full-swipe commits swipe actions (iOS)** — swiping a cell only revealed the button; you couldn't drag all the way to commit. Full-swipe is now enabled on the destructive lists: History (full-swipe = Delete, still confirms — it's permanent), Home (full-swipe = Archive), and Settings → Boxes (full-swipe = Forget box). Non-destructive swipes (e.g. Rename) are unchanged. Verify: drag a History/Home/Box cell fully across → the primary action triggers without tapping the button. (Android keeps its long-press-to-confirm pattern — no swipe there.) [iOS, on-device]

---

## v0.0.158

SSH add-box flow fix + marketing-site screenshot refresh. iOS PR #595, Android PR #594 (SSH flow), website PR #593 (real app screenshots, already live at conduit.kaopeh.com). App changes are CI-compile-only — need on-device verification.

- **1 · First-connect host-key trust no longer kills the add sheet** — adding a brand-new SSH box used to pop the unknown-host-key (TOFU) prompt as a separate top-level dialog that dismissed the "Add via SSH" sheet; after trusting the host you landed back in Settings with no box added and had to re-add it. The fingerprint-trust step now renders **inline inside the add sheet** ("First time connecting to this server — verify its fingerprint" with Trust & continue / Cancel), and the top-level alert/dialog is suppressed while the sheet is up, so the flow runs continuously: enter creds → trust host → install → connected, in one sheet. Verify on a FRESH box whose host key you've never trusted (clear known-hosts / use a reinstalled VM): add it → the verify card appears in the same sheet, Trust & continue proceeds straight into the install stages and the box comes online without the sheet vanishing. [iOS+Android, on-device]
- **2 · Failed/incomplete adds persist and are retryable from Settings** — a bootstrap that failed or got interrupted used to leave nothing behind; now it's saved as a box in Settings → Boxes marked "Add failed" with the error reason and a **Retry** button. Retry reopens the Add-via-SSH sheet **prefilled** with the saved host/port/username (you re-enter the secret — no silently-stored credential). Failed boxes can be deleted like any other. Verify: force an add to fail (wrong key / unreachable host) → a red "Add failed" box with the reason appears in Settings; Retry opens the prefilled sheet; a successful retry flips it to a normal connected box; delete also works. [iOS+Android, on-device]

---

## v0.0.157

Security-hardening batch from a 3-agent broker audit (auth logic was sound; the gaps were deployment posture + supply chain). PRs #587 (credential re-key), #588 (checksum verify + systemd hardening + secrets→EnvironmentFile), #589 (loopback default, token-leak + DoS + origin fixes), #590 (website Security section), #591 (release SHA256SUMS-upload CI fix). Broker REDEPLOYED to the dev box (binary swapped to v0.0.157, `--local` dropped) and verified server-side: public `/health` 200, unauth→401, authed→200, token unchanged (no re-pair), sessions survived, journal shows the redacted token + public-bind warning, 0 cleartext-token leaks. Website Security section live at conduit.kaopeh.com.

- **1 · App still connects after the broker redeploy** — the dev box now runs v0.0.157 with the loopback-default change (it keeps its explicit `--addr :1977`, so it stays publicly reachable) and the credential re-key (existing OAuth blobs lazy-migrate to a keyfile on first read, bearer still in env → no re-pair). Verify on-device: open the app → David box connects straight away, existing agent sessions resume, and a session that uses provider OAuth still works (confirms the credential migration). [iOS+Android+broker, on-device]
- **2 · Adding a fresh box still bootstraps (checksum + hardened unit)** — installs now verify the broker binary against the published `SHA256SUMS` before `chmod +x` (verify-if-present, hard-fail on mismatch, warn-if-absent), the systemd unit gained sandboxing directives (NoNewPrivileges, PrivateTmp, ProtectSystem=full, RestrictAddressFamilies), and secrets moved from inline `Environment=` to a `0600` EnvironmentFile. Verify on-device: add a brand-new SSH box → it installs and comes online (the install-progress modal completes, no checksum/perms failure), and an agent session runs on it. [iOS+Android+broker bootstrap, on-device]
- **3 · LAN auto-pair still works on a private network (only if you use it)** — the bearer token is still advertised over mDNS so a phone on the same LAN auto-pairs, but ONLY when the box has a genuine private (RFC1918/link-local) address; a public/VPS box never broadcasts it. Verify (optional, only if you run a broker on your home LAN): a box on your Wi-Fi still shows up for one-tap pair. (The dev box dropped `--local` entirely — it's reached via public IP/QR.) [iOS+Android, on-device, optional]
- **4 · Send-state / leak hardening is non-disruptive** — WS read-limit + upload cap, HTTP read/idle timeouts, CheckOrigin allowlist (native apps send no Origin → allowed), and the codex `--` arg-terminator should be invisible in normal use. Verify: normal chat, terminal, file upload, and a codex session all behave as before. [iOS+Android+broker, on-device]

---

## v0.0.156

Device-test round fixes: box-switch connection flicker, approval-card reconcile on a lock-screen decision, Signature-arm tool collapse, one-tap re-authenticate, install-progress modal, push-to-start Live Activity, and durable chat send. iOS PRs #575 + #576 + #581, Android PR #577, broker+relay PRs #580 + #582 + #583. REQUIRES broker+relay redeploy.

- **1 · Box switch no longer flickers connected→disconnected** — switching the active box (especially to an SSH box like Hostinger) briefly showed the shell as connected, then snapped back to a disconnected state before settling. Cause: the superseded old client's queued `onDisconnected` fired AFTER the new client was already linked and clobbered its state. Each connection is now stamped with a generation and a superseded client's callbacks are dropped (iOS: per-`StoreDelegate` generation; Android: a generation-guarded delegate wrapper — gating on the generation, not on harness reachability, so a genuine disconnect of the current client is still handled). Verify: switch David ⇄ Hostinger a few times → the target box goes straight to connected with no disconnected flash. [iOS+Android, on-device]
- **2 · Approval card reconciles after a lock-screen decision** — denying (or approving) an approval from the lock-screen Live Activity left the in-app "NEEDS YOUR INPUT" card still armed even after the agent had moved on. The decision now optimistically marks the pending-input item answered locally (no wait for the broker's WS echo). Verify: trigger a permission prompt, background the app, Deny from the lock screen → reopen the app and the inline card reads answered/declined, not still armed. [iOS+Android, on-device]
- **3 · Tool runs collapse under Signature (Conversation style B)** — under arm B a run of tool calls rendered as separate rows instead of one collapsible cluster. Arm B now has a collapsible header ("N commands · all exit 0" / "N commands · M failed" / "running"), default collapsed, expanding to the quiet spine rows; failures auto-expand. Verify: Settings → Labs → Conversation style → B, then run three shell commands one after another → they collapse into a single "3 commands" cluster you can expand. (Android already had this.) [iOS, on-device]
- **4 · One-tap re-authenticate** — Settings → a provider's ⋯ menu → "Re-authenticate" used to open the Manage sheet (which had its own ⋯), forcing a second tap. It now launches the provider's OAuth directly, and the top-level Settings entry reads "Manage". Verify: ⋯ → Re-authenticate starts sign-in immediately with no intermediate sheet. [iOS+Android, on-device]
- **5 · Install-progress modal for first-use SSH bootstrap** — adding an SSH box for the first time used to show a silent screen for many seconds while the broker installed. It now shows a blocking overlay ("Setting up user@host") with staged dots (connecting → securing → authenticating → opening tunnel → checking → downloading → starting → installing → waiting) and, on failure, the specific error plus Retry/Cancel (covers auth_failed, host_key_rejected, broker_install_failed, harness_start_timeout, etc.). PR #580. App-only. Verify: add a fresh SSH box → the progress modal shows the install stages; force a failure (bad host / kill the broker mid-install) → a readable error with Retry appears, never a silent hang. [iOS+Android, on-device]
- **6 · Live Activity starts in the background (push-to-start)** — previously the Turn Live Activity could only START while the app was foreground (`Activity.request` is foreground-only), so an approval/choice arriving while backgrounded showed nothing on the lock screen. The broker now sends an ActivityKit push-to-start when no card is running and the app is detached; the card appears on the lock screen with the app closed, the app adopts the OS-started activity on next foreground (no duplicate), and the existing update/end path resolves it on approve/deny. iOS PR #581, broker+relay PR #582. REQUIRES broker+relay redeploy (relay BEFORE broker). Verify: lock/background the device, trigger an approval-requiring action → the card appears on the lock screen with the app closed; Approve from the lock screen unblocks the agent and dismisses the card; foreground the app → exactly one card. [iOS+broker+relay, on-device]
- **7 · Durable chat send with send-state bubble** — sending a message then immediately killing the app could silently lose it: the WS write "succeeded" locally but never reached the broker, yet the bubble looked sent. "Delivered" now means the broker acknowledged it — the message stays in the persisted outbox (bubble faded with a dotted border) until a broker `chat_ack` arrives (bubble solid), and unconfirmed messages are resent on reconnect, deduped by a client message id so the agent never receives a double. PR #583 (core+broker+iOS+Android). REQUIRES broker redeploy. Verify: send a message and immediately force-kill the app → reopen → the agent still receives it and replies (not lost); watch the bubble go faded/dotted → solid when delivered, with a distinct failed state if it can't send. [iOS+Android+broker, on-device]

---

## v0.0.155

Live Activity top declutter. iOS PR #573. App-only.

- **1 · Live Activity top no longer double-prints the status** — for a "needs your input" Live Activity the top row was stacking two near-identical status lines ("needs your pick · claude" directly above "CLAUDE IS ASKING"). The redundant sub-line is now suppressed when the agent is asking, so the top is just mark + title + timer and the "CLAUDE IS ASKING" line carries the state once (lock screen + Dynamic Island expanded). Running/done activities are unchanged. Verify: trigger a choice/permission Live Activity → the top shows the title + one status line, not two. [iOS, on-device]

---

## v0.0.154

Multi-box correctness: broker auto-update on reconnect (finally working) + session/box attribution + counts. iOS PR #570, Android PR #571. App-only (no broker redeploy — the broker already reports its version).

- **1 · Broker auto-updates on reconnect (for real this time)** — the v0.0.148 auto-update was dead code: a normal reconnect with a live SSH tunnel only bounced the WebSocket and never re-ran the bootstrap that does the version check. Now, after connecting to an SSH box, the app compares the broker's reported version (`/api/capabilities`) against the app version and triggers a one-shot in-place update when the broker is older — no forget+re-add needed. Verify: with a box on an older broker, reconnect from a newer app build → the broker silently updates (check About/readiness shows the new broker version) without forgetting the box. [iOS+Android, on-device]
- **2 · Per-box session count is correct** — the Home BOXES rows were counting the whole mixed session list (so a box could claim sessions that live on another box). Each box row now counts only the sessions actually on that box, and non-active boxes show their real count. Verify: with two boxes each running a session, each box row shows its own count (not the total). [iOS+Android, on-device]
- **3 · Every active-session row shows which box it's on** — the Active Sessions list mixed boxes but only badged the non-active ones. Now every row is badged with its box name (when more than one box exists), so attribution is unambiguous. Verify: with sessions on two boxes, each Active Sessions row shows its box badge. [iOS+Android, on-device]
- **4 · History rows have a stable box label** — saved-session history was tagged with whichever box was active when the last status arrived, causing duplicate/mislabeled rows. History now uses each session's stable owning-box stamp. Verify: a session shows under one box in History with the correct label (no duplicate rows under two boxes). [iOS+Android, on-device]

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
