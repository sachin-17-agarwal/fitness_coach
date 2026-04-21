// TrendChart.swift
// Vaux
//
// Reusable trend card with gradient line + area for a single metric.

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

    /// Chronological (oldest → newest) view of `data`. Callers sometimes pass
    /// points in newest-first order (the recovery history API returns
    /// `date.desc`), which would otherwise cause the header to show the
    /// oldest reading as "latest" and invert the delta sign.
    private var sorted: [TrendDataPoint] {
        data.sorted { $0.date < $1.date }
    }

    private var delta: Double? {
        guard let first = sorted.first, let last = sorted.last, first.id != last.id else { return nil }
        return last.value - first.value
    }

    /// Tight Y-axis domain around the observed range. `.automatic(includesZero: false)`
    /// still snapped weight (values in the 80s) to a 0–100 range, flattening
    /// the line. Picking a data-hugging domain keeps every metric readable.
    private var yDomain: ClosedRange<Double> {
        let values = sorted.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let span = max(hi - lo, 1)
        let pad = max(span * 0.15, 1)
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .kerning(1)
                        .foregroundStyle(Color.textTertiary)
                    if let latest = sorted.last {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(latest.value.oneDecimal)
                                .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white)
                            Text(unit)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.textSecondary)
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
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color.opacity(0.35), color.opacity(0)],
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
                            .foregroundStyle(Color.textTertiary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                        AxisValueLabel()
                            .foregroundStyle(Color.textTertiary)
                    }
                }
                .frame(height: 130)
            } else {
                Text("Not enough data")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textTertiary)
                    .frame(height: 130)
                    .frame(maxWidth: .infinity)
            }
        }
        .darkCard(padding: 16, cornerRadius: 18)
    }

    private func deltaChip(_ delta: Double) -> some View {
        let up = delta >= 0
        let icon = up ? "arrow.up.right" : "arrow.down.right"
        let sign = up ? "+" : ""
        return HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text("\(sign)\(delta.oneDecimal)")
                .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}
