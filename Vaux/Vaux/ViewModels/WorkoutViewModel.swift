// WorkoutViewModel.swift
// FitnessCoach

import Foundation
import Observation
import UIKit

@Observable
final class WorkoutViewModel {
    // Session state
    var isActive = false
    var sessionType = ""
    var currentSession: WorkoutSession?
    var loggedSets: [WorkoutSet] = []
    var currentPrescription: ExercisePrescription?
    var allPrescriptions: [ExercisePrescription] = []
    var coachMessages: [ChatMessage] = []
    var totalTonnage: Double = 0
    var setCount = 0
    var sessionDuration: TimeInterval = 0
    var startTime: Date?

    // Set input state
    var inputWeight: Double = 0
    var inputReps: Int = 8
    var inputRPE: Double = 8.0

    // Rest timer
    var restTimeRemaining: Int = 0
    var isResting = false

    // PR
    var latestPR: PRResult?
    var showPRCelebration = false

    // Inline chat
    var inlineChatText = ""
    var showInlineChat = false

    // Summary
    var summary: WorkoutSummary?
    var showSummary = false

    // Loading
    var isLoading = false

    // Error
    var errorMessage: String?

    private let workoutService = WorkoutService()
    private let chatService = ChatService()
    private let mesocycleService = MesocycleService()
    private var durationTimer: Timer?
    private var restTimer: Timer?

    func startWorkout(type: String) async {
        sessionType = type
        isActive = true
        isLoading = true
        startTime = Date()
        errorMessage = nil

        do {
            currentSession = try await workoutService.startSession(type: type)

            // Ask AI for the workout prescription
            let prompt = "I'm starting my \(type) session. Please prescribe my exercises with sets, reps, weight, and RPE targets."
            let response = try await chatService.sendMessage(prompt)

            let assistantMsg = ChatMessage(
                id: UUID(),
                date: RecoveryService.todayString(),
                role: "assistant",
                content: response.response,
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            coachMessages.append(assistantMsg)

            // Parse prescriptions
            allPrescriptions = PrescriptionParser.parse(response.response)
            currentPrescription = allPrescriptions.first

            // Pre-fill input from prescription
            if let rx = currentPrescription {
                inputWeight = rx.targetWeightKg ?? 0
                inputReps = rx.targetReps ?? 8
                inputRPE = rx.targetRpe ?? 8.0
            }

            startDurationTimer()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func logSet() async {
        guard let session = currentSession, let sessionId = session.id else { return }
        isLoading = true

        setCount += 1
        let exercise = currentPrescription?.exerciseName ?? "Unknown"

        do {
            let set = try await workoutService.logSet(
                sessionId: sessionId,
                exercise: exercise,
                setNumber: setCount,
                weight: inputWeight,
                reps: inputReps,
                rpe: inputRPE
            )
            loggedSets.append(set)
            totalTonnage += inputWeight * Double(inputReps)

            // Check PR
            let prResult = try await workoutService.checkPR(
                exercise: exercise,
                weight: inputWeight,
                reps: inputReps
            )
            if prResult.isPR {
                latestPR = prResult
                showPRCelebration = true
                triggerHaptic(.success)

                // Auto-dismiss PR celebration
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    self?.showPRCelebration = false
                }
            }

            // Send set log to AI for feedback
            let setMsg = "Logged: \(exercise) - \(inputWeight.weightString) x \(inputReps) @ RPE \(inputRPE.oneDecimal). Set \(setCount). What's next?"
            let response = try await chatService.sendMessage(setMsg)

            let assistantMsg = ChatMessage(
                id: UUID(),
                date: RecoveryService.todayString(),
                role: "assistant",
                content: response.response,
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            coachMessages.append(assistantMsg)

            // Update prescription from response
            let newPrescriptions = PrescriptionParser.parse(response.response)
            if let next = newPrescriptions.first {
                currentPrescription = next
                inputWeight = next.targetWeightKg ?? inputWeight
                inputReps = next.targetReps ?? inputReps
                inputRPE = next.targetRpe ?? inputRPE
            }

            // Start rest timer
            let rest = currentPrescription?.restSeconds ?? 120
            startRestTimer(seconds: rest)

        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func sendInlineMessage() async {
        let text = inlineChatText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let userMsg = ChatMessage(
            id: UUID(),
            date: RecoveryService.todayString(),
            role: "user",
            content: text,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        coachMessages.append(userMsg)
        inlineChatText = ""

        do {
            let response = try await chatService.sendMessage(text)
            let assistantMsg = ChatMessage(
                id: UUID(),
                date: RecoveryService.todayString(),
                role: "assistant",
                content: response.response,
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            coachMessages.append(assistantMsg)

            let newPrescriptions = PrescriptionParser.parse(response.response)
            if let next = newPrescriptions.first {
                currentPrescription = next
                inputWeight = next.targetWeightKg ?? inputWeight
                inputReps = next.targetReps ?? inputReps
                inputRPE = next.targetRpe ?? inputRPE
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func endWorkout() async {
        guard let session = currentSession, let sessionId = session.id else { return }

        stopTimers()

        do {
            let result = try await workoutService.endSession(id: sessionId)
            summary = WorkoutSummary(
                tonnage: totalTonnage,
                totalSets: setCount,
                duration: sessionDuration,
                prs: latestPR != nil ? [latestPR!] : []
            )
            showSummary = true
            try await mesocycleService.advance()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startRestTimer(seconds: Int) {
        restTimeRemaining = seconds
        isResting = true
        restTimer?.invalidate()
        restTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.restTimeRemaining > 0 {
                self.restTimeRemaining -= 1
            } else {
                self.isResting = false
                timer.invalidate()
                self.triggerHaptic(.warning)
            }
        }
    }

    func skipRest() {
        restTimer?.invalidate()
        isResting = false
        restTimeRemaining = 0
    }

    func updateDuration() {
        guard let start = startTime else { return }
        sessionDuration = Date().timeIntervalSince(start)
    }

    func dismissSummary() {
        showSummary = false
        isActive = false
        resetState()
    }

    // MARK: - Private

    private func startDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateDuration()
        }
    }

    private func stopTimers() {
        durationTimer?.invalidate()
        restTimer?.invalidate()
    }

    private func resetState() {
        currentSession = nil
        loggedSets = []
        currentPrescription = nil
        allPrescriptions = []
        coachMessages = []
        totalTonnage = 0
        setCount = 0
        sessionDuration = 0
        startTime = nil
        latestPR = nil
        summary = nil
    }

    private func triggerHaptic(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(type)
    }

    var formattedDuration: String {
        let minutes = Int(sessionDuration) / 60
        let seconds = Int(sessionDuration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var formattedTonnage: String {
        if totalTonnage >= 1000 {
            return String(format: "%.1fk kg", totalTonnage / 1000)
        }
        return "\(Int(totalTonnage)) kg"
    }
}
