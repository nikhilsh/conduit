# Task 007 — Multi-view: chat + browser tabs on iOS and Android

## Scope
Complete the per-project view picker by implementing the Chat tab and Browser tab on both platforms. Wire the `view_event` channel through the Rust core.

**In scope:**
- `core/src/views.rs` — finalize `ChatEvent` shape (role, content, timestamp, optional file refs)
- `core/src/transport.rs` — route incoming `view_event` JSON to `on_chat_event` callback; route `preview_ready` to `on_preview_ready`
- iOS: `apps/ios/Sources/Views/ChatTab.swift` (List + composer + auto-scroll), `BrowserTab.swift` (WKWebView at `<endpoint>/preview/<uuid>/`)
- iOS: `Views/MemoryButton.swift` — header icon that opens `<endpoint>/memory/sessions/<uuid>.html` in `BrowserTab`
- Android: `ChatPage.kt` (LazyColumn + composer), `BrowserPage.kt` (WebView), `MemoryButton.kt`
- iOS + Android: Health badge in `ProjectView` / `ProjectScreen` header (🟢🟡🔴) bound to `SessionStatus.health`
- Per-session preview proxy wiring confirmation (harness side already done in task 001/006)

**Out of scope:**
- Memory editing UI (post-v1)
- Voice input (post-v1)

## Frozen contracts
- `docs/WEBSOCKET-PROTOCOL.md` — `view_event` message shape
- `docs/MEMORY-FORMAT.md` — what the memory URL renders

## Done means
- iOS sim + Android emu: spawn one session, run `npm run dev` in Terminal tab, switch to Browser tab → preview renders, switch to Chat tab → see structured agent messages
- Tap Memory icon in header → in-app browser opens session HTML
- Health badge transitions through states under fault injection
- `ci.yml` all jobs green

## Files allowed
- `core/src/{transport,views,session}.rs`
- `apps/ios/Sources/Views/{ChatTab,BrowserTab,MemoryButton,ProjectView}.swift`
- `apps/android/app/src/main/kotlin/sh/nikhil/conduit/{ChatPage,BrowserPage,MemoryButton,ProjectScreen}.kt`

## Branch
`agent/<your-name>-007-multiview-tabs`
