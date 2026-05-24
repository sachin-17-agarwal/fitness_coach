// MetricCard.swift
// Vaux

import SwiftUI
import Charts

struct MetricCard: View {
    let icon: String
    let title: String
    let value: String
    var subtitle: String? = nil
    var trend: Trend? = nil
    var trendColor: Color? = nil
    var accentColor: Color = .signal
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
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        return parts.count == 2 ? String(parts[1]) : nil
    }

    private var numberPart: String {
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        return parts.first.map(String.init) ?? value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    iconTile
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
                                .foregroundStyle(accentColor)
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
            .padding(16)

            Spacer(minLength: 0)

            RoundedRectangle(cornerRadius: 2)
                .fill(
                    LinearGradient(
                        colors: [accentColor, accentColor.opacity(0.3)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 3)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.ink2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.line, lineWidth: 1)
        )
    }

    private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accentColor.opacity(0.14))
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accentColor)
        }
        .frame(width: 24, height: 24)
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
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
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
                .foregroundStyle(accentColor)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .interpolationMethod(.catmullRom)

                AreaMark(
                    x: .value("idx", i),
                    y: .value("v", v)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [accentColor.opacity(0.15), accentColor.opacity(0.04), .clear],
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
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
        MetricCard(
            icon: "moon.fill",
            title: "Sleep",
            value: "6:09 hrs",
            subtitle: "Moderate",
            accentColor: .iris,
            sparkline: [6.8, 7.1, 6.5, 7.3, 7.0, 7.4, 6.1]
        )
        MetricCard(
            icon: "heart.fill",
            title: "Resting HR",
            value: "59 bpm",
            subtitle: "7d avg 57 bpm",
            trend: .flat,
            accentColor: .ember,
            sparkline: [57, 58, 57, 58, 59, 58, 59]
        )
        MetricCard(
            icon: "scalemass.fill",
            title: "Weight",
            value: "84.2 kg",
            subtitle: "18.6% body fat",
            accentColor: .amber,
            sparkline: [87, 86.5, 86, 85.5, 85, 84.5, 84.2]
        )
        MetricCard(
            icon: "flame.fill",
            title: "Tonnage",
            value: "41.1 t",
            subtitle: "19 sessions",
            accentColor: .signal
        )
    }
    .padding()
    .background(Color.ink0)
}
