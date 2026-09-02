// EditorialCharts.swift
// Vaux
//
// Path-drawn charts for the History screens. Every chart here carries a
// reference (a band, a need line, a previous block) so it makes a claim
// rather than decorating one. Marks: smooth 3pt ribbons with a gradient wash,
// deload weeks shaded, all-time PRs as white dots.

import SwiftUI

// MARK: - Geometry helpers

enum ChartMath {
    /// Catmull-Rom through `pts`, as cubic Béziers.
    static func smoothPath(_ pts: [CGPoint]) -> Path {
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: first)
        guard pts.count > 1 else { return p }
        for i in 0..<(pts.count - 1) {
            let p0 = i > 0 ? pts[i - 1] : pts[i]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = i + 2 < pts.count ? pts[i + 2] : p2
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            p.addCurve(to: p2, control1: c1, control2: c2)
        }
        return p
    }

    /// The ribbon's wash: the line path closed down to `floorY`.
    static func closedArea(_ line: Path, from x0: CGFloat, to x1: CGFloat, floorY: CGFloat) -> Path {
        var area = line
        area.addLine(to: CGPoint(x: x1, y: floorY))
        area.addLine(to: CGPoint(x: x0, y: floorY))
        area.closeSubpath()
        return area
    }

    static func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }

    static func stdDev(_ xs: [Double]) -> Double {
        guard xs.count > 1 else { return 0 }
        let m = mean(xs)
        return (xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count)).squareRoot()
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }
}

/// Draw-in for stroked paths: the line reveals left to right on appear.
private struct RevealOnAppear: ViewModifier {
    @State private var progress: CGFloat = 0
    var duration: Double = 0.9
    func body(content: Content) -> some View {
        content
            .mask(
                GeometryReader { geo in
                    Rectangle().frame(width: geo.size.width * progress).frame(maxWidth: .infinity, alignment: .leading)
                }
            )
            .onAppear { withAnimation(.easeOut(duration: duration)) { progress = 1 } }
    }
}

extension View {
    func revealOnAppear(duration: Double = 0.9) -> some View { modifier(RevealOnAppear(duration: duration)) }
}

// MARK: - Ribbon (per-lift and hero trend)

/// One series over equal slots. `values[i] == nil` leaves a gap in the slot
/// grid but the ribbon connects across it; the ribbon only spans slots that
/// have data.
struct RibbonChart: View {
    let values: [Double?]
    var color: Color = Editorial.lime
    var shadedSlots: Set<Int> = []
    var dividerSlots: Set<Int> = []
    var prSlots: Set<Int> = []
    var lineWidth: CGFloat = 3
    var padX: CGFloat = Editorial.gutter
    var padY: CGFloat = 16
    /// Fixed y-range, else fitted to the data with a little air.
    var range: ClosedRange<Double>? = nil
    var endDotRadius: CGFloat = 5

    /// Fixed range when given, else fitted to the data with a little air.
    static func bounds(range: ClosedRange<Double>?, values: [Double]) -> ClosedRange<Double> {
        if let range { return range }
        let mn = values.min() ?? 0, mx = values.max() ?? 1
        let air = max((mx - mn) * 0.25, mx * 0.02, 0.5)
        return (mn - air)...(mx + air)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let n = max(1, values.count)
            let present = values.enumerated().compactMap { i, v in v.map { (i, $0) } }
            let bounds = Self.bounds(range: range, values: present.map(\.1))
            let lo = bounds.lowerBound, hi = bounds.upperBound
            let step = n > 1 ? (w - 2 * padX) / CGFloat(n - 1) : 0
            let x: (Int) -> CGFloat = { i in padX + CGFloat(i) * step }
            let y: (Double) -> CGFloat = { v in padY + (1 - CGFloat((v - lo) / max(hi - lo, 0.0001))) * (h - 2 * padY) }
            let pts = present.map { CGPoint(x: x($0.0), y: y($0.1)) }

            ZStack(alignment: .topLeading) {
                ForEach(Array(shadedSlots), id: \.self) { i in
                    Rectangle().fill(Editorial.wash.opacity(0.7))
                        .frame(width: max(step, 8), height: h)
                        .offset(x: x(i) - max(step, 8) / 2)
                }
                ForEach(Array(dividerSlots), id: \.self) { i in
                    Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1, height: h)
                        .offset(x: x(i) - step / 2)
                }
                if pts.count > 1 {
                    let line = ChartMath.smoothPath(pts)
                    let area = ChartMath.closedArea(line, from: pts.first!.x, to: pts.last!.x, floorY: h)
                    area.fill(LinearGradient(colors: [color.opacity(0.38), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    line.stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                        .revealOnAppear()
                }
                ForEach(present.indices, id: \.self) { k in
                    let (i, v) = present[k]
                    if prSlots.contains(i) {
                        Circle().fill(Editorial.bg).frame(width: 14, height: 14)
                            .overlay(Circle().fill(.white).frame(width: 9, height: 9))
                            .position(x: x(i), y: y(v))
                    } else if k == present.count - 1 {
                        Circle().fill(color).frame(width: endDotRadius * 2, height: endDotRadius * 2)
                            .position(x: x(i), y: y(v))
                    }
                }
            }
        }
    }
}

// MARK: - Dots on a band (recovery)

/// Daily readings as dots over the athlete's own typical range, with the
/// 7-day average as the line. Out-of-range days turn amber.
struct DotBandChart: View {
    let values: [Double?]
    var color: Color
    var band: ClosedRange<Double>?
    /// Below the band is the bad direction (HRV) — else above (RHR).
    var badBelow: Bool = true
    var shadedSlots: Set<Int> = []
    var range: ClosedRange<Double>
    var ticks: [Double] = []
    var tickFormat: (Double) -> String = { String(format: "%.0f", $0) }
    var padX: CGFloat = Editorial.gutter
    var padRight: CGFloat = 40
    var padY: CGFloat = 14

    private func avg7(_ i: Int) -> Double? {
        let window = values[max(0, i - 6)...i].compactMap { $0 }
        return window.isEmpty ? nil : ChartMath.mean(window)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let n = max(1, values.count)
            let lo = range.lowerBound, hi = range.upperBound
            let plotW = w - padX - padRight
            let step = n > 1 ? plotW / CGFloat(n - 1) : 0
            let x: (Int) -> CGFloat = { i in padX + CGFloat(i) * step }
            let y: (Double) -> CGFloat = { v in padY + (1 - CGFloat((v - lo) / max(hi - lo, 0.0001))) * (h - 2 * padY) }
            ZStack(alignment: .topLeading) {
                ForEach(Array(shadedSlots), id: \.self) { i in
                    Rectangle().fill(Editorial.wash.opacity(0.7)).frame(width: max(step, 6), height: h)
                        .offset(x: x(i) - max(step, 6) / 2)
                }
                if let band {
                    Rectangle().fill(color.opacity(0.13))
                        .frame(width: plotW, height: max(2, y(band.lowerBound) - y(band.upperBound)))
                        .offset(x: padX, y: y(band.upperBound))
                    Path { p in
                        let m = (band.lowerBound + band.upperBound) / 2
                        p.move(to: CGPoint(x: padX, y: y(m))); p.addLine(to: CGPoint(x: padX + plotW, y: y(m)))
                    }
                    .stroke(color.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
                ForEach(ticks, id: \.self) { t in
                    Text(tickFormat(t))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Editorial.muted)
                        .position(x: w - padRight / 2, y: y(t))
                }
                let avgPts: [CGPoint] = (0..<n).compactMap { i in avg7(i).map { CGPoint(x: x(i), y: y($0)) } }
                if avgPts.count > 1 {
                    ChartMath.smoothPath(avgPts)
                        .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .revealOnAppear()
                }
                ForEach(0..<n, id: \.self) { i in
                    if let v = values[i] {
                        let bad = band.map { badBelow ? v < $0.lowerBound : v > $0.upperBound } ?? false
                        let last = i == n - 1
                        Circle()
                            .fill(bad ? Editorial.amber : (last ? color : .white))
                            .frame(width: last ? 9 : 6, height: last ? 9 : 6)
                            .overlay(Circle().stroke(Editorial.bg, lineWidth: 1.5))
                            .position(x: x(i), y: y(v))
                    }
                }
            }
        }
    }
}

// MARK: - Week ranges (HRV by block week)

struct WeekRangeChart: View {
    struct Group: Identifiable {
        let id = UUID()
        let label: String
        let values: [Double]
        var highlight = false
    }
    let groups: [Group]
    var band: ClosedRange<Double>?
    var range: ClosedRange<Double>
    var color: Color = Editorial.lime
    var badBelow = true

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let padY: CGFloat = 20, labelH: CGFloat = 18
            let plotH = h - padY - labelH
            let y: (Double) -> CGFloat = { v in padY + (1 - CGFloat((v - range.lowerBound) / max(range.upperBound - range.lowerBound, 0.0001))) * (plotH - padY) }
            let slot = (w - 2 * Editorial.gutter) / CGFloat(max(1, groups.count))
            ZStack(alignment: .topLeading) {
                if let band {
                    Rectangle().fill(color.opacity(0.10))
                        .frame(width: w - 2 * Editorial.gutter, height: max(2, y(band.lowerBound) - y(band.upperBound)))
                        .offset(x: Editorial.gutter, y: y(band.upperBound))
                }
                ForEach(Array(groups.enumerated()), id: \.element.id) { i, g in
                    let cx = Editorial.gutter + slot * CGFloat(i) + slot / 2
                    if let mn = g.values.min(), let mx = g.values.max() {
                        let m = ChartMath.mean(g.values)
                        let out = band.map { badBelow ? m < $0.lowerBound : m > $0.upperBound } ?? false
                        let col: Color = g.highlight ? color : (out ? Editorial.amber : .white)
                        Capsule().fill(col.opacity(0.45)).frame(width: 6, height: max(6, y(mn) - y(mx)))
                            .position(x: cx, y: (y(mn) + y(mx)) / 2)
                        Circle().fill(col).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Editorial.bg, lineWidth: 2))
                            .position(x: cx, y: y(m))
                        Text(String(format: "%.0f", m))
                            .font(.display(16))
                            .foregroundStyle(col)
                            .position(x: cx, y: y(mx) - 14)
                    }
                    Text(g.label)
                        .font(.system(size: 8.5, weight: .bold))
                        .kerning(1.5)
                        .foregroundStyle(g.highlight ? color : Editorial.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: slot)
                        .position(x: cx, y: h - labelH / 2)
                }
            }
        }
    }
}

// MARK: - Wave bars (tonnage by block week) with ghost of the previous block

struct WaveBarsChart: View {
    struct Bar: Identifiable {
        let id = UUID()
        let label: String
        let phase: String
        let value: Double
        var ghost: Double? = nil
        var highlight = false
    }
    let bars: [Bar]
    var format: (Double) -> String = { Editorial.tonnage($0) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let top: CGFloat = 34, base = h - 40
            let mx = max(bars.map(\.value).max() ?? 1, bars.compactMap(\.ghost).max() ?? 1, 1)
            let slot = (w - 2 * Editorial.gutter) / CGFloat(max(1, bars.count))
            let bw: CGFloat = min(44, slot * 0.5)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.white.opacity(0.15)).frame(width: w - 2 * Editorial.gutter, height: 1)
                    .offset(x: Editorial.gutter, y: base)
                ForEach(Array(bars.enumerated()), id: \.element.id) { i, b in
                    let cx = Editorial.gutter + slot * CGFloat(i) + slot / 2
                    let bh = CGFloat(b.value / mx) * (base - top)
                    if let g = b.ghost, g > 0 {
                        let gh = CGFloat(g / mx) * (base - top)
                        UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                            .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .frame(width: bw + 10, height: gh)
                            .position(x: cx, y: base - gh / 2)
                    }
                    if b.value > 0 {
                        UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                            .fill(LinearGradient(colors: b.highlight ? [Editorial.lime, Editorial.lime.opacity(0.2)] : [Editorial.emerald, Editorial.emerald.opacity(0.15)], startPoint: .top, endPoint: .bottom))
                            .frame(width: bw, height: max(2, bh))
                            .position(x: cx, y: base - bh / 2)
                            .transition(.scale(scale: 0.2, anchor: .bottom))
                        Text(format(b.value))
                            .font(.display(22))
                            .foregroundStyle(b.highlight ? .white : Editorial.mid)
                            .position(x: cx, y: base - bh - 16)
                    } else {
                        Text("—").font(.display(18)).foregroundStyle(Editorial.muted).position(x: cx, y: base - 16)
                    }
                    Text(b.label)
                        .font(.system(size: 10, weight: .bold)).kerning(2)
                        .foregroundStyle(b.highlight ? .white : Editorial.muted)
                        .position(x: cx, y: base + 14)
                    Text(b.phase)
                        .font(.system(size: 8.5, weight: .bold)).kerning(1.5)
                        .foregroundStyle(b.highlight ? Editorial.lime : Editorial.muted)
                        .position(x: cx, y: base + 29)
                }
            }
        }
    }
}

// MARK: - Sets by day (Volume hero)

struct DayBarsChart: View {
    struct Day: Identifiable {
        let id = UUID()
        let label: String
        let value: Double
        var highlight = false
    }
    let days: [Day]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let top: CGFloat = 30, base = h - 26
            let mx = max(days.map(\.value).max() ?? 1, 1)
            let slot = (w - 2 * Editorial.gutter) / CGFloat(max(1, days.count))
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.white.opacity(0.15)).frame(width: w - 2 * Editorial.gutter, height: 1)
                    .offset(x: Editorial.gutter, y: base)
                ForEach(Array(days.enumerated()), id: \.element.id) { i, d in
                    let cx = Editorial.gutter + slot * CGFloat(i) + slot / 2
                    if d.value > 0 {
                        let bh = CGFloat(d.value / mx) * (base - top)
                        UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                            .fill(LinearGradient(colors: d.highlight ? [Editorial.lime, Editorial.lime.opacity(0.2)] : [Editorial.emerald, Editorial.emerald.opacity(0.15)], startPoint: .top, endPoint: .bottom))
                            .frame(width: min(26, slot * 0.55), height: max(2, bh))
                            .position(x: cx, y: base - bh / 2)
                        Text(String(format: "%.0f", d.value))
                            .font(.display(16))
                            .foregroundStyle(d.highlight ? .white : Editorial.mid)
                            .position(x: cx, y: base - bh - 12)
                    } else {
                        Text("REST").font(.system(size: 8.5, weight: .bold)).kerning(1.5)
                            .foregroundStyle(Editorial.muted).position(x: cx, y: base - 10)
                    }
                    Text(d.label)
                        .font(.system(size: 10, weight: .bold)).kerning(2)
                        .foregroundStyle(d.highlight ? .white : Editorial.muted)
                        .position(x: cx, y: base + 14)
                }
            }
        }
    }
}

// MARK: - Sleep bars vs need

struct SleepBarsChart: View {
    let hours: [Double?]
    var need: Double = 7.5
    var shortBelow: Double = 7.0
    var shadedSlots: Set<Int> = []
    var range: ClosedRange<Double> = 4...9.5

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let padX = Editorial.gutter, padRight: CGFloat = 40, padY: CGFloat = 12
            let n = max(1, hours.count)
            let plotW = w - padX - padRight
            let step = n > 1 ? plotW / CGFloat(n - 1) : 0
            let x: (Int) -> CGFloat = { i in padX + CGFloat(i) * step }
            let y: (Double) -> CGFloat = { v in padY + (1 - CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound))) * (h - 2 * padY) }
            ZStack(alignment: .topLeading) {
                ForEach(Array(shadedSlots), id: \.self) { i in
                    Rectangle().fill(Editorial.wash.opacity(0.7)).frame(width: max(step, 6), height: h).offset(x: x(i) - max(step, 6) / 2)
                }
                ForEach(0..<n, id: \.self) { i in
                    if let v = hours[i] {
                        let short = v < shortBelow
                        let last = i == n - 1
                        RoundedRectangle(cornerRadius: 2)
                            .fill(short ? Editorial.amber : (last ? Editorial.violet : Editorial.violet.opacity(0.55)))
                            .frame(width: max(4, min(7, step * 0.6)), height: max(2, y(range.lowerBound) - y(v)))
                            .position(x: x(i), y: (y(range.lowerBound) + y(v)) / 2)
                    }
                }
                Path { p in p.move(to: CGPoint(x: padX, y: y(need))); p.addLine(to: CGPoint(x: padX + plotW, y: y(need))) }
                    .stroke(Color.white.opacity(0.7), lineWidth: 1)
                Text(Self.hm(need)).font(.system(size: 9, weight: .semibold)).foregroundStyle(Editorial.mid)
                    .position(x: w - padRight / 2, y: y(need))
                Text("6:00").font(.system(size: 9, weight: .semibold)).foregroundStyle(Editorial.muted)
                    .position(x: w - padRight / 2, y: y(6))
            }
        }
    }

    static func hm(_ hours: Double) -> String {
        let total = Int((hours * 60).rounded())
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

// MARK: - Dots + 7-day line + weekly means (weight)

struct TrendDotsChart: View {
    let values: [Double?]
    var color: Color = Editorial.sand
    var weekLabels: [(slot: Int, text: String)] = []
    var range: ClosedRange<Double>

    private func avg7(_ i: Int) -> Double? {
        let window = values[max(0, i - 6)...i].compactMap { $0 }
        return window.isEmpty ? nil : ChartMath.mean(window)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let padX = Editorial.gutter, padY: CGFloat = 18
            let n = max(1, values.count)
            let step = n > 1 ? (w - 2 * padX) / CGFloat(n - 1) : 0
            let x: (Int) -> CGFloat = { i in padX + CGFloat(i) * step }
            let y: (Double) -> CGFloat = { v in padY + (1 - CGFloat((v - range.lowerBound) / max(range.upperBound - range.lowerBound, 0.0001))) * (h - 2 * padY) }
            ZStack(alignment: .topLeading) {
                ForEach(0..<n, id: \.self) { i in
                    if let v = values[i] {
                        Circle().fill(color.opacity(0.45)).frame(width: 5, height: 5).position(x: x(i), y: y(v))
                    }
                }
                let pts: [CGPoint] = (0..<n).compactMap { i in avg7(i).map { CGPoint(x: x(i), y: y($0)) } }
                if pts.count > 1 {
                    ChartMath.smoothPath(pts).stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)).revealOnAppear()
                    Circle().fill(color).frame(width: 9, height: 9).overlay(Circle().stroke(Editorial.bg, lineWidth: 1.5)).position(pts.last!)
                }
                ForEach(weekLabels.indices, id: \.self) { k in
                    let (slot, text) = weekLabels[k]
                    Text(text).font(.display(14)).foregroundStyle(Editorial.mid).position(x: x(slot), y: 8)
                }
            }
        }
    }
}

// MARK: - Load strip (training days under the recovery hero)

struct LoadStrip: View {
    /// Tonnage per slot; nil = no session. `legs` marks the heaviest kind of day.
    let tonnage: [Double?]
    let legs: [Bool]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let padX = Editorial.gutter, padRight: CGFloat = 40
            let n = max(1, tonnage.count)
            let step = n > 1 ? (w - padX - padRight) / CGFloat(n - 1) : 0
            let mx = max(tonnage.compactMap { $0 }.max() ?? 1, 1)
            ZStack(alignment: .topLeading) {
                ForEach(0..<n, id: \.self) { i in
                    if let t = tonnage[i], t > 0 {
                        let bh = CGFloat(t / mx) * (h - 6)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(legs[i] ? Editorial.lime : Color.white.opacity(0.35))
                            .frame(width: 6, height: max(3, bh))
                            .position(x: padX + CGFloat(i) * step, y: h - bh / 2)
                    }
                }
            }
        }
    }
}

// MARK: - Band bar (sets per muscle vs target) & balance beam

struct BandBar: View {
    let value: Double
    let band: ClosedRange<Int>
    var maxValue: Double = 20
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let px: (Double) -> CGFloat = { v in CGFloat(min(v, maxValue) / maxValue) * w }
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 4).offset(y: 5)
                Rectangle().fill(Color.white.opacity(0.18))
                    .frame(width: px(Double(band.upperBound)) - px(Double(band.lowerBound)), height: 4)
                    .offset(x: px(Double(band.lowerBound)), y: 5)
                Rectangle()
                    .fill(LinearGradient(colors: [color.opacity(0.2), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(2, px(value)), height: 14)
            }
        }
        .frame(height: 14)
    }
}

struct BalanceBeam: View {
    let ratioPct: Double?
    let band: ClosedRange<Int>
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let px: (Double) -> CGFloat = { p in CGFloat((min(max(p, 40), 160) - 40) / 120) * w }
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 4).offset(y: 6)
                Rectangle()
                    .fill(LinearGradient(colors: [Editorial.emerald, Editorial.lime], startPoint: .leading, endPoint: .trailing))
                    .opacity(ratioPct == nil ? 0.35 : 1)
                    .frame(width: px(Double(band.upperBound)) - px(Double(band.lowerBound)), height: 4)
                    .offset(x: px(Double(band.lowerBound)), y: 6)
                if let r = ratioPct {
                    Rectangle().fill(color).frame(width: 4, height: 16).offset(x: px(r) - 2)
                }
            }
        }
        .frame(height: 16)
    }
}
