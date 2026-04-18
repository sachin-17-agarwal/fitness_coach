// Color+Theme.swift
// FitnessCoach

import SwiftUI

// MARK: - Hex Initializer

extension Color {
    /// Creates a `Color` from a hex string (e.g. "0D0D0D" or "#0D0D0D").
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&rgb)

        let red = Double((rgb >> 16) & 0xFF) / 255.0
        let green = Double((rgb >> 8) & 0xFF) / 255.0
        let blue = Double(rgb & 0xFF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }
}

// MARK: - Theme Colors

extension Color {
    /// Near-black app background.
    static let background = Color(hex: "0D0D0D")

    /// Slightly lighter card surface.
    static let cardBackground = Color(hex: "1A1A1A")

    /// Subtle border for cards.
    static let cardBorder = Color(hex: "2A2A2A")

    /// Green accent for good recovery / positive states.
    static let recoveryGreen = Color(hex: "00D26A")

    /// Yellow accent for moderate recovery / warnings.
    static let recoveryYellow = Color(hex: "FFB800")

    /// Red accent for poor recovery / alerts.
    static let recoveryRed = Color(hex: "FF3B3B")

    /// Primary text color (white).
    static let textPrimary = Color.white

    /// Secondary text color (gray).
    static let textSecondary = Color.gray
}
