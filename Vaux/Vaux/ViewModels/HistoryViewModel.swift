// HistoryViewModel.swift
// FitnessCoach

import Foundation
import Observation

/// One training day's worth of session rows, keyed by "date|type".
struct SessionDay: Identifiable {
    let id: String
    let sessions: [WorkoutSession]
}

@Observable
final class HistoryViewModel {
    var sessions: [WorkoutSession] = []
    var recoveryHistory: [Recovery] = []
    var isLoading = true
    var errorMessage: String?

    /// Sessions collapsed to one entry per training day, preserving the
    /// order `sessions` arrived in (newest first). A Cardio+Abs day produces
    /// two rows — cardio finished, then abs started fresh — which is one
    /// day's training and should read as one entry, and should count once.
    var sessionsByDay: [SessionDay] {
        var order: [String] = []
        var groups: [String: [WorkoutSession]] = [:]
        for session in sessions {
            let key = "\(session.date)|\(session.type)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(session)
        }
        return order.compactMap { key in
            guard let rows = groups[key] else { return nil }
            return SessionDay(id: key, sessions: rows)
        }
    }

    /// Working sets across the whole 30-day window shown by this screen.
    ///
    /// This replaces a summary stat that summed a lazily-populated cache of
    /// sets belonging to expanded session cards — so it read 0 on load and
    /// climbed as cards were tapped open, reporting "sets in whatever you
    /// happened to expand" under the label "sets". SessionCard fetches and
    /// owns its own sets when expanded, so no shared cache is needed.
    var totalSetsInWindow: Int = 0

    let weeklyVolume = WeeklyVolumeViewModel()
    let muscleStrength = MuscleStrengthViewModel()

    private let workoutService = WorkoutService()
    private let recoveryService = RecoveryService()

    func load() async {
        isLoading = true
        errorMessage = nil

        do {
            async let fetchedSessions = workoutService.fetchSessionHistory(days: 30)
            async let fetchedRecovery = recoveryService.fetchHistory(days: 30)

            sessions = try await fetchedSessions
            recoveryHistory = try await fetchedRecovery
        } catch {
            errorMessage = error.localizedDescription
        }

        // Count working sets over the same 30 days the session list covers,
        // excluding warm-ups and the cardio/yoga rows that store duration in
        // the reps column.
        if let windowStart = Calendar.current.date(byAdding: .day, value: -29, to: Date()),
           let windowSets = try? await workoutService.fetchSets(since: windowStart) {
            totalSetsInWindow = windowSets.filter { set in
                let note = (set.notes ?? "").lowercased()
                return set.isWarmup != true
                    && !note.hasPrefix("cardio")
                    && !note.hasPrefix("yoga")
            }.count
        }

        // Volume and Strength roll up their own errors so a failure in
        // either doesn't block the Training/Recovery tabs from rendering.
        await weeklyVolume.load()
        await muscleStrength.load()

        isLoading = false
    }

}
