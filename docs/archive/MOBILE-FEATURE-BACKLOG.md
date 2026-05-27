# Mobile Feature Backlog

> **Archived 2026-05-23.** Sequencing superseded by
> [`PLAN-2026-05-19.md`](PLAN-2026-05-19.md) and the per-feature plan
> docs (`PLAN-LITTER-*`, `PLAN-AGENT-OAUTH`, `PLAN-TERMINAL-REWRITE`).
> Kept for historical context.

Date: 2026-05-18

> **2026-05-19 update:** sequencing in this doc is now superseded by
> [`PLAN-2026-05-19.md`](PLAN-2026-05-19.md), which adds Rust-first
> refactor (Package 1), subagent / handoff surfaces, BLE pairing,
> Live Activities / lock-screen card, and Whisper-style voice (rail A) on
> top of the items below. Inventory in this file remains accurate; treat
> the dated plan as the execution layer.

## Purpose

This document turns the KittyLitter reference into a concrete product backlog for `swe-kitty`.

It is not a vague "make the app nicer" note. It is the next implementation plan for making the current shell behave like a real mobile client for our broker.

## What We Have Now

Current mobile chat surfaces are extremely thin:

- [apps/ios/Sources/Views/ChatTab.swift](/root/developer/projects/kitty-swe/apps/ios/Sources/Views/ChatTab.swift:1)
  - flat `ScrollView`
  - one text bubble per event
  - no typed rendering beyond role + text + file list
- [apps/android/app/src/main/kotlin/sh/nikhil/swekitty/ui/ChatPage.kt](/root/developer/projects/kitty-swe/apps/android/app/src/main/kotlin/sh/nikhil/swekitty/ui/ChatPage.kt:1)
  - same basic shape in Compose

This is enough for smoke testing transport, but not enough for serious dogfooding.

## What KittyLitter Has That We Need

From upstream `litter`:

- iOS view tree includes:
  - `ConversationView.swift`
  - `MessageBubbleView.swift`
  - `ToolCallCardView.swift`
  - `ImageGenerationToolCallView.swift`
  - `ComputerUseToolCallView.swift`
  - `ConversationComposer*`
  - `QuickReplySheet.swift`
  - `DiscoveryView.swift`
  - `SessionsScreen.swift`
  - `InlineHandoffView.swift`
  - `SubagentCardView.swift`
- iOS models include:
  - `ConversationItem.swift`
  - `PendingUserInputRequest+ThreadMatching.swift`
  - `SavedServer.swift`
  - `SavedServerStore.swift`
  - `SavedThreadsStore.swift`
  - `NetworkDiscovery.swift`
  - `StreamingRendererCoordinator.swift`
- shared Rust bridge includes:
  - `conversation.rs`
  - `hydration.rs`
  - `discovery.rs`
  - `saved_apps.rs`
  - `session/`
  - `store/`
  - `transport/`
  - `types/`
  - `widget_guidelines.rs`

Interpretation:

- KittyLitter is not just a styled chat bubble app.
- It has a richer conversation model, richer tool/rendering model, richer saved-server/session model, and richer shared core.

## Highest-Value Gaps

### 1. Conversation rendering is too primitive

What we need:

- typed transcript items instead of one flat `ChatEvent`
- proper user bubble vs assistant bubble vs tool-call card treatment
- markdown rendering for assistant content
- code-block rendering
- diff rendering
- expandable long text sections
- richer timestamp / status / metadata presentation

Why:

- KittyLitter treats the conversation as structured content, not just plain strings
- this is the single most visible gap in daily use

## 2. Tool calls need first-class UI

What we need:

- dedicated tool-call cards
- collapsed summary + expandable details
- status coloring for:
  - in progress
  - success
  - failure
- sections for:
  - key/value metadata
  - text output
  - JSON
  - code / command output
  - diffs
  - progress timelines

Why:

- upstream `ToolCallCardView.swift` is one of the most important practical surfaces
- agent work is hard to follow without this

## 3. Pending user input needs explicit UI

What we need:

- detect and surface pending `request_user_input` state
- match requests to the active thread/session
- render selectable options as native cards/buttons
- support 1-3 short questions cleanly
- keep the request inline in the transcript until answered

Why:

- this is one of the key mobile affordances you explicitly called out
- a raw text dump of user-input requests is not acceptable

## 4. Images need real rendering

What we need:

- inline image blocks for agent-produced images
- upload/attach images from the composer
- image preview / tap-to-expand behavior
- consistent image handling on both iOS and Android

Why:

- KittyLitter has explicit image-related conversation/tool surfaces
- our current app barely treats images as a first-class message element

## 5. Composer needs to become a real mobile composer

What we need:

- attachment support
- better multiline text editing
- context strip / pinned context display
- quick replies / suggestion chips
- clearer send state and disabled state
- eventually mentions for files, skills, plugins if our broker supports them

Why:

- upstream has a full `ConversationComposer*` set
- our current composer is a text field plus send button

## 6. Session and server management are too weak

What we need:

- multiple saved servers, not one remembered endpoint
- server pills / rows with live health
- better session list
- better session recovery / hydration
- clear active agent/session state
- discovery support where appropriate

Why:

- upstream has explicit `SavedServerStore`, `DiscoveryView`, `SessionsScreen`, and related support
- the current shell still behaves like a one-server demo

## 7. Handoff / subagent / multi-agent surfaces are missing

What we need:

- visible agent badges in conversation and session headers
- subagent / child-thread cards
- inline handoff surfaces
- better `switch_agent` UX and state visibility

Why:

- this is where `swe-kitty` should exceed a generic Codex mobile client
- our broker semantics need dedicated UI, not hidden protocol behavior

## 8. Streaming behavior needs to feel native

What we need:

- bottom-anchor policy while streaming
- don't yank scroll if the user is reading older content
- better incremental rendering of assistant output
- separate live/finished render paths if needed

Why:

- upstream `ConversationView.swift` has explicit streaming viewport policy and render coordination
- our current "always jump to bottom on event count change" behavior is too crude

## 9. Browser / memory / preview surfaces need stronger integration

What we need:

- tighter browser tab integration with conversation actions
- better memory/handoff preview surfaces
- richer state between session, browser preview, and transcript

Why:

- these are part of the actual product promise, not side tabs

## Recommended Execution Order

### Package 1: Conversation foundation

- define richer transcript item types in shared core
- add typed UI models on iOS and Android
- replace flat chat rows with:
  - user bubble
  - assistant markdown bubble
  - tool-call card
  - system/status row

Goal:

- make the conversation screen feel like a product, not a log viewer

### Package 2: Pending user input + quick replies

- add pending user-input state to core
- match pending requests to active session/thread
- render native answer sheets/cards
- support direct response submission

Goal:

- mobile can complete agent flows cleanly when the agent asks for structured input

### Package 3: Images + attachments

- render agent images inline
- add composer image attach flow on both platforms
- improve preview/open behavior

Goal:

- parity for image-heavy tasks

### Package 4: Sessions + saved servers

- move from one-endpoint persistence to multi-server persistence
- add server management list and health status
- add better session hydration/recovery

Goal:

- make the app viable for real repeated use, not one pairing at a time

### Package 5: `swe-kitty` differentiators

- inline handoff view
- subagent cards
- multi-agent session state
- memory/handoff preview improvements

Goal:

- product-specific value beyond upstream parity

## Platform-Specific Direction

### iOS first

Priority files to replace or refactor heavily:

- [apps/ios/Sources/Views/ChatTab.swift](/root/developer/projects/kitty-swe/apps/ios/Sources/Views/ChatTab.swift:1)
- [apps/ios/Sources/Views/ProjectView.swift](/root/developer/projects/kitty-swe/apps/ios/Sources/Views/ProjectView.swift:1)
- [apps/ios/Sources/Views/ProjectListView.swift](/root/developer/projects/kitty-swe/apps/ios/Sources/Views/ProjectListView.swift:1)
- [apps/ios/Sources/SessionStore.swift](/root/developer/projects/kitty-swe/apps/ios/Sources/SessionStore.swift:1)

Add likely new groups:

- `Views/Conversation/`
- `Views/Sessions/`
- `Models/Conversation/`
- `Models/Servers/`

### Android second but parallel-ready

Priority files to replace or refactor heavily:

- [apps/android/app/src/main/kotlin/sh/nikhil/swekitty/ui/ChatPage.kt](/root/developer/projects/kitty-swe/apps/android/app/src/main/kotlin/sh/nikhil/swekitty/ui/ChatPage.kt:1)
- `ProjectScreen.kt`
- `ProjectListScreen.kt`
- [apps/android/app/src/main/kotlin/sh/nikhil/swekitty/SessionStore.kt](/root/developer/projects/kitty-swe/apps/android/app/src/main/kotlin/sh/nikhil/swekitty/SessionStore.kt:1)

Likely add:

- conversation component package
- server/session state package
- richer shared UI theme tokens

## Shared Core Work Required

Current `core/` will need to grow beyond:

- terminal stream
- flat chat events
- basic session creation

Likely additions:

- typed conversation items
- pending user-input request state
- richer tool-call payloads
- image attachment descriptors
- saved server/session persistence support
- hydration/resume improvements

## Recommendation

Do not spend the next cycle on isolated styling tweaks.

The next meaningful mobile milestone should be:

1. replace flat chat rendering with typed conversation rendering
2. add pending user-input UI
3. add image rendering + attachments
4. strengthen sessions/servers

That is the shortest route from "shell" to "credible KittyLitter-style mobile client."

---

## v1.x — Parity follow-ups (2026-05-18 update)

The first backlog pass framed "what KittyLitter has that we lack" at the chat-bubble level. After landing the reconnect / Glass-theme / ANSI-terminal / one-line-install milestones, here are the next parity-driven items, grouped by which upstream they come from. Order roughly reflects user-visible impact per unit work.

### A. Parity with **litter** (`github.com/dnakov/litter`)

Surfaces we don't have yet, drawn from `apps/ios/Sources/Litter/Views/`:

1. **`ConversationTimelineView`-style streaming** — litter has a `StreamingRendererCoordinator` (in `Models/`) that interleaves tool-call cards with assistant text as the agent streams. Our flat `ChatTab` renders only finished events. Building this needs typed `ConversationItem`s in the Rust core (`hydration.rs` / `conversation.rs` in litter) so iOS and Android share one timeline model.

2. **Tool-call cards** — `ComputerUseToolCallView`, `ImageGenerationToolCallView`, `SubagentCardView`, `CrossServerToolResultView`. When the agent runs a shell command / writes a file / invokes a sub-agent, we should render a collapsed card with title, args, status (pending → running → done → failed), and an "expand for output" affordance. Replaces today's `[chat:tool] running ls -la` plain-text line.

3. **`QuickReplySheet`** — modal sheet of contextual chips parsed from the visible agent output. Existing memory `project-quick-replies-client-side` already pins the design: client-side detector, no MCP bridge, per-agent regex strategies. Lives in `core/` so iOS + Android share.

4. **`DiscoveryView` + saved servers** — multi-broker pairing. Today we pair one endpoint and forget. Add `SavedServerStore` (Keychain / EncryptedSharedPreferences), an mDNS browser screen listing every `_swe-kitty._tcp.local` advertiser, and a server-switcher in the sidebar / drawer. Litter's `DiscoveredServer.swift` + `SavedServer.swift` are the template.

5. **`HomeBottomBar` + `HomeComposerView`** — the in-session bottom dock from litter's `HomeDashboardView`. Glass-capsule action row that's persistent across the terminal/chat/browser tabs (new session, voice, attach, pin a context). Currently we have no global persistent affordance inside a session. Closes B.5 in `project-ios-visual-rewrite`.

6. **`ChatWallpaperBackground` / `WallpaperSelectionView`** — per-conversation visual identity. Litter ships static + video wallpapers (`VideoWallpaperPlayerView`). Nice-to-have, not load-bearing, but the AppearanceSettings story plugs into our existing `Theme/` cleanly.

7. **`AnimatedSplashView`** — closes B.6 in `project-ios-visual-rewrite`. Litter has a tuned splash that hides the cold-start latency of the Rust core boot.

8. **`InlineHandoffView`** — when an agent swap (`switch_agent`) is mid-flight, show the typed handoff progress inline in the chat instead of just flipping the badge. Mirrors our existing `docs/SESSION-LIFECYCLE.md §5` flow but adds a UX.

9. **Multi-agent visual identity** — litter ships per-agent assets in `Assets.xcassets/agent_*.imageset` (claude, codex, hermes, pi, opencode). We have one neon-cat badge. Adding agent avatars + accent colors is small but pays off when `switch_agent` is used.

10. **CarPlay + Mac Catalyst** — litter has `CarPlay/CarPlaySceneDelegate.swift`, `MacCommands/MacCommands.swift`, and Catalyst voice stubs. Out of scope for v1 but candidate for v1.x — same WebSocket protocol, just additional scene delegates.

11. **Voice in/out** — `RealtimeVoiceScreen.swift`, `VoiceCallView.swift`, `HomeVoiceOrbButton.swift`, `AudioWaveformView.swift`. On-device Whisper (iOS Speech.framework / Android SpeechRecognizer) → `send_chat`. Already in `docs/PLAN.md` Part F v1.x #4; promote to backlog with concrete entry points.

12. **Diff rendering** — `DiffRendering.swift`. Currently file edits surface as raw `+/-` text. A typed diff card with collapse/expand per hunk is high-value when an agent is writing code.

13. **`ConversationComposer*` family** — litter's composer has attach sheet, context bar, expanded view, popup overlays, modal coordinator, etc. Ours is a single TextField. Phase 1: just add attach (image / file) + a context chip ("editing X.swift").

### B. Parity with **swe-swe** (`github.com/choonkeat/swe-swe`)

`swe-swe` ships a real **web frontend** in `www/`: Elm app (`elm.js`) + vanilla JS (`index.js`) + theme-aware CSS, with FOUC-prevention boot script and `_redirects` for Netlify-style hosting. It speaks the same WebSocket protocol that swe-kitty's broker already serves.

14. **Web frontend** — at minimum, a static `www/` served by the broker at `GET /` so a user with a laptop on the same network can drive a session without installing the mobile app. v1: just a terminal view (xterm.js) wired to the existing `/ws/<uuid>` endpoint. v1.1: chat + browser tabs to match the mobile multi-view. Trade-off: PLAN.md explicitly says "no web client (swe-swe's UI already works)" — but having something on `/` keeps a non-mobile fallback alive when swe-swe isn't installed alongside, and we can ship it as ~200 KB of static assets embedded in the Go binary (`//go:embed www/*`).

15. **OS-native terminal feel on the web** — swe-swe's frontend ships xterm.js plus its CSS theme. If we do (14), reuse this exact bundle so the visual identity stays consistent across phone + laptop.

### C. Parity-independent — operational wins

These don't come from upstream but show up the moment swe-kitty has more than one user:

16. **Push notifications** — APNs/FCM wired to the broker's `view_event { kind: "stall_alert" }`, `status { phase: "exited" }`, and `pending_input` events. Today the phone is a viewer; this turns it into a real remote control. The broker needs a new endpoint `POST /push/register` that stores APNs/FCM tokens, plus a background "needs your attention" classifier in `internal/session/watchdog.go`.

17. **Background fetch / wakeup** — iOS Background App Refresh + Android `WorkManager` periodic check so a backgrounded app reconnects ahead of the user opening it. Pairs with #16: by the time the notification taps in, the session is already paired.

18. **Memory diff UI** — `swe-kitty memory show --diff <a> <b>` rendered in-app. Currently `MemoryButton` opens the rendered HTML in the in-app browser; add a "compare to last checkpoint" affordance that shows what the agent changed in its plan.

19. **Subagent / parallel sessions in one project** — when claude spawns a child task, surface it as a nested session you can drill into. Maps onto our existing per-session model — needs a `parent_session_id` field on `ProjectSession` and a tree-view in the sidebar.

20. **Pairing via shortlink** — instead of QR + bearer, the broker can mint `swekitty://pair/<short-code>` URLs and post them through the OS share sheet, so pairing from a desktop to a phone doesn't need a physical screen-to-camera step.

### Sequencing recommendation

Rough order for the next quarter, optimising for "biggest dogfood gain per week":

```
Quarter A — typed conversation:
  1. Typed ConversationItem in core/  (A.1)
  2. Tool-call cards on both platforms  (A.2)
  3. Diff rendering  (A.12)
  4. Pending-input UI  (already in earlier section)

Quarter B — multi-broker:
  5. SavedServerStore + DiscoveryView  (A.4)
  6. Push notifications  (C.16)
  7. Web frontend at GET /  (B.14)

Quarter C — polish + voice:
  8. HomeBottomBar dock  (A.5)  → closes B.5 of iOS visual rewrite
  9. AnimatedSplashView  (A.7)  → closes B.6
  10. Quick replies  (A.3)  → already memory-scoped
  11. Voice in/out  (A.11)
```

Stop-the-line items (regressions, not features): none open as of 2026-05-19. The `TestPingPong` regression flagged earlier — server sending a binary frame in violation of `WEBSOCKET-PROTOCOL.md §3.3` — is fixed on `main` (server now sends JSON text per the contract). The new typed conversation work can rely on the heartbeat path.

