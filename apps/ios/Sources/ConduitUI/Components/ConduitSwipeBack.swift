import SwiftUI
import UIKit

// MARK: - ConduitSwipeBackEnabler (round-3 §5)
//
// The session screen hides the navigation bar (`.toolbar(.hidden, for:
// .navigationBar)` + a custom back chevron), which silently disables
// UIKit's `interactivePopGestureRecognizer` — its default delegate only
// allows the gesture while the system bar is visible. So there was NO
// edge-swipe back at all.
//
// This zero-size representable digs out the hosting
// `UINavigationController` and re-arms the recognizer with our own
// delegate that returns true whenever there's somewhere to pop to. The
// system gesture brings the standard interactive-pop treatment for
// free: the top screen follows the finger across the full left edge,
// the previous screen parallaxes in beneath it, and the commit
// threshold (~40%, velocity-aware) is UIKit's own. We add a light
// impact haptic when the pop actually commits (not on cancel).

extension ConduitUI {

    struct SwipeBackEnabler: UIViewControllerRepresentable {
        func makeUIViewController(context: Context) -> SwipeBackHookController {
            SwipeBackHookController()
        }

        func updateUIViewController(_ controller: SwipeBackHookController, context: Context) {}
    }

    final class SwipeBackHookController: UIViewController, UIGestureRecognizerDelegate {
        private weak var hookedRecognizer: UIGestureRecognizer?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            hookPopGesture()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            hookPopGesture()
        }

        private func hookPopGesture() {
            // The representable lands inside SwiftUI's hosting hierarchy;
            // walk up to the navigation controller that owns the pop
            // gesture. (`self.navigationController` resolves through the
            // parent chain.)
            guard let nav = navigationController,
                  let pop = nav.interactivePopGestureRecognizer else {
                Telemetry.breadcrumb("nav", "swipe-back hook: no pop recognizer")
                return
            }
            guard hookedRecognizer !== pop else { return }
            hookedRecognizer = pop
            pop.delegate = self
            pop.isEnabled = true
            pop.addTarget(self, action: #selector(popGestureChanged(_:)))
            Telemetry.breadcrumb("nav", "swipe-back enabled")
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // Only when there's a screen to pop to, and never mid-transition.
            guard let nav = navigationController else { return false }
            return nav.viewControllers.count > 1
                && nav.transitionCoordinator == nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            // Allow the screen-edge pop gesture to begin alongside the chat
            // scroll view and any SwiftUI DragGesture. Without this, the
            // scroll view / DragGesture captures the horizontal pan first and
            // the pop never fires. The pop recognizer is constrained to the
            // left screen edge via gestureRecognizerShouldBegin above, so a
            // mid-screen vertical scroll does not accidentally trigger a pop.
            // (No breadcrumb here — this is called repeatedly during gesture
            // arbitration and would flood the ring buffer.)
            return true
        }

        @objc private func popGestureChanged(_ recognizer: UIGestureRecognizer) {
            // Fire a light haptic when the interactive pop COMMITS (the
            // finger crossed the threshold) — not when it springs back.
            guard recognizer.state == .ended,
                  let coordinator = navigationController?.transitionCoordinator else { return }
            coordinator.notifyWhenInteractionChanges { context in
                if !context.isCancelled {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
        }
    }
}
