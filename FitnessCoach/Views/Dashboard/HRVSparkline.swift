// HRVSparkline.swift
// FitnessCoach

import SwiftUI
import Charts

/// A sparkline chart showing the last 7 days of HRV data with today's
/// point highlighted and a dashed line for the 7-day average.
struct HRVSparkline: View {
    let history: [Recovery]
    let average: Double?

    /// Data points sorted chronologically for charting.
    private var chartData: [(date: String, hrv: Double)] {
        history
            .compactMap { r -> (String, Double)? in
                guard let hrv = r.hrv else { return nil }
                return (r.date, hrv)
            }
            .sorted { $0.0 < $1.0 }
    }

    private var todayDate: String {
        RecoveryService.todayString()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.recoveryGreen)

                Text("HRV Trend")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.textSecondary)

                Spacer()

                if let avg = average {
                    Text("Avg: \(Int(avg)) ms")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                }
            }

            if chartData.isEmpty {
                Text("No HRV data available")
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
            } else {
                Chart {
                    // HRV line
                    ForEach(chartData, id: \.date) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("HRV", point.hrv)
                        )
                        .foregroundStyle(Color.recoveryGreen)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.catmullRom)

                        // Area under curve
                        AreaMark(
                            x: .value("Date", point.date),
                            y: .value("HRV", point.hrv)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.recoveryGreen.opacity(0.3), Color.recoveryGreen.opacity(0.0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)

                        // Highlight today's point
                        if point.date == todayDate {
                            PointMark(
                                x: .value("Date", point.date),
                                y: .value("HRV", point.hrv)
                            )
                            .foregroundStyle(Color.recoveryGreen)
                            .symbolSize(60)
                            .annotation(position: .top, spacing: 4) {
                                Text("\(Int(point.hrv))")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                    }

                    // 7-day average dashed line
                    if let avg = average {
                        RuleMark(y: .value("Average", avg))
                            .foregroundStyle(Color.textSecondary.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic) { value in
                        if let dateStr = value.as(String.self) {
                            AxisValueLabel {
                                Text(shortDate(dateStr))
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.textSecondary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text("\(Int(v))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.textSecondary)
                            }
                        }
                        AxisGridLine()
                            .foregroundStyle(Color.cardBorder)
                    }
                }
                .frame(height: 120)
            }
        }
        .darkCard()
    }

    /// Converts "2026-04-18" to "Apr 18" for axis labels.
    private func shortDate(_ dateString: String) -> String {
        let parts = dateString.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return dateString }

        let months = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                       "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard month >= 1, month <= 12 else { return dateString }
        return "\(months[month]) \(day)"
    }
}

#Preview {
    let sampleHistory: [Recovery] = [
        Recovery(date: "2026-04-12", hrv: 45),
        Recovery(date: "2026-04-13", hrv: 52),
        Recovery(date: "2026-04-14", hrv: 48),
        Recovery(date: "2026-04-15", hrv: 55),
        Recovery(date: "2026-04-16", hrv: 50),
        Recovery(date: "2026-04-17", hrv: 58),
        Recovery(date: "2026-04-18", hrv: 62),
    ]
    HRVSparkline(history: sampleHistory, average: 52.8)
        .padding()
        .background(Color.background)
}
