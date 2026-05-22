# Terminal renderer rewrite — Ghostty libghostty pick

## Status

Stage 0 spike (feature-flag scaffold) in progress. Stage 1+ deferred.

## Why rewrite (again)

The xterm.js path (Stage F', `PLAN-TERMINAL-XTERMJS.md`) ships, but it
carries WKWebView baggage we'd rather not carry forever on iOS:

- WKWebView spin-up cost dominates first-frame time when a session is
  attached cold; we already paper over this with snapshot replay.
- The JS bridge is async-everywhere; every keystroke and resize crosses
  a postMessage boundary. Latency is fine for chat-shaped terminals
  but visible for fast-scroll TUIs.
- We can't ship a single rendering primitive across iOS + Android;
  Android already has its own native view, so the JS path is iOS-only
  and forks the rendering story.
- Selection, link-tap, mouse reporting, and accessibility are
  all xterm.js extension hooks we'd have to write a Swift bridge for —
  they're stragglers we keep punting.

A native VT emulator + native render layer fixes all of the above and
sets up a path to share the same C surface with Android via JNI later.

## Pick — Ghostty's libghostty

Two real candidates surveyed:

- **SwiftTerm** — what we used before Stage F'. Pure-Swift, single-
  maintainer, mid-stream replay is broken (the vertical-stripe bug
  that pushed us to xterm.js). Rejected.
- **Ghostty `libghostty`** — Mitchell Hashimoto's emulator, written
  in Zig, exposes a C ABI and ships a prebuilt xcframework as a
  GitHub release asset. Battle-tested by the macOS Ghostty app.
  Roadmap mentions an iOS Ghostty shell with a public reference
  impl at `macos/Sources/App/iOS/iOSApp.swift`.

Picking Ghostty.

## §E — Decisions table

| Decision                             | Choice                                                                                    | Rationale |
| ------------------------------------ | ----------------------------------------------------------------------------------------- | --------- |
| Emulator library                     | Ghostty `libghostty` (via `ghostty-vt.xcframework` / `GhosttyKit.xcframework`)            | Mature VT, C ABI, prebuilt iOS slices. |
| Distribution                         | SPM `binaryTarget` URL + checksum from a Ghostty GitHub release asset                     | Avoids checking a 9MB+ binary into git, lets us pin a version. |
| Build-locally fallback               | `zig build -Demit-xcframework` against a checked-out Ghostty source tree                  | Last resort if no upstream release fits. |
| Render layer (Stage 1)               | `CAMetalLayer` driven by a Swift rendering shim, fed by Ghostty's grid/state              | Matches Ghostty's macOS path; reuses upstream's tested glyph cache once ported. |
| Render fallback (Stage 0/Stage 1.5)  | Reuse xterm.js for pixels, use Ghostty only as the VT emulator (feed-and-serialize)       | De-risks renderer work — we can land the VT half first. |
| Input pipeline                       | UIView with `inputAccessoryView`, route keystrokes through `Ghostty.Surface` C API        | Matches existing `KeyableWKWebView` shape so the accessory bar stays. |
| Feature flag                         | `AppearanceStore.experimentalNativeTerminal` (UserDefaults), default off                  | Ship-while-it's-rough; one-line revert if it regresses. |
| xterm.js path                        | Stays compiled and reachable while the flag is off, for at least one release after the new path ships | Same one-release-fallback discipline used during SwiftTerm → xterm.js. |
| Wire protocol                        | Unchanged — broker still ships raw bytes, client still owns terminal emulation            | Stage F's per-cell idea is still off the table. |
| Snapshot/restore                     | Ghostty's `terminal_serialize` C API (or equivalent) — emit ANSI for cross-attach replay | Drop-in replacement for xterm.js's SerializeAddon. |

## Staging

- **Stage 0 — feasibility spike (THIS PR).** Pin the SPM binary
  target, wire a feature flag, expose a `GhosttyTerminalView`
  placeholder behind the flag, prove the wiring shape compiles +
  renders something. No PTY wiring, no rendering, no input — just
  prove we can load the framework and instantiate the view.
- **Stage 1 — VT-only emulator wired to xterm.js renderer.** Feed
  bytes into `libghostty`, ask it for serialized state, route that
  state to xterm.js for rendering. Keeps the JS pixel path while
  retiring the JS VT emulator. Lets us validate Ghostty's VT
  against real harness output before tackling pixels.
- **Stage 2 — native renderer.** Replace the xterm.js renderer with
  a `CAMetalLayer`-backed shim. Selection, link-tap, mouse, accessibility
  routed through native APIs.
- **Stage 3 — Android.** Native Termux `terminal-view` behind the same
  `experimentalNativeTerminal` flag. See "Android pick — Termux
  terminal-view" below. Out of scope for the iOS branch.
- **Stage 4 — retire xterm.js.** Once Stage 2 has shipped on iOS
  for one release with no rollback, drop `Sources/Resources/terminal/`
  and the WKTerminalView path.

## Risk log

- `GhosttyKit.xcframework` — the full kit with `Surface`, Metal, etc —
  is not (currently) shipped as a release asset. Only `ghostty-vt.xcframework`
  (the VT emulator C lib) is. That's enough for Stage 1 but not Stage 2.
  Building the full kit requires the Zig toolchain in CI, which we
  don't have. Mitigation: Stage 1 only needs the VT slice, so we can
  start there; defer the renderer slice to a follow-up that builds
  Ghostty from source or waits for upstream to ship a wider xcframework.
- Ghostty releases are cut as `tip` (nightly) — there is no stable
  semver tag with an xcframework asset. We'd have to either pin
  to a Ghostty commit + build from source, or pin to an asset URL
  with a known sha256 and accept that upstream may overwrite `tip`.
- CI cost: building Ghostty from source on every CI run is a non-
  starter. Either we ship the prebuilt asset path or we vendor a
  cached xcframework in releases of our own.

## Files touched by Stage 0

- `apps/ios/Sources/Models/AppearanceStore.swift` — flag.
- `apps/ios/Sources/Views/SettingsSheet.swift` — toggle row.
- `apps/ios/Sources/Views/GhosttyTerminalView.swift` — placeholder view.
- `apps/ios/Sources/Views/ProjectView.swift` — flag-gated branch in
  `tabContent`.
- `scripts/fetch-ghostty-vt-xcframework.sh` — fetch helper for the
  Ghostty `ghostty-vt.xcframework.zip` release asset.
- `apps/ios/Tests/SweKittyTests/AppearanceStoreTests.swift` — flag
  persistence + default.

The xterm.js path (`WKTerminalView`, `TerminalTabXterm`) is **untouched**
and remains the default. Toggling the flag off restores the old behavior
within a SwiftUI re-render.

## Stage 0 status — 2026-05-21

**What worked**

- Feature flag (`experimentalNativeTerminal`) added to
  `AppearanceStore`, persisted to UserDefaults, defaults `false`.
- Toggle row landed in the `ExperimentalFeaturesSheet` opened from
  Settings → Experimental → Experimental Features.
- `GhosttyTerminalView` exists as a SwiftUI `UIViewRepresentable`
  scaffold with a black-background `UIView` and a hard-coded status
  label ("GhosttyKit not yet integrated — see PLAN-TERMINAL-REWRITE
  Stage 0").
- `ProjectView.tabContent` reads the flag and dispatches to
  `GhosttyTerminalView` when it's on; the xterm.js path runs
  otherwise. Default-off ⇒ no behavior change for current users.
- `scripts/fetch-ghostty-vt-xcframework.sh` documents the canonical
  fetch + checksum step. The sha256 of the `tip` release asset at
  the time of writing is captured in the script.
- Test added asserting flag default + UserDefaults round-trip.

**What's blocked / deferred**

- **The xcframework is NOT actually wired into the Xcode project
  yet.** project.yml expects `framework: …` paths checked into the
  worktree; we don't want to commit a 9MB binary, and we don't have
  an SPM `binaryTarget` URL slot in xcodegen's `packages` block
  (it accepts named SPM packages, not raw binaryTarget URLs).
  Resolving this properly needs one of: (a) a tiny local SPM
  wrapper package (`apps/ios/GhosttyVT/Package.swift`) that hosts
  the binaryTarget; (b) extending `build-rust.sh` to fetch and
  unzip the asset before xcodegen runs. Either is mechanical and
  punted to Stage 1.
- The available release asset is `ghostty-vt.xcframework.zip`, which
  is the slim VT-only build — it does **not** include `Ghostty.Surface`,
  the Metal renderer, or the input/key APIs Ghostty's own iOS shell
  uses. The full `GhosttyKit.xcframework` is not (currently)
  published as a release asset. So even after wiring the binary,
  the SwiftUI view can't instantiate a `Ghostty.Surface` without
  also pulling in upstream Swift wrappers and writing our own
  renderer.
- `iOSApp.swift` from Ghostty's tree uses `GhosttyKit` (the full
  module). The reference implementation we wanted to mirror is not
  reachable from `ghostty-vt` alone.

**What's queued for Stage 1**

- Add `apps/ios/GhosttyVT/Package.swift` exposing the prebuilt
  `ghostty-vt.xcframework` as an SPM `binaryTarget` with a pinned
  URL + checksum; add it to `project.yml` packages.
- Write a thin Swift wrapper (`GhosttyVT.swift`) over the C API
  (`ghostty_terminal_new`, `ghostty_terminal_write`, …).
- Wire `GhosttyTerminalView` to feed PTY bytes into the libghostty
  terminal and call `ghostty_terminal_serialize` for snapshot output,
  routing the resulting ANSI back into the existing xterm.js
  renderer (Stage 1 of the staging plan).
- Decide between (a) waiting for upstream to ship a full
  `GhosttyKit.xcframework` release asset, or (b) standing up our
  own CI job that runs `zig build -Demit-xcframework` against a
  pinned Ghostty commit, before tackling Stage 2 (native render).

## Stage 1 status — 2026-05-22

**What shipped**

- `apps/ios/GhosttyVT/Package.swift` — local SPM wrapper package
  hosting a `binaryTarget` against the pinned
  `ghostty-vt.xcframework.zip` release asset (URL + sha256 mirror
  `scripts/fetch-ghostty-vt-xcframework.sh`).
- `apps/ios/GhosttyVT/Sources/GhosttyVT/Terminal.swift` — Swift
  wrapper over the libghostty-vt C ABI: `Terminal` reference type
  with `init(cols:rows:)` → `ghostty_terminal_new`, `deinit` →
  `ghostty_terminal_free`, `write(_:)` → `ghostty_terminal_vt_write`,
  `resize(cols:rows:…)` → `ghostty_terminal_resize`, and a pure-Swift
  `TerminalSnapshot` materialized via `ghostty_terminal_grid_ref` +
  `ghostty_grid_ref_graphemes`. The whole file is gated by
  `#if canImport(GhosttyVt)` (the upstream module name baked into
  the modulemap, lowercase `t`) so the iOS app keeps compiling when
  SPM fails to resolve the binary asset.
- `apps/ios/GhosttyVT/Tests/GhosttyVTTests/TerminalTests.swift` —
  smoke test: init 80×24, write `"hello\n"`, snapshot contains
  `"hello"`, cursor moved to row 1 col 0. Gated by `#if canImport`
  so the bundle stays green if the framework didn't link.
- `apps/ios/project.yml` — `GhosttyVT` registered under `packages:`
  via `path: GhosttyVT` and consumed as a `package:` dep by the
  `SweKitty` target. Existing packages (Sentry, HighlightSwift,
  SnapshotTesting) untouched.
- `apps/ios/Sources/Views/GhosttyTerminalView.swift` — when
  `#if canImport(GhosttyVT)` is true, the placeholder view
  instantiates `GhosttyVT.Terminal(cols: 80, rows: 24)` and feeds it
  a single line of bytes so the SPM binary target is exercised at
  runtime, not just at link time. The status label still reads
  "GhosttyVT linked — see PLAN-TERMINAL-REWRITE Stage 1" and there
  is no rendering or input wiring yet.

**Risk mitigation actually used**

The xcframework asset host (`tip` tag on ghostty-org/ghostty) is
rotated on every nightly cut, so the pinned sha256 in Package.swift
and `fetch-ghostty-vt-xcframework.sh` is a moving target. Every
libghostty-touching site is wrapped in `#if canImport(GhosttyVt)`
(and `#if canImport(GhosttyVT)` for the app-side import), so a
stale-checksum SPM failure degrades to the Stage 0 placeholder
without breaking the iOS build. Both code paths exercise this guard
so flipping the flag at runtime stays a one-toggle revert.

**Deferred to Stage 2**

- Wire PTY bytes from `SessionStore.terminalBuffer[session.id]`
  through `Terminal.write(_:)`. Stage 1 only proves the framework
  loads; the byte path is still xterm.js end-to-end.
- Replace the placeholder `UILabel` with a real grid renderer —
  either `CAMetalLayer` (per the §E decision table) or, as a
  Stage 1.5 interim, route `ghostty_formatter_terminal_to_*` ANSI
  back into the existing xterm.js renderer so we can validate the
  VT half independent of pixel work.
- Hook keyboard input through `ghostty_key_encoder_*` and the
  inputAccessoryView slot. Stage 1 still drops keystrokes on the
  floor.
- Swap the cell-by-cell `ghostty_terminal_grid_ref` snapshot path
  for the render-state iterator API (`GhosttyRenderState`) once the
  renderer needs framerate-grade reads. The header explicitly warns
  the grid-ref path is not built for that, which is fine for Stage 1
  tests but not Stage 2 rendering.
- Decide between (a) waiting for upstream to ship a wider
  `GhosttyKit.xcframework` (with `Surface` / renderer / input APIs)
  as a release asset, or (b) standing up our own `zig build
  -Demit-xcframework` CI job against a pinned Ghostty commit. Same
  decision queued at the end of Stage 0 — Stage 2 must pick.

### Stage 2 acceptance criteria

- `experimentalNativeTerminal` flag on with a real session attached
  renders agent output in the native view (no xterm.js loaded),
  end-to-end through `Terminal.write(_:)`.
- Hardware + soft keyboard reach the PTY via the native input path;
  Ctrl / Esc / arrows all behave the same as the xterm.js view.
- Selection, copy, link-tap, and TalkBack work without a JS bridge.
- Reflow on rotate / IME show / split-screen survives — cursor and
  scrollback intact.
- Performance: `cat large.log`, `htop`, `tail -f` all hit 60 fps on
  a current-iPhone Pro and stay above 30 fps on a 5-year-old device.
- xterm.js path still compiles and reachable when the flag is off
  (§E "xterm.js path — Stays compiled and reachable").

## Stage 2 status — 2026-05-22

**What shipped**

- `apps/ios/GhosttyVT/Package.swift` re-adds the `.binaryTarget`
  entry (PR #73 had removed it because the sha256 didn't resolve).
  Pinned URL is `https://github.com/ghostty-org/ghostty/releases/download/tip/ghostty-vt.xcframework.zip`;
  sha256 captured against the live `tip` asset on 2026-05-22:
  `0c29329a2e1012d8a6ebf05f164c589aeeaba5d417dd93e075c073ad3fa44ba7`.
  `scripts/fetch-ghostty-vt-xcframework.sh` mirrors the same pair.
- `apps/ios/Sources/Views/GhosttyTerminalView.swift` replaces the
  Stage 1 placeholder body with `GhosttyRenderView`: a `UIView`
  subclass that conforms to `UIKeyInput`, hosts `TerminalAccessoryBar`
  via `inputAccessoryView`, and renders the grid through CoreText
  into the view's own `draw(_:)` rect. The flag-on branch in
  `ProjectView.tabContent` now wires `SessionStore.terminalBuffer`
  → `Terminal.write(_:)` and routes keystrokes back through
  `SessionStore.sendInput(...)`. xterm.js is **not** loaded on this
  code path — `WKWebView` only spins up on the flag-off branch.
- `apps/ios/GhosttyVT/Tests/GhosttyVTTests/TerminalRenderTests.swift`
  exercises the render-path snapshot contract: multi-row write +
  cursor advance, resize survives existing content, ANSI CUP escape
  positions the cursor at the addressed cell. Same
  `#if canImport(GhosttyVt)` guard as `TerminalTests` so a
  stale-checksum bundle stays green.
- The flag default stays `false`. Both code paths reachable —
  toggling the experimental flag is the one-line revert.

**Architectural pivot: renderer is CoreText, not Metal**

The §E decision table called for `CAMetalLayer` driven by a Swift
rendering shim. The risk log already flagged that
`ghostty-vt.xcframework` ships only the parser/state half of
libghostty — `vt/render.h` exposes incremental dirty-state
metadata but no Metal/GL/CALayer surface. Building a Metal glyph
pipeline from scratch for the Stage 2 acceptance criterion ("renders
agent output end-to-end through Terminal.write(_:), no xterm.js
loaded") is out of scope for this PR. Stage 2 therefore lands a
CoreText-into-CALayer renderer driven by per-frame
`terminal.snapshot()` reads; Stage 3 can swap the inner renderer to
Metal (with a `vt/render.h` iterator and dirty-row tracking) without
changing the call-site shape.

**Deferred to Stage 3+**

- **Selection / copy / paste.** `vt/selection.h` is in the
  xcframework but the Swift wrapper does not bridge it yet; tap-and-
  hold falls back to the system default (i.e. nothing). Stage 2
  acceptance for "selection works without a JS bridge" is **not
  met** by this PR; tracked as the first Stage 3 task.
- **SGR colors / styles in the renderer.** The VT half parses
  styles correctly (and the C ABI exposes them via the cell API),
  but the renderer paints every cell with the default foreground.
  Wide / combining / emoji clusters draw per-cell — double-width
  cells aren't sized at 2× width.
- **TalkBack / a11y.** The native view has no `UIAccessibility`
  rotor support yet; xterm.js had no per-row a11y either, so this
  is parity-with-xterm-js, not a regression, but it's still a
  Stage 3 task.
- **Render-state dirty tracking.** Current path re-snapshots every
  frame the buffer grows. Acceptable for chat-shaped TUIs; needs
  the `vt/render.h` iterator + per-row dirty flags to hit the
  "60 fps on `cat large.log`" performance bar.
- **Font / palette config from `AppearanceStore`.** Hardcoded
  monospace at 13pt + black/white. Stage 3 reads the user's
  appearance prefs.

**Risk mitigation actually used**

- The `tip` asset rotates on every upstream nightly cut, so the
  sha256 pinned here will go stale. When SPM resolve fails with a
  checksum mismatch, the iOS app keeps building because
  `Terminal.swift`, `GhosttyTerminalView.swift`, and the test
  bundle all stay `#if canImport(GhosttyVt)`-gated. The flag-off
  xterm.js path is unaffected.
- The `draw(_:)` path has a fallback status line that surfaces when
  `cachedSnapshot` is nil (framework unavailable or first-frame
  race), so a degraded build shows a readable message instead of
  a black void.

## Android pick — Termux `terminal-view`

iOS commits to libghostty. Android needs its own pick — the same
"native, high quality, not a WebView" bar, but constrained by the
Android-side reality: **Ghostty has no Android renderer.** The
remainder of this section evaluates four candidates and commits to
**Termux's `terminal-view`** (Apache-2.0, Maven-published, View-based
Canvas renderer, used by Termux daily).

### Per-candidate verdict table

| Candidate | License | Maintenance | Renderer | Reflow | Integration shape | Verdict |
| --------- | ------- | ----------- | -------- | ------ | ----------------- | ------- |
| **libghostty on Android (NDK)** | MIT (lib-vt) + ours for renderer | Upstream Android support is research-only — open Discussion #10902, no merged PR; Zig bionic libc + 16 KB page-size blockers still unresolved | None — only the VT parser (`lib-vt`) is portable. Metal renderer is Apple-only; the GTK build's "OpenGL" path is GTK-coupled and not exposed via `libghostty` | Engine-side, but we'd have to write the renderer ourselves | Zig + NDK cross-compile → `.so` → JNI → Compose Canvas (per the unpublished `tapthaker/ghostty-android` research project, README "Status: Early development - not yet usable") | **Rejected for v1.** Months of upstream work + a renderer we'd own end-to-end. Revisit in v2 if upstream lands Android. |
| **Termux `terminal-view`** | Apache-2.0 (the `terminal-view` and `terminal-emulator` modules are exempted from the parent app's GPLv3) | Active — commits to `terminal-view/` on Jan 4/7/11 2026; v0.118.3 released May 22 2025; daily-driver for Termux on Play Store / F-Droid | `android.view.View` subclass with `Canvas`-based `onDraw` (TerminalView.java line ~30: `public final class TerminalView extends View`); hardware-accelerated by the standard Android view pipeline | Mature — `TerminalEmulator` owns the grid; `onSizeChanged` → `updateSize` (TerminalView.java ~line 1178) reflows on rotation / keyboard | Maven artifact `com.termux:terminal-view:0.118.x` + transitively `com.termux:terminal-emulator`; available via Maven Central or JitPack (`com.github.termux:termux-app:<tag>` as a multi-module). Wrap in Compose via `AndroidView { TerminalView(ctx) }` | **PICK.** Best ratio of native-quality to integration cost on Android. |
| JackPal `Android-Terminal-Emulator` | Apache-2.0 | **Archived 2022-01-14** — "Terminal Emulator for Android development has ended. I am not accepting pull requests any more." | View-based, Canvas | OK | Source-copy only (no Maven artifact) | **Rejected.** Abandonware. Termux is a strict superset of this codebase's lineage. |
| Compose Canvas + Rust VT (via UniFFI) | Ours + Apache-2.0/MIT (e.g. `alacritty_terminal`, `vte`) | Both Rust crates are well-maintained; we'd own the renderer | Compose `Canvas` (Skia) | `alacritty_terminal` explicitly does **not** reflow on resize; `vte` is parser-only | UniFFI bindings into `core/`; Compose render shim | **Rejected for v1.** Architecturally consistent with `core/`, but the missing reflow + a renderer we'd own outweighs the consistency win. Reconsider if we ever ship a desktop client and want one engine across all three. |

### The pick — Termux `terminal-view`

Termux gives us, today, almost everything libghostty gives iOS:

- Native View subclass (no WebView), hardware-accelerated Canvas,
  glyph rendering that's tuned for phone DPI;
- Grid-correct reflow on `onSizeChanged` — covers rotation, IME show,
  split-screen;
- Full IME integration via `onCreateInputConnection` (~line 560);
- Native `TextSelectionCursorController` with drag handles, action
  mode (Copy / Share / Translate), and floating toolbar;
- TalkBack via `setContentDescription(getText())` on each screen
  update (~line 1035) — accessible-by-default, even if we want to
  layer richer per-row a11y nodes on top;
- Mature hardware-keyboard + soft-keyboard handling (Termux daily-
  drives Bluetooth keyboards on tablets);
- A real VT parser with years of conformance work behind it.

What we'd still owe: a thin Kotlin wrapper that drives
`TerminalSession` from our broker byte stream (analogous to the
existing `TerminalBridge` over xterm.js), a theme bridge from our
copper / Anthropic palettes into `TerminalView.setTextSize` /
`TerminalEmulator` palette, and a Compose `inputAccessoryView`-shaped
accessory bar (we keep `InSessionBottomBar.kt`-style controls).

### Defense against the other three

**vs. libghostty on Android.** The blocker is structural, not effort
budget. Upstream Discussion #10902 ("ci: Add `lib-vt` Android
support") is open with the maintainer (mitchellh) saying "I support
this. I don't want to create a tracking issue since there are
obviously some upstream issues here but if you have workarounds for
them AND you can get a CI build for them going, then I'll 100% accept
it." Two known blockers: (1) Zig lacks Android bionic libc support,
producing `.so` files without `DT_NEEDED libc.so` (runtime
`__tls_get_addr` failures); (2) Android 15+ requires 16 KB page
alignment, fix is one line (`lib.link_z_max_page_size = 16384;`) but
not landed upstream. The only known port (`tapthaker/ghostty-android`)
is explicitly "Research & Planning" phase, no releases, demo only.
Even if all of that resolves, **we'd still get only the VT parser** —
the Metal renderer is Apple-only and Ghostty's OpenGL path is GTK-
coupled. We'd be writing a Compose Canvas renderer from scratch. That
is the same renderer-cost as option 4 (Rust VT + Compose), with
strictly more cross-compile pain.

**vs. JackPal's android-terminal-emulator.** Archived. The README's
final word is unambiguous: "I am not accepting pull requests any more."
Termux's terminal stack is the actively-maintained descendant of this
lineage.

**vs. custom Compose + Rust VT via UniFFI.** This is the most
architecturally appealing option — it would unify the VT layer with
`core/`. But: (i) `alacritty_terminal` does not reflow, and `vte` is
parser-only, so we'd be re-implementing the grid/scrollback that
Termux gives us for free; (ii) we'd own the entire glyph pipeline,
including bidi-aware emoji, double-width CJK, and combining marks —
multi-year work to match Termux's current quality; (iii) it does not
fit the "match iOS's spirit" frame — iOS chose to embed a mature
engine (libghostty), not write a renderer. Picking Termux on Android
is the same trade.

**License posture.** Termux's `terminal-view` and `terminal-emulator`
modules are explicitly carved out from the GPLv3 parent app and
released under Apache-2.0 (per the termux-app repo's LICENSE.md:
"Terminal Emulator for Android component uses code released under the
Apache 2.0 license, found in the terminal-view and terminal-emulator
libraries"). Apache-2.0 is fully compatible with our distribution
model — NOTICE-file attribution only, no copyleft contagion.

### Decisions table (additive — extends §E)

| Decision                              | Choice                                                                                          | Rationale |
| ------------------------------------- | ----------------------------------------------------------------------------------------------- | --------- |
| Android emulator + renderer           | Termux `com.termux:terminal-view` + `com.termux:terminal-emulator` (Apache-2.0)                | Mature, Maven-published, native View + Canvas, reflow + selection + IME + TalkBack solved. |
| Distribution                          | Gradle dep on Maven Central (`com.termux:terminal-view:0.118.x`); JitPack as fallback           | No source vendoring; pin a version; bump on Termux releases. |
| Render layer                          | `TerminalView extends View` with `Canvas`-based `onDraw` (hardware-accelerated by the view pipeline) | Matches "native, GPU-accelerated where reasonable" bar; libghostty's Metal path has no Android analog without a renderer rewrite. |
| Compose integration                   | `AndroidView { TerminalView(ctx).apply { … } }` inside the current `WebTerminal.kt` slot         | Drop-in for the WebView; Compose host stays intact. |
| Input pipeline                        | Termux's built-in `onCreateInputConnection` + hardware key handling; our `InSessionBottomBar.kt`-style accessory bar stays | Mature IME + hardware keyboard support; no JS bridge. |
| Feature flag                          | Shared `experimentalNativeTerminal` (iOS UserDefaults / Android DataStore mirror)               | Both platforms toggle together; one rollback story. |
| xterm.js path on Android              | Stays compiled and reachable while the flag is off, for at least one release after the new path ships | Same one-release-fallback discipline as iOS. |
| Wire protocol                         | Unchanged — broker still ships raw bytes; client drives `TerminalSession.write`                  | The byte stream contract is platform-agnostic. |
| Snapshot/restore                      | Feed the broker's PTY ring into a fresh `TerminalSession`; let Termux's emulator reconstruct grid state | Same model as Ghostty's `terminal_serialize` on iOS — re-parse on attach. |

### Android staging (mirrors the iOS Stage 0–5 shape)

Everything is feature-flagged behind the **same**
`experimentalNativeTerminal` flag iOS uses, so the rollout is
one-toggle for both platforms.

#### Stage 0 — feasibility spike (1 day timebox)

- Add `com.termux:terminal-view:0.118.x` to
  `apps/android/app/build.gradle.kts`.
- Add `experimentalNativeTerminal` to the Android `AppearanceStore`
  mirror (DataStore-backed); toggle row in the Experimental Features
  screen.
- Drop a `NativeTerminalView.kt` Compose wrapper that
  `AndroidView`-hosts a `TerminalView` against a hardcoded
  `TerminalSession` running `/system/bin/sh` (or a no-op PTY stub if
  Android-side PTY launching isn't trivial — feed it canned bytes
  instead).
- **Acceptance:** screenshot of a Termux `TerminalView` rendered
  inside swe-kitty's Compose scaffold, behind the flag.

#### Stage 1 — broker byte stream → `TerminalSession`

- Replace the JS bridge in `apps/android/.../ui/WebTerminal.kt` (when
  the flag is on) with a path that pushes broker WS frames into
  `TerminalSession.write(byte[])`.
- Resize: hook `onSizeChanged` → broker `resize` op.
- Output bytes from the local emulator are user-input only; broker
  output is the source of truth.
- **Acceptance:** a fresh session with `claude` agent renders end-to-
  end through `TerminalView`; switching between sessions preserves
  per-session scrollback; flag-off path still works unchanged.

#### Stage 2 — input + selection + accessory bar parity

- Compose accessory bar (`InSessionBottomBar.kt`-derived) sits above
  the `TerminalView`; sticky Ctrl, hold-Alt, arrow nipple, mic — same
  components Android already has.
- Hardware keyboard: Termux already handles `KeyEvent`s natively; we
  only need to pipe modifier state from the accessory bar.
- Selection: native `ActionMode` Copy / Share is on by default;
  optionally extend with "Send to chat" intent.
- Paste routes through `ClipboardManager` + bracketed-paste-aware
  forwarding (Termux's `TerminalSession.pasteText` already does this).
- **Acceptance:** parity matrix vs. the xterm.js path:
  long-press-copy, paste, Ctrl-C, Ctrl-L, Esc, arrows, Tab,
  Bluetooth keyboard all reach the PTY.

#### Stage 3 — theming + TalkBack + reflow polish

- Theme bridge: copper / Anthropic palette → `TerminalView.setTextSize`,
  `TerminalEmulator` color palette setters, glyph color overrides.
- TalkBack: Termux sets `contentDescription` per render tick. Verify
  with TalkBack on a Pixel; if per-row a11y nodes are needed, add a
  `View.AccessibilityDelegate`.
- Reflow regression matrix: rotate device, show/hide IME, split-
  screen, font-size change — verify cursor + scrollback survive.
- Performance benchmark: `cat large.log`, `htop`, `tail -f` —
  target 60 fps on a Pixel 7 / OnePlus 11; 30 fps floor on a Pixel 5a.
- **Acceptance:** demo TalkBack reading the focused row; reflow
  matrix green; perf budget met.

#### Stage 4 — default-on for Android

- Flip `experimentalNativeTerminal` default to `true` on Android
  (independent of iOS Stage 5 timing — both platforms can flip on
  their own cadence).
- Two-week soak via internal Play tester track.
- **Acceptance:** zero terminal-render bug reports during soak; APK
  size delta within budget (Termux libs are ~200 KB).

#### Stage 5 — retire `WebTerminal.kt` + WebView path on Android

- Delete `apps/android/.../ui/WebTerminal.kt`, `TerminalBridge`,
  and the Android xterm.js bundle under `app/src/main/assets/terminal/`.
- Update `docs/PLAN-TERMINAL-XTERMJS.md` to mark Android-superseded.
- Decide on the Node `@xterm/headless` sidecar in
  `broker/internal/termgrid/`: once **both** iOS and Android are
  native, the sidecar has no remaining client. Schedule its removal
  for the next release after both Stage 5s land.

### Per-stage timebox (Android)

| Stage | Estimate | Blocking |
| ----- | -------- | -------- |
| 0 — spike                    | 1 day     | none |
| 1 — byte stream wiring       | 2–3 days  | Stage 0 green |
| 2 — input + selection parity | 3–5 days  | Stage 1 |
| 3 — theme + a11y + perf      | 2–3 days  | Stage 2 |
| 4 — default-on + soak        | 2 weeks (mostly soak) | Stage 3 |
| 5 — WebView cleanup          | 1 day     | Stage 4 |

Total: **~3 weeks elapsed** of engineering + 2 weeks soak. Android is
strictly cheaper than iOS because Termux ships a complete View — no
renderer to write — whereas libghostty on iOS still owes us a
`CAMetalLayer` shim.

### Android risk log

- **Termux release cadence.** v0.118.3 was tagged May 22 2025 and
  `terminal-view/` commits land sporadically (Jan 2026 cluster after
  a 16-month gap). Pinning is fine; if upstream goes quiet we still
  hold a mature library. Mitigation: pin a known-good version; bump
  on a schedule, not on every Termux release.
- **License attribution.** Apache-2.0 requires a NOTICE file. We'll
  add `apps/android/app/src/main/assets/NOTICE` listing the Termux
  modules and link it from the About screen — same place we already
  attribute xterm.js.
- **`terminal-emulator` is a transitive Java dep — not Compose.** We
  host `TerminalView` via `AndroidView`. This is the documented
  Compose-interop path and is used by major apps; no risk, but it
  means the inside of `TerminalView` is not themable with Compose
  Material 3 — color/font config goes through the Java API. Fine,
  because we own the surrounding chrome in Compose.
- **No Android equivalent of libghostty.** If iOS Stage 2 ever needs
  to share a VT engine with Android (e.g. for a Stage F-style
  per-cell wire protocol), the Termux + libghostty split means we
  ship two emulators. The wire protocol stays raw-bytes (§E "Wire
  protocol — Unchanged"), so this cost is bounded to the emulator
  layer only; no architectural contamination.
- **Ghostty Android upstream might land later.** Discussion #10902
  may eventually produce a working `lib-vt` Android port. If so, we
  revisit — but only the VT half; we'd still be writing the renderer.
  Termux remains the right pick for v1 regardless.

### Files touched by Android Stage 0

- `apps/android/app/build.gradle.kts` — add Maven dep.
- `apps/android/app/src/main/kotlin/sh/nikhil/swekitty/AppearanceStore.kt`
  (or equivalent) — `experimentalNativeTerminal` flag mirror.
- `apps/android/app/src/main/kotlin/sh/nikhil/swekitty/ui/NativeTerminalView.kt`
  — Compose wrapper hosting `TerminalView` via `AndroidView`.
- `apps/android/app/src/main/kotlin/sh/nikhil/swekitty/ui/SettingsScreen.kt`
  (or wherever Experimental Features lives) — toggle row.
- `apps/android/app/src/main/assets/NOTICE` — Apache-2.0 attribution
  for `com.termux:terminal-view` + `com.termux:terminal-emulator`.

The xterm.js path (`WebTerminal.kt`, `TerminalBridge`) is **untouched**
and remains the default. Toggling the shared flag off restores the
WebView path within one Compose recomposition — identical rollback
shape to iOS.

## Android Stage 0 status — 2026-05-22

**What worked**

- `experimentalNativeTerminal: StateFlow<Boolean>` added to
  `apps/android/app/src/main/kotlin/sh/nikhil/swekitty/AppearanceStore.kt`,
  persisted to the existing `swekitty.appearance` SharedPreferences
  file under key `experimentalNativeTerminal` (mirrors the
  `swekitty.experimental.nativeTerminal` UserDefaults key on iOS).
  Defaults to `false` so the xterm.js path stays in production.
- Toggle row landed in the existing `Experimental` section of
  `SettingsScreen.kt`, replacing the placeholder text — flask icon,
  subtitle "Stage 0 — see PLAN-TERMINAL-REWRITE".
- `TermuxTerminalView.kt` ships as a Compose `AndroidView` host
  around a plain `TermuxPlaceholderView` (black-background
  `FrameLayout` + centered monospace `TextView` reading "Termux
  Stage 0 mounted — see PLAN-TERMINAL-REWRITE Android section").
  **No Termux dependency is added yet** — `com.termux:terminal-view`
  arrives in Stage 1.
- `ProjectScreen.kt` reads the flag in the `ProjectTab.Terminal`
  branch and dispatches to `TermuxTerminalView` when on, the
  existing `TerminalPage` (xterm.js) when off. Default-off ⇒ zero
  behavior change for current users.
- `AppearanceStoreTermuxFlagTest.kt` (Robolectric / JUnit) asserts
  fresh-install default is off + the value round-trips through a
  fresh `AppearanceStore.hydrate(ctx)`.

**What's stubbed (deferred to Stage 1)**

- Gradle dep on `com.termux:terminal-view:0.118.x` —
  `apps/android/app/build.gradle.kts` untouched at Stage 0; the
  placeholder view is plain androidx, no Maven Central reach.
- `apps/android/app/src/main/assets/NOTICE` Apache-2.0 attribution
  for the Termux modules — added with the dep in Stage 1.
- No `TerminalSession` wiring. The placeholder ignores
  `SessionStore.terminalBuffer[session.id]` and drops keystrokes /
  resize on the floor — same shape iOS Stage 0 used for
  `GhosttyPlaceholderView`.
- No IME / accessory bar wiring. `onTouchEvent` requests focus to
  set up the Stage 2 keyboard summon, but no `InputConnection` is
  produced.

**What's queued for Stage 1**

- Add `com.termux:terminal-view:0.118.x` (+ transitive
  `terminal-emulator`) to `app/build.gradle.kts`; add the NOTICE
  file and link it from the About screen.
- Replace `TermuxPlaceholderView` with a real
  `com.termux.view.TerminalView` instance fed by a
  `TerminalSession` whose stdin is `SessionStore.terminalBuffer`
  bytes from the broker.
- Hook `onSizeChanged` → `store.resize(...)`; wire
  `TerminalSession.write(...)` through to `store.sendInput(...)`.
- Surface the Stage 0 rollback discipline (flag-off path stays
  compiled + reachable) in the Android side of the per-stage
  acceptance matrix in §"Android staging".

## Android Stage 1 status — 2026-05-22

**What worked**

- Gradle deps landed:
  `com.github.termux.termux-app:terminal-view:v0.118.3` +
  `com.github.termux.termux-app:terminal-emulator:v0.118.3`. Resolved
  via a scoped JitPack repo in `apps/android/settings.gradle.kts`
  (`includeGroup("com.github.termux.termux-app")` keeps the JitPack
  exposure tight). Maven Central does **not** publish these
  artifacts — verified by `curl https://repo1.maven.org/maven2/com/termux/terminal-view/`
  → 404 and `https://search.maven.org/solrsearch/select?q=g:com.termux`
  → 0 results. The plan's "Maven Central; JitPack as fallback" wording
  is updated in spirit: JitPack is primary today.
- `TermuxTerminalView.kt` replaces the Stage 0 placeholder body with a
  real `com.termux.view.TerminalView`, configured via a Stage 1
  `TermuxSessionConfig` (shell path = `/system/bin/sh`,
  `TERM=xterm-256color`) and attached to a `TerminalSession` whose
  callbacks are stubbed to `NoopTerminalViewClient` +
  `NoopTerminalSessionClient`. A `view.post { emulator.append(...) }`
  pumps a hardcoded `"Stage 1 mounted via Termux\r\n"` banner once the
  emulator is initialized on the first layout pass — same idiom iOS
  Stage 1 used to prove `GhosttyVT` was linked.
- Risk mitigation: the factory body is wrapped in a `try { ... }
  catch (t: Throwable) { ... }` that falls back to the Stage 0
  `TermuxPlaceholderView` (now copy edited to read "Termux
  unavailable — falling back to placeholder"). Catches `Throwable`
  rather than `Exception` so `NoClassDefFoundError` (the most likely
  symptom of a Maven/JitPack resolution failure at runtime on a
  hardened device) lands on the same fallback path. Logs to
  `Log.w("TermuxTerminalView", ...)` so the catcher can grep
  `adb logcat` to see which path is live.
- `TermuxSessionConfig.from(session)` lifted as a pure-data plumbing
  helper. One JUnit test
  (`apps/android/app/src/test/java/sh/nikhil/swekitty/ui/TermuxSessionConfigTest.kt`)
  locks the Stage 1 defaults (shell path, env, argv shape, purity
  w.r.t. `session.id`). No Robolectric — Termux's emulator hits JNI
  on first `updateSize`, so any test that actually mounts the view
  must run on-device.

**What's stubbed (deferred to Stage 2)**

- PTY byte stream: `SessionStore.terminalBuffer[session.id]` is not
  read; the `AndroidView` `update {}` block is empty. Stage 2 will
  diff the buffer here and forward new bytes via
  `session.emulator.append(...)` (or `session.write(...)` once the
  broker-attached path replaces the local `sh` subprocess), mirroring
  `WebTerminal.kt`'s `lastFedByteCount` pattern.
- `onSizeChanged` → broker resize: Termux's `TerminalView` already
  forwards resize into the emulator on its own; what's missing is the
  fan-out to `SessionStore.resize(...)`. Stage 2.
- Input: `NoopTerminalViewClient` returns `false` from every
  key/codepoint method, so keystrokes drop on the floor — Stage 1
  acceptance is render-only.
- NOTICE attribution: Apache-2.0 requires a NOTICE file for the
  Termux modules and an About-screen link. Punted to Stage 2 so this
  PR can land tight; tracked in the per-stage matrix above.

**Rollback shape**

- Toggling the shared `experimentalNativeTerminal` flag off restores
  the production xterm.js path (`WebTerminal`) within one Compose
  recomposition — unchanged from Stage 0.
- If the Termux dep fails to resolve at runtime, the try/catch falls
  back to `TermuxPlaceholderView` and the app keeps working —
  identical user-visible behavior to Stage 0, just with a different
  status string.
