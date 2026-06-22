# iOS Chat Keyboard Fix — Architecture & History

## Problem

The chat composer must satisfy two simultaneous constraints:

1. **At rest** (keyboard presented and stationary): composer sits directly above the keyboard top edge, with no gap.
2. **During interactive drag** (`.scrollDismissesKeyboard(.interactively)`): composer stays glued to the descending keyboard top edge in real time, tracking every pixel of the drag.

Three prior attempts failed. The fix documented here is the fourth.

---

## Architecture: why manual lift is required

`ConduitChatView` is hosted inside `ConduitProjectView`, whose outer VStack carries:

```swift
.ignoresSafeArea(.keyboard, edges: .bottom)
```

This modifier disables SwiftUI's native keyboard avoidance for the **entire subtree** — including `ConduitChatView`. The reason it exists: without it the whole app shifts up when the keyboard appears, pushing the navigation header off-screen.

Because native avoidance is suppressed, the composer must be lifted manually:

- `keyboardInset: CGFloat` (`@State`) holds the current lift amount.
- The composer is placed via `.safeAreaInset(edge: .bottom)` on the `ScrollView`, then `.padding(.bottom, keyboardInset)` raises it above the keyboard.
- `KeyboardLiveInsetTracker` (a `CADisplayLink`-driven `ObservableObject`) publishes `liveInset` every display frame.
- `.onChange(of: kbTracker.liveInset)` writes `liveInset` into `keyboardInset` (guarded by `isActive`).

The `.ignoresSafeArea(.keyboard)` on `messagesList` is intentional: it prevents the ScrollView from double-lifting (the manual padding already does the lift; native avoidance on top would overshoot).

---

## Why each attempt failed

### Attempt 1 — Notifications only (pre-#712)

Used `UIResponder.keyboardWillShow/WillChangeFrame/WillHide` to compute `keyboardInset`.

**Failure**: these notifications fire at animation start and end — not continuously during a `.scrollDismissesKeyboard(.interactively)` drag. So while the user drags the keyboard down, `keyboardInset` stays frozen at the full keyboard height, and a gap opens between the keyboard top and the composer bottom. The gap closes only when the drag ends and `keyboardWillHide` fires.

### Attempt 2 — CADisplayLink reading `keyboardLayoutGuide` on a `UIWindow`-direct-child view (#712)

Added `KeyboardTrackerHost: UIViewRepresentable`. On `updateUIView`, created a full-window `UIView`, called `window.addSubview(host)`, constrained an `anchor` subview to `host.keyboardLayoutGuide.topAnchor`, and started a `CADisplayLink` reading `host.keyboardLayoutGuide.layoutFrame` each tick.

**Failure**: `UIKeyboardLayoutGuide` is driven by the UIKit layout pass that is managed by the **UIViewController lifecycle**. A view added directly as a `UIWindow` subview is NOT in any UIViewController's view hierarchy — it never receives the VC-managed layout update that moves `layoutFrame` off its resting (bottom of screen / safe-area-collapsed) position. So at rest, `layoutFrame.minY` stayed at the resting value, the inset computed to ~0, and the composer fell behind the keyboard.

### Attempt 3 — Constraint on the window-child guide (#715)

Same structure as #712 but added an `NSLayoutConstraint` activating `anchor.bottomAnchor.constraint(equalTo: host.keyboardLayoutGuide.topAnchor)` to "engage" the guide.

**Failure**: the insight about guide engagement was correct — an unengaged guide collapses — but a constraint does not fix the root issue. The keyboard-frame update that moves the guide's `layoutFrame` is still VC-lifecycle-driven. A window-direct-child view, even with an active constraint referencing the guide, never gets that update because it is not in a UIViewController's view subtree. The guide stays collapsed at rest.

---

## The fix (this PR)

Host the guide-reading view inside a `UIViewControllerRepresentable`. A VC's `view` IS VC-managed, so `view.keyboardLayoutGuide` receives the keyboard-frame updates that move `layoutFrame` off its resting value at rest, during animation, and during interactive drag.

### Key implementation points

**`KeyboardTrackingViewController`**: a minimal `UIViewController` subclass.

- `viewDidLoad`: sets `view.backgroundColor = .clear`, `view.isUserInteractionEnabled = false`.
- If iOS 17+: sets `view.keyboardLayoutGuide.usesBottomSafeArea = false` so the guide tracks the raw keyboard top, not the safe-area-adjusted bottom.
- Adds a zero-size hidden `anchor` subview with `bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)` (plus `leadingAnchor`, `widthAnchor = 0`, `heightAnchor = 0`) to keep the guide engaged at all times.
- Calls `tracker.start(hostView: view)`.

**`KeyboardTrackerHost: UIViewControllerRepresentable`**: returns the VC from `makeUIViewController`; `updateUIViewController` is a no-op.

**`KeyboardLiveInsetTracker.tick()`**: coordinate-space-safe. The VC view does NOT fill the window (unlike the old full-window approach), so `keyboardLayoutGuide.layoutFrame` is in the VC view's local coordinate space, not window space. Convert before computing the inset:

```swift
guard let view = hostView, let window = view.window else { return }
let local = view.keyboardLayoutGuide.layoutFrame
let inWindow = view.convert(local, to: nil)   // nil = window coords
let inset = max(0, window.bounds.maxY - inWindow.minY - window.safeAreaInsets.bottom)
```

**`stop()`**: no longer needs to call `hostView?.removeFromSuperview()` (the VC owns the view; the representable lifecycle handles teardown). The displayLink invalidation is kept.

**Single source of truth**: notification-driven inset writes (`applyKeyboardInset`) are removed. The live tracker is now the only writer of `keyboardInset`. Notifications are kept solely for their side effects (scroll-to-bottom on show, Sentry breadcrumbs).

### Telemetry

`tick()` emits a **throttled** `Telemetry.breadcrumb("keyboard", "live inset", data: [...])` including `inset`, `inWindow.minY`, `window.bounds.maxY`, and `window.safeAreaInsets.bottom`. Throttle gate: first sample, any 0-to-positive or positive-to-0 crossing, or a shift of >= 20pt. This lets Sentry show whether the guide is tracking correctly after the VC-guide fix, without flooding at 60fps.

---

## Alternatives considered

### (a) Native SwiftUI avoidance

Remove the parent `.ignoresSafeArea(.keyboard, edges: .bottom)` from `ConduitProjectView`. On iOS 26, `safeAreaInset` + `.scrollDismissesKeyboard(.interactively)` is fixed (Apple FB13296535). On iOS 15-17, those two modifiers in combination have the interactive-dismiss bug.

**Why not chosen now**: removing the parent `.ignoresSafeArea(.keyboard)` would cause the "whole app shifts up / header off-screen" regression that motivated the manual approach in the first place. That regression must be validated on-device before removing it. This is the recommended future simplification — once on-device verified, the entire manual lift architecture (`KeyboardLiveInsetTracker`, `KeyboardTrackerHost`, `keyboardInset`) can be deleted.

### (b) `inputAccessoryView` bridge (UITextView)

Wire the composer's `UITextField`/`UITextView` as a `UIKit` view with `inputAccessoryView`. This is the iMessage-style approach and is the gold-standard — the keyboard tracks an `inputAccessoryView` exactly, by definition. However it requires a deep SwiftUI-to-UIKit bridge for the entire composer, which is high-complexity and high-surface-area. Documented as backup if the VC-guide approach proves flaky in practice.

---

## Verification checklist (needs on-device verification)

- [ ] Keyboard up at rest: composer sits directly above the keyboard top edge, no gap.
- [ ] Interactive drag dismiss: drag the chat content down — composer tracks the descending keyboard top continuously, no gap, no freeze.
- [ ] QuickType bar: toggling the QuickType bar (tall/short) — composer adjusts with no undershoot or overshoot.
- [ ] Tab switch: switch Terminal -> Chat and back -> no stray keyboard, no gap.
- [ ] Tap-dismiss: tap outside the composer to dismiss the keyboard — composer descends with keyboard smoothly.
- [ ] Send: tap Send while keyboard is up — keyboard dismisses, composer returns to rest position cleanly.
- [ ] Rotation: rotate device with keyboard up — composer repositions correctly.

---

## References

- **FB13296535** — `safeAreaInset` + `.scrollDismissesKeyboard(.interactively)` interactive dismiss bug; fixed in iOS 26.
- **WWDC21 session 10259** — UIKeyboardLayoutGuide introduction; guide shown being used on `UIViewController.view`.
- **WWDC23 session 10281** — `usesBottomSafeArea` / `followsUndockedKeyboard` (iOS 17 additions).
- **Apple Developer Forums thread 737366** — `keyboardLayoutGuide` reliability in non-VC view hierarchies.
- Prior PRs: #712 (CADisplayLink on window-child), #715 (constraint on window-child guide).
