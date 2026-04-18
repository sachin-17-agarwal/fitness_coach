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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                Spacer()
                if let latest = data.last {
                    Text("\(latest.value.oneDecimal) \(unit)")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundColor(color)
                }
            }

            if data.count >= 2 {
                Chart(data) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(color)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(color.opacity(0.1))
                    .interpolationMethod(.catmullRom)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                            .foregroundStyle(.gray)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                        AxisValueLabel()
                            .foregroundStyle(.gray)
                    }
                }
                .frame(height: 120)
            } else {
                Text("Not enough data")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .modifier(DarkCardStyle())
    }
}
