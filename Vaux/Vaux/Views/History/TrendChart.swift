// TrendChart.swift
// Vaux
//
// Recovery trend card: mono header with a time-range selector, serif
// latest value with delta chip, and a glowing line chart with a labelled
// endpoint.

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

    @State private var range: ChartRange = .all

    enum ChartRange: String, CaseIterable {
        case days30 = "30D"
        case days90 = "90D"
        case all = "ALL"

        var cutoffDays: Int? {
            switch self {
            case .days30: return 30
            case .days90: return 90
            case .all: return nil
            }
        }
    }

    private var sorted: [TrendDataPoint] {
        data.sorted { $0.date < $1.date }
    }

    /// Points within the selected range.
    private var visible: [TrendDataPoint] {
        guard let days = range.cutoffDays,
              let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())
        else { return sorted }
        return sorted.filter { $0.date >= cutoff }
    }

    private var delta: Double? {
        guard let first = visible.first, let last = visible.last, first.id != last.id else { return nil }
        return last.value - first.value
    }

    private var yDomain: ClosedRange<Double> {
        let values = visible.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let span = max(hi - lo, 1)
        let pad = max(span * 0.15, 1)
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Image(systemName: iconForTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(color)
                    Text(title.uppercased())
                        .font(.eyebrow)
                        .kerning(1.2)
                        .foregroundStyle(Color.fg2)
                }

                Spacer()

                rangeSelector
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let latest = visible.last {
                    Text(latest.value.oneDecimal)
                        .font(.serifLG)
                        .foregroundStyle(Color.fg0)
                    Text(unit.uppercased())
                        .font(.eyebrow)
                        .kerning(0.8)
                        .foregroundStyle(color)
                }
                Spacer()
                if let delta {
                    deltaChip(delta)
                }
            }

            if visible.count >= 2 {
                chart
            } else {
                Text("NOT ENOUGH DATA IN THIS RANGE")
                    .font(.eyebrowSmall)
                    .kerning(1.2)
                    .foregroundStyle(Color.fg3)
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
            }
        }
        .darkCard(padding: 18, cornerRadius: 22)
    }

    // MARK: - Range selector

    private var rangeSelector: some View {
        HStack(spacing: 2) {
            ForEach(ChartRange.allCases, id: \.self) { option in
                let isSelected = range == option
                Button {
                    Haptic.selection()
                    withAnimation(Motion.snappy) { range = option }
                } label: {
                    Text(option.rawValue)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .kerning(0.8)
                        .foregroundStyle(isSelected ? color : Color.fg2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(isSelected ? color.opacity(0.10) : Color.clear)
                        )
                        .overlay(
                            Capsule().stroke(isSelected ? color.opacity(0.25) : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.ink1.opacity(0.8)))
        .overlay(Capsule().stroke(Color.line, lineWidth: 1))
    }

    // MARK: - Chart

    private var chart: some View {
        Chart(visible) { point in
            LineMark(
                x: .value("Date", point.date),
                y: .value("Value", point.value)
            )
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
            .interpolationMethod(.catmullRom)
            .shadow(color: color.opacity(0.45), radius: 4, y: 2)

            if point.id == visible.last?.id {
                PointMark(
                    x: .value("Date", point.date),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(color)
                .symbolSize(70)

                PointMark(
                    x: .value("Date", point.date),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(.white)
                .symbolSize(22)
                .annotation(position: .top, spacing: 6) {
                    Text(point.value.oneDecimal)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced).monospacedDigit())
                        .foregroundStyle(Color.ink0)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(color.opacity(0.9))
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
                        .init(color: color.opacity(0.14), location: 0),
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
                    .foregroundStyle(Color.fg3)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel()
                    .foregroundStyle(Color.fg3)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                AxisGridLine()
                    .foregroundStyle(Color.line.opacity(0.7))
            }
        }
        .frame(height: 150)
        .animation(Motion.smooth, value: range)
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
