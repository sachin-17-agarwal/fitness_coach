// MetricCard.swift
// Vaux — editorial redesign
//
// Quiet hairline card: eyebrow label, serif value + mono unit, sparkline in
// fg-2 with a faint fill, optional mono sub-copy. No colored glows.

import SwiftUI
import Charts

struct MetricCard: View {
    let icon: String
    let title: String
    let value: String
    var subtitle: String? = nil
    var trend: Trend? = nil
    var trendColor: Color? = nil
    var accentColor: Color = .fg2
    var sparkline: [Double]? = nil

    enum Trend {
        case up, down, flat
        case delta(String)

        var icon: String {
            switch self {
            case .up, .delta: return "arrow.up"
            case .down: return "arrow.down"
            case .flat: return "minus"
            }
        }

        var label: String {
            switch self {
            case .up: return "UP"
            case .down: return "DOWN"
            case .flat: return "FLAT"
            case .delta(let s): return s
            }
        }

        var color: Color {
            switch self {
            case .up, .delta: return .mint
            case .down: return .ember
            case .flat: return .fg2
            }
        }
    }

    private var unit: String? {
        // Split "54 ms" → ("54", "ms"). If no space, we render value whole.
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        return parts.count == 2 ? String(parts[1]) : nil
    }

    private var numberPart: String {
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        return parts.first.map(String.init) ?? value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Eyebrow(text: title)
                Spacer()
                if let trend {
                    trendChip(trend)
                }
            }

            HStack(alignment: .bottom, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(numberPart)
                        .font(.serifLG)
                        .foregroundStyle(Color.fg0)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let unit {
                        Text(unit)
                            .font(.eyebrow)
                            .foregroundStyle(Color.fg2)
                    }
                }
                Spacer()
                if let sparkline, sparkline.count >= 2 {
                    sparklineView(sparkline)
                        .frame(width: 72, height: 24)
                }
            }

            if let subtitle {
                Text(subtitle.uppercased())
                    .font(.eyebrowSmall)
                    .kerning(1.2)
                    .foregroundStyle(Color.fg2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.ink2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.line, lineWidth: 1)
        )
    }

    private func trendChip(_ trend: Trend) -> some View {
        let chipColor = trendColor ?? trend.color
        return HStack(spacing: 3) {
            Image(systemName: trend.icon)
                .font(.system(size: 8, weight: .bold))
            Text(trend.label)
                .font(.eyebrowSmall)
                .kerning(1.0)
        }
        .foregroundStyle(chipColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(chipColor.opacity(0.10)))
        .overlay(Capsule().stroke(chipColor.opacity(0.22), lineWidth: 0.5))
    }

    private func sparklineView(_ data: [Double]) -> some View {
        Chart {
            ForEach(Array(data.enumerated()), id: \.offset) { i, v in
                LineMark(
                    x: .value("idx", i),
                    y: .value("v", v)
                )
                .foregroundStyle(Color.fg1)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .interpolationMethod(.catmullRom)

                AreaMark(
                    x: .value("idx", i),
                    y: .value("v", v)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.fg1.opacity(0.12), Color.fg1.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
    }
}

#Preview {
    VStack(spacing: 12) {
        MetricCard(
            icon: "moon.fill",
            title: "Sleep",
            value: "8.7 hrs",
            subtitle: "Deep 2h · REM 1.5h",
            trend: .up,
            sparkline: [6.8, 7.1, 6.5, 7.3, 7.0, 7.4, 8.7]
        )
        MetricCard(
            icon: "heart.fill",
            title: "Resting HR",
            value: "49 bpm",
            subtitle: "7d avg 51 bpm",
            trend: .down,
            sparkline: [52, 51, 53, 52, 50, 51, 49]
        )
    }
    .padding()
    .background(Color.ink0)
}
