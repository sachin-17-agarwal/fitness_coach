// WorkoutViewModel.swift
// Vaux

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
    var totalTonnage: Double = 0
    var setCount = 0
    var sessionDuration: TimeInterval = 0
    var startTime: Date?

    // Coach feedback (compact note shown in UI, not full chat dump)
    var coachNote: String?
    var isCoachThinking = false

    // Set input state
    var inputWeight: Double = 0
    var inputReps: Int = 8
    var inputRPE: Double = 8.0

    // Exercise-level set tracking
    var exerciseSetIndex = 0
    var exerciseSetsForCurrentExercise: [WorkoutSet] = []

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

    // Loading (blocks start/end, NOT per-set logging)
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
        startDurationTimer()

        do {
            currentSession = try await workoutService.startSession(type: type)
        } catch {
            errorMessage = "Session create failed: \(error.localizedDescription)"
        }

        if currentSession != nil {
            do {
                let prompt = "I'm starting my \(type) session. Please prescribe my exercises with sets, reps, weight, and RPE targets."
                let response = try await chatService.sendMessage(prompt)
                applyAIResponse(response.response)
            } catch {
                print("Coach prescription failed: \(error)")
            }
        }
        isLoading = false
    }

    func logSet() async {
        guard let session = currentSession, let sessionId = session.id else { return }
        errorMessage = nil

        setCount += 1
        exerciseSetIndex += 1
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
            exerciseSetsForCurrentExercise.append(set)
            totalTonnage += inputWeight * Double(inputReps)
        } catch {
            setCount -= 1
            exerciseSetIndex -= 1
            errorMessage = "Failed to log set: \(error.localizedDescription)"
            return
        }

        // PR check (best-effort)
        do {
            let prResult = try await workoutService.checkPR(
                exercise: exercise,
                weight: inputWeight,
                reps: inputReps
            )
            if prResult.isPR {
                latestPR = prResult
                showPRCelebration = true
                triggerHaptic(.success)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    self?.showPRCelebration = false
                }
            }
        } catch {
            print("PR check failed: \(error)")
        }

        // Rest timer starts immediately
        let rest = currentPrescription?.restSeconds ?? 120
        startRestTimer(seconds: rest)

        // AI feedback in background — UI stays responsive
        isCoachThinking = true
        let setMsg = "Logged: \(exercise) - \(inputWeight.weightString) x \(inputReps) @ RPE \(inputRPE.oneDecimal). Set \(exerciseSetIndex) for this exercise, \(setCount) total. What's next?"
        do {
            let response = try await chatService.sendMessage(setMsg)
            applyAIResponse(response.response)
        } catch {
            print("Coach feedback failed: \(error)")
        }
        isCoachThinking = false
    }

    func sendInlineMessage() async {
        let text = inlineChatText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inlineChatText = ""
        isCoachThinking = true

        do {
            let response = try await chatService.sendMessage(text)
            applyAIResponse(response.response)
        } catch {
            errorMessage = error.localizedDescription
        }
        isCoachThinking = false
    }

    func endWorkout() async {
        stopTimers()

        if let session = currentSession, let sessionId = session.id {
            do {
                try await workoutService.endSession(id: sessionId)
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        summary = WorkoutSummary(
            tonnage: totalTonnage,
            totalSets: setCount,
            duration: sessionDuration,
            prs: latestPR != nil ? [latestPR!] : []
        )
        showSummary = true

        do {
            try await mesocycleService.advance()
        } catch {
            print("Mesocycle advance failed: \(error)")
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

    // MARK: - AI response handling

    private func applyAIResponse(_ text: String) {
        let oldExercise = currentPrescription?.exerciseName

        allPrescriptions = PrescriptionParser.parse(text)
        if let rx = allPrescriptions.first {
            currentPrescription = rx
            inputWeight = rx.targetWeightKg ?? inputWeight
            inputReps = rx.targetReps ?? inputReps
            inputRPE = rx.targetRpe ?? inputRPE

            // Reset exercise set counter when exercise changes
            if rx.exerciseName != oldExercise {
                exerciseSetIndex = 0
                exerciseSetsForCurrentExercise = []
            }
        }

        coachNote = PrescriptionParser.extractCoachNote(text)
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
        coachNote = nil
        totalTonnage = 0
        setCount = 0
        exerciseSetIndex = 0
        exerciseSetsForCurrentExercise = []
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
