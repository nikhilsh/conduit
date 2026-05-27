# PLAN — Litter Visual Parity (exhaustive gap audit)

> **Archived 2026-05-27 — shipped; see [`docs/ROADMAP.md`](../ROADMAP.md).** The
> 5-PR visual-parity rebuild shipped end-to-end on iOS + Android. Preserved for
> the gap-audit detail.

Date: 2026-05-22 (status block updated 2026-05-23)
Author: research agent (audit only, no code changes)
Reference: `github.com/dnakov/litter` @ main (Swift sources fetched 2026-05-22)
Prior plan: `docs/PLAN-LITTER-UI.md` (staged structural rebuild — Stage 6 landed; visual drift remains)
Mobile port spec: `docs/MOBILE-PORT-MATRIX.md`

## Status (2026-05-23): rebuild plan shipped

The 5-PR rebuild proposed in Section E **shipped end-to-end**, including
an Android mirror that wasn't originally scoped:

| PR | Title | Status |
|---|---|---|
| PR 1 — Foundation | typography ramp, tokens, iOS 26 glass, lighter shadows | **shipped (#139)** |
| PR 2 — Settings | iOS 26 glass on LitterUI, font-size slider, 14pt corners (iOS+Android) | **shipped (#140)** |
| PR 3 — Home | footnote row density, 7pt indicator, 44pt bottom bar, drop top-row gear (iOS+Android) | **shipped (#141)** — top-row settings gear partially restored in #147 for discoverability after the search button was found to duplicate (decision §3 below revised) |
| PR 4 — ProjectView header + ChatTab | heading-scale ramp, flat tool cards, drop diff stroke (iOS+Android) | **shipped (#142)** |
| PR 5 — Sheets | ServerPill stroke treatment, AddServerSheet 28pt icons, plain SessionInfo Done | **shipped (#143)** |
| Polish (deferred items from PR4) | flat inline rows for PendingInput/Handoff, 20/12 discovery padding, inline agent-picker header | **shipped (#145)** |

What's still open (Section F deferrals, all explicitly carried):

- Pinch-to-zoom on home (F.8) — `HomeSessionsScrollView`-style UIKit gesture machine, ~800+ LOC, no PR yet.
- Per-chat wallpaper (F.6) — deferred indefinitely.
- Live Activities / Lock Screen widget (F.7) — needs entitlement + widget target.
- `AnimatedLogo` (Section "Open decisions" #4) — user kept the static `KittyMark`; not chasing.
- `BadgeStack` on `ServerPill` (A.9.2) — multi-agent runtime badges per pill, no PR yet.

Open decisions (Section "Open decisions for the user") — outcomes:

1. User message style (A.2.1, PR 4) — kept `.flat`; the `userMessageStyleIsFlat` regression test is intentionally still pinned.
2. Default body font (B.2) — kept monospaced default.
3. Top-row settings gear (A.1.6, PR 3) — initially dropped per litter, restored as a small affordance in #147 after the user reported a discoverability regression.
4. AnimatedLogo (PR 3) — kept static `KittyMark`.
5. `UserMessageBackground` test (A.2.1) — kept; assertion unchanged.

The rest of this doc is preserved verbatim for design reference. Any
future visual-parity work should branch from PR5's end-state (commit
`d10c007` and the polish in `d218ec1`), not from the original drift
described below.

## Why this doc exists

We have shipped six "litter-stage-N" PRs. The IA matches at the structural level: home stack with pills + sessions + bottom bar, sectioned settings, three-row session header, glass primitives, copper accent. **But the screens still look subtly off** against the user's litter screenshots — spacing is loose, typography is wrong in places, the glass treatment is heavier than litter's, our cards stack too vertically, our pills/chips are mistinted, and several semantic tokens are missing entirely.

The drift compounded because every PR was incremental — "tighten this row, fix that bubble." Each round shaved a few points here and tinted a chip there, but no PR ever **rebuilt a screen end-to-end against the litter source**. This doc catalogues the gap holistically so the next 3-5 PRs can each rebuild ONE screen against the litter reference, top-to-bottom, holistically.

The doc is intentionally exhaustive. The next agents do not need to re-derive any of this from the litter source; they need to execute against it.

---

## Section A — Per-screen side-by-side

For each screen: list the litter primitives we should match, then concrete drift items, with file pointers.

### A.1 — Home

**Litter** (`Views/HomeDashboardView.swift`, `Views/HomeBottomBar.swift`, `Views/HomeSessionsScrollView.swift`):
- Animated brand logo top-left, zoom buttons top-right. No icon-button gear.
- Sessions render as `SessionCanvasLine` rows with **four zoom levels** (SCAN/GLANCE/READ/DEEP). Pinch-to-zoom is a UIKit-backed `HomeSessionsScrollView` — not SwiftUI ScrollView. Continuous interpolation, snap to discrete level. Vignette during pinch, blur on non-anchor rows.
- Row geometry: title in `.footnote`, metadata in `.caption2`; `padding(.leading, 1), .trailing, 8, .vertical, 5`. Active row background `RoundedRectangle(cornerRadius: 6).fill(surfaceLight.opacity(0.55))`. Depth indent `CGFloat(depth) * 8`.
- Bottom bar: TWO `GlassMorphContainer`s (so plus/composer and search don't visually merge). Button size **44pt**, container spacing **14**, horizontal padding **14**, spring `response: 0.42, dampingFraction: 0.82`.
- Composer expands inline from `+` button using `glassMorphID` (`matchedGeometryEffect`) — collapses back when keyboard dismissed and composer empty + 0.6s elapsed.

**Ours** (`Views/HomeView.swift`, `Views/BottomActionBar.swift`, `Views/HomeSessionRow` inline):
- Top row: gear (left), brand mark (center), clock + list (right) — all `glassCircle` buttons at 40×40. **Drift: litter has no gear up top — settings is in the sessions list or accessed via a different affordance.**
- Sessions: plain `ScrollView { VStack(spacing: 6) { ForEach { HomeSessionRow } } }`. No zoom. No pinch. Single density. Row uses `.title3 monospaced bold` for title, **way bigger than litter's `.footnote`**.
- Bottom bar: `BottomActionBar` is a static HStack — mic glassCircle 52×52 on the left, copper outlined-circle `+` 64×64 on the right. **Litter does not have an oversized outlined-circle plus.** Litter's `+` is a 44pt filled glass capsule that morphs into the composer.
- We have no inline-expanding composer on home. The `+` opens a separate `AgentPickerSheet` modal.

**Concrete drift items:**
- A.1.1 **Session row font is 1.5× too big.** Ours: `.system(.title3, design: .monospaced).weight(.bold)` (~20pt). Litter: `.litterFont(.footnote)` (~13pt). Caption ours `.caption monospaced`; litter `.caption2`.
- A.1.2 **Row vertical padding is 2.8× too big.** Ours: `.padding(.horizontal, 16), .vertical, 14`. Litter: `.padding(.leading, 1), .trailing, 8, .vertical, 5`.
- A.1.3 **Active-row affordance missing.** Litter fills the selected row with `surfaceLight.opacity(0.55)` over a 6pt rounded rect. We instead swap a `circle.fill` vs `circle` icon.
- A.1.4 **No zoom levels.** Litter's headline interaction is pinch-to-zoom from SCAN→DEEP. We have a fixed render. (Defer — this is a big build. Not blocking visual parity for the first 3 PRs, but should be acknowledged.)
- A.1.5 **Bottom bar over-built.** The 64pt copper-outline circle is not in litter. Replace with a 44pt `glassCapsule(interactive: true)` `+` button that morphs into the composer. Mic stays but is also 44pt.
- A.1.6 **Top row has the wrong handle.** Litter uses the AnimatedLogo as the brand affordance; gear (settings) does not sit on home. Move settings into the sessions-area chrome or the sidebar, not a top-row glass circle.
- A.1.7 **`HomeSessionRow` indicator is wrong.** Ours uses `circle.fill` / `circle` SF symbol. Litter uses a 7pt filled dot for pulsing live status and a depth-indent for nested threads.
- A.1.8 **Background gradient is too saturated.** We brightness-shift `±0.02` on `#0C0E12` (`Theme.swift:75`). Litter uses the flat `#1A1A1A` (dark) / `#F2F2F7` (light) surface with no per-corner shift. The shimmer adds noise without value.

### A.2 — Chat (ChatTab + ConversationView)

**Litter** (`Views/ConversationView.swift`, `Views/MessageBubbleView.swift`, `Views/ConversationComposerContentView.swift`):
- User bubbles: `GlassRectModifier(cornerRadius: 14|18, tint: LitterTheme.accent.opacity(0.3))`. **Tinted glass user bubble.** Compact: `padding(.horizontal, 12), .vertical, 8`, corner 14. Normal: `18 / 14 / 18`.
- System/tool bubbles: `padding(.horizontal, 12), .vertical, 10`, corner 12.
- Message spacing: `.padding(.bottom, 14)` between turns. VStack internal `4-8` compact, `8-14` normal.
- Body font: `litterFont` ≈ `.body` with `LitterPalette.fontDesign` (monospaced if user picked it; serif/system otherwise). Heading scales `1.07×–1.43×` of base.
- Code blocks: `cornerRadius: 12 or 8`, `LitterTheme.codeBackground.opacity(0.8)` (`#F0F0F5` light / `#111111` dark).
- Composer (`ConversationComposerContentView`): UIKit-backed UITextView wrapped via UIViewRepresentable. Single rounded rect with leading buttons row + autocomplete popup above (8pt corner, 95% opacity, 56pt offset). Slash-commands, @mentions, $skills, plugin mentions.

**Ours** (`Views/ChatTab.swift`, `Views/ConversationView.swift`):
- User messages: `.flat` style — right-aligned plain text in the accent color, no bubble at all. **Locked by `ConversationStyle.userMessage = .flat`** and asserted by a test. **This is a deliberate divergence from litter.** Litter user bubbles ARE tinted-glass capsules.
- Assistant text: SwiftUI `Text(AttributedString(markdown:))` with `appearance.bodyFont()`. No heading scale (markdown parser doesn't scale `# H1` — they all render at body size).
- Composer: SwiftUI `TextField(... axis: .vertical)` plain style. No UIKit backing. No @ / $ / / autocomplete popups.
- Quick replies: horizontal scroll of glass capsules above the composer. Litter has them too but they're tied to the streaming tool detection, not heuristic keyword matching.
- Tab strip: `Picker(...) .pickerStyle(.segmented)` in a `glassRoundedRect(cornerRadius: smallCornerRadius=14)`. Litter has NO tab strip — only conversation.

**Concrete drift items:**
- A.2.1 **`UserMessageStyle.flat` likely contradicts litter.** Re-evaluate: user wants litter parity, litter uses a tinted glass bubble. The test that asserts `.flat` will need to be updated or removed. **Decision needed (Section E).**
- A.2.2 **No heading scale.** Litter's `litterFont` ramps headings 1.07–1.43× of base. Ours uses raw `.body` markdown. Need a typography ramp (Section B).
- A.2.3 **Tool card glass is too prominent.** Our `ConversationToolCard` uses `glassRect(cornerRadius: 18, tint: statusTint.opacity(0.24))` with full glass treatment, then renders nested `.surface.opacity(0.72)` blocks inside. Litter uses a single flat `surface.opacity(0.6-0.8)` rounded rect — no layered glass. Our version reads "card inside card inside card."
- A.2.4 **`STDOUT` / `STDERR` / `COMMAND` section labels** use `.caption2 weight(.bold).tracking(0.7)`. Fine. But the wrapping container double-stacks corner radii (14 outer, 14 inner code block, 12 command) — visually messy.
- A.2.5 **Composer not UIKit-backed** — no @ / $ / / autocomplete. Deferred — but our composer is functionally weaker than litter's. Mention in Section C.
- A.2.6 **Message spacing.** Ours: `LazyVStack(spacing: 14)`. Litter: also 14 between turns — match. Inside turns we use various 8/10pt spacing, which mostly matches.
- A.2.7 **Pending input / handoff / subagent cards** use full `glassRect(cornerRadius: 18, tint: warning.opacity(0.22))` treatment. Litter's `InlineHandoffView` is a much flatter pill-row, not a card. Our 18pt corner + heavy shadow + tint reads "alert," not "informative."
- A.2.8 **Avatars/icons in cards.** We use `wrench.and.screwdriver.fill` for the tool header. Litter shows the tool name + a small status dot, no wrench glyph. Less iconic, more text-forward.
- A.2.9 **Diff blocks**: we render with `surface.opacity(0.72)` + `border.opacity(0.55)` 0.8pt stroke. Litter renders without the visible stroke — tints diff lines green/red against a flat surface. Drop the stroke.

### A.3 — Settings

**Litter** (`Views/SettingsView.swift`, `Views/AccountView.swift`):
- `Form` with `LitterTheme.backgroundGradient.ignoresSafeArea()` + `.scrollContentBackground(.hidden)`. Section row backgrounds `LitterTheme.surface.opacity(0.6)`.
- Section headers: `UPPERCASED` `litterFont(.caption)` in `textMuted`, **20pt horizontal padding**. Content boxes: `14pt vertical, 20pt horizontal`. Outer container: 16pt horizontal.
- Glass: `.ultraThinMaterial` with 10pt corner radius. **Note: smaller corner radius (10) than ours (22).**
- Rows are mostly NavigationLinks with a leading accent-colored SF Symbol icon (no circular background — just the symbol), a label, and a chevron-right. Subtitles below labels in `textSecondary`.

**Ours** (`Views/SettingsSheet.swift`):
- `ScrollView { VStack(spacing: 22) { sections... } }` with `.padding(.horizontal, 16), .vertical, 18`. Each section: a `SettingsSectionHeader` (`title3.bold` in `textPrimary`, sentence-case) above a `glassRoundedRect()` (corner 22) containing the rows. Inner padding `14 horizontal, 14 vertical`.
- Rows: 22pt-wide accent-colored SF Symbol icon (no circular background — correct), title `.subheadline.weight(.semibold)`, optional `.caption` subtitle in `textMuted`, trailing `chevron.right` in `.caption.weight(.semibold)`.
- Toolbar "Done" button is wrapped in a copper-tinted capsule — overstyled for a confirmation action.

**Concrete drift items:**
- A.3.1 **Section header weight is too heavy.** Ours uses `title3.bold` sentence-case in `textPrimary`. Litter uses small `caption` UPPERCASED in `textMuted`. We've gone from "section label" to "section heading" — making the page feel like a magazine article rather than a settings list.
- A.3.2 **Card corner radius too large.** Ours: `cardCornerRadius = 22`. Litter: `10`. Our cards read as iOS-26-Liquid-Glass "tiles"; litter reads as flat dark "panels."
- A.3.3 **Card material too heavy.** We use `regularMaterial` everywhere. Litter uses `.ultraThinMaterial` on settings. Our cards read solid; litter's float.
- A.3.4 **Container inner padding too tight.** Ours: 14 horizontal / 14 vertical. Litter: 20 horizontal / 14 vertical. The wider gutter makes rows breathe.
- A.3.5 **Done button overstyled.** Currently wrapped in a copper-tinted capsule with stroke. Litter uses a plain `Button("Done")` in `.confirmationAction` — flat blue (or accent) link, no capsule.
- A.3.6 **Mixed section styles in the same screen.** Top sections (Support, Theme, Font, Conversation, Experimental, Agent accounts) use the new `SettingsSectionHeader` (sentence-case title3). Bottom sections (Servers, Harness, About) use the legacy `SettingsSection` (uppercased mono caption2). This split is visible to the user and looks half-rebuilt — because it is.
- A.3.7 **`Tip the Kitty` link row** uses the generic `SettingsLinkRowContent` — fine — but the icon (`pawprint.fill`) is in the copper accent which competes with the heart/sponsor semantics. Litter's tip row uses a subdued color + has a "Buy us a treat" subtitle.

### A.4 — Add-Server Sheet

**Litter** (`Views/AlleycatAddServerSheet.swift`):
- SwiftUI `Form` with `.scrollContentBackground(.hidden)` and `LitterTheme.backgroundGradient`. Sections use `LitterTheme.surface.opacity(0.6)` as the row background.
- Single-form approach with sections for QR / LAN / SSH / Manual; user enters JSON or fills fields, agents listed inline with icon + checkmark, recommended agents have stronger border opacity.

**Ours** (`Views/AddServerSheet.swift`):
- Custom card layout — four `entryCard`s in a vertical stack, each a `glassRect(cornerRadius: 22, tint: tint.opacity(0.16))` with a 42pt colored-filled circle icon, title, subtitle, chevron.
- Each card opens a separate sheet for that flow (QR scanner, DiscoveryView, SSH login, manual pair).

**Concrete drift items:**
- A.4.1 **We use four discrete cards; litter uses one Form with sections.** Architecturally different. The four cards approach is arguably more affordance-friendly for a first-time user (each route is its own big tap target), but it doesn't match litter's visual density.
- A.4.2 **Icon circles too big.** 42×42 filled-color circles read as "primary action buttons" — but the row itself is the action. Reduce to 28pt symbol-only (matching the settings row pattern).
- A.4.3 **Card tint is per-route (copper / green / claude / warning).** Litter uses neutral surface throughout. The multi-color cards make the sheet read like a launchpad, not a settings sheet.
- A.4.4 **`ManualPairSheet`** uses raw TextField/SecureField with `surface.opacity(0.6)` 12pt corner — close to litter's pattern, but rounded label headers (`.caption.weight(.semibold)` in `textSecondary`) instead of uppercased.

### A.5 — AgentPickerSheet

**Litter** does not have a dedicated "pick an agent" sheet. The agent picker is part of the `HomeDashboardView` — model + reasoning effort chip morphs into a list via `HomeModelChip`.

**Ours** (`Views/AgentPickerSheet.swift`):
- Sheet with optional `headerNote` card, optional `promptPreview` card (voice-driven flow), two big agent buttons (`agentButton` for `claude` + `codex`) using `glassRect(cornerRadius: 22, tint: tint.opacity(0.20))` with a 44pt `AgentAvatar`, title `.title3.weight(.semibold)`, subtitle `.caption`, chevron.

**Concrete drift items:**
- A.5.1 **Format mismatch.** Litter morphs the chip on home into a popup. We open a separate sheet. **Justified divergence** — our agent set is larger (claude, codex, hermes, pi, opencode) and Cmd+K-style picker isn't ready. Keep the sheet.
- A.5.2 **Subtitle wording is dev-facing.** "Anthropic — copper accent, headstrong" reads as developer self-talk. Litter would say "Claude 3.7 Sonnet" or omit subtitle.
- A.5.3 **Header card height balloons** when `headerNote` is present (full glass card just to display the host). Litter inlines pairing context as a label, not a full card.

### A.6 — SessionInfoView (the ⓘ screen)

**Litter** (`Views/ConversationInfoView.swift`):
- Hero: status indicator, thread title, model/reasoning badges, current cwd, thread ID, created/updated relative timestamps.
- Action buttons: Appearance / Fork / Rename (or Shell in server-only mode).
- Stats grid: 2-column. Messages, turns, commands executed, files changed (with +/-), MCP calls, exec time.
- Server usage: token-by-conversation area/line chart, activity-by-day bar chart, model-usage horizontal bar, rate limit gauges.

**Ours** (`Views/SessionInfoView.swift`):
- Hero in `glassRoundedRect(agentTint: ...)` — `AgentAvatar` + `HealthDot` + title (`.title2.weight(.bold)`) + edit pencil + two `AgentPill`s (`session.assistant`, reasoning effort) + folder/hash/time meta rows.
- Action row: three `ActionTile`s (Appearance / Fork / Rename) with `cardCornerRadius=22` rounded rect filled with `surface.opacity(0.85)`, stroked with `border.opacity(0.35)`.
- Stats section: `StatsGrid` with `Conversation Stats` title3.bold.
- Server usage: only token-by-conversation chart. Activity-by-day, model breakdown, rate-limit gauges all missing.

**Concrete drift items:**
- A.6.1 **Section titles too big.** `Conversation Stats` and `Server Usage` use `title3.bold`, but litter uses small caps `caption.bold tracking(0.6) textSecondary`.
- A.6.2 **Hero card tint via `glassRoundedRect(agentTint:)`** — applies an 8% accent overlay. Reasonable but only the avatar+badges should be tinted; the card should stay neutral. Litter's hero card is flat.
- A.6.3 **`ActionTile` (Appearance/Fork/Rename) corner radius too large (22pt).** Litter's action buttons are smaller pill/rect with 10-14pt corners.
- A.6.4 **Stats grid backing missing.** Our `StatsGrid` (separate file) — verify it matches litter's pattern (big copper number + mono label below). Not read in this audit; flag as a check in the rebuild PR.
- A.6.5 **Missing charts**: activity-by-day, model breakdown, rate limit gauges. Token-by-conversation chart present but with a thin `border.opacity(0.4)` grid which clashes with the surrounding glass card.
- A.6.6 **Heading icon: `pencil` next to the title** for the rename affordance — fine, but tap target is tiny. Litter floats Rename as an action button in the row below; the title is plain.

### A.7 — VoiceDictationSheet

**Litter** (`Views/RealtimeVoiceScreen.swift`):
- `SiriEdgeGlow` overlay on a hex background. Multi-layered stroke borders with intensity scaling. Blur effects 4 / 12 / 20pt. Phase-based color (listening = success greens, speaking = warning oranges, thinking = warning + accent blend).
- Primary text uses `LitterTheme.textPrimary` with opacity scaling by recency.
- Controls: 52×52pt circular buttons with `controlFillColor`. 64×64pt red danger end-call button.

**Ours** (`Views/VoiceDictationSheet.swift`):
- Vanilla `NavigationStack` with background gradient. 24-bar `Capsule` waveform driven by `TimelineView` + `sin()` (visual only — no actual audio level reading).
- Cancel / Send buttons at bottom — Cancel is `glassRoundedRect(cornerRadius: 24)`, Send is `accentStrong`-filled `RoundedRectangle(cornerRadius: 24)`.

**Concrete drift items:**
- A.7.1 **No phase-color treatment.** Listening should be tinted accent/success, error tinted danger. We only switch the icon when in `.error` state.
- A.7.2 **Waveform is decorative.** Litter's `AudioWaveformView` reads actual audio levels. Ours is a sine. Tolerable for v1 but flagged.
- A.7.3 **End / send buttons styled inconsistently with each other.** Cancel uses glassRoundedRect; Send uses flat accent fill. Should both be either glass or flat (litter uses two flat buttons of the same shape).
- A.7.4 **No glow.** Litter's `SiriEdgeGlow` is signature. We have nothing. Could be added as a future polish, not blocking parity v1.

### A.8 — DiscoveryView

**Litter** (`Views/DiscoveryView.swift`, `ProximityPairView.swift`):
- `padding(.horizontal, 20), .vertical, 12`; `spacing: 14` between sections.
- Card backgrounds: `surface.opacity(0.6) or 0.85`, `cornerRadius: 14` continuous. Border `accent.opacity(0.18 to 0.45)`.
- "Recommended" pairing cards get enhanced opacity + stronger border.
- Status tags: `cornerRadius: 4` (very square!) with `opacity(0.15)` tinted backgrounds.

**Ours** (`Views/DiscoveryView.swift`):
- `padding(.horizontal, 14), .vertical, 16`. Header card uses `glassRect(cornerRadius: 22)`. Pill row + saved section + nearby section.
- Discovered rows: `glassRoundedRect(cornerRadius: 16)` per row, with a 28pt `wifi.circle.fill` icon, name + host:port + version, and a copper-filled `Pair` capsule button.

**Concrete drift items:**
- A.8.1 **Padding too narrow.** Ours 14pt horizontal; litter 20pt. Adds breathing room.
- A.8.2 **Corner radius too round.** Ours 16pt on discovered rows + 22pt on header card; litter 14pt continuous throughout.
- A.8.3 **Status tags missing.** Litter shows nearby-server status as a small 4pt-corner tinted tag (`live`, `connecting`). We rely on the dot+caption only.
- A.8.4 **Pair button is a filled copper capsule** — fine but litter's pairing CTA uses a `glassCapsule(interactive:)` with accent stroke, not a flat fill.

### A.9 — ServerPill / ServerPillRow

**Litter** (`Views/ServerPill.swift`):
- `padding(.horizontal, 12), .vertical, 6`. HStack spacing 6 between dot and name; inner spacing 2 between name and badges.
- Status dot: 8pt circle.
- Name: `litterFont(.subheadline, weight: .semibold) monospaced` = ~13pt semibold. `textPrimary` color, lineLimit 1.
- Selected stroke: 1.2pt accent at 0.75 opacity. Unselected: 0.6pt muted text at 0.25 opacity.
- BadgeStack: up to 4 agent runtime badges at 18pt with -7pt overlap offset. Overflow shows 3 + count.

**Ours** (`Views/ServerPill.swift`):
- `padding(.horizontal, 12), .vertical, 8` (1pt more vertical). HStack spacing 8 (correct + 2). VStack inner spacing 1 (matches roughly).
- Dot: 7pt (close enough).
- Name: `.system(.subheadline, design: .monospaced).weight(.semibold)` — matches.
- Caption: `.caption2` — matches.
- Uses `glassCapsule(interactive:, tint:)` with active=accentStrong@0.32, inactive=surface@0.65 — instead of litter's stroke-only treatment.
- **No badge stack.** We don't surface running agent badges per server pill.

**Concrete drift items:**
- A.9.1 **Filled vs stroked.** Litter renders unselected pills as transparent with a thin stroke; we fill them with a glass surface tint. Ours look "selected by default."
- A.9.2 **Missing badge stack.** Up to 4 agent badges per pill — significant feature, deferred.
- A.9.3 **Vertical padding +2pt** — minor but adds up across the row.

### A.10 — Terminal + Browser tabs (swe-kitty divergence)

Litter has no per-session multi-view; conversation IS the surface. We have Terminal / Chat / Browser tabs under a segmented picker. **Keep them** (user-decided).

**Drift items relative to our own header:**
- A.10.1 **Tab picker is too prominent** — wrapped in `glassRoundedRect(cornerRadius: smallCornerRadius=14)` with `.controlSize(.large)` segmented picker. Visually it competes with the agent pill above it. Section D addresses this.
- A.10.2 **Tab labels use system icons + text** — fine. But the segmented picker on iOS 26 is wider than typical and pushes the conversation content down.

---

## Section B — Design-token diff

### B.1 — Palette

| Token | Litter (`LitterPalette.swift`) | Ours (`Palette.swift`) | Drift |
|---|---|---|---|
| `accent` light/dark | `#4A4A4A` / `#B0B0B0` | `#4A4A4A` / `#B0B0B0` | match |
| `accentStrong` light/dark | `#00995D` / `#00FF9C` (neon green) | `#CC785C` / `#E89677` (copper) | **deliberate divergence** — we chose Anthropic copper to match agent-tinted UI. Litter's neon green IS their brand. Keep ours. |
| `textPrimary` | `#1A1A1A` / `#FFFFFF` | match | match |
| `textSecondary` | `#6B6B6B` / `#888888` | match | match |
| `textMuted` | `#9E9E9E` / `#555555` | match | match |
| `textBody` | `#2D2D2D` / `#E0E0E0` | match | match |
| `textSystem` | `#3A4A3F` / `#C6D0CA` | **missing** | **GAP** — used by handoff/system rendering for muted-green tone |
| `surface` | `#F2F2F7` / `#1A1A1A` | match | match |
| `surfaceLight` | `#E5E5EA` / `#2A2A2A` | match | match |
| `border` | `#D1D1D6` / `#333333` | match | match |
| `separator` | `#E0E0E0` / `#1E1E1E` | match | match |
| `danger` | `#D32F2F` / `#FF5555` | match | match |
| `success` | `#2E7D32` / `#6EA676` | match | match |
| `warning` | `#E65100` / `#E2A644` | match | match |
| `textOnAccent` | `#FFFFFF` / `#0D0D0D` | match | match |
| `codeBackground` | `#F0F0F5` / `#111111` | **missing** | **GAP** — used by all `code` blocks; we instead use `surface.opacity(0.72)` ad-hoc |
| `background` | not in `LitterPalette` (computed via `LitterTheme.backgroundGradient` from `surface`) | `#FAFAFA` / `#0C0E12` (separate token) | **drift** — we have an extra brightness-shift gradient (`Theme.swift:75-83`); litter uses surface directly |
| Per-agent accents (`claudeAccent`, `codexAccent`, `hermesAccent`, `piAccent`, `opencodeAccent`) | not in litter | ours ship them | **deliberate addition** — keep, this is a swe-kitty feature |

**B.1 verdict:** add `textSystem` and `codeBackground` tokens. Drop the brightness-shifted gradient and use flat surface for the background.

### B.2 — Typography

**Litter** ships a `LitterFont` ramp (file not retrievable at audit time — 404, possibly renamed) but the codebase shows:
- `litterFont(.footnote)`, `litterFont(.caption2, weight: .semibold)`, `litterFont(.subheadline, weight: .semibold)` — wrapper calls that respect `LitterPalette.fontDesign` (mono vs default).
- `LitterFont.conversationBodyPointSize` is variable (user-controllable).
- Heading scale: 1.07× / 1.15× / 1.30× / 1.43× of base size (extracted from MessageBubbleView's markdown rendering).

**Ours** uses raw `Font.system(.style, design: .monospaced|.default)` calls. No central font ramp. `AppearanceStore.bodyFont()` exists but only returns the body font — no heading scale, no caption scale.

**B.2 verdict:** **GAP — add `SweKittyTypography` with:**
- `body(design:)` — respects `appearance.fontFamily`
- `heading(level:)` — h1 1.43×, h2 1.30×, h3 1.15×, h4 1.07× of body
- `caption()`, `footnote()`, `subheadline()` wrappers (all design-aware)
- `monoCaption()`, `monoFootnote()` — always monospaced regardless of preference (for path / branch labels)
- Pin a `defaultBodyPointSize: CGFloat = 14` and let users scale ±2pt in Appearance.

### B.3 — Corner radii / shape tokens

| Token | Litter | Ours (`Theme.swift`) | Action |
|---|---|---|---|
| Settings card / list panel | 10 | `cardCornerRadius = 22` | **REDUCE to 14** for settings cards; keep 22 only on hero-style cards. |
| Inline tag / chip | 4 | n/a (our chips use Capsule) | Add a `tagCornerRadius = 4` for hard-edged tags (status tags). |
| Code block | 8 or 12 | ad-hoc 12 / 14 inline | Add `codeBlockCornerRadius = 10`. |
| User bubble | 14 (compact) or 18 (normal) | n/a (we are flat) | Decision (Section E). |
| Glass capsule | Capsule | Capsule | match |

### B.4 — Glass primitives

| Primitive | Litter | Ours | Drift |
|---|---|---|---|
| `GlassRectModifier` | `glassEffect(.regular, in: …)` on iOS 26 / material fallback below | `RegularMaterial` always | **iOS 26 capability missed.** We don't use `glassEffect`. Plan: gate behind `#available(iOS 26.0, *)` and use the native glass primitive on iOS 26+. |
| `GlassRoundedRectModifier` | same shape, agent-tint via overlay | match | match (shape only) |
| `GlassCapsuleModifier` | `.interactive()` glassEffect on iOS 26 | `regularMaterial` + scale wiggle | drift |
| `GlassCircleModifier` | floating affordance, `.ultraThinMaterial` on fallback | match (we use ultraThin) | match |
| `GlassMorphContainer` | `GlassEffectContainer` on iOS 26 | pass-through `VStack` | **GAP — morph IS the litter signature.** Without it, the `+` → composer transition doesn't morph; it cuts. |
| `glassMorphID(_:in:)` | `glassEffectID(_:in:)` on iOS 26 / `matchedGeometryEffect` fallback | falls through to `matchedGeometryEffect` | match (fallback path is correct) |

**B.4 verdict:** Liquid Glass on iOS 26 is the biggest missing capability. `Glass.swift` already has the surface shape — we need to add the `#available(iOS 26.0, *)` branches that call `glassEffect(.regular, in: shape)` instead of `.regularMaterial.background`. This is the difference between "Material-blur" and "actual refracting glass."

### B.5 — Elevation / shadow

| Token | Litter | Ours |
|---|---|---|
| Card shadow | minimal — relies on glass | `textPrimary.opacity(0.16)` radius 18 y 10 — **heavy** |
| Capsule shadow | flat | same heavy shadow |

**B.5 verdict:** halve the shadow opacity (0.08) and radius (10) on `GlassSurfaceModifier`. Currently every glass surface drops a "magazine drop shadow."

---

## Section C — Component diff

### Primitives litter has that we lack

- **`LitterFont`** — typography ramp. (See B.2.)
- **`StatusDot`** — pulsing dot for live sessions. We have `HealthDot` which is similar; verify it pulses.
- **`AnimatedLogo`** — brand logo on home (we have `KittyMark` static image). Could replace with an animated mark.
- **`BrandLogo`** — header-sized variant.
- **`HomeModelChip`** — model + reasoning chip that morphs into the agent picker. (We use a static pill button.)
- **`HomeVoiceOrbButton`** — global voice entry from home. (We use a generic `glassCircle` mic.)
- **`SessionReplySwipe`** / **`SwipeableRow`** — swipe-to-reply on session rows. (We have nothing.)
- **`MessageRenderCache` / `StreamingAssistantRenderCache`** — we have `MessageRenderCache` in our tree (good).
- **`ContextBadgeView`** — small content-badge for context chips. (We use `ContextChip` — similar.)
- **`ChatWallpaperBackground`** — per-chat wallpaper. (We use the global background gradient.)
- **`LiveActivityPreview`** / **`LockScreenCardView`** — Live Activities for ongoing sessions. (We have none.)
- **`PetSpriteView` / `PetSettingsView`** — desktop pet overlay. (Not for us — litter-specific brand feature.)
- **`AudioWaveformView`** (real audio levels) — (we have a fake sine wave).
- **`SubagentCardView`** — proper subagent rendering. (We have `ConversationSubagentCard` inline — verify it matches.)
- **`ToolCallCardView`** — first-class tool-call card. (We have `ConversationToolCard` inline — over-styled per A.2.3.)
- **`InlineHandoffView`** — flat handoff row. (We have `ConversationHandoffCard` as a heavy glass card.)
- **`CodeBlockView`** — dedicated code block. (We have `ConversationCodeBlock` inline.)
- **`ProjectChip`** — project-level chip. (We use `ContextChip` for both.)
- **`MountedFoldersView`** — surface mounted folders. (We have a stub via SessionInfoView.)
- **`AppsListView`** — apps-list affordance. (Not applicable yet — needs broker support.)
- **`OnboardingCoachmarks`** — first-launch coachmarks. (We have nothing.)

### Primitives we have that litter doesn't (justified divergence)

- **`AgentAvatar`** — multi-agent avatar (claude/codex/hermes/pi/opencode) — required by our agent multiplicity.
- **`AgentPickerSheet`** — see A.5.
- **`InSessionBottomBar`** — three-tab navigation dock. Litter has no tabs.
- **`ContextChip` / `ContextBar`** — pinned context surfacing for chat (broker-specific).
- **`HarnessBadge`** — broker connection state. Litter has model badges, not "harness state" badges.
- **`GhosttyTerminalView` / `WKTerminalView`** — terminal renderers. (Litter has no terminal tab.)
- **`BrowserTab`** — web preview tab. (Litter has none.)
- **`SyntaxHighlightedCodeBlock`** — code highlighting via highlight.js. Litter likely has its own; keep ours.

---

## Section D — Tab divergence justification

**User decision (re-affirmed):** keep Terminal / Chat / Browser tabs. They are the main idea per session.

**Problem:** the current segmented picker (`Picker(...).pickerStyle(.segmented).controlSize(.large)` wrapped in `glassRoundedRect`) eats vertical space and competes with the agent pill above it. Litter has no tab strip, so its chat-area visual weight starts immediately under the agent pill — ours starts ~40pt lower.

**Resolution path (D.1):** convert the tab picker into a **hairline segmented control** above the chat area, so:
1. The agent pill + path caption sit closer to top (smaller header card).
2. The tab strip is rendered as `Picker` with `.pickerStyle(.segmented)` AT `.controlSize(.small)` (or even custom HStack of pill buttons at 28pt height) without a glass wrapper. Use a 1pt bottom hairline `border.opacity(0.5)` as separator.
3. The chat area starts immediately below the hairline, full-width, identical visual weight to litter's `ConversationView`.

**Net effect:** parity in chat-area visual weight while keeping tabs.

**Alternative (D.2):** Make Terminal/Browser a long-press affordance on the agent pill (drop-down: "View as Chat / Terminal / Browser"). Less discoverable; not recommended.

**Recommendation:** D.1 — hairline segmented control.

---

## Section E — Rebuild plan

5 PRs, in order. Each rebuilds ONE screen end-to-end against the litter source. **No PR may overlap the surface area of an earlier one** — each picks up where the last left off.

### PR 1 — Foundation: typography, tokens, glass

**Scope:** add the missing tokens and primitives so subsequent PRs have a working palette. **No screen changes.**

Files:
- `apps/ios/Sources/Theme/Palette.swift` — add `textSystem`, `codeBackground` Pair tokens.
- `apps/ios/Sources/Theme/Theme.swift` — drop the brightness-shift gradient; use `surface.color(for: scheme)` directly. Add `tagCornerRadius = 4`, `codeBlockCornerRadius = 10`, reduce `cardCornerRadius` to `14`, keep `smallCornerRadius` at `10`.
- `apps/ios/Sources/Theme/Typography.swift` (NEW) — `SweKittyTypography` enum:
  - `body()`, `heading1()..heading4()` with multiplier (1.43, 1.30, 1.15, 1.07 × bodyPointSize).
  - `caption()`, `footnote()`, `subheadline()`, `monoCaption()`, `monoFootnote()`.
  - All design-aware via `AppearanceStore.fontFamily`.
- `apps/ios/Sources/Theme/Glass.swift` — add `#available(iOS 26.0, *)` branches that call `.glassEffect(.regular, in: shape)` / `.interactive()` instead of `material.background`. Halve shadow opacity (0.08) and radius (10).
- `apps/ios/Sources/Models/AppearanceStore.swift` — add `bodyPointSize: CGFloat = 14` (range 12-18).
- Tests: token presence assertions, `cardCornerRadius == 14` regression test.

LOC: ~300. Risk: low. Acceptance: app builds, no visual surprises, all existing screens render with marginally tighter corners + lighter shadows.

### PR 2 — Settings sheet exact rebuild

**Scope:** rebuild `SettingsSheet.swift` against litter's `SettingsView.swift` / `AccountView.swift` patterns. One pass, top-to-bottom.

Files:
- `apps/ios/Sources/Views/SettingsSheet.swift` — full rewrite:
  - Replace `SettingsSectionHeader` (title3.bold sentence-case) with **uppercased caption in textMuted**, 20pt horizontal padding.
  - Drop the legacy `SettingsSection` (different visual treatment). Unify on one section style.
  - Card backing: `.ultraThinMaterial` instead of `.regularMaterial`; corner radius 14 instead of 22.
  - Inner padding 20 horizontal / 14 vertical.
  - Toolbar "Done": plain Button, no capsule wrap.
- `apps/ios/Sources/Views/AppearanceSheet.swift` — mirror updates.
- Tests: settings section count, no remaining `SettingsSection` usages, `Done` not wrapped.

LOC: ~400. Acceptance: open Settings on iPhone with litter screenshots side-by-side — section headers small caps, cards flat ultraThin, corners crisper, no two card styles mixed.

### PR 3 — Home rebuild (session row density + bottom bar morph)

**Scope:** rebuild `HomeView.swift`, `BottomActionBar.swift`, and the inline `HomeSessionRow`.

Files:
- `apps/ios/Sources/Views/HomeView.swift` — full rewrite:
  - Top row: brand mark left (consider migrating to an `AnimatedLogo`), search/list right. **Drop the top-row settings gear**; relocate settings into a long-press on the brand mark (matches litter's settings access pattern via sidebar/menu).
  - Session list: typography from `SweKittyTypography.footnote()` (title) + `.monoCaption()` (subtitle). Padding `.leading 1 / .trailing 8 / .vertical 5`. Active row fills `RoundedRectangle(cornerRadius: 6).fill(surfaceLight.opacity(0.55))`.
  - Indicator: replace SF Symbol circle.fill with a 7pt `Circle()` filled `accentStrong` (or `success` for live status) with optional pulse animation.
- `apps/ios/Sources/Views/BottomActionBar.swift` — full rewrite:
  - Two `GlassMorphContainer`s. Buttons at 44pt. Spacing 14. Spring `response 0.42 / dampingFraction 0.82`.
  - Plus button: `glassCapsule(interactive: true, tint: accentStrong.opacity(0.32))` morphing into a composer.
  - Mic button: `glassCapsule(interactive: true, tint: surface.opacity(0.65))`.
  - Drop the 64pt outlined-copper-circle plus.
- `apps/ios/Sources/Theme/Glass.swift` — flesh out `GlassMorphContainer` to use `GlassEffectContainer` on iOS 26.
- Tests: row metrics (font size, padding), bottom-bar button size 44 not 64, no top-row gear.

LOC: ~500. Acceptance: home screen visually matches litter's `HomeDashboardView` reference (modulo our agent + endpoint multiplicity).

### PR 4 — ProjectView header + ChatTab rebuild

**Scope:** rebuild the per-session header and chat content area.

Files:
- `apps/ios/Sources/Views/ProjectView.swift` — header rebuild:
  - Drop the heavy `glassRoundedRect` wrapping the entire 3-row header. Use a single `VStack(spacing: 8)` with no card backing.
  - Tab picker: convert to **hairline segmented control** per D.1. `.controlSize(.small)`. 1pt `border.opacity(0.5)` hairline below.
  - Agent pill: keep but reduce inner padding (10 horizontal, 4 vertical from current 12/6).
- `apps/ios/Sources/Views/ChatTab.swift` — composer rebuild:
  - Composer: single `glassRoundedRect(agentTint:)` with reduced inner padding (10 horizontal, 6 vertical).
  - Quick-reply chips: smaller, use `tagCornerRadius=4` not `glassCapsule`.
  - "Connecting" pill: drop to flat `surface.opacity(0.4)` with no border stroke.
- `apps/ios/Sources/Views/ConversationView.swift` — major edit:
  - **Decide on `UserMessageStyle`** (Section E2 — user decision required). If switching to `.bubble`, update the assertion test.
  - Apply typography ramp from `SweKittyTypography` — headings scale 1.07–1.43× of body in `ConversationMarkdownBlock`. (Implementation: post-parse the `AttributedString` to walk `.markdown.heading.level` runs and set point size.)
  - `ConversationToolCard`: drop the outer `glassRect`; use flat `surface.opacity(0.6)` with 14pt corner. Drop nested `surface.opacity(0.72)` blocks — pick one surface depth.
  - `ConversationHandoffCard` / `ConversationPendingInputCard`: convert from heavy glass cards to flat inline rows with a small leading tint dot.
  - Drop `border.opacity(0.55)` strokes on code/diff blocks.

LOC: ~600 (over the 500 ceiling — consider splitting into PR 4a "header + composer" and PR 4b "conversation rendering").

Acceptance: open a session, the chat area starts immediately below a hairline tab strip; assistant headings render larger; tool cards read flat; user message decision is documented.

### PR 5 — SessionInfoView + AddServerSheet + DiscoveryView polish

**Scope:** the remaining sheet/screen surfaces.

Files:
- `apps/ios/Sources/Views/SessionInfoView.swift` — section titles small caps not title3; hero card drop agent tint; action tiles 14pt corner not 22; add activity-by-day bar chart (uses existing `events` data).
- `apps/ios/Sources/Views/AddServerSheet.swift` — convert from four custom cards to a `Form` with three sections (`QR + LAN`, `SSH`, `Manual`) using neutral surface, smaller icons (28pt symbol, no filled circle).
- `apps/ios/Sources/Views/DiscoveryView.swift` — padding 20/12, corners 14 throughout, status tags (4pt corner, opacity 0.15) for nearby-server status, Pair button as `glassCapsule(interactive:)` not flat copper.
- `apps/ios/Sources/Views/ServerPill.swift` — unselected pills become transparent-with-stroke (`0.6pt textMuted.opacity(0.25)`), selected get `1.2pt accent.opacity(0.75)`. Drop the default-glass-capsule fill.
- `apps/ios/Sources/Views/AgentPickerSheet.swift` — subtitle rewording (less dev-self-talk); drop the heavy header card when `headerNote` is present (inline as small caption instead).
- `apps/ios/Sources/Views/VoiceDictationSheet.swift` — phase-color tint on background gradient + waveform; unify Cancel/Send button shapes.

LOC: ~500. Acceptance: every sheet matches the litter reference for spacing, corner radii, and section header treatment.

---

## Section F — What's NOT going to match litter (justified divergence)

These are explicit "do not chase litter on this" calls. Each gets one paragraph.

### F.1 — Brand accent: copper, not green

Litter's `accentStrong` is `#00FF9C` neon green — their brand. Ours is `#CC785C` Anthropic copper. This is deliberate: most of our agent ecosystem is Claude-first, and copper-tinted UI signals "Claude-tuned" the same way litter's green signals "Codex-tuned." We also offer per-agent tints (claudeAccent, codexAccent, hermesAccent, piAccent, opencodeAccent) — litter doesn't. **Do not change to green.**

### F.2 — Terminal + Browser tabs under the chat area

Litter has only chat. We have Terminal / Chat / Browser. User has explicitly said keep tabs (per `docs/PLAN-LITTER-UI.md` decisions §1). The hairline-segmented-control treatment in Section D minimizes the visual cost, but the tabs themselves are non-negotiable — they are the main idea per session for swe-kitty.

### F.3 — Multi-agent picker + per-agent accents

Litter is OpenAI-only (Codex) with model variants. We support five agents (claude, codex, hermes, pi, opencode) and ship a dedicated `AgentPickerSheet`. The picker stays a sheet (not an inline morph from a chip) and the per-agent accent system stays. The cost: our home screen has agent identity baked into more places than litter's. Acceptable.

### F.4 — Harness / broker chrome

We have a "harness state" badge (linked/live/connecting/failed/disconnected), pairing flows for SSH / QR / LAN / manual, and a Saved Servers concept. Litter has a much simpler local/remote toggle (`AccountView`). Our chrome is heavier here because our networking surface is fundamentally larger. **Keep the four-route Add-Server sheet — but match litter's typography and spacing within it.** Don't collapse to a single `Form` section.

### F.5 — Session list ordering

We sort by recency-touched with the active session pinned. Litter has a more complex zoom-aware sort with pinned threads + forking. We don't have forking surfaced enough yet to mirror their ordering. **Keep our simpler sort.**

### F.6 — Per-chat wallpaper

Litter ships `ChatWallpaperBackground` + `WallpaperSelectionView` + `WallpaperAdjustView`. We use the global background gradient. Per-chat wallpaper is signature litter polish; **defer indefinitely** — adds 600+ LOC for a feature that's not on our roadmap.

### F.7 — Live Activities / Lock Screen

Litter ships `LiveActivityPreview` + `LockScreenCardView` + a `LitterLiveActivity` widget target. We have none. **Defer to a later milestone** — Live Activities require entitlements, App Group config, and a widget target we haven't set up. Tracked in `docs/MOBILE-FEATURE-BACKLOG.md` if anywhere.

### F.8 — Pinch-to-zoom on home

Litter's `HomeSessionsScrollView` (UIKit-backed) with 4 zoom levels is signature interaction. We have flat scroll. The UIKit work to match it (UIHostingController + pinch arbitration + vignette CAGradientLayer + paused UIViewPropertyAnimator for blur scrubbing) is significant — probably 800+ LOC for the gesture machine alone. **Defer to a dedicated PR (PR 6+)** after the first 5 rebuild PRs land. The screens above ship without pinch and still match litter visually at the default density.

---

## Open decisions for the user

These need user input before the next PRs proceed:

1. **User message style (A.2.1, PR 4):** litter renders user messages as a **tinted-glass bubble** (`GlassRectModifier(cornerRadius: 14 or 18, tint: accent.opacity(0.3))`). We currently render as **flat right-aligned accent-colored text** (`ConversationStyle.userMessage = .flat`), with a regression test pinning that decision. Switch to litter's bubble style, or keep flat?
2. **Default body font (B.2):** our `AppearanceStore.fontFamily` defaults to monospaced. Litter defaults to monospaced too (`LitterPalette.isMono` reads `fontFamily` from App Group, defaulting to `"mono"`). Stay monospaced default, or switch to system?
3. **Top-row settings gear on home (A.1.6, PR 3):** Litter has no top-row gear — settings access is via the sidebar/menu. Plan suggests moving it to long-press on the brand mark. Confirm or propose alternative location?
4. **AnimatedLogo (PR 3):** replace the static `KittyMark` image with an animated SwiftUI logo (litter has `AnimatedLogo.swift`)? Or keep the static mark?
5. **`UserMessageBackground` test (A.2.1):** the test that asserts `userMessage == .flat` (`ConversationRendererTests.userMessageStyleIsFlat`) needs to be updated or removed when #1 is decided. Acknowledge?
