// DashboardViewModel.swift
// Vaux

import Foundation
import Observation

@Observable
final class DashboardViewModel {
    var recovery: Recovery?
    var recoveryHistory: [Recovery] = []
    var hrvHistory: [Recovery] = []
    var hrvAvg: Double?
    var rhrAvg: Double?
    var mesocycle: MesocycleState = MesocycleState(day: 1, week: 1)
    var recentSessions: [WorkoutSession] = []
    var currentStreak: Int = 0
    var weekTonnage: Double = 0
    var isLoading = true
    var errorMessage: String?
    /// Today's coach note, when the briefing flow has already generated one.
    /// Read from cache only — see BriefingService.cachedCoachNoteForToday.
    var briefingNote: String?

    private let recoveryService = RecoveryService()
    private let mesocycleService = MesocycleService()
    private let workoutService = WorkoutService()
    private let briefingService = BriefingService()

    /// Composite recovery score 0-100 combining sleep, HRV, and resting HR.
    var recoveryScore: Int {
        recovery?.compositeScore(hrv7DayAvg: hrvAvg, rhr7DayAvg: rhrAvg) ?? 0
    }

    var recoveryColor: RecoveryLevel {
        guard let score = recovery?.compositeScore(hrv7DayAvg: hrvAvg, rhr7DayAvg: rhrAvg) else {
            return .unknown
        }
        if score >= 75 { return .green }
        if score >= 55 { return .yellow }
        return .red
    }

    /// Most recent non-null body weight across the recovery history. Today's
    /// row may have `weightKg == nil` on days without a weigh-in, so fall
    /// back through prior days instead of hiding the metric card.
    var latestWeightKg: Double? {
        recoveryHistory.compactMap(\.weightKg).first
    }

    /// Most recent non-null body-fat reading — same fallback logic as weight.
    var latestBodyFatPct: Double? {
        recoveryHistory.compactMap(\.bodyFatPct).first
    }

    /// HRV delta vs 7-day avg — string like "+3 ms" / "-2 ms".
    var hrvDeltaText: String {
        guard let hrv = recovery?.hrv, let avg = hrvAvg else { return "" }
        let diff = Int(hrv - avg)
        if diff > 0 { return "+\(diff) ms vs avg" }
        if diff < 0 { return "\(diff) ms vs avg" }
        return "on baseline"
    }

    enum RecoveryLevel {
        case green, yellow, red, unknown
    }

    func load() async {
        isLoading = true
        errorMessage = nil

        do {
            async let latestRecovery = recoveryService.fetchLatest()
            async let history = recoveryService.fetchHistory(days: 14)
            async let averages = recoveryService.fetch7DayAverages()
            async let mesoState = mesocycleService.loadState()
            async let sessions = workoutService.fetchSessionHistory(days: 14)

            recovery = try await latestRecovery
            recoveryHistory = try await history
            hrvHistory = recoveryHistory
            let avgs = try await averages
            hrvAvg = avgs.hrvAvg
            rhrAvg = avgs.rhrAvg
            mesocycle = try await mesoState
            recentSessions = try await sessions

            currentStreak = Self.computeStreak(recentSessions)
            weekTonnage = Self.weekTonnage(recentSessions)
            briefingNote = briefingService.cachedCoachNoteForToday()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Swaps today's session for `type`, or restores the schedule when passed
    /// nil. Reloads the state afterwards so the card reflects what was stored
    /// rather than what was requested.
    func setTodayOverride(_ type: String?) async {
        do {
            try await mesocycleService.setTodayOverride(type)
            mesocycle = try await mesocycleService.loadState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Refreshes only the mesocycle slice. Called when Settings (or
    /// `MesocycleService.advance()` after a workout) posts
    /// `.mesocycleDidChange` — a full `load()` would needlessly re-pull
    /// recovery and history for what's really a one-field update.
    func refreshMesocycle() async {
        if let state = try? await mesocycleService.loadState() {
            mesocycle = state
        }
    }

    // MARK: - Home-screen derivations

    /// The verdict color for a composite score, shared by the hero numeral,
    /// the verdict line, the history strip and the mesocycle wave.
    static func level(for score: Int?) -> RecoveryLevel {
        guard let score else { return .unknown }
        if score >= 75 { return .green }
        if score >= 55 { return .yellow }
        return .red
    }

    /// One bar per day for the 14-day strip, oldest first, each carrying the
    /// zone it landed in so the strip reads as verdict history, not a shape.
    var historyBars: [(score: Int, level: RecoveryLevel)] {
        recoveryHistory
            .reversed()
            .suffix(14)
            .map { rec in
                let score = rec.compositeScore(hrv7DayAvg: hrvAvg, rhr7DayAvg: rhrAvg)
                return (score ?? 0, Self.level(for: score))
            }
    }

    /// Today's session if it has been finished — the home screen stops
    /// asking to START and shows the recap instead.
    var todayFinishedSession: WorkoutSession? {
        let today = RecoveryService.todayString()
        return recentSessions.first { $0.date == today && SessionStatus($0.status).isFinished }
    }

    /// Finished sessions in the trailing 7 days.
    var sessionsThisWeek: Int {
        let cutoff = Self.dayCutoff(daysAgo: 6)
        return recentSessions.filter {
            SessionStatus($0.status).isFinished && (Self.day(of: $0.date) ?? .distantPast) >= cutoff
        }.count
    }

    /// Tonnage change vs the 7 days before this week. nil when the prior week
    /// has no tonnage, so a fresh account doesn't read as +infinity.
    var tonnageDeltaPct: Double? {
        let thisStart = Self.dayCutoff(daysAgo: 6)
        let priorStart = Self.dayCutoff(daysAgo: 13)
        let prior = recentSessions
            .filter { s in
                guard let d = Self.day(of: s.date) else { return false }
                return d >= priorStart && d < thisStart
            }
            .compactMap(\.tonnageKg)
            .reduce(0, +)
        guard prior > 0 else { return nil }
        return (weekTonnage - prior) / prior * 100
    }

    /// Average sleep over the trailing 7 days, and the change against the 7
    /// before that, in minutes.
    var sleepAvgHours: Double? { Self.average(sleep(daysAgo: 0...6)) }
    var sleepDeltaMinutes: Int? {
        guard let now = sleepAvgHours, let prior = Self.average(sleep(daysAgo: 7...13)) else { return nil }
        return Int(((now - prior) * 60).rounded())
    }

    /// Latest weight against the oldest reading in the 14-day window.
    var weightDeltaKg: Double? {
        let weights = recoveryHistory.compactMap(\.weightKg)
        guard let latest = weights.first, let oldest = weights.last, weights.count >= 2 else { return nil }
        return latest - oldest
    }

    private func sleep(daysAgo range: ClosedRange<Int>) -> [Double] {
        let newest = Self.dayCutoff(daysAgo: range.lowerBound)
        let oldest = Self.dayCutoff(daysAgo: range.upperBound)
        return recoveryHistory.compactMap { rec in
            guard let d = Self.day(of: rec.date), d >= oldest, d <= newest else { return nil }
            return rec.sleepHours
        }
    }

    private static func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func day(of string: String) -> Date? {
        dayFormatter.date(from: string).map { Calendar.current.startOfDay(for: $0) }
    }

    private static func dayCutoff(daysAgo: Int) -> Date {
        let d = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return Calendar.current.startOfDay(for: d)
    }

    // MARK: - Streak / tonnage

    /// Returns the number of consecutive days ending today that have at least
    /// one completed workout session. Zero if today has no workout yet.
    private static func computeStreak(_ sessions: [WorkoutSession]) -> Int {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let workoutDates = Set(sessions.compactMap { f.date(from: $0.date) }.map(Calendar.current.startOfDay(for:)))

        let today = Calendar.current.startOfDay(for: Date())
        var cursor = today
        var streak = 0
        while workoutDates.contains(cursor) {
            streak += 1
            guard let prev = Calendar.current.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    /// Tonnage across sessions from the last 7 calendar days.
    private static func weekTonnage(_ sessions: [WorkoutSession]) -> Double {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let cutoff = Calendar.current.date(byAdding: .day, value: -6, to: Date())!
        let cutoffDay = Calendar.current.startOfDay(for: cutoff)
        return sessions
            .compactMap { session -> Double? in
                guard let date = f.date(from: session.date),
                      Calendar.current.startOfDay(for: date) >= cutoffDay else { return nil }
                return session.tonnageKg
            }
            .reduce(0, +)
    }
}
