// HistoryViewModel.swift
// Vaux
//
// Loads the raw rows — sessions and sets across a four-block window, widened to twelve on request — the
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

    /// Four blocks load on open — enough for the current reading and its
    /// comparison — and the scrubber asks for the rest (twelve blocks) only
    /// when someone steps back past the earliest loaded block.
    static let initialBlocks = 4
    static let maxBlocks = 12
    private(set) var loadedBlocks = HistoryViewModel.initialBlocks
    private(set) var isLoadingEarlier = false
    var canLoadEarlier: Bool { loadedBlocks < Self.maxBlocks && !isLoadingEarlier }
    var windowDays: Int { loadedBlocks * Config.weeksPerBlock * 7 }

    private let workoutService = WorkoutService()
    private let mesocycleService = MesocycleService()

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false; hasLoadedOnce = true }

        await ExerciseCatalog.shared.loadIfNeeded()
        let state = try? await mesocycleService.loadState()

        await fetchWindow(state: state)
        strength.rebuild(sets: sets, sessions: sessions, calendar: calendar)
        training.rebuild(sets: sets, sessions: sessions, calendar: calendar)
        await recovery.load(sessions: sessions, calendar: calendar)
        await weeklyVolume.load()
    }

    /// Widens the window to the full twelve blocks and re-reads. The block
    /// on screen stays on screen: the Strength reader is re-pointed at the
    /// same block number after the rebuild.
    func loadEarlier() async {
        guard canLoadEarlier else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        let keep = strength.shown?.judged.block
        loadedBlocks = Self.maxBlocks
        let state = try? await mesocycleService.loadState()
        await fetchWindow(state: state)
        strength.rebuild(sets: sets, sessions: sessions, calendar: calendar)
        training.rebuild(sets: sets, sessions: sessions, calendar: calendar)
        if let keep { strength.show(block: keep) }
    }

    private func fetchWindow(state: MesocycleState?) async {
        let since = Calendar.current.date(byAdding: .day, value: -(windowDays - 1), to: Calendar.current.startOfDay(for: Date())) ?? Date()
        do {
            async let fetchedSessions = workoutService.fetchSessionHistory(days: windowDays)
            async let fetchedSets = workoutService.fetchSets(since: since)
            sessions = try await fetchedSessions
            sets = try await fetchedSets
        } catch {
            errorMessage = error.localizedDescription
        }
        calendar = BlockCalendar(sessions: sessions, state: state)
    }

    /// Recovery re-reads on its own when the range chips change.
    func reloadRecovery() async {
        await recovery.load(sessions: sessions, calendar: calendar)
    }

    var hasAnyData: Bool { !sessions.isEmpty || !recovery.history.isEmpty }
}
