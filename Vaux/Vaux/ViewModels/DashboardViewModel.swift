// DashboardViewModel.swift
// FitnessCoach

import Foundation
import Observation

@Observable
final class DashboardViewModel {
    var recovery: Recovery?
    var hrvHistory: [Recovery] = []
    var hrvAvg: Double?
    var rhrAvg: Double?
    var mesocycle: MesocycleState = MesocycleState(day: 1, week: 1)
    var isLoading = true
    var errorMessage: String?

    private let recoveryService = RecoveryService()
    private let mesocycleService = MesocycleService()

    /// Computed recovery score 0-100 based on HRV relative to 7-day average.
    var recoveryScore: Int {
        guard let hrv = recovery?.hrv, let avg = hrvAvg, avg > 0 else { return 0 }
        let ratio = hrv / avg
        let score = min(100, max(0, Int(ratio * 100)))
        return score
    }

    /// Recovery color based on HRV vs average.
    var recoveryColor: RecoveryLevel {
        guard let hrv = recovery?.hrv, let avg = hrvAvg, avg > 0 else { return .unknown }
        let ratio = hrv / avg
        if ratio >= 1.0 { return .green }
        if ratio >= 0.9 { return .yellow }
        return .red
    }

    enum RecoveryLevel {
        case green, yellow, red, unknown
    }

    func load() async {
        isLoading = true
        errorMessage = nil

        do {
            async let latestRecovery = recoveryService.fetchLatest()
            async let history = recoveryService.fetchHistory(days: 7)
            async let averages = recoveryService.fetch7DayAverages()
            async let mesoState = mesocycleService.loadState()

            recovery = try await latestRecovery
            hrvHistory = try await history
            let avgs = try await averages
            hrvAvg = avgs.hrvAvg
            rhrAvg = avgs.rhrAvg
            mesocycle = try await mesoState
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
