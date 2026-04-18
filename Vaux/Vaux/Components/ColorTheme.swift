// ColorTheme.swift
// Vaux
//
// Card styles, typography, animation & shadow tokens for the design system.

import SwiftUI

// MARK: - Card styles

/// Standard card: subtle gradient fill + hairline border.
struct DarkCardStyle: ViewModifier {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Gradients.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.cardBorder, lineWidth: 0.6)
            )
            .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
    }
}

/// Glass card — translucent with faint inner highlight. Used on hero surfaces.
struct GlassCardStyle: ViewModifier {
    var cornerRadius: CGFloat = 24
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.12), Color.white.opacity(0.02)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 12)
    }
}

/// Hero card — large gradient surface used for the recovery block and morning briefing.
struct HeroCardStyle: ViewModifier {
    let accent: Color
    var cornerRadius: CGFloat = 28
    var padding: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Gradients.hero)

                    // Colored glow
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [accent.opacity(0.22), .clear],
                                center: .topTrailing,
                                startRadius: 10,
                                endRadius: 260
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [accent.opacity(0.35), accent.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: accent.opacity(0.18), radius: 28, x: 0, y: 14)
    }
}

/// Filled accent card — primary-colored background (used on a session/CTA card).
struct AccentCardStyle: ViewModifier {
    let gradient: LinearGradient
    var cornerRadius: CGFloat = 22
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(gradient)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
    }
}

// MARK: - View Extensions

extension View {
    func darkCard(padding: CGFloat = 16, cornerRadius: CGFloat = 20) -> some View {
        modifier(DarkCardStyle(padding: padding, cornerRadius: cornerRadius))
    }

    func glassCard(padding: CGFloat = 18, cornerRadius: CGFloat = 24) -> some View {
        modifier(GlassCardStyle(cornerRadius: cornerRadius, padding: padding))
    }

    func heroCard(accent: Color, padding: CGFloat = 20, cornerRadius: CGFloat = 28) -> some View {
        modifier(HeroCardStyle(accent: accent, cornerRadius: cornerRadius, padding: padding))
    }

    func accentCard(_ gradient: LinearGradient, padding: CGFloat = 18, cornerRadius: CGFloat = 22) -> some View {
        modifier(AccentCardStyle(gradient: gradient, cornerRadius: cornerRadius, padding: padding))
    }
}

// MARK: - Typography presets

extension Font {
    /// Huge hero number (recovery score, stats).
    static let display = Font.system(size: 64, weight: .bold, design: .rounded).monospacedDigit()
    static let heroNumber = Font.system(size: 48, weight: .bold, design: .rounded).monospacedDigit()
    static let largeNumber = Font.system(size: 36, weight: .bold, design: .rounded).monospacedDigit()
    static let mediumNumber = Font.system(size: 26, weight: .bold, design: .rounded).monospacedDigit()
    static let smallNumber = Font.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit()

    static let sectionTitle = Font.system(size: 13, weight: .semibold, design: .default).smallCaps()
    static let cardTitle = Font.system(size: 16, weight: .semibold)
    static let cardBody = Font.system(size: 14)
    static let chipLabel = Font.system(size: 12, weight: .medium, design: .rounded)
}

// MARK: - Haptics

enum Haptic {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    static func soft() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }
    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    static func rigid() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

// MARK: - Animation presets

enum Motion {
    static let spring: Animation = .spring(response: 0.4, dampingFraction: 0.82)
    static let bouncy: Animation = .spring(response: 0.5, dampingFraction: 0.65)
    static let smooth: Animation = .easeInOut(duration: 0.25)
    static let snappy: Animation = .easeOut(duration: 0.18)
    static let soft: Animation = .easeInOut(duration: 0.4)
}

// MARK: - Small UI building blocks

/// Small rounded pill label. Used for trend chips, status badges, streak tags.
struct Chip: View {
    let text: String
    var icon: String? = nil
    var color: Color = .recoveryGreen
    var filled: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
            }
            Text(text)
                .font(.chipLabel)
        }
        .foregroundStyle(filled ? .black : color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(filled ? color : color.opacity(0.14))
        )
        .overlay(
            Capsule().stroke(color.opacity(filled ? 0 : 0.25), lineWidth: 0.5)
        )
    }
}

/// A section header label with small-caps styling.
struct SectionHeader: View {
    let title: String
    var accessory: AnyView? = nil

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .kerning(0.8)
                .foregroundStyle(Color.textSecondary)
            Spacer()
            if let accessory { accessory }
        }
    }
}

/// Small dot to separate compact text.
struct TextDot: View {
    var body: some View {
        Circle()
            .fill(Color.textTertiary)
            .frame(width: 3, height: 3)
    }
}
