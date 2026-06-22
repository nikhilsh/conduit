# iOS Keyboard Avoidance Plan

## Problem

The chat composer was hidden behind the soft keyboard on iPhone. The keyboard
appeared but the composer did not lift above it, leaving the text field
inaccessible without dismissing the keyboard first. Reported as device bug #19.

## Why the manual lift existed (FB13296535)

SwiftUI's native keyboard avoidance -- where a `.safeAreaInset(edge: .bottom)`
view automatically rides up with the keyboard -- had a known bug (Apple
FB13296535): during a `.scrollDismissesKeyboard(.interactively)` drag the
native avoidance did NOT follow the keyboard continuously. The composer froze
at its raised position while the keyboard descended, opening a visible gap.

Because of FB13296535, prior implementations added a manual keyboard-lift
mechanism: opt out of native avoidance with `.ignoresSafeArea(.keyboard,
edges: .bottom)`, then manually track the keyboard position and apply a
`.padding(.bottom, keyboardInset)` to the composer.

## Attempts #712, #715, #716

All three PRs worked within the constraint that FB13296535 was unfixed and
native avoidance was broken for interactive dismiss. They iterated on the
manual-lift approach:

- #712: UIResponder notifications for show/hide (missed continuous drag frames)
- #715: CADisplayLink reading UIKeyboardLayoutGuide every frame (worked at rest
  and during drag, but required a window-level UIView host and a retain-cycle
  proxy)
- #716: ViewController-based UIKeyboardLayoutGuide constraint (safeAreaInset
  VC-guide approach; surgical, but still manual)

## iOS 26 fixes FB13296535

Apple fixed FB13296535 in iOS 26. With the fix, SwiftUI's native keyboard
avoidance correctly tracks the keyboard during a
`.scrollDismissesKeyboard(.interactively)` drag. The composer -- hosted as
`.safeAreaInset(edge: .bottom)` on the ScrollView -- now follows the keyboard
continuously in both the resting position AND during the interactive drag.

Because the app's deployment target is iOS 26.0 (per `apps/ios/project.yml`),
the FB13296535 workaround is no longer necessary.

## The change (this PR)

### ConduitChatView.swift

Removed the entire manual keyboard machinery:

- `KeyboardLiveInsetTracker` class (CADisplayLink + UIKeyboardLayoutGuide
  window-level host)
- `KeyboardTrackerHost` UIViewRepresentable (the 0x0 placeholder that installed
  the tracker view)
- `@State private var keyboardInset: CGFloat = 0`
- `@StateObject private var kbTracker = KeyboardLiveInsetTracker()`
- `.ignoresSafeArea(.keyboard, edges: .bottom)` from the `messagesList` body
- `.background(KeyboardTrackerHost(...))` from the body
- `.onChange(of: kbTracker.liveInset)` sync block
- `.padding(.bottom, keyboardInset)` on the composer
- `.background(alignment: .bottom) { if keyboardInset > 0 { ... } }` fill block
- `keyboardInset = 0` write in the `isActive` false branch
- The now-redundant `willChangeFrame` notification receiver

Kept:

- `.safeAreaInset(edge: .bottom)` on the ScrollView (native avoidance target)
- `.scrollDismissesKeyboard(.interactively)` on the ScrollView
- `keyboardWillShow` notification handler (scroll-to-bottom side effect only)
- `keyboardWillHide` notification handler (Sentry breadcrumb)
- `dismissStrayKeyboard` / `isActive` tab-switch logic (unchanged)
- `logKeyboardDiag` with `composerMaxY` tracking (still useful for Sentry)
- `keyboardAnimation(_:)` helper (drives the willShow scroll animation)

### ConduitProjectView.swift

Removed `.ignoresSafeArea(.keyboard, edges: .bottom)` from the outer VStack
(header + tabStrip + Divider + content). This modifier was added to prevent the
header from riding up when the keyboard opened -- but it was also preventing
native avoidance from propagating into the chat content subtree, which was the
root cause of the composer-behind-keyboard bug.

Left intact:
- `.ignoresSafeArea(.keyboard, edges: .bottom)` on the terminal tab content
- `.ignoresSafeArea(.keyboard, edges: .bottom)` on the browser tab content

Both of those surfaces manage their own keyboards and must not participate in
the ZStack keyboard negotiation.

## Header-pinning risk and how it is handled

The primary risk of removing the VStack `.ignoresSafeArea(.keyboard)` is that
the header could ride up when the keyboard opens. The analysis for why it should
not:

With native avoidance active, the keyboard height is absorbed by the bottom
`safeAreaInset` on the chat ScrollView (the flexible element). The ScrollView
shrinks vertically to accommodate; the VStack's fixed-height children above it
(header, tabStrip, Divider) are not affected. The header stays pinned.

The approach taken here is the minimal removal: just delete the suppressor and
let native avoidance operate normally. The fallback, if device testing shows the
header riding up, is to scope the keyboard-avoiding region explicitly by moving
the top chrome into a `.safeAreaInset(edge: .top)` on the chat content --
effectively the same layout but forcing the bottom-avoidance scope to exclude
the top chrome. This fallback is documented in PR #716.

## Fallback

PR #716 (VC-guide approach) is the documented fallback if native avoidance
regresses the header on device. Its surgical ViewController-level constraint
does not depend on FB13296535 being fixed and would work on any iOS 15+ target.

## WWDC23 reference

WWDC23 session s10281 "What's new in SwiftUI" documents `safeAreaInset` as the
idiomatic way to pin a composer above the keyboard. The interactive-dismiss
tracking fix is part of the iOS 26 keyboard avoidance improvements.

## Device-verify checklist

- [ ] Keyboard up at rest: composer sits directly above the keyboard (the core
      bug -- not behind it)
- [ ] Interactive scroll-dismiss drag: composer stays glued to the descending
      keyboard (no gap between composer and keyboard top during the drag)
- [ ] HEADER STAYS PINNED when the keyboard opens (does NOT ride up or off-screen)
      -- the #1 risk of this approach
- [ ] QuickType/predictive bar resize: no undershoot (composer stays flush)
- [ ] Tab switch Terminal/Browser <-> Chat: no stray keyboard; clean re-focus
- [ ] Tap-dismiss / send: composer drops smoothly
