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

    private let recoveryService = RecoveryService()
    private let mesocycleService = MesocycleService()
    private let workoutService = WorkoutService()

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
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
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
