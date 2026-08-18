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
// ── Two earlier attempts, and why each failed ────────────────────────────
// 1. `interactivePopGestureRecognizer?.isEnabled = false`. UIKit re-enables
//    that recogniser itself across navigation transitions, so the guard held
//    until the first time anything moved and then lapsed.
//
// 2. A gesture delegate, installed from a single `DispatchQueue.main.async`
//    hop inside `updateUIViewController`. A delegate is the right mechanism —
//    UIKit does not reset it — but the install was the problem: if
//    `navigationController` was still nil one runloop tick after the update,
//    it bailed and never tried again, and `updateUIViewController` only re-runs
//    when the flag changes. A zero-frame representable in `.background()` is
//    exactly the case where the lookup loses that race.
//
// So installation is now driven by the view controller's own lifecycle, which
// cannot fire before it is in the hierarchy, and re-asserted on every
// appearance and every SwiftUI update. WorkoutModeView also hides the back
// button while a session is live, which is the documented way to suppress the
// gesture; this is the belt to that pair of braces.

import SwiftUI
import UIKit

/// Answers the recogniser on each attempt. Holding the flag here rather than
/// on the recogniser is the point — this object survives the transitions that
/// were clearing `isEnabled`.
private final class PopGestureGate: NSObject, UIGestureRecognizerDelegate {
    var isEnabled = true
    weak var navigationController: UINavigationController?
    weak var originalDelegate: UIGestureRecognizerDelegate?

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard isEnabled else { return false }
        // UIKit's own delegate refuses the swipe on the root view controller,
        // and replacing it without reproducing that check is how this gesture
        // wedges a stack with nothing to pop back to.
        guard let nav = navigationController, nav.viewControllers.count > 1 else {
            return false
        }
        return true
    }
}

private final class PopGateController: UIViewController {
    let gate = PopGestureGate()

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        install()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        install()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        install()
    }

    /// Idempotent, and called from everywhere it could possibly succeed.
    /// Cheap enough that trying four times costs nothing; missing once cost a
    /// whole session.
    func install() {
        guard let nav = navigationController,
              let recognizer = nav.interactivePopGestureRecognizer else { return }
        gate.navigationController = nav
        // Take over once and stay taken over. Re-assigning on every call would
        // eventually capture our own gate as the "original" and make the
        // restore below a no-op.
        if recognizer.delegate !== gate {
            gate.originalDelegate = recognizer.delegate
            recognizer.delegate = gate
        }
        // The recogniser must also be enabled or the delegate is never asked.
        recognizer.isEnabled = true
    }

    /// Hand the gesture back. Leaving our gate installed would keep answering
    /// for screens that never asked to restrict it.
    func restore() {
        guard let recognizer = gate.navigationController?.interactivePopGestureRecognizer,
              recognizer.delegate === gate else { return }
        recognizer.delegate = gate.originalDelegate
    }
}

private struct InteractivePopGate: UIViewControllerRepresentable {
    let isEnabled: Bool

    func makeUIViewController(context: Context) -> PopGateController {
        let controller = PopGateController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ controller: PopGateController, context: Context) {
        controller.gate.isEnabled = isEnabled
        controller.install()
    }

    static func dismantleUIViewController(_ controller: PopGateController, coordinator: ()) {
        controller.restore()
    }
}

extension View {
    /// Enables or disables the system swipe-from-edge back gesture on the
    /// enclosing NavigationStack push.
    func interactivePopGesture(enabled: Bool) -> some View {
        background(
            InteractivePopGate(isEnabled: enabled)
                // Not zero-sized. A zero-frame representable is the case where
                // SwiftUI is least likely to give it a place in the controller
                // hierarchy, which is what the lookup needs.
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .allowsHitTesting(false)
        )
    }
}
