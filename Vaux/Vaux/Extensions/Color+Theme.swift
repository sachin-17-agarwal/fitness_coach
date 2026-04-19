// Color+Theme.swift
// Vaux

import SwiftUI

// MARK: - Hex Initializer

extension Color {
    /// Creates a `Color` from a hex string (e.g. "0D0D0D" or "#0D0D0D").
    /// Supports optional leading "#" and 6-digit RGB hex.
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
    // Surfaces
    static let background = Color(hex: "0A0A0E")
    static let surface = Color(hex: "141418")
    static let surfaceRaised = Color(hex: "1C1C22")
    static let cardBackground = Color(hex: "17171C")
    static let cardBorder = Color(hex: "26262E")
    static let divider = Color(hex: "1F1F25")

    // Semantic accents
    static let recoveryGreen = Color(hex: "00E57A")
    static let recoveryYellow = Color(hex: "FFB800")
    static let recoveryRed = Color(hex: "FF4D4D")

    // Extended palette
    static let accentTeal = Color(hex: "00D4FF")
    static let accentCoral = Color(hex: "FF6B6B")
    static let accentPurple = Color(hex: "9D7BF4")
    static let accentAmber = Color(hex: "FFA940")
    static let accentBlue = Color(hex: "5B9DFF")

    // Text
    static let textPrimary = Color.white
    static let textSecondary = Color(hex: "8B8B96")
    static let textTertiary = Color(hex: "55555E")
}

// MARK: - Gradient tokens

enum Gradients {
    /// Vibrant recovery gradient (green → teal). Used for hero metrics.
    static let recovery = LinearGradient(
        colors: [Color(hex: "00E57A"), Color(hex: "00D4FF")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Moderate state (yellow → amber).
    static let moderate = LinearGradient(
        colors: [Color(hex: "FFB800"), Color(hex: "FFA940")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Low / strain gradient (amber → coral).
    static let strain = LinearGradient(
        colors: [Color(hex: "FFA940"), Color(hex: "FF4D4D")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Cool/calm gradient (teal → blue → purple).
    static let cool = LinearGradient(
        colors: [Color(hex: "00D4FF"), Color(hex: "5B9DFF"), Color(hex: "9D7BF4")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Violet/pull day accent.
    static let violet = LinearGradient(
        colors: [Color(hex: "9D7BF4"), Color(hex: "5B9DFF")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Push day accent (amber → coral).
    static let push = LinearGradient(
        colors: [Color(hex: "FFA940"), Color(hex: "FF6B6B")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Legs day accent (coral → red).
    static let legs = LinearGradient(
        colors: [Color(hex: "FF6B6B"), Color(hex: "FF4D4D")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Cardio accent (teal → green).
    static let cardio = LinearGradient(
        colors: [Color(hex: "00D4FF"), Color(hex: "00E57A")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Yoga accent (purple → blue).
    static let yoga = LinearGradient(
        colors: [Color(hex: "9D7BF4"), Color(hex: "00D4FF")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Card surface gradient (subtle elevation).
    static let card = LinearGradient(
        colors: [Color(hex: "1C1C22"), Color(hex: "17171C")],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Hero card — deep purple → surface.
    static let hero = LinearGradient(
        colors: [Color(hex: "1F1B2E"), Color(hex: "17171C")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Ambient background glow (subtle).
    static let ambient = RadialGradient(
        colors: [Color(hex: "1A1A22").opacity(0.8), Color.clear],
        center: .top,
        startRadius: 0,
        endRadius: 500
    )

    /// Returns the appropriate gradient for a recovery level 0…100.
    static func forRecovery(_ score: Int) -> LinearGradient {
        switch score {
        case 70...: return recovery
        case 40...: return moderate
        default: return strain
        }
    }

    /// Returns the session-type gradient.
    static func forSession(_ type: String) -> LinearGradient {
        switch type {
        case "Pull": return violet
        case "Push": return push
        case "Legs": return legs
        case "Cardio+Abs": return cardio
        case "Yoga": return yoga
        default: return recovery
        }
    }
}

// MARK: - Solid accent resolution for session types

extension Color {
    static func forSession(_ type: String) -> Color {
        switch type {
        case "Pull": return .accentPurple
        case "Push": return .accentAmber
        case "Legs": return .accentCoral
        case "Cardio+Abs": return .accentTeal
        case "Yoga": return .accentBlue
        default: return .recoveryGreen
        }
    }
}
