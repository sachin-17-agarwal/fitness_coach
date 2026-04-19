// HRVSparkline.swift
// Vaux

import SwiftUI
import Charts

/// A 7-day HRV trend card.
struct HRVSparkline: View {
    let history: [Recovery]
    let average: Double?

    private var chartData: [(date: String, hrv: Double)] {
        history
            .compactMap { r -> (String, Double)? in
                guard let hrv = r.hrv else { return nil }
                return (r.date, hrv)
            }
            .sorted { $0.0 < $1.0 }
            .suffix(14)
            .map { $0 }
    }

    private var todayDate: String { RecoveryService.todayString() }

    private var todayValue: Double? { chartData.first(where: { $0.date == todayDate })?.hrv }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if chartData.isEmpty {
                emptyState
            } else {
                chart
            }
        }
        .darkCard(padding: 18, cornerRadius: 20)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("HRV TREND")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .kerning(1.2)
                    .foregroundStyle(Color.textSecondary)

                if let today = todayValue {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(Int(today))")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("ms")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.textSecondary)
                    }
                }
            }
            Spacer()
            if let avg = average {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("7D AVG")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .kerning(1.0)
                        .foregroundStyle(Color.textTertiary)
                    Text("\(Int(avg)) ms")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(chartData, id: \.date) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("HRV", point.hrv)
                )
                .foregroundStyle(Color.recoveryGreen)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)

                AreaMark(
                    x: .value("Date", point.date),
                    y: .value("HRV", point.hrv)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.recoveryGreen.opacity(0.32), Color.recoveryGreen.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                if point.date == todayDate {
                    PointMark(
                        x: .value("Date", point.date),
                        y: .value("HRV", point.hrv)
                    )
                    .foregroundStyle(Color.recoveryGreen)
                    .symbolSize(90)
                }
            }

            if let avg = average {
                RuleMark(y: .value("avg", avg))
                    .foregroundStyle(Color.textSecondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 100)
    }

    private var emptyState: some View {
        HStack {
            Image(systemName: "waveform.path.ecg")
                .foregroundStyle(Color.textTertiary)
            Text("No HRV data yet — sync Apple Health")
                .font(.system(size: 13))
                .foregroundStyle(Color.textTertiary)
            Spacer()
        }
        .frame(height: 100)
    }
}
