// Color+Theme.swift
// Vaux — editorial redesign tokens
//
// Single source of truth for color. Matches the design-handoff tokens:
//   ink scale (backgrounds), fg scale (text), signal palette (accents).
// Old gradient-heavy names are kept as aliases so legacy views still compile
// while we migrate screens one at a time.

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

// MARK: - Editorial tokens

extension Color {
    // Ink scale
    static let ink0 = Color(hex: "05060A")
    static let ink1 = Color(hex: "0B0D12")
    static let ink2 = Color(hex: "12141B")
    static let ink3 = Color(hex: "191C25")
    static let ink4 = Color(hex: "242832")
    static let line = Color(hex: "1E2230")
    static let line2 = Color(hex: "2B3040")

    // Paper
    static let paper = Color(hex: "F5F4EF")
    static let bone = Color(hex: "E7E4DB")

    // Foreground text
    static let fg0 = Color(hex: "F4F3EE")
    static let fg1 = Color(hex: "CFCEC7")
    static let fg2 = Color(hex: "878791")
    static let fg3 = Color(hex: "4E4E5A")

    // Signal palette (one accent per role)
    static let signal = Color(hex: "CFFF3E")
    static let signalInk = Color(hex: "0A0F00")
    static let mint = Color(hex: "7CE8B5")
    static let amber = Color(hex: "F5B84E")
    static let ember = Color(hex: "F26B4A")
    static let iris = Color(hex: "A8A0FF")
}

// MARK: - Legacy aliases (retain compilation for views not yet migrated)

extension Color {
    static let background = Color.ink0
    static let surface = Color.ink1
    static let surfaceRaised = Color.ink3
    static let cardBackground = Color.ink2
    static let cardBorder = Color.line
    static let divider = Color.line

    static let recoveryGreen = Color.mint
    static let recoveryYellow = Color.amber
    static let recoveryRed = Color.ember

    static let accentTeal = Color.mint
    static let accentCoral = Color.ember
    static let accentPurple = Color.iris
    static let accentAmber = Color.amber
    static let accentBlue = Color.iris

    static let textPrimary = Color.fg0
    static let textSecondary = Color.fg1
    static let textTertiary = Color.fg2

    static let signalLime = Color.signal
    static let signalLimeMuted = Color(hex: "8FB324")
}

// MARK: - Gradient tokens (quiet, single-tone)
//
// The editorial direction rejects vibrant gradients. We keep the Gradient
// helpers as mild single-color LinearGradients so card styles that still
// reference them render as quiet solid fills without extra refactoring.

enum Gradients {
    static let recovery = LinearGradient(
        colors: [Color.mint, Color.mint.opacity(0.85)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let moderate = LinearGradient(
        colors: [Color.amber, Color.amber.opacity(0.85)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let strain = LinearGradient(
        colors: [Color.ember, Color.ember.opacity(0.85)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cool = LinearGradient(
        colors: [Color.iris, Color.iris.opacity(0.85)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let violet = cool
    static let push = moderate
    static let legs = strain
    static let cardio = recovery
    static let yoga = cool

    static let card = LinearGradient(
        colors: [Color.ink2, Color.ink2],
        startPoint: .top,
        endPoint: .bottom
    )

    static let hero = LinearGradient(
        colors: [Color.ink2, Color.ink1],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let ambient = RadialGradient(
        colors: [Color.ink3.opacity(0.6), Color.clear],
        center: .top,
        startRadius: 0,
        endRadius: 500
    )

    static func forRecovery(_ score: Int) -> LinearGradient {
        switch score {
        case 70...: return recovery
        case 40...: return moderate
        default: return strain
        }
    }

    static func forSession(_ type: String) -> LinearGradient {
        switch type {
        case "Pull": return cool
        case "Push": return moderate
        case "Legs": return strain
        case "Cardio+Abs": return recovery
        case "Yoga": return cool
        default: return recovery
        }
    }
}

// MARK: - Session type → solid accent

extension Color {
    static func forSession(_ type: String) -> Color {
        switch type {
        case "Pull": return .iris
        case "Push": return .amber
        case "Legs": return .ember
        case "Cardio+Abs": return .mint
        case "Yoga": return .iris
        default: return .signal
        }
    }

    /// Zone color for a 0–100 recovery score.
    static func forZone(_ score: Int) -> Color {
        switch score {
        case 70...: return .mint
        case 40...: return .amber
        default: return .ember
        }
    }
}
