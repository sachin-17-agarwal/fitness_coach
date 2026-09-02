// ColorTheme.swift
// Vaux
//
// Design system core: backgrounds, card styles, typography, headers,
// animation & haptic tokens. The visual language is a dark "precision
// instrument" aesthetic — ink surfaces, hairline borders with a machined
// top highlight, mono microlabels, serif display numerals, and a single
// signal accent reserved for primary actions and live data.

import SwiftUI
import UIKit

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
        .accessibilityHidden(true)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.9), radius: pulse ? size : size * 0.3)
            .scaleEffect(pulse ? 1.0 : 0.8)
            .onAppear {
                // Reduce Motion keeps the dot lit at full strength rather than
                // breathing forever — the glow is the signal, the pulse was
                // only ever decoration on top of it.
                guard !reduceMotion else {
                    pulse = true
                    return
                }
                withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .accessibilityHidden(true)
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
                    .font(.scaled(16, weight: .semibold, relativeTo: .headline))
                    .kerning(0.2)
            }
        }
        .foregroundStyle(textColor)
        .frame(maxWidth: .infinity, minHeight: 44)
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
//
// The editorial direction depends on specific point sizes — a 96pt serif
// numeral is the design, not a rounded-up body style — so these can't simply
// become `.system(.largeTitle)`. Instead each preset keeps its drawn size and
// runs it through `UIFontMetrics`, which scales it by the reader's Dynamic
// Type setting. Display sizes get a ceiling: a 96pt hero tripled would push
// every neighbouring element off screen, whereas body and label text is
// allowed to grow freely because that is the text people enlarge the setting
// for in the first place.
//
// These are computed rather than stored so the scale is read at render time
// instead of being frozen at the value that happened to be set at launch.

private extension Font.TextStyle {
    /// The UIKit equivalent, since `UIFontMetrics` — the only API that will
    /// scale an arbitrary point size — is a UIKit type. Taking SwiftUI's own
    /// `Font.TextStyle` at the call sites keeps them in one framework's
    /// vocabulary and avoids relying on UIKit being in scope wherever a preset
    /// is declared.
    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        @unknown default: return .body
        }
    }
}

extension Font {
    /// A fixed design size, scaled for Dynamic Type.
    ///
    /// - Parameters:
    ///   - style: the text style whose scaling curve to follow. Labels scale
    ///     faster than display type, so pairing each preset with a comparable
    ///     style keeps the hierarchy intact as sizes grow.
    ///   - cap: upper bound in points, for type that would otherwise break
    ///     the layout it anchors.
    static func scaled(
        _ size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo style: Font.TextStyle = .body,
        cap: CGFloat? = nil
    ) -> Font {
        var points = UIFontMetrics(forTextStyle: style.uiTextStyle).scaledValue(for: size)
        if let cap { points = min(points, cap) }
        return .system(size: points, weight: weight, design: design)
    }

    // Hero serif numbers
    static var numHero: Font { scaled(96, weight: .light, design: .serif, relativeTo: .largeTitle, cap: 132) }
    static var numXL: Font { scaled(68, weight: .light, design: .serif, relativeTo: .largeTitle, cap: 96) }
    static var numDisplay: Font { scaled(46, weight: .light, design: .serif, relativeTo: .title, cap: 68) }
    static var numLG: Font { scaled(36, weight: .medium, design: .monospaced, relativeTo: .title2, cap: 54).monospacedDigit() }
    static var numMD: Font { scaled(22, weight: .medium, design: .monospaced, relativeTo: .title3, cap: 36).monospacedDigit() }
    static var numSM: Font { scaled(16, weight: .medium, design: .monospaced, relativeTo: .body).monospacedDigit() }

    // Editorial serif titles
    static var serifXL: Font { scaled(52, weight: .light, design: .serif, relativeTo: .largeTitle, cap: 74) }
    static var serifLG: Font { scaled(34, weight: .light, design: .serif, relativeTo: .title, cap: 50) }
    static var serifMD: Font { scaled(24, weight: .regular, design: .serif, relativeTo: .title2, cap: 38) }
    static var serifSM: Font { scaled(18, weight: .medium, design: .serif, relativeTo: .headline) }
    static var serifBrand: Font { scaled(22, weight: .medium, design: .serif, relativeTo: .title3, cap: 34) }

    // UI + labels
    static var eyebrow: Font { scaled(10, weight: .medium, design: .monospaced, relativeTo: .caption2) }
    static var eyebrowSmall: Font { scaled(9, weight: .medium, design: .monospaced, relativeTo: .caption2) }
    static var uiBody: Font { scaled(14, weight: .regular, relativeTo: .subheadline) }
    static var uiStrong: Font { scaled(14, weight: .semibold, relativeTo: .subheadline) }
    static var uiSmall: Font { scaled(12, weight: .regular, relativeTo: .footnote) }

    // Legacy aliases — keep existing views compiling while screens migrate.
    static var display: Font { numXL }
    static var heroNumber: Font { numXL }
    static var largeNumber: Font { numLG }
    static var mediumNumber: Font { numMD }
    static var smallNumber: Font { numSM }
    static var sectionTitle: Font { eyebrow }
    static var cardTitle: Font { uiStrong }
    static var cardBody: Font { uiBody }
    static var chipLabel: Font { eyebrow }
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

// MARK: - Entrance motion
//
// Soft rise-and-fade used to stagger sections into place on first
// appearance. Views stay mounted across tab switches, so this fires once
// per launch rather than on every visit.

struct RiseIn: ViewModifier {
    var delay: Double = 0
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            // Reduce Motion drops the travel but keeps the fade, which is the
            // part that reads as "this just loaded" rather than as movement.
            .offset(y: shown || reduceMotion ? 0 : 14)
            .onAppear {
                let animation: Animation = reduceMotion
                    ? .easeOut(duration: 0.2).delay(delay)
                    : .spring(response: 0.55, dampingFraction: 0.85).delay(delay)
                withAnimation(animation) { shown = true }
            }
    }
}

extension View {
    func riseIn(delay: Double = 0) -> some View {
        modifier(RiseIn(delay: delay))
    }
}

// MARK: - Glow-ring icon badge
//
// Concentric hairline rings around a glowing symbol — the shared visual
// for start screens, empty states, and completion heroes. `size` is the
// inner ring diameter; the outer ring extends 30% beyond it.

struct IconBadge: View {
    let systemName: String
    var accent: Color = .signal
    var size: CGFloat = 120

    var body: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(0.10), lineWidth: 1)
                .frame(width: size * 1.3, height: size * 1.3)
            Circle()
                .stroke(accent.opacity(0.22), lineWidth: 1)
                .frame(width: size, height: size)
            Circle()
                .fill(accent.opacity(0.07))
                .frame(width: size, height: size)
            Image(systemName: systemName)
                .font(.system(size: size * 0.34, weight: .medium))
                .foregroundStyle(accent)
                .shadow(color: accent.opacity(0.6), radius: 12)
        }
        .frame(width: size * 1.3, height: size * 1.3)
        // Always paired with a heading that says the same thing in words.
        .accessibilityHidden(true)
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


// MARK: - Display face

extension Font {
    /// The poster face used for hero numerals and session titles: Anton when
    /// the bundled font registered (Resources/Anton-Regular.ttf, UIAppFonts),
    /// otherwise SF Compressed Black — close enough in voice that a
    /// registration failure degrades the look, never the layout.
    static func display(_ size: CGFloat) -> Font {
        if UIFont(name: "Anton-Regular", size: size) != nil {
            return .custom("Anton-Regular", size: size)
        }
        if UIFont(name: "Anton", size: size) != nil {
            return .custom("Anton", size: size)
        }
        return .system(size: size, weight: .black).width(.compressed)
    }
}
