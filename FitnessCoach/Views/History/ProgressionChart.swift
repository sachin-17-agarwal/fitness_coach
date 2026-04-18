import SwiftUI
import Charts

struct ProgressionChart: View {
    let sessions: [WorkoutSession]
    @State private var selectedExercise = ""
    @State private var setData: [WorkoutSet] = []
    @State private var availableExercises: [String] = []

    private let workoutService = WorkoutService()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Strength Progression")
                .font(.headline)
                .foregroundColor(.white)

            if !availableExercises.isEmpty {
                Picker("Exercise", selection: $selectedExercise) {
                    ForEach(availableExercises, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color.recoveryGreen)
                .onChange(of: selectedExercise) {
                    Task { await loadSetsForExercise() }
                }
            }

            let chartPoints = setData.compactMap { set -> TrendDataPoint? in
                guard let weight = set.actualWeightKg else { return nil }
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                guard let dateStr = set.date, let date = formatter.date(from: dateStr) else { return nil }
                return TrendDataPoint(date: date, value: weight)
            }

            if chartPoints.count >= 2 {
                Chart(chartPoints) { point in
                    PointMark(
                        x: .value("Date", point.date),
                        y: .value("Weight", point.value)
                    )
                    .foregroundStyle(Color.recoveryGreen)

                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Weight", point.value)
                    )
                    .foregroundStyle(Color.recoveryGreen)
                    .interpolationMethod(.catmullRom)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis {
                    AxisMarks(position: .trailing) { _ in
                        AxisValueLabel()
                            .foregroundStyle(.gray)
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                            .foregroundStyle(.gray)
                    }
                }
                .frame(height: 200)
            } else {
                Text("Select an exercise to see progression")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .modifier(DarkCardStyle())
        .task { await loadExercises() }
    }

    private func loadExercises() async {
        var exercises = Set<String>()
        for session in sessions {
            guard let id = session.id else { continue }
            if let sets = try? await workoutService.fetchSets(sessionId: id) {
                for s in sets { exercises.insert(s.exercise) }
            }
        }
        availableExercises = exercises.sorted()
        if let first = availableExercises.first {
            selectedExercise = first
            await loadSetsForExercise()
        }
    }

    private func loadSetsForExercise() async {
        guard !selectedExercise.isEmpty else { return }
        setData = (try? await workoutService.getLastSessionSets(exercise: selectedExercise)) ?? []
    }
}
