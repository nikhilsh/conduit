# Plan — Litter-style UI rebuild

Date: 2026-05-20
Reference: 4 litter iOS screenshots shared by the user
(`Home`, `Info`, `Chat`, `Settings`) + `https://kittylitter.app/`.

## Goal

Bring SweKitty's visual + structural design into alignment with
litter's iOS reference, while keeping our own product affordances —
specifically the per-session **Terminal / Chat / Browser** multi-view,
which is the main idea per chat window for us.

## Decisions (locked in by user 2026-05-20)

| # | Topic | Decision |
|---|---|---|
| 1 | Terminal / Chat / Browser tabs | **Keep.** They are the main idea per chat window. Prominent under the new session header. |
| 2 | Bottom-bar voice + search | **Build both.** Not stubs. Voice as a global dictation entry point. Search as a sessions-across-servers search view. |
| 3 | iPad / large screen support | **Keep.** Retain `NavigationSplitView` (or equivalent) on regular size class; new bottom bar is iPhone-shape only. |
| 4 | Glass primitives | **Keep.** `glassRoundedRect`, `glassCapsule`, etc. stay. New surfaces also use glass where appropriate — we do not replace with flat cards. |

## Scope summary

| Surface | Today | Target | Change |
|---|---|---|---|
| Brand accent | green (`#00A86B`) | Anthropic copper (`#CC785C`) | **Done** (commit b22bd63) |
| Chat body font | system sans | monospaced w/ user setting | **Body done** (b22bd63); Font setting + propagation still to ship |
| Home navigation root | `NavigationSplitView` | iPhone: stack + bottom bar; iPad: keep split | **Rebuild for compact size class** |
| Server selection | inside Settings | first-class server-pill tabs at home top | **New ServerTabsStrip** |
| Bottom bar | none | voice / + / search (3 controls) | **New BottomActionBar + voice + search features** |
| Session header | compact info card | back · status·model selector · path subtitle · refresh · info | **Redesign** |
| Tabs (Terminal/Chat/Browser) | top of session, segmented picker | top of session, segmented picker — **kept and emphasized** | Visual restyle only |
| Session Info | none | dedicated screen with stats + actions (Appearance, Fork, Rename) | **New SessionInfoView** |
| Settings IA | one card list | sectioned (Support, Theme, Font, Conversation, Servers, Experimental) | **Rebuild** |
| Card style | glass | glass — retained | No primitive swap |
| Stats card visual | none | big copper number + mono label grid | **New StatsGrid primitive** |

## Open product gaps to fill

1. **Voice (global)** — currently we only have voice inside the chat composer (`InlineVoiceButton`). New bottom-bar voice tile triggers a global modal dictation that hands the transcript to whatever screen is active (compose new session prompt, search query, or message). Reuses the existing speech recognizer.
2. **Search (sessions)** — new view. Searches across `store.savedServers` × `store.sessions` × `store.conversationLog` for a query. v1: client-side text-match on the conversation log; v2 (later) push the search server-side via broker.
3. **Session "Info" screen** — surfaces stats we already track + Fork/Rename ops we don't fully have yet:
   - Fork (Rust core has no `fork_session` — add it: new session with same agent + cwd + seed the conversation log with the current one as system prompt).
   - Rename — store-local `displayName` field on `ProjectSession`, no broker round-trip needed.

## Visual tokens to formalize

Keep the existing tokens, plus add:

- `SweKittyTheme.statBig: Font` — big-number font for stat grids (mono, large size).
- `SweKittyTheme.bodyMono: Font` — bound to `AppearanceStore.fontFamily`.
- `SettingsRow` shape — rounded-rect with leading orange icon, trailing chevron, optional toggle. Uses `glassRoundedRect`.
- `SectionLabel` shape — small uppercased mono label above section.

## Staged rollout

Each stage = one release, sideload + evaluate, then next stage.

### Stage 1 — Foundation: AppearanceStore + Font setting + Settings rebuild

**Risk: low. Visible polish.**

Files:
- New iOS `Models/AppearanceStore.swift` — `@Observable` settings holding `fontFamily: FontFamily = .monospaced | .system`, `collapseTurns: Bool`, persisted to `UserDefaults.standard`.
- iOS `Views/ConversationView.swift` — read AppearanceStore for the markdown block font.
- iOS `Views/SettingsSheet.swift` — full rebuild as sectioned `glassRoundedRect` rows:
  - **Support** — "Sponsor on GitHub" → external link
  - **Theme** — Appearance row → `AppearanceSheet` (modal with theme + font picker)
  - **Font** — inline picker, Monospaced / System
  - **Conversation** — Collapse Turns toggle (UI only for v1)
  - **Servers** — list saved + "Add server" CTA → existing AddServerSheet
  - **Experimental** — voice toggle, debug flags
- iOS `Views/AppearanceSheet.swift` — new
- Android mirrors: `AppearanceStore.kt` (DataStore-backed), `SettingsScreen.kt` rebuild, `AppearanceSheet.kt`.

Acceptance: open Settings, see sectioned IA matching litter's Settings screenshot. Toggle Font → Monospaced; chat body switches font.

### Stage 2 — Chat header redesign + composer + agent selector placement

**Risk: low. Contained to ProjectView + ChatTab.**

Files:
- iOS `Views/ProjectView.swift` — new header structure:
  - Row 1: `← back` · `● claude medium ▼` (status dot + agent selector dropdown) · `↻` refresh · `ⓘ` info
  - Row 2: project path (truncated middle, mono caption, muted)
  - Row 3: existing Terminal / Chat / Browser segmented picker — visually heightened to be the "main idea"
- iOS `Views/ChatTab.swift` — drop the inline agent-switcher pill (redundant with new header); restyle composer as a single rounded-rect (`+` plus button left, textfield, mic right) inspired by litter's "Message litter…" composer.
- Android mirrors.

Acceptance: open a session, see the litter-style title + tabs prominent.

### Stage 3 — Session Info screen + stats + Fork/Rename

**Risk: medium. New screen + new core method.**

Files:
- iOS `Views/SessionInfoView.swift` — new. Presented as a sheet via the ⓘ button in the header.
  - Hero: status dot + session name (large) + agent pills (`claude` / `medium` filled outline) + path/id/ts.
  - Action row: `Appearance` (opens AppearanceSheet) / `Fork` (calls store.forkSession) / `Rename` (inline editable).
  - Stats grid: Messages count (from conversationLog), Turns (count of distinct user turns), Commands (count of `tool` items with command set), Files Changed (count of unique paths in `files`), MCP Calls (count of tool items where toolName matches MCP), Exec Time (sum of durationMs).
  - Server Usage card — count of bytes sent/received per session if we instrument transport; v1 placeholder "—".
- iOS `Models/SessionStore.swift` — add `forkSession(sessionID:)`, `renameSession(sessionID:to:)`.
- Rust core `core/src/lib.rs` — new `fork_session` UniFFI method.
- UDL surface update + bindings regen.
- Android mirrors: `ui/SessionInfoScreen.kt`, store methods.

Acceptance: ⓘ button in chat header opens Info screen with real stats. Fork creates a new session. Rename persists locally.

### Stage 4 — Home rebuild: ServerTabsStrip + BottomActionBar (compact-size only)

**Risk: medium-high. Biggest structural change.**

Files:
- iOS `Views/RootView.swift` — branch on `horizontalSizeClass`:
  - Compact (iPhone): new `HomeView` with stack + bottom bar.
  - Regular (iPad): keep `NavigationSplitView` — left rail gets a litter-style restyle but layout structure stays.
- iOS `Views/HomeView.swift` — new (compact-only).
  - Top: settings gear (left), centered logo/mark, list icon (right) — all in glass circles.
  - `ServerTabsStrip` (horizontal scrollable pills from `store.savedServers` + `+ server` last pill).
  - Sessions list — flat rows: `○` (or `●` if selected) + name (mono) + "ts · ip" subtitle.
  - `BottomActionBar` — three controls: `mic.fill` (left), `plus` FAB (center, big copper), `magnifyingglass` (right).
- iOS `Views/ServerTabsStrip.swift` — new.
- iOS `Views/BottomActionBar.swift` — new.
- iOS `Views/SessionSearchView.swift` — new (triggered by search button).
- iOS `Views/VoiceDictationSheet.swift` — new (triggered by mic button). Hands transcript back via callback to currently active context (new-session prompt if no current session, otherwise composer).
- Android mirrors.

Acceptance: iPhone home matches litter. iPad still uses split view but with new visual language.

### Stage 5 — Voice (global) + Search (sessions) functional

**Risk: medium. Real feature work.**

Voice:
- Reuse the existing `SFSpeechRecognizer` pipeline from `InlineVoiceButton`.
- New `VoiceDictationSheet` presents a fullscreen-ish modal with a big waveform + transcript-so-far + send/cancel.
- On confirm, send transcript to broker as a chat message if a session is active; otherwise open AgentPickerSheet pre-populated with the transcript as the initial prompt.

Search:
- iOS: build an index from `store.conversationLog` and `store.savedServers`. Filter as user types.
- Result rows: server pill + session name + matched snippet (with highlight).
- Tap → open that session.

Android equivalents.

### Stage 6 — Polish & glass-effect tuning

**Risk: low. Cleanup.**

- Review every glass surface — make sure tints + opacities match litter's contrast (litter's "cards" feel solid rather than translucent; ours can be a bit blurrier).
- Apply per-agent tint subtly to the chat composer + Info screen agent pill — but keep the brand accent (copper) as the dominant global accent.
- Any visual inconsistencies surfaced during stages 1-5.

## What's explicitly NOT in this plan

- **Litter's agent-output parsing (permission prompts, diff cards, tool affordances)** — that's task #16, separate package. Without that, our chat won't FUNCTIONALLY mimic litter's chat even when it visually does.
- **Carplay / Watch / Live Activities** — long-roadmap, not relevant.
- **Berkeley Mono shipping** — we'll use SF Mono / system mono for v1. Berkeley Mono is a paid font with licensing implications; revisit later.

## Release-tag map

| Stage | Tag | Approx. effort |
|---|---|---|
| 1 | `manual-2026-XX-XX-litter-stage1` | ~2 hr |
| 2 | `manual-2026-XX-XX-litter-stage2` | ~1.5 hr |
| 3 | `manual-2026-XX-XX-litter-stage3` | ~3 hr (includes Rust core change) |
| 4 | `manual-2026-XX-XX-litter-stage4` | ~3 hr |
| 5 | `manual-2026-XX-XX-litter-stage5` | ~2 hr |
| 6 | `manual-2026-XX-XX-litter-stage6` | ~1 hr |

Sum: ~12.5 hours of real work, spread across as many sessions as needed.

## Existing tasks this absorbs / supersedes

- Task #18 (Litter-style home + settings rebuild) — this plan _is_ that, expanded.
- Task #16 (litter-style chat adapter for agent output parsing) — stays separate, complements but doesn't depend on this plan.
- Task #17 (debug agent-swap) — independent; should be done before Stage 2 so the new chat header's agent dropdown actually works.

## Acceptance for "litter-ish enough" (whole-plan exit criteria)

When you can open the app and the visual + structural feel matches your litter screenshots side-by-side at a glance — same brand accent, same monospace body, same home layout pattern (pills + sessions + bottom bar), same info screen treatment, same settings sectioning — even if individual flows still differ underneath. The agent-output parsing (task #16) is what closes the remaining functional gap.
