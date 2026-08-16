// InteractivePopGesture.swift
// Vaux
//
// Enables or disables the swipe-from-edge back gesture on the enclosing
// UINavigationController.
//
// Use sparingly — back-swipe is an expected platform gesture. Only disable it
// for modes where an accidental dismissal would lose work or context (e.g. an
// in-progress workout).
//
// ── Why this is a delegate and not `isEnabled` ───────────────────────────
// The first version set `interactivePopGestureRecognizer?.isEnabled = false`.
// That reads correctly and does not work: UIKit re-enables the recogniser
// itself across navigation transitions and whenever the view controller
// hierarchy is rebuilt, so the guard held until the first time anything moved
// and then quietly lapsed. Mid-workout, a stray thumb near the left edge
// popped the whole session — and because leaving the screen triggers a resume
// on the way back in, one accidental swipe also cost a full re-prescription
// round trip.
//
// A delegate is not something UIKit resets. `gestureRecognizerShouldBegin` is
// consulted on every single attempt, so the answer cannot go stale.

import SwiftUI
import UIKit

/// Answers the recogniser on each attempt. Holding the flag here rather than
/// on the recogniser is the entire point — this object survives the
/// transitions that were clearing `isEnabled`.
private final class PopGestureGate: NSObject, UIGestureRecognizerDelegate {
    var isEnabled = true
    weak var navigationController: UINavigationController?
    weak var originalDelegate: UIGestureRecognizerDelegate?

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard isEnabled else { return false }
        // UIKit's own delegate refuses the swipe on the root view controller,
        // and replacing it without reproducing that check is how this gesture
        // wedges a navigation stack that has nothing to pop back to.
        guard let nav = navigationController, nav.viewControllers.count > 1 else {
            return false
        }
        return true
    }
}

private struct InteractivePopGate: UIViewControllerRepresentable {
    let isEnabled: Bool

    func makeCoordinator() -> PopGestureGate { PopGestureGate() }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        let gate = context.coordinator
        gate.isEnabled = isEnabled

        // Deferred because SwiftUI has not attached this representable to its
        // host navigation controller yet on the first update — `navigationController`
        // is nil until the next runloop tick.
        DispatchQueue.main.async {
            guard let nav = controller.navigationController,
                  let recognizer = nav.interactivePopGestureRecognizer else { return }
            gate.navigationController = nav
            // Take over once and stay taken over. Re-assigning on every update
            // would eventually capture our own gate as the "original" and make
            // the restore below a no-op.
            if recognizer.delegate !== gate {
                gate.originalDelegate = recognizer.delegate
                recognizer.delegate = gate
            }
            // Belt and braces: the recogniser must also be enabled, or the
            // delegate is never consulted at all.
            recognizer.isEnabled = true
        }
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: PopGestureGate) {
        // Hand the gesture back on the way out. Leaving our gate installed
        // would keep answering for screens that never asked to restrict it.
        guard let recognizer = coordinator.navigationController?.interactivePopGestureRecognizer,
              recognizer.delegate === coordinator else { return }
        recognizer.delegate = coordinator.originalDelegate
    }
}

extension View {
    /// Enables or disables the system swipe-from-edge back gesture on the
    /// enclosing NavigationStack push.
    func interactivePopGesture(enabled: Bool) -> some View {
        background(
            InteractivePopGate(isEnabled: enabled)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }
}
