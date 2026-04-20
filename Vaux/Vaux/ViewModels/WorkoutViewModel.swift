// WorkoutViewModel.swift
// Vaux

import Foundation
import Observation
import UIKit

enum SetPhase: String {
    case warmup = "Warm-up"
    case working = "Working"
    case backoff = "Back-off"
}

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
    var warmupCount = 0
    var sessionDuration: TimeInterval = 0
    var startTime: Date?

    // Coach feedback
    var coachNote: String?
    var isCoachThinking = false

    // Set input state
    var inputWeight: Double = 0
    var inputReps: Int = 8
    var inputRPE: Double = 8.0

    // Set phase tracking — which part of the prescription we're in
    var currentPhase: SetPhase = .warmup
    var phaseSetIndex = 0
    var exerciseSetIndex = 0
    var exerciseSetsForCurrentExercise: [WorkoutSet] = []

    var isCurrentSetWarmup: Bool { currentPhase == .warmup }

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
                applyAIResponse(response)
            } catch {
                print("Coach prescription failed: \(error)")
            }
        }
        isLoading = false
    }

    func logSet() async {
        guard let session = currentSession, let sessionId = session.id else { return }
        errorMessage = nil

        // Snapshot the phase *before* we advance — the label below must describe
        // the set the user just logged, not the next prescribed phase.
        let loggedPhase = currentPhase
        let isWarmup = loggedPhase == .warmup
        let exercise = currentPrescription?.exerciseName ?? "Unknown"

        if !isWarmup {
            setCount += 1
        } else {
            warmupCount += 1
        }
        exerciseSetIndex += 1

        do {
            let set = try await workoutService.logSet(
                sessionId: sessionId,
                exercise: exercise,
                setNumber: isWarmup ? warmupCount : setCount,
                weight: inputWeight,
                reps: inputReps,
                rpe: isWarmup ? nil : inputRPE,
                isWarmup: isWarmup
            )
            loggedSets.append(set)
            exerciseSetsForCurrentExercise.append(set)
            if !isWarmup {
                totalTonnage += inputWeight * Double(inputReps)
            }
        } catch {
            if !isWarmup { setCount -= 1 } else { warmupCount -= 1 }
            exerciseSetIndex -= 1
            errorMessage = "Failed to log set: \(error.localizedDescription)"
            return
        }

        // PR check only for working sets
        if !isWarmup {
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
        }

        // Advance to next target in the prescription
        advancePhase()

        // Rest timer — shorter for warm-ups
        let rest = isWarmup ? 60 : (currentPrescription?.restSeconds ?? 120)
        startRestTimer(seconds: rest)

        // AI feedback
        isCoachThinking = true
        let label: String
        switch loggedPhase {
        case .warmup:  label = "warm-up"
        case .working: label = "working"
        case .backoff: label = "back-off"
        }
        let setMsg = "Logged \(label): \(exercise) - \(inputWeight.weightString) x \(inputReps)\(isWarmup ? "" : " @ RPE \(inputRPE.oneDecimal)"). Set \(exerciseSetIndex) for this exercise, \(setCount) working sets total. What's next?"
        do {
            let response = try await chatService.sendMessage(setMsg)
            applyAIResponse(response)
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
            applyAIResponse(response)
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

    // MARK: - Phase progression

    private func advancePhase() {
        guard let rx = currentPrescription else { return }
        phaseSetIndex += 1

        switch currentPhase {
        case .warmup:
            if phaseSetIndex >= rx.warmupSets.count {
                if !rx.workingSets.isEmpty {
                    currentPhase = .working
                    phaseSetIndex = 0
                } else if !rx.backoffSets.isEmpty {
                    currentPhase = .backoff
                    phaseSetIndex = 0
                }
            }
        case .working:
            if phaseSetIndex >= rx.workingSets.count {
                if !rx.backoffSets.isEmpty {
                    currentPhase = .backoff
                    phaseSetIndex = 0
                }
            }
        case .backoff:
            break
        }

        prefillFromCurrentTarget()
    }

    private func prefillFromCurrentTarget() {
        guard let rx = currentPrescription else { return }

        switch currentPhase {
        case .warmup:
            if phaseSetIndex < rx.warmupSets.count {
                let target = rx.warmupSets[phaseSetIndex]
                inputWeight = target.weight
                inputReps = target.reps
                inputRPE = 6.0
            }
        case .working:
            if phaseSetIndex < rx.workingSets.count {
                let target = rx.workingSets[phaseSetIndex]
                inputWeight = target.weight
                inputReps = target.reps
                inputRPE = target.rpe ?? 8.0
            } else if let first = rx.workingSets.first {
                inputWeight = first.weight
                inputReps = first.reps
                inputRPE = first.rpe ?? 8.0
            }
        case .backoff:
            if phaseSetIndex < rx.backoffSets.count {
                let target = rx.backoffSets[phaseSetIndex]
                inputWeight = target.weight
                inputReps = target.reps
                inputRPE = target.rpe ?? 7.0
            } else if let first = rx.backoffSets.first {
                inputWeight = first.weight
                inputReps = first.reps
                inputRPE = first.rpe ?? 7.0
            }
        }
    }

    // MARK: - AI response handling

    private func applyAIResponse(_ chatResponse: ChatResponse) {
        let text = chatResponse.response
        let oldExercise = currentPrescription?.exerciseName

        // Prefer server-side parsed prescription, fall back to client-side regex
        if let serverRx = chatResponse.prescription {
            let rx = ExercisePrescription(
                exerciseName: serverRx.exercise,
                warmupSets: (serverRx.warmup ?? []).map { ($0.weight, $0.reps) },
                workingSets: (serverRx.working ?? []).map { ($0.weight, $0.reps, $0.rpe) },
                backoffSets: (serverRx.backoff ?? []).map { ($0.weight, $0.reps, $0.rpe) },
                formCue: serverRx.form,
                tempo: serverRx.tempo,
                restSeconds: Self.parseRestString(serverRx.rest)
            )
            allPrescriptions = [rx]
            currentPrescription = rx
        } else {
            allPrescriptions = PrescriptionParser.parse(text)
            if let rx = allPrescriptions.first {
                currentPrescription = rx
            }
        }

        if let rx = currentPrescription {
            if rx.exerciseName != oldExercise {
                exerciseSetIndex = 0
                exerciseSetsForCurrentExercise = []
                phaseSetIndex = 0
                currentPhase = rx.warmupSets.isEmpty ? .working : .warmup
            }
            prefillFromCurrentTarget()
        }

        coachNote = PrescriptionParser.extractCoachNote(text)
    }

    private static func parseRestString(_ rest: String?) -> Int? {
        guard let rest else { return nil }
        let lower = rest.lowercased().trimmingCharacters(in: .whitespaces)
        if let match = lower.range(of: #"(\d+)\s*min"#, options: .regularExpression) {
            let digits = lower[match].filter(\.isNumber)
            if let mins = Int(digits) { return mins * 60 }
        }
        if let match = lower.range(of: #"(\d+)\s*s"#, options: .regularExpression) {
            let digits = lower[match].filter(\.isNumber)
            if let secs = Int(digits) { return secs }
        }
        if let num = Int(lower) { return num < 10 ? num * 60 : num }
        return nil
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
        warmupCount = 0
        exerciseSetIndex = 0
        exerciseSetsForCurrentExercise = []
        phaseSetIndex = 0
        currentPhase = .warmup
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
