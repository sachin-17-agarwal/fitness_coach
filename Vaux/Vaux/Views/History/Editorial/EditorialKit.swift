// EditorialKit.swift
// Vaux
//
// The History screens are set like a sports annual: a full-bleed gradient
// hero with grain, one giant display figure, a stat stack, a diagnosis
// sentence, then poster rows. These are the shared pieces. Every colour here
// has one job; the body-map scale lives in `StrengthState`.

import SwiftUI

enum Editorial {
    static let bg = Color(hex: "06080B")
    static let heroTop = Color(hex: "0E2A1F")
    static let heroMid = Color(hex: "0A1A15")
    static let lime = Color.signal
    static let emerald = Color(hex: "1DB874")
    static let amber = Color(hex: "FF9E5E")
    static let coral = Color(hex: "C2664F")
    static let blue = Color(hex: "8FB8FF")
    static let violet = Color(hex: "C9A7FF")
    static let sand = Color(hex: "D9C9A3")
    static let mid = Color(hex: "AEB4BF")
    static let muted = Color(hex: "6E7683")
    static let rule = Color.white.opacity(0.08)
    static let wash = Color.white.opacity(0.06)

    static let gutter: CGFloat = 22
    /// Clearance for the floating capsule tab bar.
    static let bottomInset: CGFloat = 118

    static func tonnage(_ kg: Double) -> String {
        if kg >= 1000 { return String(format: "%.1fT", kg / 1000) }
        return "\(Int(kg.rounded()))kg"
    }

    static func signedPct(_ pct: Double, decimals: Int = 1) -> String {
        let arrow = pct > 0 ? "▴ " : (pct < 0 ? "▾ " : "")
        return arrow + String(format: "%.\(decimals)f%%", abs(pct))
    }
}

// MARK: - Type

struct EditorialEyebrow: View {
    let text: String
    var color: Color = Editorial.mid
    var size: CGFloat = 11
    var kerning: CGFloat = 3

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .bold))
            .kerning(kerning)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// A display figure that counts up from zero when it appears.
struct CountUpFigure: View {
    let value: Double
    var decimals: Int = 0
    var size: CGFloat = 150
    var color: Color = .white
    @State private var shown: Double = 0

    var body: some View {
        Text(String(format: "%.\(decimals)f", shown))
            .font(.display(size))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .contentTransition(.numericText())
            .onAppear {
                shown = 0
                withAnimation(.easeOut(duration: 0.9)) { shown = value }
            }
            .onChange(of: value) { _, new in
                withAnimation(.easeOut(duration: 0.6)) { shown = new }
            }
            .accessibilityLabel(String(format: "%.\(decimals)f", value))
    }
}

// MARK: - Hero panel

/// Full-bleed gradient with film grain. `content` is laid out inside the
/// safe area; the gradient runs under the status bar.
struct HeroPanel<Content: View>: View {
    var height: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                stops: [
                    .init(color: Editorial.heroTop, location: 0),
                    .init(color: Editorial.heroMid, location: 0.55),
                    .init(color: Editorial.bg, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            GrainOverlay()
            content()
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
    }
}

/// Deterministic film grain — a scatter of faint specks drawn once per size.
struct GrainOverlay: View {
    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { ctx, size in
            var seed: UInt32 = 0x9E37_79B9
            func next() -> CGFloat {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                return CGFloat(seed >> 8) / CGFloat(1 << 24)
            }
            let count = Int(size.width * size.height / 110)
            for _ in 0..<count {
                let x = next() * size.width
                let y = next() * size.height
                let a = 0.03 + next() * 0.07
                ctx.fill(Path(CGRect(x: x, y: y, width: 1.2, height: 1.2)), with: .color(.white.opacity(a)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Tab / block label pair at the top of every hero.
struct HeroTopBar: View {
    let left: String
    let right: String

    var body: some View {
        HStack {
            EditorialEyebrow(text: left)
            Spacer()
            EditorialEyebrow(text: right, size: 11, kerning: 1)
        }
    }
}

/// Three right-aligned facts beside the hero figure.
struct StatStack: View {
    struct Line: Identifiable {
        var id: String { text }
        let text: String
        var color: Color = Editorial.mid
    }
    let lines: [Line]

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(lines) { line in
                Text(line.text.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .kerning(1.5)
                    .foregroundStyle(line.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }
}

/// The screen's tabs as chips, set inside the hero.
struct HistoryTabChips: View {
    @Binding var selected: HistoryView.Tab

    var body: some View {
        HStack(spacing: 6) {
            ForEach(HistoryView.Tab.allCases, id: \.self) { tab in
                let on = tab == selected
                Button {
                    Haptic.selection()
                    withAnimation(Motion.snappy) { selected = tab }
                } label: {
                    Text(tab.rawValue.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .kerning(1.6)
                        .foregroundStyle(on ? Color.signalInk : Editorial.mid)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(on ? Editorial.lime : Color.white.opacity(0.06)))
                        .overlay(Capsule().stroke(on ? Color.clear : Editorial.rule, lineWidth: 1))
                        .frame(minHeight: 36)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

// MARK: - Sentence

/// The computed diagnosis. Tapping hands the question to the coach.
struct DiagnosisText: View {
    let text: AttributedString
    var coachPrompt: String?
    var askCoach: ((String) -> Void)?

    var body: some View {
        Button {
            if let coachPrompt, let askCoach {
                Haptic.light()
                askCoach(coachPrompt)
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text(text)
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .foregroundStyle(Editorial.mid)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if coachPrompt != nil && askCoach != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                        Text("ASK THE COACH ABOUT THIS")
                            .font(.system(size: 9.5, weight: .bold))
                            .kerning(2)
                    }
                    .foregroundStyle(Editorial.lime)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(coachPrompt == nil || askCoach == nil)
        .padding(.horizontal, Editorial.gutter)
        .padding(.top, 14)
        .padding(.bottom, 22)
    }
}

extension AttributedString {
    /// Builds a sentence with `bold` fragments in white.
    static func editorial(_ parts: [(String, Bool)]) -> AttributedString {
        var out = AttributedString()
        for (text, strong) in parts {
            var piece = AttributedString(text)
            if strong {
                piece.foregroundColor = .white
                piece.font = .system(size: 15, weight: .semibold)
            }
            out.append(piece)
        }
        return out
    }
}

// MARK: - Sections & rows

struct SectionBar: View {
    let title: String
    var right: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            EditorialEyebrow(text: title)
            Spacer()
            EditorialEyebrow(text: right, color: Editorial.muted, size: 10, kerning: 1.5)
        }
        .padding(.horizontal, Editorial.gutter)
        .padding(.top, 22)
        .padding(.bottom, 12)
    }
}

/// Status eyebrow · display title · display figure, ruled above.
struct PosterRow<Below: View>: View {
    let eyebrow: String
    let eyebrowColor: Color
    let title: String
    var subtitle: String = ""
    var value: String = ""
    var unit: String = ""
    var trailingCaption: String = ""
    var trailingCaptionColor: Color = Editorial.muted
    var valueColor: Color = .white
    var titleSize: CGFloat = 32
    @ViewBuilder var below: () -> Below

    init(
        eyebrow: String, eyebrowColor: Color, title: String, subtitle: String = "",
        value: String = "", unit: String = "", trailingCaption: String = "",
        trailingCaptionColor: Color = Editorial.muted, valueColor: Color = .white,
        titleSize: CGFloat = 32,
        @ViewBuilder below: @escaping () -> Below
    ) {
        self.eyebrow = eyebrow; self.eyebrowColor = eyebrowColor; self.title = title
        self.subtitle = subtitle; self.value = value; self.unit = unit
        self.trailingCaption = trailingCaption; self.trailingCaptionColor = trailingCaptionColor
        self.valueColor = valueColor; self.titleSize = titleSize; self.below = below
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Editorial.rule).frame(height: 1)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 7) {
                    EditorialEyebrow(text: eyebrow, color: eyebrowColor, size: 10, kerning: 2.5)
                    Text(title.uppercased())
                        .font(.display(titleSize))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Editorial.muted)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                if !value.isEmpty {
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(value)
                                .font(.display(52))
                                .foregroundStyle(valueColor)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            if !unit.isEmpty {
                                Text(unit.uppercased())
                                    .font(.system(size: 11, weight: .bold))
                                    .kerning(1)
                                    .foregroundStyle(Editorial.muted)
                            }
                        }
                        if !trailingCaption.isEmpty {
                            Text(trailingCaption)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(trailingCaptionColor)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, Editorial.gutter)
            .padding(.top, 20)
            below()
        }
    }
}

extension PosterRow where Below == EmptyView {
    init(
        eyebrow: String, eyebrowColor: Color, title: String, subtitle: String = "",
        value: String = "", unit: String = "", trailingCaption: String = "",
        trailingCaptionColor: Color = Editorial.muted, valueColor: Color = .white,
        titleSize: CGFloat = 32
    ) {
        self.init(eyebrow: eyebrow, eyebrowColor: eyebrowColor, title: title, subtitle: subtitle,
                  value: value, unit: unit, trailingCaption: trailingCaption,
                  trailingCaptionColor: trailingCaptionColor, valueColor: valueColor,
                  titleSize: titleSize, below: { EmptyView() })
    }
}

/// A hairline-separated disclosure line, e.g. "ALL 19 LIFTS ›".
struct DisclosureLine: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Rectangle().fill(Editorial.rule).frame(height: 1)
                HStack {
                    EditorialEyebrow(text: title)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Editorial.muted)
                }
                .padding(.horizontal, Editorial.gutter)
                .padding(.vertical, 16)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Range filter chips (30D / 90D / ALL).
struct RangeChips: View {
    let options: [String]
    @Binding var selected: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { o in
                let on = o == selected
                Button {
                    Haptic.selection()
                    withAnimation(Motion.snappy) { selected = o }
                } label: {
                    Text(o)
                        .font(.system(size: 10, weight: .bold))
                        .kerning(2)
                        .foregroundStyle(on ? Color.signalInk : Editorial.muted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(on ? Editorial.lime : .clear))
                        .overlay(Capsule().stroke(on ? Color.clear : Editorial.rule, lineWidth: 1))
                        .frame(minHeight: 34)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Explains why a block-over-block reading is grey.
struct NoReadNote: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle().fill(Editorial.muted).frame(width: 2)
            Text(text)
                .font(.system(size: 12))
                .lineSpacing(3)
                .foregroundStyle(Editorial.muted)
        }
        .padding(.horizontal, Editorial.gutter)
        .padding(.vertical, 14)
    }
}

// MARK: - Body-map scale

/// The one ordered scale every muscle and lift wears. Kept quiet on purpose:
/// only an all-time PR is allowed to be bright.
enum StrengthState: Int, CaseIterable, Comparable {
    case none = 0, hold, up, pr, short, stall, drop

    static func < (a: StrengthState, b: StrengthState) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .pr: return "ALL-TIME PR"
        case .up: return "PROGRESSING"
        case .hold: return "HOLDING"
        case .stall: return "STALLED"
        case .drop: return "DROPPING"
        case .short: return "SHORT ON SETS"
        case .none: return "NO READ"
        }
    }

    var color: Color {
        switch self {
        case .pr: return Editorial.lime
        case .up: return Color(hex: "62B37A")
        case .hold: return Color(hex: "4A6D63")
        case .stall: return Color(hex: "C9A15A")
        case .drop: return Color(hex: "B8614F")
        case .short: return Color(hex: "6F7BA3")
        case .none: return Color(hex: "182521")
        }
    }

    /// Text colour for the state word — the fills are too dark for text in
    /// two cases.
    var inkColor: Color {
        switch self {
        case .none: return Editorial.muted
        case .hold: return Color(hex: "7FA396")
        default: return color
        }
    }

    /// Legend order, best to worst then the two non-strength states.
    static let legendOrder: [StrengthState] = [.pr, .up, .hold, .stall, .drop, .short, .none]

    /// Sort order for "watch first" lists.
    var attention: Int {
        switch self {
        case .drop: return 0
        case .stall: return 1
        case .short: return 2
        case .none: return 3
        case .pr: return 4
        case .up: return 5
        case .hold: return 6
        }
    }
}

struct StateLegend: View {
    var states: [StrengthState] = StrengthState.legendOrder
    var body: some View {
        FlowLayout(spacing: 14, rowSpacing: 8) {
            ForEach(states, id: \.self) { s in
                HStack(spacing: 6) {
                    Circle().fill(s == StrengthState.none ? Color(hex: "2E3F37") : s.color).frame(width: 8, height: 8)
                    Text(s.label)
                        .font(.system(size: 9.5, weight: .bold))
                        .kerning(1.5)
                        .foregroundStyle(Editorial.mid)
                }
            }
        }
    }
}

/// Minimal wrapping layout for legend chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 390
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width, x > 0 { x = 0; y += rowH + rowSpacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Centre each row.
        var rows: [[(LayoutSubview, CGSize)]] = [[]]
        var x: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.width, x > 0 { rows.append([]); x = 0 }
            rows[rows.count - 1].append((s, sz))
            x += sz.width + spacing
        }
        var y = bounds.minY
        for row in rows {
            let rowW = row.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(0, row.count - 1))
            let rowH = row.map(\.1.height).max() ?? 0
            var rx = bounds.minX + (bounds.width - rowW) / 2
            for (s, sz) in row {
                s.place(at: CGPoint(x: rx, y: y), proposal: ProposedViewSize(sz))
                rx += sz.width + spacing
            }
            y += rowH + rowSpacing
        }
    }
}
