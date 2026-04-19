// ProgressionChart.swift
// Vaux
//
// Per-exercise strength curve across sessions.

import SwiftUI
import Charts

struct ProgressionChart: View {
    @State private var selectedExercise = ""
    @State private var setData: [WorkoutSet] = []
    @State private var availableExercises: [String] = []

    private let workoutService = WorkoutService()

    private var chartPoints: [TrendDataPoint] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"

        var bestByDate: [String: Double] = [:]
        for set in setData {
            if set.isWarmup == true { continue }
            guard let weight = set.actualWeightKg, weight > 0,
                  let dateStr = set.date else { continue }
            bestByDate[dateStr] = max(bestByDate[dateStr] ?? 0, weight)
        }

        return bestByDate.compactMap { dateStr, weight in
            guard let date = f.date(from: dateStr) else { return nil }
            return TrendDataPoint(date: date, value: weight)
        }
        .sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !availableExercises.isEmpty {
                exercisePicker
            }

            if chartPoints.count >= 2 {
                chart
            } else if !availableExercises.isEmpty {
                Text("Not enough data for \(selectedExercise)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textTertiary)
                    .frame(height: 160)
                    .frame(maxWidth: .infinity)
            } else {
                Text("No exercise data yet")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textTertiary)
                    .frame(height: 160)
                    .frame(maxWidth: .infinity)
            }
        }
        .darkCard(padding: 16, cornerRadius: 18)
        .task { await loadExercises() }
    }

    private var header: some View {
        HStack {
            Text("STRENGTH")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .kerning(1)
                .foregroundStyle(Color.textTertiary)
            Spacer()
            if let last = chartPoints.last {
                Text("\(Int(last.value)) kg")
                    .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.recoveryGreen)
            }
        }
    }

    private var exercisePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(availableExercises, id: \.self) { name in
                    Button {
                        Haptic.selection()
                        selectedExercise = name
                        Task { await loadSetsForExercise() }
                    } label: {
                        Text(name)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(selectedExercise == name ? .black : Color.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(selectedExercise == name ? AnyShapeStyle(Gradients.recovery) : AnyShapeStyle(Color.surface))
                            )
                    }
                }
            }
        }
    }

    private var chart: some View {
        Chart(chartPoints) { point in
            LineMark(
                x: .value("Date", point.date),
                y: .value("Weight", point.value)
            )
            .foregroundStyle(Color.recoveryGreen)
            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
            .interpolationMethod(.catmullRom)

            PointMark(
                x: .value("Date", point.date),
                y: .value("Weight", point.value)
            )
            .foregroundStyle(Color.recoveryGreen)
            .symbolSize(40)

            AreaMark(
                x: .value("Date", point.date),
                y: .value("Weight", point.value)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [Color.recoveryGreen.opacity(0.3), Color.recoveryGreen.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel().foregroundStyle(Color.textTertiary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .foregroundStyle(Color.textTertiary)
            }
        }
        .frame(height: 170)
    }

    private func loadExercises() async {
        availableExercises = (try? await workoutService.getDistinctExercises()) ?? []
        if let first = availableExercises.first, selectedExercise.isEmpty {
            selectedExercise = first
            await loadSetsForExercise()
        }
    }

    private func loadSetsForExercise() async {
        guard !selectedExercise.isEmpty else { return }
        setData = (try? await workoutService.getExerciseHistory(exercise: selectedExercise)) ?? []
    }
}
