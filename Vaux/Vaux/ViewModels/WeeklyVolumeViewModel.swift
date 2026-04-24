// WeeklyVolumeViewModel.swift
// Vaux
//
// Aggregates the trailing 14 days of `workout_sets` rows into per-day
// tonnage and per-muscle-group set counts for the History → Volume tab.
// Working sets only (warm-ups are excluded so the bars match the same
// definition the live stats bar uses during a session).

import Foundation
import Observation

struct DayTonnage: Identifiable, Hashable {
    let date: Date
    let tonnage: Double
    var id: Date { date }
}

struct MuscleGroupVolume: Identifiable, Hashable {
    let group: String
    let setCount: Int
    let tonnage: Double
    var id: String { group }
}

@Observable
final class WeeklyVolumeViewModel {
    private(set) var tonnageByDay: [DayTonnage] = []
    private(set) var setsByMuscleGroup: [MuscleGroupVolume] = []
    /// % change in tonnage vs. the prior 7 days. `nil` when the prior
    /// week has no data (avoids divide-by-zero noise on a fresh user).
    private(set) var tonnageDeltaPct: Double?
    private(set) var thisWeekTonnage: Double = 0
    private(set) var thisWeekSets: Int = 0
    private(set) var isLoading = false
    private(set) var hasLoadedOnce = false

    private let workoutService = WorkoutService()

    func load() async {
        isLoading = true
        defer { isLoading = false }

        await ExerciseCatalog.shared.loadIfNeeded()

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let weekStart = calendar.date(byAdding: .day, value: -6, to: today),
              let priorWeekStart = calendar.date(byAdding: .day, value: -13, to: today) else {
            return
        }

        let allSets: [WorkoutSet]
        do {
            allSets = try await workoutService.fetchSets(since: priorWeekStart)
        } catch {
            print("[WeeklyVolume] fetch failed: \(error.localizedDescription)")
            allSets = []
        }

        // Working sets only — warm-ups (is_warmup == true) inflate the
        // tonnage bars without representing real training stimulus.
        let working = allSets.filter { $0.isWarmup != true }

        let dayFormatter = Self.dateFormatter
        var thisWeekByDay: [Date: Double] = [:]
        var thisWeekByGroup: [String: (count: Int, tonnage: Double)] = [:]
        var thisWeekTonnageTotal: Double = 0
        var thisWeekSetsTotal: Int = 0
        var priorWeekTonnage: Double = 0

        for set in working {
            guard let dateStr = set.date,
                  let setDay = dayFormatter.date(from: dateStr) else { continue }
            let weight = set.actualWeightKg ?? set.targetWeightKg ?? 0
            let reps = set.actualReps ?? set.targetReps ?? 0
            let tonnage = weight * Double(reps)
            guard tonnage > 0 else { continue }

            if setDay >= weekStart {
                thisWeekByDay[setDay, default: 0] += tonnage
                thisWeekTonnageTotal += tonnage
                thisWeekSetsTotal += 1
                let group = ExerciseCatalog.shared.muscleGroup(for: set.exercise) ?? "Other"
                var bucket = thisWeekByGroup[group] ?? (0, 0)
                bucket.count += 1
                bucket.tonnage += tonnage
                thisWeekByGroup[group] = bucket
            } else if setDay >= priorWeekStart {
                priorWeekTonnage += tonnage
            }
        }

        // Always emit a row per day in the trailing 7-day window so the
        // chart shows a full week even on rest days.
        var days: [DayTonnage] = []
        for offset in (0...6).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            days.append(DayTonnage(date: day, tonnage: thisWeekByDay[day] ?? 0))
        }
        tonnageByDay = days

        setsByMuscleGroup = thisWeekByGroup
            .map { MuscleGroupVolume(group: $0.key, setCount: $0.value.count, tonnage: $0.value.tonnage) }
            .sorted { $0.setCount > $1.setCount }

        thisWeekTonnage = thisWeekTonnageTotal
        thisWeekSets = thisWeekSetsTotal

        if priorWeekTonnage > 0 {
            tonnageDeltaPct = ((thisWeekTonnageTotal - priorWeekTonnage) / priorWeekTonnage) * 100
        } else {
            tonnageDeltaPct = nil
        }

        hasLoadedOnce = true
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
}
