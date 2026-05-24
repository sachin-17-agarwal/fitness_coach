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
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.04), Color.clear],
                            startPoint: .top,
                            endPoint: .center
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
    }
}

// MARK: - View Extension

extension View {
    /// Applies the standard dark card styling (background, rounded corners, border).
    func darkCard() -> some View {
        modifier(DarkCardStyle())
    }
}
