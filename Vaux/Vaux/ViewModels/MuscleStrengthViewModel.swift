// MuscleStrengthViewModel.swift
// Vaux
//
// Aggregates the trailing 12 weeks of working sets into per-muscle-group
// estimated-1RM trends (how strength is moving for each muscle) plus a
// "what's lacking" readout. The readout combines four signals the athlete
// asked for: stalled strength, under-trained volume, neglected muscles,
// and push/pull (opposing-group) imbalance.
//
// The chart plots the best Epley estimated 1RM across a muscle's exercises
// per week — the same formula the PR check uses. The TREND, however, is
// computed per movement (recent 4-week best vs the prior 4 weeks of the
// same exercise, median across the group's movements) so that exercise
// rotation, deloads on one lift, or a different machine at another gym
// can't masquerade as a strength change.

import Foundation
import Observation

/// One weekly data point in a muscle's strength curve: the best estimated
/// 1RM (Epley) across that muscle's exercises in that week.
struct StrengthPoint: Identifiable, Hashable {
    let weekStart: Date
    let estimated1RM: Double
    var id: Date { weekStart }
}

/// Per-muscle strength summary over the analysis window.
struct MuscleStrength: Identifiable, Hashable {
    let group: String
    /// Weekly best e1RM series, oldest → newest. Empty when the muscle was
    /// only trained with bodyweight movements (no load to estimate from).
    let series: [StrengthPoint]
    /// Best e1RM in the recent window (last 4 weeks); 0 when none.
    let currentBest: Double
    /// % change of recent best vs the earlier-window best. nil when there
    /// isn't enough history to judge a trend (treated as "new", never
    /// flagged as stalled).
    let trendPct: Double?
    /// Working sets logged in the last 7 days.
    let setsThisWeek: Int
    /// Days since the most recent working set; nil if never trained in the
    /// window.
    let daysSinceTrained: Int?
    var id: String { group }
}

/// A muscle flagged in the "what's lacking" readout, with the reasons why.
struct LackingFlag: Identifiable, Hashable {
    let group: String
    let reasons: [String]
    var id: String { group }
}

@Observable
final class MuscleStrengthViewModel {
    private(set) var muscles: [MuscleStrength] = []
    private(set) var lacking: [LackingFlag] = []
    private(set) var isLoading = false
    private(set) var hasLoadedOnce = false

    /// Muscle groups with at least two weekly strength points, for the chart
    /// picker. Sorted by current best e1RM descending (heaviest first).
    var chartableGroups: [String] {
        muscles.filter { $0.series.count >= 2 }.map(\.group)
    }

    private let workoutService = WorkoutService()

    // 12-week analysis window; the most recent 4 weeks count as "recent" for
    // the trend comparison.
    private static let windowDays = 84
    private static let recentWeeks = 4

    // Flag thresholds. One rep at 10-12 reps moves an Epley e1RM by ~3%,
    // and machine stacks differ across the gyms the athlete rotates
    // through, so anything inside ±5% is measurement noise, not a trend —
    // the old -2% cutoff flagged "strength dropping" on a single missed rep.
    private static let stalledThresholdPct = 1.0   // < +1% over the window
    private static let droppingThresholdPct = -5.0 // beyond single-rep noise
    private static let neglectedDays = 10
    private static let imbalanceRatio = 0.6        // <60% of partner's sets

    // Opposing groups whose working-set volume should stay roughly balanced.
    private static let opposingPairs: [(String, String)] = [
        ("Chest", "Back"),
        ("Biceps", "Triceps"),
        ("Shoulders", "Rear Delts"),
    ]

    private static let coreGroups = [
        "Chest", "Back", "Shoulders", "Rear Delts",
        "Biceps", "Triceps", "Legs", "Calves", "Abs",
    ]

    func load() async {
        isLoading = true
        defer { isLoading = false }

        await ExerciseCatalog.shared.loadIfNeeded()

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let windowStart = calendar.date(byAdding: .day, value: -(Self.windowDays - 1), to: today),
              let weekStartCutoff = calendar.date(byAdding: .day, value: -6, to: today) else {
            return
        }

        let allSets: [WorkoutSet]
        do {
            allSets = try await workoutService.fetchSets(since: windowStart)
        } catch {
            print("[MuscleStrength] fetch failed: \(error.localizedDescription)")
            allSets = []
        }

        let working = allSets.filter { $0.isWarmup != true }
        let dayFormatter = Self.dateFormatter

        // group → weekIndex (0 == most recent week) → best e1RM that week.
        // Drives the chart series and the headline number.
        var bestByGroupWeek: [String: [Int: Double]] = [:]
        // group → exercise → weekIndex → best e1RM. Trends compare each
        // movement to ITSELF — pooling a group's exercises meant a switch
        // from heavy face pulls to light reverse flys read as a strength
        // collapse ("Rear Delts -48%") when it was just exercise selection.
        var bestByGroupExerciseWeek: [String: [String: [Int: Double]]] = [:]
        var lastTrained: [String: Date] = [:]
        var setsThisWeek: [String: Int] = [:]
        var setsInWindow: [String: Int] = [:]

        for set in working {
            if Self.isCardioOrYoga(set) { continue }
            guard let dateStr = set.date, let day = dayFormatter.date(from: dateStr) else { continue }
            guard let group = ExerciseCatalog.shared.muscleGroup(for: set.exercise) else { continue }

            // Volume / recency count every working set, even bodyweight ones.
            setsInWindow[group, default: 0] += 1
            if day >= weekStartCutoff { setsThisWeek[group, default: 0] += 1 }
            if let prev = lastTrained[group] {
                if day > prev { lastTrained[group] = day }
            } else {
                lastTrained[group] = day
            }

            // Strength series needs a real external load to estimate a 1RM.
            let weight = set.actualWeightKg ?? 0
            let reps = set.actualReps ?? 0
            guard weight > 0, reps > 0 else { continue }
            let e1rm = WorkoutService.epley1RM(weight: weight, reps: reps)
            let daysAgo = max(0, calendar.dateComponents([.day], from: day, to: today).day ?? 0)
            let weekIndex = daysAgo / 7
            var byWeek = bestByGroupWeek[group] ?? [:]
            byWeek[weekIndex] = max(byWeek[weekIndex] ?? 0, e1rm)
            bestByGroupWeek[group] = byWeek

            let exercise = PrescriptionParser.normalizeExerciseName(set.exercise)
            var byExercise = bestByGroupExerciseWeek[group] ?? [:]
            var exerciseWeeks = byExercise[exercise] ?? [:]
            exerciseWeeks[weekIndex] = max(exerciseWeeks[weekIndex] ?? 0, e1rm)
            byExercise[exercise] = exerciseWeeks
            bestByGroupExerciseWeek[group] = byExercise
        }

        var summaries: [MuscleStrength] = []
        let allGroups = Set(setsInWindow.keys).union(bestByGroupWeek.keys)
        for group in allGroups {
            let byWeek = bestByGroupWeek[group] ?? [:]
            // Convert week buckets (0 == most recent) into time-ascending points.
            let series: [StrengthPoint] = byWeek.keys.sorted(by: >).compactMap { wi in
                guard let e = byWeek[wi], e > 0,
                      let weekStart = calendar.date(byAdding: .day, value: -(wi * 7), to: today) else {
                    return nil
                }
                return StrengthPoint(weekStart: weekStart, estimated1RM: e)
            }

            let recentBest = Self.best(in: byWeek) { $0 < Self.recentWeeks }

            // Trend: per-exercise, equal-width windows (recent 4 weeks vs
            // the PRIOR 4 weeks), median across the group's movements.
            // The old group-level "recent 4 vs weeks 5-12" comparison was
            // biased negative — the max of 8 weeks is almost always higher
            // than the max of 4 — and blind to exercise switches. Exercises
            // without data in BOTH windows sit out rather than polluting
            // the trend.
            let exerciseTrends: [Double] = (bestByGroupExerciseWeek[group] ?? [:]).values.compactMap { weeks in
                let recent = Self.best(in: weeks) { $0 < Self.recentWeeks }
                let prior = Self.best(in: weeks) {
                    $0 >= Self.recentWeeks && $0 < Self.recentWeeks * 2
                }
                guard recent > 0, prior > 0 else { return nil }
                return (recent - prior) / prior * 100
            }
            let trendPct = Self.median(of: exerciseTrends)

            let days = lastTrained[group].map {
                max(0, calendar.dateComponents([.day], from: $0, to: today).day ?? 0)
            }

            summaries.append(MuscleStrength(
                group: group,
                series: series,
                currentBest: recentBest > 0 ? recentBest : (series.last?.estimated1RM ?? 0),
                trendPct: trendPct,
                setsThisWeek: setsThisWeek[group] ?? 0,
                daysSinceTrained: days
            ))
        }

        muscles = summaries.sorted { $0.currentBest > $1.currentBest }
        lacking = Self.computeLacking(summaries: summaries, setsInWindow: setsInWindow)
        hasLoadedOnce = true
    }

    // MARK: - Lacking analysis

    private static func computeLacking(
        summaries: [MuscleStrength],
        setsInWindow: [String: Int]
    ) -> [LackingFlag] {
        var reasons: [String: [String]] = [:]
        func add(_ group: String, _ reason: String) {
            reasons[group, default: []].append(reason)
        }

        let byGroup = Dictionary(uniqueKeysWithValues: summaries.map { ($0.group, $0) })

        for group in coreGroups {
            let s = byGroup[group]
            let days = s?.daysSinceTrained
            let neglected = (days == nil) || (days! >= neglectedDays)

            // Neglect subsumes low-volume, so only flag one of the two.
            if neglected {
                if let days {
                    add(group, "Not trained in \(days)d")
                } else {
                    add(group, "Not trained recently")
                }
            } else {
                let setsWk = s?.setsThisWeek ?? 0
                let target = targetRange(for: group)
                if setsWk < target.lowerBound {
                    add(group, "Low volume — \(setsWk) of \(target.lowerBound)+ sets")
                }
            }

            // Stalled / dropping strength — independent of volume.
            if let trend = s?.trendPct {
                if trend < droppingThresholdPct {
                    add(group, "Strength dropping \(Self.signedPct(trend))")
                } else if trend < stalledThresholdPct {
                    add(group, "Strength stalled")
                }
            }
        }

        // Imbalance between opposing groups, by working-set volume.
        for (a, b) in opposingPairs {
            let av = setsInWindow[a] ?? 0
            let bv = setsInWindow[b] ?? 0
            guard av > 0 || bv > 0 else { continue }
            if Double(av) < Double(bv) * imbalanceRatio {
                add(a, "Under-trained vs \(b)")
            } else if Double(bv) < Double(av) * imbalanceRatio {
                add(b, "Under-trained vs \(a)")
            }
        }

        return coreGroups.compactMap { g in
            guard let r = reasons[g], !r.isEmpty else { return nil }
            return LackingFlag(group: g, reasons: r)
        }
    }

    static func signedPct(_ pct: Double) -> String {
        String(format: "%@%.0f%%", pct >= 0 ? "+" : "", pct)
    }

    // MARK: - Helpers

    /// Best e1RM across the week buckets whose index satisfies `where`.
    private static func best(in byWeek: [Int: Double], where predicate: (Int) -> Bool) -> Double {
        byWeek.reduce(0.0) { acc, entry in
            predicate(entry.key) ? max(acc, entry.value) : acc
        }
    }

    /// Median, used to combine per-exercise trends into one group trend —
    /// robust to a single outlier movement (a deload week on one lift, a
    /// different machine at another gym) dominating the readout.
    private static func median(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Weekly set ranges tuned for the once-per-week Pull/Push/Legs split —
    /// mirrors the targets used by the Volume tab so the two tabs agree on
    /// what "enough" looks like.
    private static func targetRange(for group: String) -> ClosedRange<Int> {
        switch group.lowercased() {
        case "legs", "quads", "hamstrings", "glutes": return 8...14
        case "back", "chest": return 6...12
        case "shoulders": return 4...8
        case "biceps", "triceps": return 3...6
        case "rear delts": return 2...5
        case "abs", "core": return 3...8
        default: return 4...10
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    /// Cardio/yoga rows are tagged in `notes` on write; mirror the detection
    /// used elsewhere so they never enter the strength buckets.
    private static func isCardioOrYoga(_ set: WorkoutSet) -> Bool {
        let note = (set.notes ?? "").lowercased()
        if note.hasPrefix("yoga") || note.contains(" yoga") { return true }
        if note.hasPrefix("cardio") || note.contains(" cardio") { return true }
        return false
    }
}
