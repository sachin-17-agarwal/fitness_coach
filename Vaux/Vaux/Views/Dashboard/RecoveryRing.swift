// RecoveryRing.swift
// Vaux
//
// Hero recovery card: instrument-style ring with the serif score inside
// and a glowing progress tip, zone readout + verdict on the right,
// 14-day bars, and a hairline-divided 3-col stat strip. Zone tick marks
// sit at 40 / 70 on the ring track.

import SwiftUI

struct RecoveryRing: View {
    let score: Int
    let level: DashboardViewModel.RecoveryLevel
    let statusText: String
    var sleep: Double? = nil
    var hrv: Double? = nil
    var rhr: Double? = nil
    var hrvDelta: Int? = nil
    var rhrDelta: Int? = nil
    var recentScores: [Int] = []

    @State private var animatedProgress: Double = 0

    private var zoneColor: Color {
        switch level {
        case .green: return .mint
        case .yellow: return .amber
        case .red: return .ember
        case .unknown: return .fg2
        }
    }

    private var zoneLabel: String {
        switch level {
        case .green: return "GREEN ZONE"
        case .yellow: return "AMBER ZONE"
        case .red: return "RED ZONE"
        case .unknown: return "NO DATA"
        }
    }

    private var statusChipLabel: String {
        switch level {
        case .green: return "Recovered"
        case .yellow: return "Moderate"
        case .red: return "Low"
        case .unknown: return "No data"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            lockup
            bars
            Hairline()
            statStrip
        }
        .heroCard(accent: zoneColor, padding: 22, cornerRadius: 28)
        .onAppear {
            withAnimation(.easeOut(duration: 1.1)) {
                animatedProgress = Double(score) / 100.0
            }
        }
        .onChange(of: score) { _, new in
            withAnimation(.easeOut(duration: 0.8)) {
                animatedProgress = Double(new) / 100.0
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Eyebrow(text: "Recovery")
            Spacer()
            recoveredChip
        }
    }

    private var recoveredChip: some View {
        HStack(spacing: 6) {
            GlowDot(color: zoneColor, size: 5)
            Text(statusChipLabel.uppercased())
                .font(.eyebrow)
                .kerning(1.2)
                .foregroundStyle(zoneColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(zoneColor.opacity(0.08)))
        .overlay(Capsule().stroke(zoneColor.opacity(0.22), lineWidth: 1))
    }

    // MARK: - Ring + readout lockup

    private var lockup: some View {
        HStack(alignment: .center, spacing: 22) {
            ring
                .frame(width: 148, height: 148)

            VStack(alignment: .leading, spacing: 10) {
                Text(zoneLabel)
                    .font(.eyebrow)
                    .kerning(1.6)
                    .foregroundStyle(zoneColor)

                subCopy

                if let delta = hrvDelta {
                    deltaReadout(delta)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var subCopy: some View {
        if hrvDelta != nil {
            Text(trainingVerdict)
                .font(.uiSmall)
                .foregroundStyle(Color.fg1)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        } else if !statusText.isEmpty {
            Text(statusText)
                .font(.uiSmall)
                .foregroundStyle(Color.fg1)
        }
    }

    private func deltaReadout(_ delta: Int) -> some View {
        let sign = delta >= 0 ? "+" : ""
        let deltaColor: Color = delta >= 0 ? .mint : .ember
        return HStack(spacing: 6) {
            Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(deltaColor)
            Text("HRV \(sign)\(delta) MS VS BASELINE")
                .font(.eyebrowSmall)
                .kerning(1.0)
                .foregroundStyle(Color.fg2)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.ink1.opacity(0.8)))
        .overlay(Capsule().stroke(Color.line, lineWidth: 1))
    }

    private var trainingVerdict: String {
        switch level {
        case .green: return "Systems are go — push training is appropriate today."
        case .yellow: return "Partially recovered. Keep intensity moderate."
        case .red: return "Recovery is compromised. Consider a deload day."
        case .unknown: return "Sync Apple Health to compute today's readiness."
        }
    }

    private var ring: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let stroke: CGFloat = 7

            ZStack {
                // Track
                Circle()
                    .stroke(Color.line.opacity(0.9), lineWidth: stroke)

                // Progress arc — fades in toward the glowing tip
                Circle()
                    .trim(from: 0, to: animatedProgress)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [zoneColor.opacity(0.25), zoneColor]),
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360 * animatedProgress)
                        ),
                        style: StrokeStyle(lineWidth: stroke, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: zoneColor.opacity(0.35), radius: 8)

                // Zone tick marks at 40 and 70
                tickMark(atFraction: 0.40, size: size)
                tickMark(atFraction: 0.70, size: size)

                // Glowing tip
                progressTip(size: size)

                // Score readout
                VStack(spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(score)")
                            .font(.numDisplay)
                            .foregroundStyle(Color.fg0)
                            .contentTransition(.numericText(value: Double(score)))
                        Text("%")
                            .font(.system(size: 16, weight: .regular, design: .serif))
                            .foregroundStyle(Color.fg2)
                    }
                    Text("READY")
                        .font(.eyebrowSmall)
                        .kerning(2.0)
                        .foregroundStyle(Color.fg2)
                }
            }
            .frame(width: size, height: size)
        }
    }

    private func tickMark(atFraction fraction: Double, size: CGFloat) -> some View {
        let radius = (size / 2) - 1
        let angle = (fraction * 360.0) - 90.0
        let rad = angle * .pi / 180.0
        let x = (size / 2) + CGFloat(cos(rad)) * radius
        let y = (size / 2) + CGFloat(sin(rad)) * radius
        return Circle()
            .fill(Color.fg3)
            .frame(width: 3, height: 3)
            .position(x: x, y: y)
    }

    private func progressTip(size: CGFloat) -> some View {
        let radius = size / 2
        let angle = (animatedProgress * 360.0) - 90.0
        let rad = angle * .pi / 180.0
        let x = radius + CGFloat(cos(rad)) * radius
        let y = radius + CGFloat(sin(rad)) * radius
        return Circle()
            .fill(Color.white)
            .frame(width: 7, height: 7)
            .shadow(color: zoneColor.opacity(0.95), radius: 6)
            .position(x: x, y: y)
            .opacity(animatedProgress > 0.01 ? 1 : 0)
    }

    // MARK: - 14-day bars

    private var bars: some View {
        let days = normalizedBars
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(days.enumerated()), id: \.offset) { idx, day in
                    let isToday = idx == days.count - 1
                    let color: Color = isToday ? .signal : zoneFor(day.score)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color.opacity(isToday ? 1 : 0.45))
                        .frame(height: max(8, 42 * CGFloat(day.score) / 100.0))
                        .shadow(color: isToday ? Color.signal.opacity(0.5) : .clear, radius: 6)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 42)

            HStack {
                Text("14 DAYS AGO")
                    .font(.eyebrowSmall)
                    .kerning(1.0)
                    .foregroundStyle(Color.fg3)
                Spacer()
                Text("TODAY")
                    .font(.eyebrowSmall)
                    .kerning(1.0)
                    .foregroundStyle(Color.fg2)
            }
        }
    }

    private struct DayBar { let score: Int }

    private var normalizedBars: [DayBar] {
        let target = 14
        let source = recentScores.suffix(target)
        let padding = max(0, target - source.count)
        let pad = Array(repeating: DayBar(score: 30), count: padding)
        return pad + source.map { DayBar(score: $0) }
    }

    private func zoneFor(_ score: Int) -> Color {
        switch score {
        case 70...: return .mint
        case 40...: return .amber
        default: return .ember
        }
    }

    // MARK: - Stat strip

    private var statStrip: some View {
        HStack(spacing: 0) {
            stat(
                label: "HRV",
                value: hrv.map { "\(Int($0))" } ?? "—",
                unit: "ms",
                trend: hrvDelta.map { $0 >= 0 ? .up : .down }
            )
            Rectangle().fill(Color.line).frame(width: 1)
            stat(
                label: "Sleep",
                value: formatSleepValue(sleep),
                unit: "hrs",
                trend: nil
            )
            Rectangle().fill(Color.line).frame(width: 1)
            stat(
                label: "RHR",
                value: rhr.map { "\(Int($0))" } ?? "—",
                unit: "bpm",
                trend: rhrDelta.map { $0 <= 0 ? .down : .up }
            )
        }
    }

    private enum Trend { case up, down }

    private func stat(label: String, value: String, unit: String, trend: Trend?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(text: label)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let trend {
                    Image(systemName: trend == .up ? "arrow.up" : "arrow.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(
                            // For HRV, up is good; for RHR, down is good.
                            label == "RHR"
                                ? (trend == .down ? Color.mint : Color.ember)
                                : (trend == .up ? Color.mint : Color.ember)
                        )
                }
                Text(value)
                    .font(.numMD)
                    .foregroundStyle(Color.fg0)
                Text(unit)
                    .font(.eyebrow)
                    .foregroundStyle(Color.fg2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private func formatSleepValue(_ v: Double?) -> String {
        guard let v else { return "—" }
        let hours = Int(v)
        let minutes = Int((v - Double(hours)) * 60)
        return String(format: "%d:%02d", hours, minutes)
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 16) {
            RecoveryRing(
                score: 87, level: .green, statusText: "HRV above average",
                sleep: 8.68, hrv: 54, rhr: 49, hrvDelta: 7, rhrDelta: -2,
                recentScores: [52, 61, 58, 74, 68, 71, 79, 82, 76, 84, 81, 85, 83, 87]
            )
            RecoveryRing(
                score: 55, level: .yellow, statusText: "HRV below baseline",
                sleep: 6.1, hrv: 42, rhr: 60, hrvDelta: -5, rhrDelta: 3,
                recentScores: [72, 65, 58, 50, 48, 55]
            )
        }
        .padding()
    }
    .background(Color.ink0)
}
