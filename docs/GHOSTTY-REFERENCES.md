# Ghostty / libghostty reference projects

Reference material for Conduit's native iOS terminal, which is built on **libghostty**
(Mitchell Hashimoto's Ghostty terminal emulator, exposed via a C ABI). Collected while
researching a ground-up rebuild of our iOS terminal (see
`docs/archive/PLAN-TERMINAL-REWRITE.md` for the original staged plan, and the rebuild plan
that produced this doc). Most of these links previously lived only in chat history — this
file is the durable record.

## How we ship libghostty

We do **not** build Ghostty from source. We pin a prebuilt `GhosttyKit.xcframework` from
**`Lakr233/libghostty-spm`** (a community project that runs a weekly CI matrix building the
iOS device + simulator + macOS slices that upstream Ghostty does not publish as a single
release asset). It is vendored into the repo (the `storage.*` release tags are mutable and
have 404'd on us mid-release):

- xcframework: `apps/ios/GhosttyVT/Vendor/GhosttyKit.xcframework.zip` (pinned `storage.1.2.2`)
- SPM wrapper: `apps/ios/GhosttyVT/Package.swift` (binaryTarget, module name `libghostty`)
- bump/verify script: `scripts/fetch-ghostty-kit-xcframework.sh`

## Reference implementations

### Primary (working iOS apps we port lifecycle from)

| Project | What it is | Why it matters to us |
|---|---|---|
| **[daiimus/geistty](https://github.com/daiimus/geistty)** | iOS Ghostty terminal app; remote **SSH + tmux** client feeding bytes into a *client-side* libghostty surface. | **Our architectural twin.** Same topology as Conduit (remote PTY bytes → client libghostty render). Source of our surface lifecycle, CADisplayLink draw pump, resize-timing handling, and surface-reattach-across-tab-switch patterns. Key files: `Sources/Ghostty/Ghostty.swift`, `Ghostty.App.swift`, `GhosttyInput.swift`, `TmuxSurfaceProtocol.swift`; `docs/archive/METAL_COMPATIBILITY_WORKAROUNDS_MAR_2026.swift`, `REATTACH_PRESERVED_SURFACES_FEB_2026.swift`. |
| **[eriklangille/clauntty](https://github.com/eriklangille/clauntty)** | iOS Ghostty terminal app (SSH client). Bundles the full `GhosttyKit.xcframework`. | Second reference. Clean **App singleton + pointer-keyed surface registry + NSLock**, **background-queue feed** (documents that feeding on the main thread self-deadlocks the surface mailbox), bracketed-paste + selection handles. Key files: `Clauntty/Core/Terminal/{GhosttyApp,GhosttyBridge,TerminalSurface}.swift`, `Views/TerminalView.swift`. Fork it builds against: **[eriklangille/ghostty](https://github.com/eriklangille/ghostty)**. |

### Upstream + packaging

| Project | Role |
|---|---|
| **[ghostty-org/ghostty](https://github.com/ghostty-org/ghostty)** | Upstream Ghostty. The libghostty C ABI lives here; `macos/Sources/App/iOS/iOSApp.swift` is the canonical (private-ish) iOS reference. xcframework build: `src/build/GhosttyXCFramework.zig`. |
| **[Lakr233/libghostty-spm](https://github.com/Lakr233/libghostty-spm)** | The prebuilt `GhosttyKit.xcframework` we pin (weekly CI matrix → `storage.*` release tags, all iOS/sim/macOS slices). |
| **[ghostty-org/ghostling](https://github.com/ghostty-org/ghostling)** | "A minimum viable terminal emulator built on top of the libghostty C API." Smallest reference for the raw C surface API. |

### Other ports / clients (surveyed, not ported from)

| Project | Role |
|---|---|
| **[arach/TermBridgeKit](https://github.com/arach/TermBridgeKit)** | Alternative `GhosttyKit.xcframework` distribution (SPM, release `0.1.5`). Fallback packaging source if Lakr233 disappears. |
| **[cadooo/ghostty-ios](https://github.com/cadooo/ghostty-ios)** | Another iOS libghostty client. |
| **[BunsDev/ghostty-terminal](https://github.com/BunsDev/ghostty-terminal)** | iOS libghostty terminal. |
| **[tapthaker/ghostty-android](https://github.com/tapthaker/ghostty-android)** | Android NDK port research ("early development, not yet usable"). Android upstream support is research-only (Discussion #10902); our Android terminal uses **Termux** (`terminal-view`/`terminal-emulator`), not libghostty. |

## Ground-truth ABI (from the pinned `GhosttyKit.xcframework` header, `storage.1.2.2`)

The pin dictates the integration shape — it is **neither pure clauntty nor pure geistty** (their
exact feed/callback API names differ from what our pin exposes):

- **Feed bytes in:** only `ghostty_surface_write_buffer(surface, const uint8_t*, uintptr_t)`.
  (No `write_pty_output` / `write_output`.) **Must run off the main thread** — feeding on main
  self-deadlocks the surface mailbox (clauntty documents this; matches our EXC_BAD_ACCESS class).
- **Host-managed backend:** `ghostty_surface_config_s.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED`,
  with config callbacks `receive_buffer(void*, const uint8_t*, size_t)` and `receive_resize(...)`
  for surface-emitted bytes. (No `set_pty_input_callback`; no write-callback on `surface_new`.)
- **Draw:** `ghostty_surface_draw(surface)` — there is **no** `draw_now`. Drive from a CADisplayLink.
- **Surface config struct:** `platform_tag`, `platform`(union → `ghostty_platform_ios_s { void* uiview }`),
  `userdata`, `backend`, `receive_userdata`, `receive_buffer`, `receive_resize`, `scale_factor`,
  `font_size`, `working_directory`, `command`, `env_vars`, `env_var_count`, `initial_input`,
  `wait_after_command`, `context`.
- **Size struct:** `ghostty_surface_size_s { uint16_t columns; uint16_t rows; uint32_t width_px;
  uint32_t height_px; uint32_t cell_width_px; uint32_t cell_height_px; }`.
- **Surface ops:** `set_content_scale`, `set_size`, `size`, `set_focus`, `set_occlusion`, `refresh`,
  `set_color_scheme`, `key`, `text`, `mouse_pos`, `mouse_button`, `has_selection`, `read_selection`,
  `free_text`, `complete_clipboard_request`, `update_config`, `free`.
- **App:** `ghostty_init`, `ghostty_config_new`/`finalize`/`free`, `ghostty_app_new`, `ghostty_app_tick`,
  `ghostty_app_set_color_scheme`, `ghostty_app_set_focus`, `ghostty_app_free`.
- **Runtime callbacks:** `wakeup_cb`, `action_cb`, `read_clipboard_cb`, `confirm_read_clipboard_cb`,
  `write_clipboard_cb`, `close_surface_cb`.

## Distilled best practices (from reading geistty + clauntty source)

1. **App singleton, one `ghostty_init`.** Lock-guard it. `setenv("GHOSTTY_RESOURCES_DIR",
   Bundle.main.bundlePath, 1)` before init so config/themes resolve. Sequence:
   `ghostty_init` → `ghostty_config_new` → `ghostty_config_finalize` → `ghostty_runtime_config_s`
   (all **real** callbacks) → `ghostty_app_new` → `ghostty_app_set_color_scheme`.
2. **Pump the app loop from `wakeup_cb`** via `DispatchQueue.main.async { ghostty_app_tick(app) }`.
   It is event-driven, not a timer. No-op callbacks = a permanently blank terminal (our old bug).
3. **No `layerClass = CAMetalLayer` override.** libghostty parents its **own** `IOSurfaceLayer`
   via an ObjC `@objc(addSublayer:)` message on the view's default layer. (geistty archived the
   `layerClass` override as having no effect.)
4. **Create the surface in `init` with a non-zero frame** (geistty uses 800×600) inside
   `CATransaction.setDisableActions(true)` — avoids the 0×0 surface and white-flash.
5. **Set content scale before size, in pixels.** `ghostty_surface_set_content_scale(scale, scale)`
   then `ghostty_surface_set_size(pixelW, pixelH)`; read the grid back with `ghostty_surface_size()`.
   Size the IOSurface sublayer's `frame`/`contentsScale` inside `setDisableActions(true)`.
6. **Draw via a CADisplayLink** held by a **weak proxy** (avoid the displaylink→view retain cycle),
   calling `ghostty_surface_draw` each vsync (`preferredFrameRateRange` 60–120). Start when the view
   has a window, stop when it doesn't. Use `set_occlusion`/`set_focus` for tab-switch wake/sleep.
7. **Feed bytes on a dedicated background serial queue**, copying `Data` first. Never main.
8. **Explicit `close()` before dealloc**, on main: stop the display link **first**, nil callbacks,
   `ghostty_surface_free`, then `surface = nil`. `deinit` should only backstop (`assert surface == nil`).
   Freeing from `deinit` is unsafe because ARC `deinit` can fire mid-CoreAnimation-commit (the
   `apprt.surface.Mailbox.push` UAF). Use a pointer-keyed registry + lock so renderer-thread
   `action_cb`/clipboard callbacks route to the right surface safely.
9. **Double-emulator caveat (tmux/remote topology):** when the remote PTY+tmux already answers VT
   queries (DA/DSR/XTVERSION) and a *client-side* libghostty re-answers them, the duplicate echoes
   at the prompt. Keep user input on a **direct path to the remote** and run surface-emitted
   `receive_buffer` bytes through a query-response filter (`QueryResponseFilter.swift`).
