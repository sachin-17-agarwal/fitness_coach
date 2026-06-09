// InteractivePopGesture.swift
// Vaux
//
// SwiftUI doesn't expose a way to disable the system swipe-from-edge
// back gesture on a NavigationStack push. This helper bridges to UIKit
// and toggles `UINavigationController.interactivePopGestureRecognizer`
// on the enclosing nav controller.
//
// Use sparingly — back-swipe is an expected platform gesture. Only
// disable it for modes where an accidental dismissal would lose work
// or context (e.g. an in-progress workout).

import SwiftUI
import UIKit

private struct InteractivePopGate: UIViewControllerRepresentable {
    let isEnabled: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // Defer to the next runloop tick so we run after SwiftUI has
        // attached this representable to its host navigation controller.
        DispatchQueue.main.async {
            uiViewController.navigationController?.interactivePopGestureRecognizer?.isEnabled = isEnabled
        }
    }
}

extension View {
    /// Enables or disables the system swipe-from-edge back gesture on
    /// the enclosing NavigationStack push.
    func interactivePopGesture(enabled: Bool) -> some View {
        background(
            InteractivePopGate(isEnabled: enabled)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }
}
