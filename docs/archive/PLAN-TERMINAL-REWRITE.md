# Terminal renderer rewrite — Ghostty libghostty pick

> **Archived 2026-05-27 — shipped; see [`docs/ROADMAP.md`](../ROADMAP.md).**
> xterm.js is the shipping default terminal; the native Ghostty path is built
> and reachable behind `experimentalNativeTerminal`. The one remaining item —
> on-device verification before Ghostty becomes the default and xterm.js is
> retired — is tracked in `ROADMAP.md` "In progress". Preserved for the staging
> rationale.

## Status

Stage 0 spike (feature-flag scaffold) in progress. Stage 1+ deferred.

## Why rewrite (again)

The xterm.js path (Stage F', `archive/PLAN-TERMINAL-XTERMJS.md`) ships, but it
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
- `apps/ios/Tests/ConduitTests/AppearanceStoreTests.swift` — flag
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
  `Conduit` target. Existing packages (Sentry, HighlightSwift,
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

**Update (conduitcore-framework-rewrap):** PR #88 had to comment out
the GhosttyVT `.binaryTarget` because the ConduitCore xcframework was
built as `-library + -headers` (legacy shape), and Xcode's
`ProcessXCFramework` writes every such xcframework's module map to the
shared `$BUILT_PRODUCTS_DIR/include/module.modulemap` path. With both
ConduitCore and ghostty-vt fighting for that file, xcodebuild emitted
"Multiple commands produce include/module.modulemap" and refused to
link. `apps/ios/build-rust.sh` now produces a `.framework`-flavored
xcframework instead: each arch slice contains a per-arch
`conduit_coreFFI.framework/` with its module map under
`Modules/module.modulemap` (scoped to the framework, no shared path).
The Ghostty `binaryTarget` is therefore re-enabled and libghostty
actually loads at runtime — Stage 2 now meets its core acceptance
criterion ("framework loaded, libghostty parses VT, CoreText paints
real cells"). Status: framework loaded, libghostty parses VT,
CoreText paints real cells. A `--legacy` flag on `build-rust.sh`
emits the old `-library + -headers` shape for A/B if the new shape
regresses something subtle.

**What shipped**

- `apps/ios/GhosttyVT/Package.swift` re-adds the `.binaryTarget`
  entry (PR #73 had removed it because the sha256 didn't resolve;
  PR #88 commented it out again over the modulemap collision above).
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
  inside conduit's Compose scaffold, behind the flag.

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
- Update `docs/archive/PLAN-TERMINAL-XTERMJS.md` to mark Android-superseded.
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
- `apps/android/app/src/main/kotlin/sh/nikhil/conduit/AppearanceStore.kt`
  (or equivalent) — `experimentalNativeTerminal` flag mirror.
- `apps/android/app/src/main/kotlin/sh/nikhil/conduit/ui/NativeTerminalView.kt`
  — Compose wrapper hosting `TerminalView` via `AndroidView`.
- `apps/android/app/src/main/kotlin/sh/nikhil/conduit/ui/SettingsScreen.kt`
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
  `apps/android/app/src/main/kotlin/sh/nikhil/conduit/AppearanceStore.kt`,
  persisted to the existing `conduit.appearance` SharedPreferences
  file under key `experimentalNativeTerminal` (mirrors the
  `conduit.experimental.nativeTerminal` UserDefaults key on iOS).
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
  (`apps/android/app/src/test/java/sh/nikhil/conduit/ui/TermuxSessionConfigTest.kt`)
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

## Android Stage 2 status — 2026-05-22

**What worked**

- `TermuxTerminalView.kt` now routes the broker's live PTY byte
  stream into Termux's `TerminalEmulator`. The Compose
  `AndroidView.update` lambda diffs
  `SessionStore.terminalBuffer[session.id]` against
  `TermuxMount.lastFedByteCount` (mirroring `WebTerminal.kt`'s
  `lastFedByteCount` discipline) and either appends the tail bytes
  via `session.emulator.append(bytes, len)` or — when the buffer
  shrank, signalling a snapshot replay — calls `session.reset()`
  then replays the entire snapshot. A backup `LaunchedEffect` keyed
  on `(sessionId, buffer, emulatorReadyTick)` re-runs the same
  diff once the emulator finishes its first-layout init, so broker
  bytes that arrived **before** the emulator was ready aren't lost.
- User input round-trip:
  - Soft-keyboard / printable code points → `BrokerTerminalViewClient.onCodePoint`
    returns `true` (consuming the event before TerminalView calls
    `mTermSession.writeCodePoint`), folds Ctrl-X into the
    corresponding C0 byte (lifted from `TerminalView.inputCodePoint`),
    UTF-8 encodes, and forwards to `SessionStore.sendInput(sessionId, bytes)`.
  - Hardware special keys (arrows / Enter / Tab / Esc / F-keys /
    Ctrl-X) → `BrokerTerminalViewClient.onKeyDown` runs the same
    `KeyHandler.getCode(keyCode, mod, cursorApp, keypadApp)`
    Termux's TerminalView would have used, and forwards the
    resulting ANSI sequence to the broker. Returning `true`
    consumes the event so TerminalView's internal
    `mTermSession.write(code)` path never runs.
- Resize → `SessionStore.resize`: a `View.OnLayoutChangeListener`
  on the `TerminalView` reads `emulator.mColumns` / `emulator.mRows`
  after each layout pass and forwards to
  `store.resize(sessionId, rows, cols)` whenever they change.
  Termux's own `onSizeChanged → mTermSession.updateSize` runs
  first; we piggyback on the resulting emulator state instead of
  re-deriving it.
- One pure-data JUnit test (`TermuxSessionConfigTest` —
  `computeFeed` cases for grow / equal / shrink / empty-initial)
  locks the Stage 2 reducer. We skip Robolectric for the actual
  mount because `TerminalEmulator.append` is fine on the JVM but
  `TerminalSession`'s `updateSize` calls `JNI.createSubprocess`,
  which needs an on-device runtime.

**Risk mitigation actually used**

- `com.termux.terminal.TerminalSession` is declared `final`, so we
  can't subclass to elide its `JNI.createSubprocess` call. The
  Stage 2 workaround: spawn `/system/bin/sleep 2147483647`
  (`SLEEP_FOREVER`, ~68 years) instead of `/system/bin/sh`. The
  local PTY still exists (it has to — `TerminalView` needs a
  non-null `mEmulator`, which only `TerminalSession.initializeEmulator`
  creates), but it produces no output that could race the broker
  bytes. The user-input side never reaches the local PTY because
  the client hooks consume every keystroke before `mTermSession.write`
  is called.
- Mount failure still falls back to `TermuxPlaceholderView`. The
  factory body wraps in `try { ... } catch (t: Throwable) { ... }`;
  a `NoClassDefFoundError` or a hardened-device JNI failure logs to
  `Log.w("TermuxTerminalView", ...)` and the user sees the Stage 0
  placeholder, not a crash.
- Toggling `experimentalNativeTerminal` off still restores the
  xterm.js path inside one Compose recomposition. The factory is
  bypassed entirely when the flag is off — no Termux classes load.

**Gaps relative to the full Stage 2 acceptance criteria**

The §"Stage 2 acceptance criteria" list in this doc is the iOS
Stage 2 (libghostty + Metal renderer) bar. The **Android** Stage 2
shape (per the §"Android staging" section) is "input + selection
parity"; what landed in this PR covers the byte-stream + input
half. Still queued for a follow-up Android Stage 2.1 / 2.2:

- Local PTY responses (emulator-generated CSI replies, mouse
  reporting, OSC clipboard writes, device-status responses) still
  go to the local `/system/bin/sleep` PTY where they're dropped.
  Most TUIs don't depend on these, but `vim`'s mouse mode and
  `tmux`'s focus-tracking will under-react. Fix path: read the
  emulator's `mSession` output queue via reflection (the field is
  package-private), drain it on a side thread, and forward to the
  broker — or wait for Termux to publish a "headless TerminalSession"
  shape upstream.
- `IME composing` text isn't intercepted yet — Compose users with
  Japanese / Chinese / Korean keyboards will see partial-commit
  artifacts. The path through `onCreateInputConnection` →
  `BaseInputConnection.commitText` lands `setComposingText` calls
  on `TerminalView` directly; we'd need to override the
  `InputConnection` to mirror that into broker writes.
- Selection / copy / link-tap / TalkBack still use Termux's
  built-in handlers. Stage 3 wires the Termux
  `TerminalSessionClient.onCopyTextToClipboard` /
  `onPasteTextFromClipboard` callbacks into `ClipboardManager` so
  the floating action mode's Copy / Paste buttons round-trip through
  the system clipboard and the broker. Selection mode still
  competes with the broker's own bracketed-paste semantics on some
  devices — hasn't bitten yet in dev testing, flagged for the soak.
- The Compose accessory bar (sticky Ctrl, arrow nipple, mic)
  hasn't been wired through `BrokerTerminalViewClient.readControlKey`
  / `readAltKey` / `readShiftKey` yet — those still return `false`.
  Stage 2 only covers direct hardware/soft keyboard input.
- NOTICE attribution for the Termux modules is still queued
  (carried over from Stage 1 deferred list).

**Rollback shape**

- Flag-off path is unchanged: `ProjectScreen` reads
  `experimentalNativeTerminal` and routes to `TerminalPage` (the
  xterm.js `WebTerminal`). The Termux classes never get loaded
  when the flag is off, so a Stage 2 regression is a one-toggle
  revert.
- Within the flag-on path, a runtime mount failure still
  short-circuits to `TermuxPlaceholderView` via the factory's
  `try/catch`. The user sees a placeholder instead of a crash;
  `adb logcat -s TermuxTerminalView` shows the underlying error.

## Stage 3 status — 2026-05-22 (selection + copy + paste)

Closes the Stage 2 deferred item ("Selection / copy / paste —
`vt/selection.h` is in the xcframework but the Swift wrapper does not
bridge it yet"). Ships both platforms in one PR
(`terminal-stage3-selection`).

**iOS — `apps/ios/Sources/Views/GhosttyTerminalView.swift`**

- `GhosttyRenderView` is now a first-responder on tap (single-tap
  hides any selection + summons the soft keyboard); long-press
  anchors a `TerminalSelectionRange` at the tap point's `(row, col)`
  computed from `cellWidth` / `cellHeight`; pan after long-press
  extends `end`; double-tap selects the ASCII-word at the tap cell;
  triple-tap selects the full row.
- `draw(_:)` paints a translucent `ConduitTheme.warning` (yellow at
  0.25 opacity) rectangle under the selected cells **before** the
  glyphs so the text remains readable. The highlight walks the same
  normalized rectangle the text extractor reads — what you see is
  what `copy()` ships.
- `canPerformAction(_:withSender:)` surfaces `.copy(_:)` whenever a
  selection exists and `.paste(_:)` whenever the system clipboard
  has a string. `target(forAction:withSender:)` routes both to the
  view itself so the iOS edit menu (`UIMenuController.shared`) calls
  our overrides. `UIMenuController.showMenu(from:rect:)` is invoked
  on long-press / drag-end so the floating Copy / Paste appears at
  the selection.
- `copy(_:)` derives the substring from `cachedSnapshot` via
  `TerminalSelectionRange.selectedText(from:)` and writes
  `UIPasteboard.general.string`. `paste(_:)` reads the same
  clipboard slot, normalizes `LF` → `CR` (matches
  `insertText`), and forwards UTF-8 bytes through `onInput` →
  `SessionStore.sendInput(...)` — same input path the soft keyboard
  takes, so bracketed-paste semantics are the harness's
  responsibility.

**Android — `apps/android/.../ui/TermuxTerminalView.kt`**

- Termux's `TerminalView` already ships the live selection drag-
  handles + floating action mode (`TextSelectionCursorController`).
  We leave that on; Stage 3 only wires Termux's
  `TerminalSessionClient` clipboard hooks into the OS:
  - `onCopyTextToClipboard(session, text)` → `ClipboardManager.setPrimaryClip`
    with a `ClipData.newPlainText("conduit terminal", text)`
    payload. Fires when the user taps Copy in Termux's action mode.
  - `onPasteTextFromClipboard(session)` → read
    `ClipboardManager.primaryClip` → forward bytes through `onInput`
    (= `SessionStore.sendInput`), so the broker — not the silent
    `/system/bin/sleep` local PTY — receives the paste.
- Both callbacks wrap in `try/catch` and log to
  `TermuxTerminalView` so a hardened-device clipboard service
  failure logs but doesn't crash.

**Both platforms — pure-data extraction**

`TerminalSelectionRange` is the same shape on both platforms:
`(start: (row, col), end: (row, col))` anchors + `normalized()` to
swap drag-backwards anchors + `selectedText(...)` to walk the cell
grid. Inclusive on both ends. Out-of-bounds anchors clamp to the
snapshot bounds. Empty cells render as a single space so the
substring matches the on-screen width.

Tests pin both implementations against the same scenario set:

- `apps/ios/Tests/ConduitTests/TerminalSelectionRangeTests.swift`
  — Swift Testing, 11 cases.
- `apps/android/app/src/test/java/sh/nikhil/conduit/ui/TerminalSelectionRangeTest.kt`
  — JUnit 4, 11 cases mirroring the Swift suite.

**What's deferred**

- The Android `TerminalSelectionRange` is **not** wired into the
  live mount today — Termux's own `TextSelectionCursorController`
  owns the on-screen drag handles. The shape is parked here so a
  future "Send selection to chat" intent or a Compose-side
  selection overlay can reuse it. Today's Android selection UX is
  Termux's default, plus the new clipboard round-trip.
- The iOS edit-menu animation defaults to the legacy
  `UIMenuController` shape rather than `UIEditMenuInteraction` (iOS
  16+). Mechanical swap in a follow-up; the deprecated API still
  works in iOS 26 and matches the test target.
- TalkBack / VoiceOver on selected cells is unchanged from Stage 2
  on both platforms.

## Stage 2 unblock — how others build the xcframework

PRs #86, #89, #92, #93 each surfaced a deeper blocker on the way to
linking libghostty into the iOS Stage 0 spike. PR #94 finally pinned
the cause: upstream's `ghostty-vt.xcframework.zip` release asset (the
one our `scripts/fetch-ghostty-vt-xcframework.sh` points at) ships
**only** an `ios-arm64/` slice — there is no
`ios-arm64_x86_64-simulator/`, so `xcodebuild` linking the iOS
simulator target produces `building for 'iOS-simulator', but linking
in object file built for 'iOS'` and CI is red.

This section captures what the other Ghostty-on-iOS consumers do
about it, picks the right path for conduit, and writes down the
exact command surface so the next agent has zero archaeology to do.

### Survey

#### `eriklangille/clauntty` — closest reference (iOS Ghostty app)

- **No CI.** `https://api.github.com/repos/eriklangille/clauntty/contents/.github/workflows`
  returns 404. There is no release pipeline; everything happens on
  contributor laptops.
- **`Frameworks/GhosttyKit.xcframework` is a git symlink** pointing at
  `../../ghostty/macos/GhosttyKit.xcframework` — i.e. the build
  expects a sibling checkout of the Ghostty fork next to the clauntty
  repo on disk.
- **Build command** (from `README.md` / `CLAUDE.md`):
  ```bash
  cd ghostty && zig build -Demit-xcframework -Doptimize=ReleaseFast
  ln -s ../../ghostty/zig-out/GhosttyKit.xcframework \
      clauntty/Frameworks/GhosttyKit.xcframework
  ```
- They depend on **`libxev` checked out as a sibling** of the
  Ghostty checkout — `../libxev` — because their Ghostty fork
  references it at build time for iOS kqueue fixes.
- Toolchain: Zig 0.15.2+, Xcode 15+, iOS 17+ deployment target.
- **Showstopper this solves:** none — it punts. Clauntty does not
  ship via App Store TestFlight from CI; it's a build-on-your-Mac
  project. That works for one maintainer; it does not work for us
  (we already ship via GitHub Actions release builds — `RELEASE-IOS.md`).

#### `ghostty-org/ghostty` itself — what the upstream build emits

- **`src/build/GhosttyXCFramework.zig`** (verbatim, the slice list):
  ```zig
  // Universal macOS build
  const macos_universal = try GhosttyLib.initMacOSUniversal(b, deps);
  // Native macOS build
  const macos_native = try GhosttyLib.initStatic(b, &try deps.retarget(
      b, Config.genericMacOSTarget(b, null)));
  // iOS
  const ios = try GhosttyLib.initStatic(b, &try deps.retarget(
      b, b.resolveTargetQuery(.{
          .cpu_arch = .aarch64,
          .os_tag = .ios,
          .os_version_min = Config.osVersionMin(.ios),
          .abi = null,
      })));
  // iOS Simulator
  const ios_sim = try GhosttyLib.initStatic(b, &try deps.retarget(
      b, b.resolveTargetQuery(.{
          .cpu_arch = .aarch64,
          .os_tag = .ios,
          .os_version_min = Config.osVersionMin(.ios),
          .abi = .simulator,
          .cpu_model = .{ .explicit =
              &std.Target.aarch64.cpu.apple_a17 },
      })));
  ```
  Built into the xcframework only when `target == .universal`
  (`src/build/xcframework.zig` defines `Target = enum { native,
  universal }`).
- **Default `xcframework_target` is `.native`** for fast local
  iteration. To get the `ios-arm64-simulator` slice you must invoke:
  ```bash
  zig build -Demit-xcframework -Dxcframework-target=universal \
      -Doptimize=ReleaseFast
  ```
  The "tip" workflow builds GhosttyKit only via the macOS scheme; the
  separately-shipped `ghostty-vt.xcframework.zip` we pin uses a
  different build (`build-lib-vt-xcframework` job → `zig build
  -Demit-lib-vt -Doptimize=ReleaseFast`, no target spec) which
  resolves to whatever the host runner is — Apple Silicon macOS — and
  that's why the published asset only carries `ios-arm64/`. The
  `ios-arm64-simulator` slice is not emitted by `-Demit-lib-vt`
  today; it only exists in the GhosttyKit (macOS-app) path.
- Upstream **does not publish a multi-arch GhosttyKit.xcframework
  release asset**. The macOS Ghostty app's `Ghostty.xcodeproj` builds
  the xcframework as a project step on the developer's machine.
- **Showstopper this would solve for us:** none, directly. Upstream
  policy is "consume the source tree, not a binary release," and
  `ghostty-vt.xcframework.zip` is meant for the
  `libghostty-vt`-only headless use case (no Metal renderer, no
  iOS simulator slice promised).
- Source files referenced: `src/build/GhosttyXCFramework.zig`,
  `src/build/GhosttyLibVt.zig`, `src/build/xcframework.zig`,
  `.github/workflows/release-tip.yml`, `macos/Sources/App/iOS/iOSApp.swift`.

#### `Lakr233/libghostty-spm` — the prebuilt multi-arch wrapper

This is the find. Lakr233 publishes a community-maintained
`GhosttyKit.xcframework.zip` as a GitHub release **with every slice
conduit needs**, and ships an SPM package that exposes it as a
binary target.

- **Package.swift** at
  `https://raw.githubusercontent.com/Lakr233/libghostty-spm/main/Package.swift`:
  ```swift
  .binaryTarget(
      name: "libghostty",
      url: "https://github.com/Lakr233/libghostty-spm/releases/download/storage.1.1.5/GhosttyKit.xcframework.zip",
      checksum: "a7045bef1f3149989d79e413b07f2f17847d68348da9f55eb56578093a5af405"
  )
  ```
- **Platforms:** iOS 16+, macOS 13+, macCatalyst 16+.
- **Build matrix (`.github/workflows/build.yml`)** runs on
  `macos-15` with this `strategy.matrix.include`:
  ```yaml
  - target: aarch64-macos              variant: macosx
  - target: x86_64-macos               variant: macosx
  - target: aarch64-ios                variant: iphoneos
  - target: aarch64-ios-simulator      variant: iphonesimulator
    cpu: apple_a17
  - target: x86_64-ios-simulator       variant: iphonesimulator
  - target: aarch64-ios-macabi         variant: maccatalyst
    cpu: apple_a17
  - target: x86_64-ios-macabi          variant: maccatalyst
  ```
  Each leg runs `./Script/build-ghostty.sh <source> <target> <out>`
  which calls:
  ```bash
  zig build -Doptimize=ReleaseFast \
      -Dapp-runtime=none \
      -Demit-exe=false -Demit-xcframework=false \
      -Demit-macos-app=false -Demit-docs=false \
      -Dsentry=false -Dcustom-shaders=false -Dinspector=false \
      -Dtarget="$ZIG_TARGET" \
      ${ZIG_CPU:+-Dcpu=$ZIG_CPU}
  ```
  i.e. it builds the static `libghostty.a` per target, not the
  upstream xcframework step.
- **Stitching** (`Script/merge-xcframework.sh`): per-variant `lipo`
  of arm64+x86_64 archives → per-variant `.framework` bundle →
  `xcodebuild -create-xcframework -framework ... -framework ...
  -output BinaryTarget/GhosttyKit.xcframework`. Final zip via
  `ditto`.
- **Patches** (`Patches/ghostty/`): a small directory of upstream
  patches Lakr233 applies before building. Today it contains
  fixes for the iOS / Mac Catalyst build graph that haven't all
  been upstreamed.
- **Release cadence:** scheduled cron `23 6 * * 1` (weekly Monday)
  plus `workflow_dispatch`, against the latest upstream Ghostty
  semver tag. Latest release at time of writing is `1.1.5`
  (matches Ghostty `1.1.5`).
- **License:** MIT (the spm wrapper); Ghostty itself is MIT.
- **Showstopper this solves:** all of them.
  - Multi-arch xcframework with `ios-arm64-simulator` and
    `ios-x86_64-simulator` → CI iOS-sim linker resolves.
  - Catalyst slice present → free upgrade path for the Mac app target.
  - macOS universal slice present → SwiftUI previews work.
  - Published via SPM `binaryTarget` URL + sha256 → identical
    distribution shape to what `PLAN-TERMINAL-REWRITE.md §E`
    already committed to ("SPM `binaryTarget` URL + checksum from
    a Ghostty GitHub release asset").

#### Other consumers found via `gh search code "GhosttyKit.xcframework" extension:swift`

| Repo | iOS? | xcframework source |
| ---- | ---- | ------------------ |
| `BarutSRB/OmniWM`                    | macOS only | committed binary |
| `muxy-app/muxy`                      | macOS only | committed binary |
| `supabitapp/supacode`                | macOS only | `.build/ghostty/...` (built locally) |
| `iAmCorey/kooky`                     | macOS only | committed `Vendor/` binary |
| `vaayne/mori`                        | macOS only | committed binary |
| `zxcvbnmzsedr/devhaven`              | macOS only | committed `Vendor/` binary |
| `scarce/axel`                        | macOS only | committed binary |
| `misterclayt0n/the-editor`           | macOS only | path-based |
| **`Lakr233/libghostty-spm`**         | **iOS + macOS + Catalyst** | **SPM binary target via release URL** |

Every other consumer either is macOS-only (so they only need the
`macos-arm64_x86_64/` slice that upstream's GhosttyKit step does
emit) or punts to a local build. Lakr233 is the only one solving
the actual iOS-simulator problem, and they're solving it by
running essentially the same recipe we'd have to write ourselves
in CI.

### Why upstream's `tip` asset is arm64-only

Two reasons stacked:

1. The release asset comes from the `build-lib-vt-xcframework`
   job, which runs `zig build -Demit-lib-vt -Doptimize=ReleaseFast`
   with no `-Dtarget=` flag. That builds for the host runner's
   triple (Apple Silicon macOS → `aarch64-ios` via cross-compile),
   not the universal xcframework matrix.
2. `-Demit-lib-vt` invokes a different build graph than
   `-Demit-xcframework`. The lib-vt path produces a slimmer
   headless-VT library (`ghostty-vt` — no Metal, no surface) and
   was never wired to produce the iOS simulator slice; the
   GhosttyKit path is where the universal-mode simulator slice
   lives (see `src/build/GhosttyXCFramework.zig` above).

So even if upstream fixed (1), we'd still be missing Metal/surface
on iOS — exactly the things Stage 1 of our plan needs.

### Options considered for conduit

#### Option A — cross-compile from source in our CI

A new GitHub Actions job (`.github/workflows/ghostty-xcframework.yml`)
that runs on `macos-15`, checks out Ghostty at a pinned commit,
loops `zig build -Dtarget=<...> -Demit-lib-vt=false
-Demit-xcframework=true` for each slice (or runs the same
`-Demit-xcframework -Dxcframework-target=universal` once), then
uploads `GhosttyKit.xcframework.zip` as a release asset on the
**conduit** repo. The xcframework asset URL feeds our existing
`scripts/fetch-ghostty-vt-xcframework.sh` (renamed).

- **Pros:** no third-party dependency; we control the patch surface
  and the rebuild cadence; the recipe is well-trodden (Lakr233's
  workflow is essentially the spec).
- **Cons:** ~20 minutes of CI per build, including a Zig 0.15
  toolchain provision; a non-trivial workflow YAML; we own the
  patches dir if upstream ever needs one for iOS-sim.
- **Sketch (the workflow that would land):** matrix exactly mirrors
  Lakr233's, with the `zig build` invocation pinned to
  `-Demit-xcframework -Dxcframework-target=universal -Doptimize=ReleaseFast`
  on a single leg (since upstream's `GhosttyXCFramework.zig`
  already does the per-slice work internally). Falls back to a
  matrix of individual targets only if the universal path turns
  out broken for `x86_64-ios-simulator` (it does today — see
  Lakr233's matrix includes `x86_64-ios-simulator` but
  `GhosttyXCFramework.zig` does not).

#### Option B — fork Ghostty, run our own release workflow

A `nikhilsh/ghostty` fork with the missing simulator slice wired
into the upstream `release-tip.yml` job; publish to fork releases;
pin conduit against the fork.

- **Pros:** maximum control; upstream-shaped recipe.
- **Cons:** we now own a Ghostty fork. Rebasing against upstream is
  weekly toil for the lifetime of the project; we've already
  resolved not to vendor a fork unless forced (xterm.js path
  precedent in `archive/PLAN-TERMINAL-XTERMJS.md`).

#### Option C — contribute upstream

Open a PR to `ghostty-org/ghostty` adding `ios-arm64-simulator` (and
ideally `x86_64-ios-simulator`) to the `release-tip.yml`
`build-lib-vt-xcframework` job's emit graph.

- **Pros:** the right place to fix it; everyone benefits.
- **Cons:** review/merge timing is not under our control;
  `mitchellh` may reasonably defer this given the lib-vt path was
  designed as headless. Stage 0 is blocked **now**.

#### Option D — vendor Ghostty as a git subtree

Add Ghostty source to conduit as a subtree under
`vendor/ghostty/`, call `zig build -Demit-xcframework
-Dxcframework-target=universal` from `scripts/build-rust.sh` (or
a new `scripts/build-ghostty.sh`) as part of the iOS build.

- **Pros:** completely self-contained; no network dep at build
  time; matches how some of the other consumers do it.
- **Cons:** Ghostty + libxev + dependencies adds ~80MB to the
  repo; subtree pulls are clunky; the iOS build now requires Zig
  0.15+ on every CI runner and every contributor's Mac. We
  already keep `RELEASE-IOS.md` lean and this would break that.

### Pick — **Option E: pin against Lakr233's prebuilt GhosttyKit.xcframework**

(*A combination of "use someone else's working build" + Option A as the
contingency.*)

1. Rewrite `apps/ios/GhosttyVT/Package.swift` (or its eventual
   landing spot — Stage 0 still has it commented out) to point at
   `https://github.com/Lakr233/libghostty-spm/releases/download/storage.<X.Y.Z>/GhosttyKit.xcframework.zip`
   instead of `https://github.com/ghostty-org/ghostty/releases/download/tip/ghostty-vt.xcframework.zip`.
2. Update `scripts/fetch-ghostty-vt-xcframework.sh` (rename to
   `fetch-ghostty-kit-xcframework.sh`) to fetch the same URL +
   sha256.
3. Pin to the exact tag (`storage.1.1.5` at time of writing — Lakr233
   ships `storage.<version>` tags as immutable releases, separate
   from the floating Swift package version tag). Bump on a
   schedule, not a treadmill.
4. **Contingency: keep Option A ready.** If Lakr233 stops
   publishing, drop in the workflow YAML described in Option A
   above. The matrix and stitching script are already validated
   by their pipeline; we'd be copying a known-working recipe.

**Why E over A:**

- Stage 0 unblocks **today**, not in a week. Zero new CI to
  write; the SPM URL+checksum dance is identical to what §E of
  this plan already committed to.
- The xcframework Lakr233 publishes contains exactly the slices
  we need: `ios-arm64`, `ios-arm64_x86_64-simulator`,
  `macos-arm64_x86_64`, plus Catalyst (free future-proofing if we
  ever ship a Mac Catalyst build).
- Lakr233's pipeline tracks upstream Ghostty semver tags
  automatically (weekly cron + `workflow_dispatch`). We get
  upstream bumps for free, on the same cadence we'd be willing
  to bump anyway.
- If Lakr233 disappears (single maintainer; same shape of risk
  as `eriklangille/clauntty`), our fallback is Option A — well
  scoped, ~half a day of agent work, and we have the recipe
  in this doc.

**Why not A as primary:**

- A is strictly more work today and not strictly safer (any
  fork/upstream-tracking project is one-maintainer-deep until
  proven otherwise). Pin first, build later if forced.

**Why not B/C/D:** explained above; all of them are either heavier
than E or have unbounded timing risk.

### What the next agent does

Concretely, Stage 0.5 (a new substage before Stage 1):

1. `scripts/fetch-ghostty-vt-xcframework.sh` →
   `scripts/fetch-ghostty-kit-xcframework.sh`. Change
   `ASSET_URL` to
   `https://github.com/Lakr233/libghostty-spm/releases/download/storage.1.1.5/GhosttyKit.xcframework.zip`.
   Pin the new `EXPECTED_SHA256` (the package's binaryTarget
   checksum is the same sha256 — `a7045bef1f3149989d79e413b07f2f17847d68348da9f55eb56578093a5af405`).
2. Re-enable the SPM binary target in
   `apps/ios/GhosttyVT/Package.swift` against the new URL +
   checksum.
3. Smoke-run the iOS simulator build locally; CI on the next
   push should be green.
4. Roll the conduit release notes to mention we now pin
   `libghostty-spm storage.1.1.5` (downstream of Ghostty 1.1.5).
5. If anything in Lakr233's xcframework is missing for Stage 1
   (e.g. a header we need but they patched out), drop to
   Option A and write the workflow YAML — recipe is documented
   above.

## Stage 2 status — Lakr233 pin (live) — 2026-05-22

**What shipped (`ghostty-pin-lakr233`)**

- `apps/ios/GhosttyVT/Package.swift` now declares
  `.binaryTarget(name: "libghostty", url:
  "https://github.com/Lakr233/libghostty-spm/releases/download/storage.1.1.5/GhosttyKit.xcframework.zip",
  checksum: "a7045bef1f3149989d79e413b07f2f17847d68348da9f55eb56578093a5af405")`.
  The `GhosttyVT` Swift target depends on `libghostty`, so SPM
  resolution exercises the link path on every build; a stale checksum
  surfaces immediately at SPM-resolve time instead of as a runtime
  no-op. Slices verified by extracting the asset's `Info.plist`:
  `ios-arm64`, `ios-arm64_x86_64-simulator`,
  `ios-arm64_x86_64-maccatalyst`, `macos-arm64_x86_64`. This was the
  exact set PR #94 lost when upstream's `tip` arm64-only asset
  refused to link against the iOS simulator target.
- `scripts/fetch-ghostty-vt-xcframework.sh` renamed to
  `scripts/fetch-ghostty-kit-xcframework.sh` with the same URL +
  sha256 pin. Asset filename in the script is now
  `GhosttyKit.xcframework.zip` (matches Lakr233's release naming);
  output xcframework dir is `apps/ios/GhosttyVT/GhosttyKit.xcframework`.
- `apps/ios/project.yml` `packages: GhosttyVT` comment updated to
  point at the new pin + new fetch-script filename + new module
  name. `dependencies: GhosttyVT` line is unchanged — the iOS app
  target still imports the same SPM product, and the project regen
  story is identical.
- `docs/PLAN-TERMINAL-REWRITE.md` adds this Stage 2 status section.

**Sha256 source.** Two paths cross-verified to the same digest before
landing:

1. Lakr233's published `Package.swift`
   (`https://raw.githubusercontent.com/Lakr233/libghostty-spm/main/Package.swift`)
   `.binaryTarget` `checksum:` field for the `libghostty` target.
2. Live re-compute against the release asset:
   `curl -fsSL "$ASSET_URL" | shasum -a 256` (2026-05-22).

Both produced
`a7045bef1f3149989d79e413b07f2f17847d68348da9f55eb56578093a5af405`.

**API-surface gap — intentional, this PR's tight scope.**

Lakr233's xcframework exposes the full Ghostty C surface (the macOS
app's `App` / `Surface` / `Inspector` API; umbrella header
`ghostty.h` at ~1200 lines). The slim VT-only surface our existing
`apps/ios/GhosttyVT/Sources/GhosttyVT/Terminal.swift` wrapper drives
— `ghostty_terminal_new`, `ghostty_terminal_vt_write`,
`ghostty_terminal_grid_ref`, `GhosttyTerminalOptions`,
`GhosttyPoint`, `GhosttyGridRef`, `GhosttyCell`, the
`GHOSTTY_TERMINAL_DATA_*` enums, the `ghostty_grid_ref_graphemes`
readback — does not exist in this xcframework. Calling any of those
from Swift would fail to compile.

This is the documented PR #96 risk-mitigation case: the wrapper
rewrite to the App/Surface API is a Stage 3-shaped follow-up (event
loop + runtime config + host window), not a "swap the pin" PR. To
keep the iOS build healthy today, the canImport guards stay as-is:

- `Terminal.swift` keeps `#if canImport(GhosttyVt)`. The new pin's
  module is `libghostty` (per its modulemap:
  `framework module libghostty { umbrella header "ghostty.h" }`),
  so the guard evaluates `false` and the file compiles down to its
  trap-on-init placeholder branch. `Terminal.isAvailable` reports
  `false`.
- `GhosttyTerminalView.swift` keeps `#if canImport(GhosttyVT)` and
  every libghostty-touching site stays `#if canImport(GhosttyVt)`-
  gated below that. Same outcome — placeholder draws + status-line
  fallback in `draw(_:)`.
- `GhosttyVTTests` (both `TerminalTests` and `TerminalRenderTests`)
  fall into their `#else` branches and assert
  `XCTAssertFalse(Terminal.isAvailable)` — bundle stays green.

The flag-off path (`WKTerminalView` / xterm.js) is untouched. The
flag-on path falls back to the Stage 0-shape "framework unavailable"
status line, same fallback Stage 1+ already used for stale-checksum
recoveries. Net: zero behaviour change in production; the binaryTarget
is wired + resolves + the iOS-simulator linker is happy; ground
prepared for the wrapper rewrite.

**Bump cadence.** Lakr233's pipeline runs a weekly Monday cron
(`23 6 * * 1`) plus `workflow_dispatch`, against the latest upstream
Ghostty semver tag. We pin per upstream semver tag, not per Lakr233
cut — the `storage.<version>` tags are immutable so a tag-pinned URL
stays valid forever; bumping is mechanical (new URL + new sha256,
both source-able from Lakr233's `Package.swift` on GitHub).

**Contingency unchanged.** If Lakr233 ever stops publishing, drop in
Option A from §"Stage 2 unblock — how others build the xcframework"
— our own GitHub Actions job running essentially Lakr233's
`Script/build-ghostty.sh` matrix. The full recipe (build flags, `lipo`
+ `xcodebuild -create-xcframework` stitching) is captured in PR #96's
research section.

**Deferred (queued for the wrapper rewrite PR)**

- Bridge `Terminal.swift` from the slim VT API to the App/Surface
  API. Steps: build a `ghostty_runtime_config_s` (host
  runtime callbacks) and `ghostty_surface_config_s` from
  `AppearanceStore` defaults; wire `ghostty_surface_write_buffer`
  for byte-feed, `ghostty_surface_text` / `ghostty_surface_key`
  for input, `ghostty_surface_read_text` + `ghostty_surface_size`
  for snapshot readback. Drop the `ghostty_terminal_grid_ref`
  per-cell path (the App/Surface model doesn't expose a public
  grid-ref equivalent — the renderer is supposed to consume Ghostty's
  Metal output instead).
- Decide whether to keep CoreText rendering (paint from
  `ghostty_surface_read_text` snapshots) or pivot to Ghostty's own
  Metal renderer (`ghostty_surface_draw` against a host
  `CAMetalLayer`). The latter unlocks SGR colors / styles / wide
  cells "for free" (Stage 3 deferred list) but adds a Metal host
  view setup. Decision lives in the wrapper-rewrite PR's plan
  section.
- Bump the xcframework when upstream Ghostty cuts a new semver tag
  AND Lakr233's cron picks it up — purely mechanical, no code
  changes expected (the API surface is stable across Ghostty
  patch releases per upstream's MAJOR.MINOR ABI policy).

## Stage 4 — App/Surface live (2026-05-22, ghostty-bridge-app-surface-v3)

**Goal.** Prove libghostty actually loads at runtime by bridging
Swift to the App/Surface C ABI Lakr233's pin exposes. Pre-Stage 4
the wrapper's `canImport(GhosttyVt)` gate always evaluated `false`
(the real module name on the xcframework's umbrella modulemap is
`libghostty`, not `GhosttyVt`), so `Terminal.isAvailable` reported
`false`, no surface was ever created, and the experimental
terminal flag's CoreText renderer painted an empty grid because
the byte feed went through a stub that dropped everything on the
floor. Result on a user's device: tab open with the flag on
→ black rectangle, no agent output.

**What shipped.**

- `apps/ios/GhosttyVT/Sources/GhosttyVT/Terminal.swift` rewritten
  against the App/Surface ABI. New public types:
  - `GhosttyApp` — process-wide singleton over `ghostty_app_t`.
    Lazy-inits inside `static let shared`. Calls `ghostty_init`,
    `ghostty_config_new` → `ghostty_config_load_default_files` →
    `ghostty_config_finalize`, then `ghostty_app_new` with a stub
    `ghostty_runtime_config_s` (all callbacks are no-ops — the
    host-managed I/O backend means libghostty never wakes itself
    or asks for the clipboard). Reports `isAlive: Bool` +
    `lastInitError: String?` + `debugDescription` (hex address
    of the C handle) for the iOS status overlay.
  - `GhosttySurface` — RAII wrapper over `ghostty_surface_t`. Built
    on `GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED` so libghostty
    never spawns a child process; bytes arrive via `feed(_:)` →
    `ghostty_surface_write_buffer` from the harness's PTY stream.
    Holds a strong ref to the host UIView so the
    `ghostty_platform_ios_s.uiview` slot stays valid until
    Stage 5 attaches the Metal renderer.
  - `Terminal` (legacy façade) — same public Swift shape as
    Stage 1 so `GhosttyTerminalView.swift`'s CoreText renderer
    compiles unchanged. Now forwards `write(_:)` through to
    `GhosttySurface.feed(_:)` and surfaces
    `Terminal.statusDescription()` for the empty-grid overlay.
- Gate flipped from `canImport(GhosttyVt)` (broken; lowercase `Vt`,
  never matched any module) to `canImport(libghostty)` (matches
  the umbrella modulemap exactly). Comments in
  `apps/ios/GhosttyVT/Package.swift` + `apps/ios/project.yml`
  updated to record the new state.
- `GhosttyTerminalView.swift`'s `drawStatus(in:)` now reads
  `Terminal.statusDescription()` so the empty-grid banner shows
  "libghostty alive — GhosttyApp(0x…)" when the boot succeeded,
  or "libghostty init failed: …" if `ghostty_app_new` returned
  nil. The configure path also calls
  `Terminal.attach(hostView: self, …)` so the UIView pointer
  reaches libghostty's iOS platform slot — Stage 5 reads that
  slot to target the layer for Metal output.
- Tests in `GhosttyVTTests` rewritten against the new shape: the
  Stage 1 per-cell snapshot assertions (`row 0 starts with
  'alpha'`) are gone — the App/Surface ABI doesn't expose a
  per-cell readback — and replaced with smoke checks
  (`Terminal.isAvailable == true`, `write` does not trap,
  snapshot shape matches the cached cols/rows). Both files gate
  on `canImport(libghostty)` so the bundle still stays green if
  the binary target ever fails to resolve.

**What's deferred to Stage 5.**

- The pixel pipeline. The CoreText renderer still owns the visible
  glyph grid; libghostty's Metal renderer is wired up to a
  `CAMetalLayer` but `ghostty_surface_draw` is not yet called per
  frame because we haven't decided where the draw cadence lives
  (`CADisplayLink` vs `setNeedsDisplay` rate-limited). Stage 5
  swaps `GhosttyTerminalView.swift`'s `draw(_:)` for a
  `CAMetalLayer`-backed view that calls `ghostty_surface_draw` and
  deletes the CoreText draw path + the `TerminalSnapshot` data
  type entirely.
- Selection / copy. The App/Surface ABI exposes
  `ghostty_surface_has_selection` + `ghostty_surface_read_selection`;
  the gesture handlers in the renderer keep their CoreText-side
  snapshot reads until Stage 5 cuts over.
- Hardware keyboard wiring through `ghostty_surface_key`. The
  existing `UIKeyInput` + `keyCommands` path still posts bytes
  directly to the harness; we'll move it through libghostty's
  keymap so app-defined keybinds + IME work the way the macOS app
  does.
- Process-exit handling via `ghostty_surface_process_exited` —
  irrelevant for the host-managed backend (the harness owns
  session lifetime) but the integration point is worth noting.

**Why the renderer stayed CoreText.** Building a full
`CAMetalLayer` + `CADisplayLink` + content-scale + occlusion-state
handshake on top of libghostty's Metal output blows past the
3-hour timebox the Stage 4 PR was scoped to. The risk-mitigation
posture from the original brief — "ship a skeleton: GhosttyApp.init
calls ghostty_app_new and verifies non-nil, GhosttySurface is a
black UIView with a label 'libghostty alive'. User confirms
'ghostty loads' even if not rendering" — was the explicit fallback
target if the full pipeline didn't fit. We hit that fallback: the
App/Surface handshake is live, bytes flow through, the status
overlay reads "libghostty alive — GhosttyApp(0x…)", and the
CoreText renderer keeps painting so the user sees agent output.
Stage 5 will replace the visible pixels with libghostty's own
Metal output now that the surface lifecycle is proven.

**Risk: still false-true.** A successful `ghostty_app_new` does
NOT prove libghostty's internal state machine accepts our byte
feeds — until Stage 5 lands the Metal renderer, the only
observable signal is the runtime status string. If
`ghostty_surface_write_buffer` silently drops bytes (e.g. because
the surface backend rejects host-managed mode on iOS), we won't
notice from the CoreText overlay. The first Stage 5 milestone is
"first frame of Metal output appears" — which doubles as the
existence proof that the byte feed was actually parsed.
