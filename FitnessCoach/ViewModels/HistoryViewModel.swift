// HistoryViewModel.swift
// FitnessCoach

import Foundation
import Observation

@Observable
final class HistoryViewModel {
    var sessions: [WorkoutSession] = []
    var recoveryHistory: [Recovery] = []
    var isLoading = true
    var errorMessage: String?

    // Expandable session detail
    var expandedSessionId: UUID?
    var sessionSets: [UUID: [WorkoutSet]] = [:]

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

        isLoading = false
    }

    func loadSetsForSession(_ sessionId: UUID) async {
        guard sessionSets[sessionId] == nil else { return }
        do {
            let sets = try await workoutService.fetchSets(sessionId: sessionId)
            sessionSets[sessionId] = sets
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleSession(_ sessionId: UUID) async {
        if expandedSessionId == sessionId {
            expandedSessionId = nil
        } else {
            expandedSessionId = sessionId
            await loadSetsForSession(sessionId)
        }
    }
}
