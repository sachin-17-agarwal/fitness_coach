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

    private var delta: Double? {
        guard data.count >= 2,
              let first = data.first?.value,
              let last = data.last?.value else { return nil }
        return last - first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1)
                        .foregroundColor(Color.textSecondary)

                    if let latest = data.last {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(latest.value.oneDecimal)
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            Text(unit)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(Color.textSecondary)
                        }
                    }
                }

                Spacer()

                if let delta {
                    HStack(spacing: 3) {
                        Image(systemName: delta >= 0 ? "arrow.down.right" : "arrow.down.right")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(delta >= 0 ? -90 : 0))
                        Text("\(delta >= 0 ? "+" : "")\(delta.oneDecimal)")
                            .font(.system(size: 12, weight: .bold).monospacedDigit())
                    }
                    .foregroundStyle(delta >= 0 ? Color.recoveryGreen : Color.recoveryRed)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background((delta >= 0 ? Color.recoveryGreen : Color.recoveryRed).opacity(0.12))
                    .clipShape(Capsule())
                }
            }

            if data.count >= 2 {
                Chart(data) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color.opacity(0.25), color.opacity(0.05), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                            .foregroundStyle(Color.textSecondary)
                            .font(.system(size: 10))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                        AxisValueLabel()
                            .foregroundStyle(Color.textSecondary)
                            .font(.system(size: 10))
                        AxisGridLine()
                            .foregroundStyle(Color.cardBorder)
                    }
                }
                .frame(height: 140)
            } else {
                Text("Not enough data")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
            }
        }
        .darkCard()
    }
}
