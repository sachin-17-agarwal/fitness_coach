// HistoryViewModel.swift
// Vaux
//
// Loads the raw rows once — sessions and sets across a 16-week window, the
// mesocycle position, recovery — places them on the block calendar, and hands
// the same placed data to each tab's reader. One fetch, four readings.

import Foundation
import Observation

@Observable
final class HistoryViewModel {
    private(set) var sessions: [WorkoutSession] = []
    private(set) var sets: [WorkoutSet] = []
    private(set) var calendar = BlockCalendar.empty
    private(set) var isLoading = true
    private(set) var errorMessage: String?
    private(set) var hasLoadedOnce = false

    let strength = StrengthViewModel()
    let training = TrainingBlockViewModel()
    let recovery = RecoveryInsightsViewModel()
    let weeklyVolume = WeeklyVolumeViewModel()

    static let windowDays = 16 * 7

    private let workoutService = WorkoutService()
    private let mesocycleService = MesocycleService()

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false; hasLoadedOnce = true }

        await ExerciseCatalog.shared.loadIfNeeded()
        let state = try? await mesocycleService.loadState()

        let since = Calendar.current.date(byAdding: .day, value: -(Self.windowDays - 1), to: Calendar.current.startOfDay(for: Date())) ?? Date()
        do {
            async let fetchedSessions = workoutService.fetchSessionHistory(days: Self.windowDays)
            async let fetchedSets = workoutService.fetchSets(since: since)
            sessions = try await fetchedSessions
            sets = try await fetchedSets
        } catch {
            errorMessage = error.localizedDescription
        }

        calendar = BlockCalendar(sessions: sessions, state: state)
        strength.rebuild(sets: sets, sessions: sessions, calendar: calendar)
        training.rebuild(sets: sets, sessions: sessions, calendar: calendar)
        await recovery.load(sessions: sessions, calendar: calendar)
        await weeklyVolume.load()
    }

    /// Recovery re-reads on its own when the range chips change.
    func reloadRecovery() async {
        await recovery.load(sessions: sessions, calendar: calendar)
    }

    var hasAnyData: Bool { !sessions.isEmpty || !recovery.history.isEmpty }
}
