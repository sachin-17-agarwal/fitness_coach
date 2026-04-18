// ColorTheme.swift
// FitnessCoach

import SwiftUI

/// A `ViewModifier` that applies the standard dark card style used throughout the app.
///
/// Usage:
/// ```swift
/// VStack { ... }
///     .modifier(DarkCardStyle())
/// ```
/// Or via the convenience extension:
/// ```swift
/// VStack { ... }
///     .darkCard()
/// ```
struct DarkCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(Color.cardBackground)
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.cardBorder, lineWidth: 1)
            )
    }
}

// MARK: - View Extension

extension View {
    /// Applies the standard dark card styling (background, rounded corners, border).
    func darkCard() -> some View {
        modifier(DarkCardStyle())
    }
}
