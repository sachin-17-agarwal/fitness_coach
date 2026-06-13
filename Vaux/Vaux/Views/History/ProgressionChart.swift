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
                Text("NOT ENOUGH DATA FOR \(selectedExercise.uppercased())")
                    .font(.eyebrowSmall)
                    .kerning(1.2)
                    .foregroundStyle(Color.fg3)
                    .multilineTextAlignment(.center)
                    .frame(height: 160)
                    .frame(maxWidth: .infinity)
            } else {
                Text("NO EXERCISE DATA YET")
                    .font(.eyebrowSmall)
                    .kerning(1.2)
                    .foregroundStyle(Color.fg3)
                    .frame(height: 160)
                    .frame(maxWidth: .infinity)
            }
        }
        .darkCard(padding: 16, cornerRadius: 18)
        .task { await loadExercises() }
    }

    private var header: some View {
        HStack {
            Eyebrow(text: "Strength")
            Spacer()
            if let last = chartPoints.last {
                Text("\(Int(last.value)) kg")
                    .font(.numSM)
                    .foregroundStyle(Color.signal)
            }
        }
    }

    private var exercisePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(availableExercises, id: \.self) { name in
                    let isSelected = selectedExercise == name
                    Button {
                        Haptic.selection()
                        selectedExercise = name
                        Task { await loadSetsForExercise() }
                    } label: {
                        Text(name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.signal : Color.fg1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.signal.opacity(0.08) : Color.ink3)
                            )
                            .overlay(
                                Capsule()
                                    .stroke(isSelected ? Color.signal.opacity(0.22) : Color.line, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
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
            .foregroundStyle(Color.signal)
            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
            .interpolationMethod(.catmullRom)
            .shadow(color: Color.signal.opacity(0.45), radius: 4, y: 2)

            PointMark(
                x: .value("Date", point.date),
                y: .value("Weight", point.value)
            )
            .foregroundStyle(Color.signal)
            .symbolSize(point.id == chartPoints.last?.id ? 70 : 36)

            if point.id == chartPoints.last?.id {
                PointMark(
                    x: .value("Date", point.date),
                    y: .value("Weight", point.value)
                )
                .foregroundStyle(.white)
                .symbolSize(22)
                .annotation(position: .top, spacing: 6) {
                    Text("\(Int(point.value))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced).monospacedDigit())
                        .foregroundStyle(Color.ink0)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.signal.opacity(0.9))
                        )
                }
            }

            AreaMark(
                x: .value("Date", point.date),
                y: .value("Weight", point.value)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [Color.signal.opacity(0.16), Color.signal.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel()
                    .foregroundStyle(Color.fg3)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                AxisGridLine()
                    .foregroundStyle(Color.line.opacity(0.7))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .foregroundStyle(Color.fg3)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
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
