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

    /// Everything in `allPrescriptions` after the one we're currently working on.
    var upcomingPrescriptions: [ExercisePrescription] {
        Array(allPrescriptions.dropFirst())
    }
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

    // Live heart rate (streams from HealthKit while workout is active)
    let heartRateMonitor = HeartRateMonitor()

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
        heartRateMonitor.start(from: startTime ?? Date())

        var issues: [String] = []

        do {
            currentSession = try await workoutService.startSession(type: type)
        } catch {
            issues.append("Couldn't save the session (\(error.localizedDescription)). You'll see today's plan, but logged sets won't persist until you retry.")
        }

        // Always ask the coach for the plan — even if the Supabase session-create
        // call failed, we still want the user to see today's exercises instead
        // of a blank screen.
        do {
            let prompt = "Starting my \(type) session. List today's full exercise plan first (every exercise with sets/reps/weight/RPE in the strict format), then prescribe the first exercise in detail so I can warm up."
            let response = try await chatService.sendMessage(prompt)
            applyAIResponse(response)
        } catch {
            issues.append("Coach didn't respond (\(error.localizedDescription)). Pull down or tap End and try again.")
        }

        if !issues.isEmpty {
            errorMessage = issues.joined(separator: " ")
        }
        isLoading = false
    }

    /// Reuses an in-progress session for `type` if one already exists today
    /// (e.g. opened earlier via the cardio logger on a Cardio+Abs day) so
    /// strength work for abs gets logged against the same session row
    /// instead of creating a duplicate. Falls back to `startWorkout` when
    /// nothing is open.
    func startOrResumeWorkout(type: String) async {
        if let existing = await fetchInProgressSession(type: type) {
            await resume(session: existing)
        } else {
            await startWorkout(type: type)
        }
    }

    /// Resume-only variant used when the view remounts (e.g. after an
    /// accidental back-swipe): if there's already an in-progress session for
    /// today's type, hydrate into it. Does NOT create a new session when
    /// nothing's open — that still requires an explicit "Begin session" tap.
    func resumeIfInProgress(type: String) async {
        guard !isActive, !showSummary, !type.isEmpty else { return }
        guard let existing = await fetchInProgressSession(type: type) else { return }
        await resume(session: existing)
    }

    private func fetchInProgressSession(type: String) async -> WorkoutSession? {
        let today = Self.todayString()
        let sessions: [WorkoutSession]? = try? await SupabaseClient.shared.fetch(
            "workout_sessions",
            query: [
                "date": "eq.\(today)",
                "type": "eq.\(type)",
                "status": "eq.in_progress",
            ],
            order: "start_time.desc",
            limit: 1
        )
        return sessions?.first
    }

    private func resume(session: WorkoutSession) async {
        sessionType = session.type
        currentSession = session
        isActive = true
        isLoading = true
        errorMessage = nil
        if let startStr = session.startTime,
           let start = ISO8601DateFormatter().date(from: startStr) {
            startTime = start
        } else {
            startTime = Date()
        }
        startDurationTimer()
        heartRateMonitor.start(from: startTime ?? Date())

        // Hydrate tonnage / set counters from sets already persisted in this
        // session so the live stats bar reflects what's already logged.
        // Cardio/yoga entries live in the same session but use `actual_reps`
        // as a duration — filter them out so they don't inflate `setCount`
        // or `tonnage` for the strength portion.
        if let id = session.id {
            if let existing = try? await workoutService.fetchSets(sessionId: id) {
                let strengthOnly = existing.filter { set in
                    let note = (set.notes ?? "").lowercased()
                    return !note.hasPrefix("cardio") && !note.hasPrefix("yoga")
                }
                loggedSets = strengthOnly
                for set in strengthOnly {
                    if set.isWarmup == true {
                        warmupCount += 1
                    } else {
                        setCount += 1
                        let w = set.actualWeightKg ?? 0
                        let r = Double(set.actualReps ?? 0)
                        totalTonnage += w * r
                    }
                }
            }
        }

        // For the abs flow, ask the coach for an abs exercise prescription
        // rather than a full-session plan.
        let prompt: String
        if session.type == "Cardio+Abs" {
            prompt = "I've finished cardio for my \(session.type) session. Prescribe the first abs exercise in detail — sets, reps, weight, RPE, rest."
        } else {
            prompt = "Resuming my \(session.type) session. Resend today's full plan and prescribe the next exercise."
        }
        do {
            let response = try await chatService.sendMessage(prompt)
            applyAIResponse(response)
        } catch {
            errorMessage = "Coach didn't respond (\(error.localizedDescription))."
        }
        isLoading = false
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    private static func todayString() -> String {
        dateFormatter.string(from: Date())
    }

    /// Re-requests today's plan from the coach without creating a new session.
    /// Used as a manual retry when `startWorkout` left the screen empty.
    func retryPrescription() async {
        guard isActive else { return }
        isLoading = true
        errorMessage = nil
        do {
            let prompt = "Resend today's \(sessionType) plan — full exercise list followed by the first exercise in detail."
            let response = try await chatService.sendMessage(prompt)
            applyAIResponse(response)
        } catch {
            errorMessage = "Coach didn't respond (\(error.localizedDescription))."
        }
        isLoading = false
    }

    func logSet() async {
        guard let session = currentSession, let sessionId = session.id else {
            errorMessage = "Session not saved — tap End and Begin session again to retry."
            return
        }
        // Refuse to persist a set when we don't yet know what exercise is
        // current — otherwise the backend ends up with orphan "Unknown" rows
        // if the user races the prescription load.
        guard let rawExercise = currentPrescription?.exerciseName,
              !rawExercise.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Waiting on the coach's prescription — try again once the exercise card loads."
            return
        }
        errorMessage = nil

        // Snapshot the phase *before* we advance — the label below must describe
        // the set the user just logged, not the next prescribed phase.
        let loggedPhase = currentPhase
        let isWarmup = loggedPhase == .warmup
        let exercise = PrescriptionParser.normalizeExerciseName(rawExercise)

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
                setNumber: exerciseSetIndex,
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
        heartRateMonitor.stop()

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
            prs: latestPR != nil ? [latestPR!] : [],
            avgHR: heartRateMonitor.avgBPM,
            maxHR: heartRateMonitor.maxBPM,
            minHR: heartRateMonitor.minBPM
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

        // Server-side parser only ever returns the first exercise it finds,
        // so we always also run the client parser — it handles multi-exercise
        // responses like the full session plan we now ask for on start.
        let clientParsed = PrescriptionParser.parse(text)

        var prescriptions: [ExercisePrescription] = []
        if let serverRx = chatResponse.prescription {
            let rx = ExercisePrescription(
                exerciseName: PrescriptionParser.normalizeExerciseName(serverRx.exercise),
                warmupSets: (serverRx.warmup ?? []).map { ($0.weight, $0.reps) },
                workingSets: (serverRx.working ?? []).map { ($0.weight, $0.reps, $0.rpe) },
                backoffSets: (serverRx.backoff ?? []).map { ($0.weight, $0.reps, $0.rpe) },
                formCue: serverRx.form,
                tempo: serverRx.tempo,
                restSeconds: Self.parseRestString(serverRx.rest)
            )
            prescriptions = [rx] + clientParsed.dropFirst()
        } else {
            prescriptions = clientParsed
        }

        if !prescriptions.isEmpty {
            allPrescriptions = prescriptions
            currentPrescription = prescriptions.first
        } else if let next = nextExerciseMentioned(in: text, after: oldExercise) {
            // Coach transitions without re-sending the full prescription
            // ("moving to calves…") — advance to the next known exercise so
            // the UI doesn't stay stuck on the previous card.
            currentPrescription = next
            allPrescriptions = rearrangedPrescriptions(startingAt: next)
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

        // Always show *something* from the coach. extractCoachNote strips out
        // the structured lines; if nothing is left (e.g. the response didn't
        // match any expected format), fall back to the raw text so the user
        // doesn't stare at an empty screen.
        let note = PrescriptionParser.extractCoachNote(text)
        if let note, !note.isEmpty {
            coachNote = note
        } else if currentPrescription == nil {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            coachNote = trimmed.isEmpty ? nil : trimmed
        } else {
            coachNote = nil
        }
    }

    /// Looks for a mention of any upcoming exercise in the coach's narrative
    /// text. Ignores the currently-displayed exercise so a mere "great job on
    /// leg press" doesn't re-pin us to the same card.
    private func nextExerciseMentioned(
        in text: String,
        after current: String?
    ) -> ExercisePrescription? {
        let candidates = allPrescriptions
            .map(\.exerciseName)
            .filter { $0 != current }
        guard !candidates.isEmpty else { return nil }
        guard let matched = PrescriptionParser.detectExerciseTransition(
            in: text, candidates: candidates
        ) else { return nil }
        return allPrescriptions.first { $0.exerciseName == matched }
    }

    /// Moves `target` to the head of the prescription list while preserving
    /// the rest of the order, so the "up next" card stays consistent with
    /// whatever the coach just transitioned us into.
    private func rearrangedPrescriptions(startingAt target: ExercisePrescription) -> [ExercisePrescription] {
        guard let idx = allPrescriptions.firstIndex(where: { $0.exerciseName == target.exerciseName }) else {
            return allPrescriptions
        }
        var reordered = allPrescriptions
        let item = reordered.remove(at: idx)
        reordered.insert(item, at: 0)
        return reordered
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
