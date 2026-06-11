// ColorTheme.swift
// Vaux
//
// Design system core: backgrounds, card styles, typography, headers,
// animation & haptic tokens. The visual language is a dark "precision
// instrument" aesthetic — ink surfaces, hairline borders with a machined
// top highlight, mono microlabels, serif display numerals, and a single
// signal accent reserved for primary actions and live data.

import SwiftUI

// MARK: - Screen background
//
// Every tab root sits on this: ink-0 base, an ultra-faint blueprint dot
// grid, and two soft radial glows that give the black depth without
// turning it into a gradient poster. Purely decorative — never blocks
// touches.

struct TechBackground: View {
    var accent: Color = .signal

    var body: some View {
        ZStack {
            Color.ink0

            DotGrid()

            RadialGradient(
                colors: [accent.opacity(0.06), .clear],
                center: UnitPoint(x: 0.9, y: -0.08),
                startRadius: 0,
                endRadius: 440
            )

            RadialGradient(
                colors: [Color.iris.opacity(0.045), .clear],
                center: UnitPoint(x: 0.02, y: 0.02),
                startRadius: 0,
                endRadius: 380
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Faint engineering-paper dot matrix.
struct DotGrid: View {
    var spacing: CGFloat = 24
    var dotSize: CGFloat = 1.4
    var opacity: Double = 0.05

    var body: some View {
        Canvas { context, size in
            let color = Color.white.opacity(opacity)
            var x: CGFloat = 0
            while x <= size.width {
                var y: CGFloat = 0
                while y <= size.height {
                    let rect = CGRect(
                        x: x - dotSize / 2,
                        y: y - dotSize / 2,
                        width: dotSize,
                        height: dotSize
                    )
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                    y += spacing
                }
                x += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Screen header
//
// Unified editorial header used on every tab in place of the stock UIKit
// large title: kerned mono eyebrow line (with optional live dot and
// trailing accessory) above a light serif title.

struct ScreenHeader: View {
    let eyebrow: String
    let title: String
    var showsLiveDot: Bool = false
    var accessory: AnyView? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if showsLiveDot {
                    GlowDot(color: .signal, size: 5)
                }
                Eyebrow(text: eyebrow)
                Spacer()
                if let accessory { accessory }
            }

            Text(title)
                .font(.serifLG)
                .foregroundStyle(Color.fg0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Live status dot

struct GlowDot: View {
    var color: Color = .signal
    var size: CGFloat = 6
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.9), radius: pulse ? size : size * 0.3)
            .scaleEffect(pulse ? 1.0 : 0.8)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

// MARK: - Card styles

/// Standard card: ink fill, hairline border with a machined top-edge
/// highlight, deep soft shadow.
struct DarkCardStyle: ViewModifier {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.ink2.opacity(0.94))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.10), Color.line, Color.line],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 10)
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

/// Hero card — large accent-tinted surface for the recovery block and briefing.
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
                        .fill(Color.ink2.opacity(0.94))

                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [accent.opacity(0.10), .clear],
                                center: .topLeading,
                                startRadius: 10,
                                endRadius: 320
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [accent.opacity(0.40), accent.opacity(0.08), Color.line],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: accent.opacity(0.14), radius: 24, x: 0, y: 12)
            .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
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

// MARK: - Primary CTA
//
// The single filled signal-lime action of a screen. Soft accent glow,
// pressed scale via PressScaleStyle at the call site.

struct CTALabel: View {
    let text: String
    var icon: String? = nil
    var busy: Bool = false
    var fill: Color = .signal
    var textColor: Color = .signalInk

    var body: some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView().tint(textColor)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
            }
            if !busy {
                Text(text)
                    .font(.system(size: 16, weight: .semibold))
                    .kerning(0.2)
            }
        }
        .foregroundStyle(textColor)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                .blendMode(.plusLighter)
        )
        .shadow(color: fill.opacity(0.30), radius: 18, x: 0, y: 10)
    }
}

// MARK: - Typography presets

extension Font {
    // Editorial direction — serif for hero numbers/titles, mono for
    // numerics/eyebrows, system sans for UI.

    // Hero serif numbers
    static let numHero = Font.system(size: 96, weight: .light, design: .serif)
    static let numXL = Font.system(size: 68, weight: .light, design: .serif)
    static let numDisplay = Font.system(size: 46, weight: .light, design: .serif)
    static let numLG = Font.system(size: 36, weight: .medium, design: .monospaced).monospacedDigit()
    static let numMD = Font.system(size: 22, weight: .medium, design: .monospaced).monospacedDigit()
    static let numSM = Font.system(size: 16, weight: .medium, design: .monospaced).monospacedDigit()

    // Editorial serif titles
    static let serifXL = Font.system(size: 52, weight: .light, design: .serif)
    static let serifLG = Font.system(size: 34, weight: .light, design: .serif)
    static let serifMD = Font.system(size: 24, weight: .regular, design: .serif)
    static let serifSM = Font.system(size: 18, weight: .medium, design: .serif)
    static let serifBrand = Font.system(size: 22, weight: .medium, design: .serif)

    // UI + labels
    static let eyebrow = Font.system(size: 10, weight: .medium, design: .monospaced)
    static let eyebrowSmall = Font.system(size: 9, weight: .medium, design: .monospaced)
    static let uiBody = Font.system(size: 14, weight: .regular)
    static let uiStrong = Font.system(size: 14, weight: .semibold)
    static let uiSmall = Font.system(size: 12, weight: .regular)

    // Legacy aliases — keep existing views compiling while screens migrate.
    static let display = numXL
    static let heroNumber = numXL
    static let largeNumber = numLG
    static let mediumNumber = numMD
    static let smallNumber = numSM
    static let sectionTitle = eyebrow
    static let cardTitle = uiStrong
    static let cardBody = uiBody
    static let chipLabel = eyebrow
}

// MARK: - Eyebrow label
//
// Small, mono, uppercase, kerned label used above hero numbers, cards, and
// sections.

struct Eyebrow: View {
    let text: String
    var color: Color = .fg2

    var body: some View {
        Text(text.uppercased())
            .font(.eyebrow)
            .kerning(1.4)
            .foregroundStyle(color)
    }
}

// MARK: - Hairline divider

struct Hairline: View {
    var color: Color = .line
    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 1)
    }
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

// MARK: - Press scale button style

struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
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
            Eyebrow(text: title)
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
