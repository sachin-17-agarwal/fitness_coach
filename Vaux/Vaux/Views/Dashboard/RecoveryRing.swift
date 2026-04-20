// RecoveryRing.swift
// Vaux — editorial redesign
//
// Hero recovery card: ring + serif number lockup side-by-side, 14-day bars,
// hairline-divided 3-col stat strip. Ring has zone tick marks at 40 / 70 and
// a mono zone label inside ("GREEN / AMBER / RED").

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
        case .green: return "GREEN"
        case .yellow: return "AMBER"
        case .red: return "RED"
        case .unknown: return "—"
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
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.ink2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.line, lineWidth: 1)
        )
        .onAppear {
            withAnimation(.easeOut(duration: 1.0)) {
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
        Text(statusChipLabel)
            .font(.eyebrow)
            .kerning(1.2)
            .foregroundStyle(zoneColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(zoneColor.opacity(0.08)))
            .overlay(Capsule().stroke(zoneColor.opacity(0.22), lineWidth: 1))
    }

    // MARK: - Ring + number lockup

    private var lockup: some View {
        HStack(alignment: .center, spacing: 22) {
            ring
                .frame(width: 120, height: 120)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(score)")
                        .font(.numXL)
                        .foregroundStyle(Color.fg0)
                        .contentTransition(.numericText(value: Double(score)))
                    Text("%")
                        .font(.serifMD)
                        .foregroundStyle(Color.fg2)
                }

                subCopy
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var subCopy: some View {
        if let delta = hrvDelta {
            let sign = delta >= 0 ? "+" : ""
            let deltaColor: Color = delta >= 0 ? .mint : .ember
            (
                Text("HRV ")
                    .font(.uiSmall)
                    .foregroundStyle(Color.fg1)
                +
                Text("\(sign)\(delta)ms")
                    .font(.numSM)
                    .foregroundStyle(deltaColor)
                +
                Text(" vs baseline. ")
                    .font(.uiSmall)
                    .foregroundStyle(Color.fg1)
                +
                Text(trainingVerdict)
                    .font(.uiSmall)
                    .foregroundStyle(Color.fg1)
            )
            .lineSpacing(2)
        } else if !statusText.isEmpty {
            Text(statusText)
                .font(.uiSmall)
                .foregroundStyle(Color.fg1)
        }
    }

    private var trainingVerdict: String {
        switch level {
        case .green: return "Push training is appropriate."
        case .yellow: return "Keep intensity moderate."
        case .red: return "Consider a deload day."
        case .unknown: return ""
        }
    }

    private var ring: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let stroke: CGFloat = 6

            ZStack {
                // Track
                Circle()
                    .stroke(Color.line, lineWidth: stroke)

                // Progress
                Circle()
                    .trim(from: 0, to: animatedProgress)
                    .stroke(zoneColor, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                // Tick marks at 40 and 70
                tickMark(atFraction: 0.40, size: size)
                tickMark(atFraction: 0.70, size: size)

                // Interior label
                VStack(spacing: 2) {
                    Eyebrow(text: "Zone")
                    Text(zoneLabel)
                        .font(.numSM)
                        .foregroundStyle(zoneColor)
                }
            }
            .frame(width: size, height: size)
        }
    }

    private func tickMark(atFraction fraction: Double, size: CGFloat) -> some View {
        let radius = (size / 2) - 3
        let angle = (fraction * 360.0) - 90.0
        let rad = angle * .pi / 180.0
        let x = (size / 2) + CGFloat(cos(rad)) * radius
        let y = (size / 2) + CGFloat(sin(rad)) * radius
        return Circle()
            .fill(Color.fg2)
            .frame(width: 3, height: 3)
            .position(x: x, y: y)
    }

    // MARK: - 14-day bars

    private var bars: some View {
        let days = normalizedBars
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(days.enumerated()), id: \.offset) { idx, day in
                let isToday = idx == days.count - 1
                let color: Color = isToday ? .signal : zoneFor(day.score)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color.opacity(isToday ? 1 : 0.55))
                    .frame(height: max(8, 42 * CGFloat(day.score) / 100.0))
            }
        }
        .frame(height: 42)
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
    .background(Color.ink0)
}
