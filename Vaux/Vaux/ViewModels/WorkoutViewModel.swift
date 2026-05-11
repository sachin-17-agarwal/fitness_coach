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
        // the set the user just logged, not the next prescribed phase. Same
        // for the index into the phase: we use it to pull the prescription's
        // target for the *just-logged* set so the coach can compare actual vs
        // target without re-deriving it from history.
        let loggedPhase = currentPhase
        let loggedPhaseSetIndex = phaseSetIndex
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
        let phaseTotal: Int = {
            guard let rx = currentPrescription else { return 0 }
            switch loggedPhase {
            case .warmup:  return rx.warmupSets.count
            case .working: return rx.workingSets.count
            case .backoff: return rx.backoffSets.count
            }
        }()
        // Spell out *which* set inside the phase was just done ("warm-up 2 of 2")
        // so Claude can't mistake the running-set counter for a working-set
        // index — that misread was making it quote the working prescription's
        // weight × reps as the recap of a warm-up.
        let phaseProgress: String
        if phaseTotal > 0 {
            phaseProgress = "\(label) \(loggedPhaseSetIndex + 1) of \(phaseTotal)"
        } else {
            phaseProgress = label
        }
        let actual = "\(inputWeight.weightString) × \(inputReps)" + (isWarmup ? "" : " @ RPE \(inputRPE.oneDecimal)")
        let targetSuffix = formatTargetSuffix(
            phase: loggedPhase,
            phaseSetIndex: loggedPhaseSetIndex,
            isWarmup: isWarmup
        )
        // Tell the coach *exactly* what to prescribe next. Without this
        // hint, Claude would sometimes skip the back-off entirely and jump
        // to the next exercise after the working set — the post-advance
        // phase tracker on this side knows whether there's a phase left.
        let nextHint = nextPhaseHintForCoach(currentExercise: exercise)
        // Spell out actual vs target so the coach can't quote the prescription's
        // target as if it were the performed set. Claude was previously echoing
        // back the back-off prescription as the working-set result, and the
        // working set's target as a warm-up's actual.
        let setMsg = "Logged \(phaseProgress): \(exercise) — actual: \(actual)\(targetSuffix). \(setCount) working sets done so far. \(nextHint) Acknowledge the athlete's actual numbers (\(actual)) — do NOT echo any other phase's target as the result, and do NOT prescribe a different phase or exercise than the one named above. What's next?"
        // The next-phase decision belongs to the iOS phase tracker, not the
        // coach — pass `allowExerciseChange: false` so a stray "moving to
        // chest" in the response can't skip the back-off that's still owed.
        do {
            let response = try await chatService.sendMessage(setMsg)
            applyAIResponse(response, allowExerciseChange: false)
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

        let topWorkingSet = bestWorkingSet()
        summary = WorkoutSummary(
            tonnage: totalTonnage,
            totalSets: setCount,
            duration: sessionDuration,
            prs: latestPR != nil ? [latestPR!] : [],
            avgHR: heartRateMonitor.avgBPM,
            maxHR: heartRateMonitor.maxBPM,
            minHR: heartRateMonitor.minBPM,
            topExercise: topWorkingSet?.exercise,
            topExerciseWeight: topWorkingSet?.actualWeightKg,
            topExerciseReps: topWorkingSet?.actualReps
        )
        showSummary = true

        // The sheet renders immediately because `showSummary` already
        // fired through @Observable. Awaiting these in sequence here
        // means the recap card pops in once the chat call returns; the
        // sheet is already visible to the user.
        await fetchPostWorkoutRecap()

        do {
            try await mesocycleService.advance()
        } catch {
            print("Mesocycle advance failed: \(error)")
        }
    }

    /// Returns the heaviest working set logged this session, used to give
    /// the coach a concrete data point for the recap prompt.
    private func bestWorkingSet() -> WorkoutSet? {
        loggedSets
            .filter { $0.isWarmup != true }
            .max { lhs, rhs in
                let l = (lhs.actualWeightKg ?? 0) * Double(lhs.actualReps ?? 0)
                let r = (rhs.actualWeightKg ?? 0) * Double(rhs.actualReps ?? 0)
                return l < r
            }
    }

    private func fetchPostWorkoutRecap() async {
        guard var snapshot = summary, snapshot.totalSets > 0 else {
            // No working sets logged — clear the placeholder so the
            // recap card hides instead of spinning forever.
            summary?.coachRecap = ""
            return
        }
        let prompt = buildRecapPrompt(snapshot)
        do {
            let response = try await chatService.sendMessage(prompt)
            let trimmed = response.response.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            snapshot.coachRecap = trimmed
            summary = snapshot
        } catch {
            print("[Recap] coach call failed: \(error.localizedDescription)")
        }
    }

    private func buildRecapPrompt(_ s: WorkoutSummary) -> String {
        let mins = Int(s.duration / 60)
        var parts: [String] = [
            "I just finished a \(sessionType) session.",
            "\(s.totalSets) working sets, \(Int(s.tonnage))kg tonnage, \(mins) minutes.",
        ]
        if let avg = s.avgHR, let peak = s.maxHR {
            parts.append("Avg HR \(avg), peak \(peak).")
        }
        if let ex = s.topExercise, let w = s.topExerciseWeight, let r = s.topExerciseReps, w > 0, r > 0 {
            parts.append("Heaviest set: \(ex) \(Int(w))kg × \(r).")
        }
        if let pr = s.prs.first(where: \.isPR) {
            parts.append("New PR on \(pr.exercise) (est. 1RM \(Int(pr.estimated1RM))kg).")
        }
        parts.append("Give me a 2–3 sentence recap: what went well and one thing to adjust next time. No questions, no formatting.")
        return parts.joined(separator: " ")
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

    /// Whether every prescribed warm-up / working / back-off set on the
    /// current exercise has already been logged. Used by `applyAIResponse`
    /// to refuse the coach's attempts to skip ahead to a new exercise
    /// before the current one is finished — a recurring failure mode
    /// where Claude jumped from a working set straight to the next
    /// exercise, silently dropping the back-off from the session.
    private func isCurrentExerciseComplete() -> Bool {
        guard let rx = currentPrescription else { return true }
        let warmupsDone = exerciseSetsForCurrentExercise.filter { $0.isWarmup == true }.count
        let nonWarmupsDone = exerciseSetsForCurrentExercise.count - warmupsDone
        let totalNonWarmup = rx.workingSets.count + rx.backoffSets.count
        return warmupsDone >= rx.warmupSets.count && nonWarmupsDone >= totalNonWarmup
    }

    private func applyAIResponse(
        _ chatResponse: ChatResponse,
        allowExerciseChange: Bool = true
    ) {
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
            let newFirstName = prescriptions.first?.exerciseName
            let wantsDifferentExercise = newFirstName != oldExercise
            let blockChange = !allowExerciseChange
                && wantsDifferentExercise
                && !isCurrentExerciseComplete()
            if !blockChange {
                allPrescriptions = prescriptions
                currentPrescription = prescriptions.first
            } else {
                // Coach tried to skip ahead — keep the current prescription
                // so the back-off (or whichever phase is unfilled) stays on
                // screen. The coach's narrative still flows into the note
                // strip via `extractCoachNote` below.
                print("[Coach] Ignored premature exercise change: \(newFirstName ?? "?") (current=\(oldExercise ?? "?"))")
            }
        } else if allowExerciseChange || isCurrentExerciseComplete(),
                  let next = nextExerciseMentioned(in: text, after: oldExercise) {
            // Coach transitions without re-sending the full prescription
            // ("moving to calves…") — advance to the next known exercise so
            // the UI doesn't stay stuck on the previous card. Suppressed
            // mid-exercise after a logSet so the back-off can't be skipped
            // by a stray "moving on to chest" line in the narrative.
            currentPrescription = next
            allPrescriptions = rearrangedPrescriptions(startingAt: next)
        }

        if let rx = currentPrescription {
            if rx.exerciseName != oldExercise {
                exerciseSetIndex = 0
                exerciseSetsForCurrentExercise = []
            }
            // Re-derive the phase from what's already logged for this
            // exercise so a re-prescription that *adds* warm-ups or
            // back-offs (e.g. user asks "give me warm-up + back-off too")
            // moves the input form back to warm-up phase 0 instead of
            // continuing to log as working. Without this, the visual
            // chips updated but the next Log Set still wrote a working
            // set with the warm-up's reps.
            syncPhaseToPrescription()
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

    /// Re-derives `currentPhase` and `phaseSetIndex` from the sets already
    /// logged for this exercise plus the active prescription. Called every
    /// time `currentPrescription` is replaced — including same-exercise
    /// updates triggered by user requests like "add a warm-up too" — so
    /// the input form lines up with the unfilled phase, not whatever phase
    /// happened to be active before the prescription changed.
    private func syncPhaseToPrescription() {
        guard let rx = currentPrescription else { return }
        let warmupsDone = exerciseSetsForCurrentExercise.filter { $0.isWarmup == true }.count
        let nonWarmupsDone = exerciseSetsForCurrentExercise.count - warmupsDone
        let workingPrescribed = rx.workingSets.count

        if warmupsDone < rx.warmupSets.count {
            currentPhase = .warmup
            phaseSetIndex = warmupsDone
        } else if nonWarmupsDone < workingPrescribed {
            currentPhase = .working
            phaseSetIndex = nonWarmupsDone
        } else if !rx.backoffSets.isEmpty {
            currentPhase = .backoff
            phaseSetIndex = max(0, nonWarmupsDone - workingPrescribed)
        } else {
            // Prescription has no back-off — leave us at the last working
            // set so prefill still shows something reasonable.
            currentPhase = rx.warmupSets.isEmpty ? .working : (workingPrescribed > 0 ? .working : .warmup)
            phaseSetIndex = max(0, min(nonWarmupsDone, max(0, workingPrescribed - 1)))
        }
    }

    /// Builds the "Next: …" sentence appended to the iOS log message so
    /// the coach knows whether to prescribe the next phase of the current
    /// exercise or move on. Without this, Claude would jump straight to
    /// the next exercise after a working set, silently skipping the
    /// back-off that was still in the prescription. Run *after* the
    /// phase has been advanced — `currentPhase` / `phaseSetIndex` now
    /// point at the next set to do.
    private func nextPhaseHintForCoach(currentExercise: String) -> String {
        guard let rx = currentPrescription else { return "" }
        let phaseLabel: String?
        let phaseTotal: Int
        let phaseIndex = phaseSetIndex
        switch currentPhase {
        case .warmup:
            phaseLabel = phaseIndex < rx.warmupSets.count ? "warm-up" : nil
            phaseTotal = rx.warmupSets.count
        case .working:
            phaseLabel = phaseIndex < rx.workingSets.count ? "working set" : nil
            phaseTotal = rx.workingSets.count
        case .backoff:
            phaseLabel = phaseIndex < rx.backoffSets.count ? "back-off" : nil
            phaseTotal = rx.backoffSets.count
        }

        if let label = phaseLabel {
            let nextTarget = targetForNextPhase()
            return "Next: \(label) \(phaseIndex + 1) of \(phaseTotal) on \(currentExercise)\(nextTarget). Prescribe that exact set — do NOT move to a new exercise yet."
        }

        // No more sets left in the current exercise → coach should move on.
        // Hand them the next exercise's name (if known) so they don't
        // hallucinate one.
        let upcoming = upcomingPrescriptions.first?.exerciseName
        if let upcoming {
            return "Next: \(currentExercise) is complete — move on to \(upcoming) and prescribe it in full."
        }
        return "Next: \(currentExercise) is complete — move on to the next exercise in today's plan."
    }

    /// Returns " (target X × Y @ RPE Z)" for the next set we expect the
    /// coach to prescribe, so the coach has both the phase name and the
    /// numbers it should echo back.
    private func targetForNextPhase() -> String {
        guard let rx = currentPrescription else { return "" }
        let target: (weight: Double, reps: Int, rpe: Double?)? = {
            switch currentPhase {
            case .warmup:
                guard phaseSetIndex < rx.warmupSets.count else { return nil }
                let t = rx.warmupSets[phaseSetIndex]
                return (t.weight, t.reps, nil)
            case .working:
                guard phaseSetIndex < rx.workingSets.count else { return nil }
                return rx.workingSets[phaseSetIndex]
            case .backoff:
                guard phaseSetIndex < rx.backoffSets.count else { return nil }
                return rx.backoffSets[phaseSetIndex]
            }
        }()
        guard let t = target else { return "" }
        var s = " (target \(t.weight.weightString) × \(t.reps)"
        if let rpe = t.rpe {
            s += " @ RPE \(rpe.oneDecimal)"
        }
        s += ")"
        return s
    }

    /// Returns " (target was 95kg × 6 @ RPE 8)" when we know what was
    /// prescribed for the just-logged phase index, or "" otherwise. The
    /// suffix is appended to the coach's "Logged …" message so Claude has
    /// both the actual and target side by side and can't conflate them.
    private func formatTargetSuffix(
        phase: SetPhase,
        phaseSetIndex: Int,
        isWarmup: Bool
    ) -> String {
        guard let rx = currentPrescription else { return "" }
        let target: (weight: Double, reps: Int, rpe: Double?)? = {
            switch phase {
            case .warmup:
                guard phaseSetIndex < rx.warmupSets.count else { return nil }
                let t = rx.warmupSets[phaseSetIndex]
                return (t.weight, t.reps, nil)
            case .working:
                guard phaseSetIndex < rx.workingSets.count else { return nil }
                return rx.workingSets[phaseSetIndex]
            case .backoff:
                guard phaseSetIndex < rx.backoffSets.count else { return nil }
                return rx.backoffSets[phaseSetIndex]
            }
        }()
        guard let t = target else { return "" }
        var s = " (target was \(t.weight.weightString) × \(t.reps)"
        if !isWarmup, let rpe = t.rpe {
            s += " @ RPE \(rpe.oneDecimal)"
        }
        s += ")"
        return s
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
