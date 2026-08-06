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
    /// Sets per week, fractionally attributed and normalised over 14 days.
    ///
    /// A Double, not an Int, because a set now divides across the muscles
    /// that do the work — a row gives Back 1.0 and Biceps 0.5. And "per
    /// week" rather than "this week": the rotation is four days rolling
    /// through six training days, so a 7-day window never holds a whole
    /// number of rotations and every muscle oscillated 2x depending on
    /// where the week fell. Fourteen days holds exactly three of each
    /// session, so halving it gives a figure that means the same thing
    /// every day and is comparable to the target bands.
    let setsPerWeek: Double
    let tonnage: Double
    var id: String { group }
}

@Observable
final class WeeklyVolumeViewModel {
    private(set) var tonnageByDay: [DayTonnage] = []
    private(set) var setsByMuscleGroup: [MuscleGroupVolume] = []
    /// Strength exercises logged this week that have no `muscle_group`
    /// in the catalog. Surfaced so the user can see which logged names
    /// aren't being matched and either fix the name or add the catalog
    /// entry. Sorted by set count descending.
    private(set) var uncategorizedExercises: [(name: String, setCount: Int)] = []
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
        var byGroupFortnight: [String: (sets: Double, tonnage: Double)] = [:]
        var unmatchedByExercise: [String: Int] = [:]
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

            // Per-day tonnage and the week totals stay on the trailing 7 days:
            // that chart is "what did I do this week", where a real week is
            // the right unit and the oscillation is the point.
            if setDay >= weekStart {
                thisWeekByDay[setDay, default: 0] += tonnage
                thisWeekTonnageTotal += tonnage
                thisWeekSetsTotal += 1
            } else if setDay >= priorWeekStart {
                priorWeekTonnage += tonnage
            }

            // Muscle-group volume spans the FULL fortnight, halved later.
            // Cardio/yoga entries are tagged in `notes` by CardioYogaLogView
            // and have no useful muscle-group mapping — exclude them entirely
            // from the strength breakdown.
            if Self.isCardioOrYoga(set) { continue }

            let contributions = ExerciseCatalog.shared.muscleContributions(for: set.exercise)
            if contributions.isEmpty {
                // Strength set with no catalog match. Track by display name
                // so the user can see which exercises need a catalog entry.
                // Only counted for the current week so the badge matches the
                // window the athlete is looking at.
                if setDay >= weekStart {
                    let name = set.exercise.trimmingCharacters(in: .whitespacesAndNewlines)
                    unmatchedByExercise[name, default: 0] += 1
                }
                continue
            }
            for (muscle, share) in contributions {
                var bucket = byGroupFortnight[muscle] ?? (0, 0)
                bucket.sets += share
                bucket.tonnage += tonnage * share
                byGroupFortnight[muscle] = bucket
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

        // Halve the fortnight to get a stable per-week figure.
        setsByMuscleGroup = byGroupFortnight
            .map {
                MuscleGroupVolume(
                    group: $0.key,
                    // One decimal: fractional attribution produces .5s and
                    // .8s that matter (6.8 hamstrings vs 6.0 rear delts).
                    setsPerWeek: (($0.value.sets / 2) * 10).rounded() / 10,
                    tonnage: $0.value.tonnage / 2
                )
            }
            .sorted { $0.setsPerWeek > $1.setsPerWeek }

        uncategorizedExercises = unmatchedByExercise
            .map { (name: $0.key, setCount: $0.value) }
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

    /// Cardio/yoga entries are tagged via the `notes` column on write
    /// (see `CardioYogaLogView`). Mirror the same detection used by
    /// `SessionCard` so they're excluded from the strength-volume bucket.
    private static func isCardioOrYoga(_ set: WorkoutSet) -> Bool {
        let note = (set.notes ?? "").lowercased()
        if note.hasPrefix("yoga") || note.contains(" yoga") { return true }
        if note.hasPrefix("cardio") || note.contains(" cardio") { return true }
        return false
    }
}
