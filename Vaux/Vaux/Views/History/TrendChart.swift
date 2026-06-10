// TrendChart.swift
// Vaux

import SwiftUI
import Charts

struct TrendDataPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

struct TrendChart: View {
    let title: String
    let data: [TrendDataPoint]
    let color: Color
    let unit: String

    private var sorted: [TrendDataPoint] {
        data.sorted { $0.date < $1.date }
    }

    private var delta: Double? {
        guard let first = sorted.first, let last = sorted.last, first.id != last.id else { return nil }
        return last.value - first.value
    }

    private var yDomain: ClosedRange<Double> {
        let values = sorted.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let span = max(hi - lo, 1)
        let pad = max(span * 0.15, 1)
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(color.opacity(0.14))
                            Image(systemName: iconForTitle)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(color)
                        }
                        .frame(width: 24, height: 24)

                        Text(title.uppercased())
                            .font(.eyebrow)
                            .kerning(1.2)
                            .foregroundStyle(Color.fg2)
                    }

                    if let latest = sorted.last {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(latest.value.oneDecimal)
                                .font(.numLG)
                                .foregroundStyle(Color.fg0)
                            Text(unit)
                                .font(.eyebrow)
                                .foregroundStyle(color)
                        }
                    }
                }

                Spacer()

                if let delta {
                    deltaChip(delta)
                }
            }

            if sorted.count >= 2 {
                Chart(sorted) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .interpolationMethod(.catmullRom)
                    .shadow(color: color.opacity(0.4), radius: 4, y: 2)

                    if point.id == sorted.last?.id {
                        PointMark(
                            x: .value("Date", point.date),
                            y: .value("Value", point.value)
                        )
                        .foregroundStyle(.white)
                        .symbolSize(30)

                        PointMark(
                            x: .value("Date", point.date),
                            y: .value("Value", point.value)
                        )
                        .foregroundStyle(color)
                        .symbolSize(60)
                        .annotation(position: .top, spacing: 6) {
                            Text(point.value.oneDecimal)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced).monospacedDigit())
                                .foregroundStyle(Color.ink0)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(color.opacity(0.85))
                                )
                        }
                    }

                    AreaMark(
                        x: .value("Date", point.date),
                        yStart: .value("Baseline", yDomain.lowerBound),
                        yEnd: .value("Value", point.value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            stops: [
                                .init(color: color.opacity(0.12), location: 0),
                                .init(color: color.opacity(0.03), location: 0.6),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }
                .chartYScale(domain: yDomain)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                            .foregroundStyle(Color.fg2)
                            .font(.system(size: 10))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                        AxisValueLabel()
                            .foregroundStyle(Color.fg2)
                            .font(.system(size: 10))
                        AxisGridLine()
                            .foregroundStyle(Color.line)
                    }
                }
                .frame(height: 150)
            } else {
                Text("Not enough data")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.fg2)
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.ink2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.line, lineWidth: 1)
        )
    }

    private var iconForTitle: String {
        switch title.lowercased() {
        case "hrv": return "waveform.path.ecg"
        case "resting hr": return "heart.fill"
        case "weight": return "scalemass.fill"
        default: return "chart.line.uptrend.xyaxis"
        }
    }

    private func deltaChip(_ delta: Double) -> some View {
        let up = delta >= 0
        let chipColor = up ? Color.mint : Color.ember
        return HStack(spacing: 4) {
            Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 10, weight: .bold))
            Text("\(up ? "+" : "")\(delta.oneDecimal)")
                .font(.system(size: 11, weight: .medium, design: .monospaced).monospacedDigit())
        }
        .foregroundStyle(chipColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(chipColor.opacity(0.12))
        )
        .overlay(
            Capsule().stroke(chipColor.opacity(0.25), lineWidth: 0.5)
        )
    }
}
