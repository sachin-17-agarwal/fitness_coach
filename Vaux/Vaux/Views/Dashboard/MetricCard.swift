// MetricCard.swift
// Vaux

import SwiftUI
import Charts

/// Reusable metric card with icon, title, value, optional subtitle,
/// optional trend chip, and optional sparkline.
struct MetricCard: View {
    let icon: String
    let title: String
    let value: String
    var subtitle: String? = nil
    var trend: Trend? = nil
    var trendColor: Color? = nil
    var accentColor: Color = .recoveryGreen
    var sparkline: [Double]? = nil

    enum Trend {
        case up, down, flat
        case delta(String)

        var icon: String {
            switch self {
            case .up, .delta: return "arrow.up.right"
            case .down: return "arrow.down.right"
            case .flat: return "arrow.right"
            }
        }

        var label: String {
            switch self {
            case .up: return "up"
            case .down: return "down"
            case .flat: return "flat"
            case .delta(let s): return s
            }
        }

        var color: Color {
            switch self {
            case .up, .delta: return .recoveryGreen
            case .down: return .recoveryRed
            case .flat: return .textSecondary
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(accentColor.opacity(0.14))
                        .frame(width: 28, height: 28)
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(accentColor)
                }

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)

                Spacer()

                if let trend {
                    trendChip(trend)
                }
            }

            HStack(alignment: .bottom) {
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Spacer()

                if let sparkline, sparkline.count >= 2 {
                    sparklineView(sparkline)
                        .frame(width: 76, height: 28)
                }
            }

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .darkCard()
    }

    private func trendChip(_ trend: Trend) -> some View {
        let chipColor = trendColor ?? trend.color
        return HStack(spacing: 3) {
            Image(systemName: trend.icon)
                .font(.system(size: 9, weight: .bold))
            Text(trend.label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(chipColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(chipColor.opacity(0.14)))
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
                        colors: [accentColor.opacity(0.35), accentColor.opacity(0)],
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
            value: "7.2h",
            subtitle: "Deep 1.8h · REM 1.5h",
            trend: .up,
            accentColor: .accentBlue,
            sparkline: [6.8, 7.1, 6.5, 7.3, 7.0, 7.4, 7.2]
        )
        MetricCard(
            icon: "waveform.path.ecg",
            title: "HRV",
            value: "58 ms",
            subtitle: "7d avg: 54 ms",
            trend: .delta("+4"),
            accentColor: .recoveryGreen,
            sparkline: [52, 48, 55, 51, 58, 54, 58]
        )
    }
    .padding()
    .background(Color.background)
}
