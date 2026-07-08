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

    /// Everything in `allPrescriptions` after the current exercise that
    /// the athlete hasn't already worked through. Without this filter,
    /// exercises that were fully logged earlier in the session (Cable Row,
    /// Lat Pulldown, etc.) kept sitting in "UP NEXT" even though they
    /// were done — confusing when the plan list had already been completed.
    var upcomingPrescriptions: [ExercisePrescription] {
        let completedNames = Set(
            loggedSets
                .filter { $0.isWarmup != true }
                .map { PrescriptionParser.normalizeExerciseName($0.exercise) }
        )
        return allPrescriptions
            .dropFirst()
            .filter { !completedNames.contains($0.exerciseName) }
    }
    var totalTonnage: Double = 0
    var setCount = 0
    var warmupCount = 0
    var sessionDuration: TimeInterval = 0
    var startTime: Date?

    // Coach feedback
    var coachNote: String?
    var isCoachThinking = false

    // True from the moment a Log tap is accepted until the set is persisted
    // and the phase tracker has advanced. Guards logSet against reentry and
    // disables the Log button: the phase only advances AFTER the network
    // insert, so a second tap during that window (impatient re-tap on slow
    // gym data, or a touch double-fire) snapshotted the SAME phase and
    // logged a duplicate set — consuming the next prescribed set's slot and
    // skipping the athlete ahead ("warm-up 2 logged twice, warm-up 3 marked
    // done, straight to working set").
    var isLoggingSet = false

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

    // Rest timer — driven by an absolute deadline so the on-screen ring
    // tracks wall-clock time exactly. The RestTimer view renders from this
    // date via TimelineView; there is intentionally no per-second Timer here
    // (two timers decrementing one value caused an irregular, glitchy tick).
    var restEndDate: Date?
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
            prompt = "I've finished cardio for my \(session.type) session. Prescribe the first abs exercise using the strict straight-set format: *Exercise Name* on its own line, then a Working Set: line with EVERY set enumerated comma-separated (e.g. 25kg x12, 25kg x12, 25kg x12) plus Tempo and Rest, then a Form: line. Abs are straight sets — no Back-off line. The iOS card needs this exact format to render."
        } else {
            // Explicit demand for the full phase list — the iOS card uses
            // Warm-up / Working Set / Back-off as the structure for its
            // chips, and Claude has a habit of dropping already-completed
            // phases on resume, which then erases them from the UI.
            prompt = "Resuming my \(session.type) session. The [LIVE WORKOUT — IN PROGRESS] block in your context shows exactly what I've logged. Resend today's full plan and re-prescribe the current exercise in the strict format with ALL originally prescribed phases present — Warm-up, Working Set, and Back-off lines (straight-set ab exercises have no Back-off; re-list every enumerated set on the Working Set line instead) — even if some of those sets are already done. I need the full block so my card can show the complete progress, not just the unfinished phases."
        }
        do {
            let response = try await chatService.sendMessage(prompt)
            applyAIResponse(response)
            rehydrateCurrentExerciseStateFromLoggedSets()
        } catch {
            errorMessage = "Coach didn't respond (\(error.localizedDescription))."
        }
        isLoading = false
    }

    /// After `resume()` applies the coach's prescription, the
    /// `exercise-changed` branch in `applyAIResponse` resets
    /// `exerciseSetIndex` to 0 and clears `exerciseSetsForCurrentExercise`,
    /// because the prior `currentPrescription` was nil. That's a bug for
    /// resume: the session already has sets persisted for the prescribed
    /// exercise, and starting `setNumber` back at 1 collides with the rows
    /// already in `workout_sets` — producing duplicate `#1`/`#2` warm-ups
    /// in history. Rebuild the counters and phase from what's actually in
    /// the DB before the next `logSet` runs.
    private func rehydrateCurrentExerciseStateFromLoggedSets() {
        guard let rx = currentPrescription else { return }
        let target = PrescriptionParser.normalizeExerciseName(rx.exerciseName).lowercased()
        let matching = loggedSets.filter {
            PrescriptionParser.normalizeExerciseName($0.exercise).lowercased() == target
        }
        guard !matching.isEmpty else { return }

        exerciseSetsForCurrentExercise = matching
        // Pick the largest set_number we've already used so the next insert
        // gets a fresh, non-colliding value — protects against gaps if any
        // intermediate set was deleted.
        exerciseSetIndex = matching.map { $0.setNumber }.max() ?? matching.count
        syncPhaseToPrescription()
        prefillFromCurrentTarget()
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
        guard !isLoggingSet else { return }
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
        // Snapshot the input values too. `advancePhase()` calls
        // `prefillFromCurrentTarget()` which mutates `inputWeight` /
        // `inputReps` / `inputRPE` to the *next* phase's target — building
        // the recap from `inputWeight` after that point would read those
        // next-phase prefills, which is why the fact line was reporting
        // "0kg × 7" after a BW × 5 warm-up (the working set's prefill
        // sneaking into the recap).
        let loggedWeight = inputWeight
        let loggedReps = inputReps
        let loggedRPE = inputRPE

        isLoggingSet = true

        if !isWarmup {
            setCount += 1
        } else {
            warmupCount += 1
        }
        exerciseSetIndex += 1

        // Pull the prescribed target for the just-logged phase index so
        // it gets persisted alongside the actual — the live-workout
        // context block on the backend uses this to show actual-vs-target
        // per set without re-parsing chat history.
        let target: (weight: Double, reps: Int, rpe: Double?)? = {
            guard let rx = currentPrescription else { return nil }
            switch loggedPhase {
            case .warmup:
                guard loggedPhaseSetIndex < rx.warmupSets.count else { return nil }
                let t = rx.warmupSets[loggedPhaseSetIndex]
                return (t.weight, t.reps, nil)
            case .working:
                guard loggedPhaseSetIndex < rx.workingSets.count else { return nil }
                let t = rx.workingSets[loggedPhaseSetIndex]
                return (t.weight, t.reps, t.rpe)
            case .backoff:
                guard loggedPhaseSetIndex < rx.backoffSets.count else { return nil }
                let t = rx.backoffSets[loggedPhaseSetIndex]
                return (t.weight, t.reps, t.rpe)
            }
        }()

        do {
            let set = try await workoutService.logSet(
                sessionId: sessionId,
                exercise: exercise,
                setNumber: exerciseSetIndex,
                weight: loggedWeight,
                reps: loggedReps,
                rpe: isWarmup ? nil : loggedRPE,
                isWarmup: isWarmup,
                targetWeight: target?.weight,
                targetReps: target?.reps,
                targetRpe: target?.rpe
            )
            loggedSets.append(set)
            exerciseSetsForCurrentExercise.append(set)
            if !isWarmup {
                totalTonnage += loggedWeight * Double(loggedReps)
            }
        } catch {
            if !isWarmup { setCount -= 1 } else { warmupCount -= 1 }
            exerciseSetIndex -= 1
            errorMessage = "Failed to log set: \(error.localizedDescription)"
            isLoggingSet = false
            return
        }

        // PR check only for working sets
        if !isWarmup {
            do {
                let prResult = try await workoutService.checkPR(
                    exercise: exercise,
                    weight: loggedWeight,
                    reps: loggedReps
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

        // Set persisted and phase advanced — re-enable the Log button here
        // rather than after the coach round-trip, so the athlete can log
        // the next set while the coach is still composing feedback.
        isLoggingSet = false

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
        let actual = "\(loggedWeight.weightString) × \(loggedReps)" + (isWarmup ? "" : " @ RPE \(loggedRPE.oneDecimal)")
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
        // Locally-authored ground truth. Prepended to the displayed coach
        // note after `applyAIResponse` so the athlete always sees the
        // correct phase + numbers even when Claude misquotes them. This
        // failure mode has been recurring (working-set target shown as
        // the warm-up's actual, back-off target shown as the working-set
        // result, etc.), and the only thing the iOS can reliably trust
        // is what the iOS itself just logged.
        let factPrefix = "Logged \(phaseProgress): \(actual)."
        // The next-phase decision belongs to the iOS phase tracker, not the
        // coach — pass `allowExerciseChange: false` so a stray "moving to
        // chest" in the response can't skip the back-off that's still owed.
        do {
            let response = try await chatService.sendMessage(setMsg)
            applyAIResponse(response, allowExerciseChange: false)
            // Prepend the fact AFTER applyAIResponse, because that call
            // resets `coachNote` from the parsed response.
            if let existing = coachNote, !existing.isEmpty {
                coachNote = "\(factPrefix)\n\n\(existing)"
            } else {
                coachNote = factPrefix
            }
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
        // Capture skip intent against the phase the athlete is looking at
        // *now* — applyAIResponse may re-sync the phase from the log below.
        let athleteAskedToSkip = athleteRequestedWarmupSkip(text)

        do {
            let response = try await chatService.sendMessage(text)
            applyAIResponse(response)
            // Only skip when the athlete clearly asked to drop the warm-up
            // AND the coach didn't push back. The coach can't move the iOS
            // phase tracker on its own, but we also won't drop a set on a
            // loose "skip" mention or a question the coach declined — the
            // double-gate is what keeps this from skipping randomly.
            if athleteAskedToSkip && !coachRefusedWarmupSkip(response.response) {
                skipRemainingWarmups()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isCoachThinking = false
    }

    /// True only when the athlete gave an explicit, affirmative instruction
    /// to skip the warm-up while the warm-up phase is active. Questions
    /// ("should I skip the warm-up?") and negations ("don't skip the
    /// warm-up", "I never skip warm-ups") are rejected so a casual mention
    /// of the word never drops a set.
    private func athleteRequestedWarmupSkip(_ text: String) -> Bool {
        guard currentPhase == .warmup else { return false }
        let lower = text.lowercased()

        // Questions are requests for advice, not commands.
        if lower.contains("?") { return false }

        // Negations / hypotheticals override any skip phrase.
        let blockers = [
            "don't skip", "dont skip", "do not skip", "shouldn't skip",
            "should not skip", "can't skip", "cannot skip", "won't skip",
            "would not skip", "wouldn't skip", "not skip", "never skip",
            "without skipping", "rather not skip", "no need to skip",
            "don't remove", "dont remove", "do not remove", "not remove",
            "never remove", "don't drop", "dont drop", "do not drop",
            "not drop", "don't cut", "dont cut", "do not cut", "not cut",
        ]
        if blockers.contains(where: lower.contains) { return false }

        // Explicit directives aimed at the warm-up or at jumping to the
        // working set. Each phrase names the thing being skipped so a bare
        // "skip" / "remove" can't match. The athlete phrases this many ways
        // — "skip", "remove", "drop", "cut", "no warm-up" — and any wording
        // the list misses makes the app silently ignore an explicit command
        // while the coach happily agrees in text.
        let directives = [
            "skip the warm", "skip warm", "skip my warm", "skip this warm",
            "skip last warm", "skip the last warm", "skip remaining warm",
            "skip the rest of the warm", "skip rest of the warm",
            "skip the final warm", "skip final warm",
            "skip the third warm", "skip the 3rd warm", "skip third warm",
            "skip 3rd warm", "skip the second warm", "skip 2nd warm",
            "skip to working", "skip to the working", "skip to work",
            "skip straight to work", "straight to the working set",
            "no more warm", "done warming up", "done with warm",
            "finished warming up",
            "remove warm", "remove the warm", "remove my warm",
            "remove all warm", "remove remaining warm",
            "drop warm", "drop the warm", "drop my warm",
            "cut warm", "cut the warm", "cut my warm",
            "get rid of the warm", "get rid of warm", "lose the warm",
            "no warm-up", "no warmup", "no warm up",
            "without warm", "without the warm", "without a warm",
        ]
        return directives.contains(where: lower.contains)
    }

    /// True when the coach's reply pushes back on the skip ("keep the
    /// warm-up", "finish your warm-up"), which vetoes it. The athlete's
    /// message was already an explicit imperative, so anything short of a
    /// refusal counts as agreement — requiring a positive affirmation
    /// keyword meant a perfectly agreeable "Warm-ups removed 👍" failed the
    /// gate and the app ignored the same command three times in a row.
    private func coachRefusedWarmupSkip(_ response: String) -> Bool {
        let lower = response.lowercased()
        let refusals = [
            "don't skip", "do not skip", "keep the warm", "keep your warm",
            "finish your warm", "finish the warm", "do the warm",
            "one more warm", "stick with the warm", "complete your warm",
            "still need the warm", "need that warm", "needs the warm",
            "wouldn't skip", "would not skip", "let's not skip",
            "i'd keep", "recommend the warm",
            "don't remove", "do not remove", "wouldn't remove",
            "would not remove", "not removing", "keep them", "keep both",
            "don't drop", "do not drop", "wouldn't drop", "would not drop",
        ]
        return refusals.contains(where: lower.contains)
    }

    /// Drops any not-yet-logged warm-up sets from the current prescription
    /// so the phase advances to the working set. Trimming (rather than just
    /// bumping the phase index) also removes the skipped chip from the card
    /// and keeps `syncPhaseToPrescription` stable on subsequent calls — it
    /// re-derives the phase from logged-vs-prescribed counts, so a skipped
    /// set that stayed in the prescription would otherwise snap the phase
    /// back to the warm-up.
    private func skipRemainingWarmups() {
        guard currentPhase == .warmup, var rx = currentPrescription else { return }
        let warmupsDone = exerciseSetsForCurrentExercise.filter { $0.isWarmup == true }.count
        guard warmupsDone < rx.warmupSets.count else { return }
        rx.warmupSets = Array(rx.warmupSets.prefix(warmupsDone))
        currentPrescription = rx
        if !allPrescriptions.isEmpty,
           allPrescriptions[0].exerciseName == rx.exerciseName {
            allPrescriptions[0] = rx
        }
        syncPhaseToPrescription()
        prefillFromCurrentTarget()
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
        restEndDate = Date().addingTimeInterval(Double(seconds))
        isResting = true
    }

    func skipRest() {
        isResting = false
        restEndDate = nil
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
                workingSets: (serverRx.working ?? []).map { ($0.weight, $0.reps, $0.repsHigh, $0.rpe) },
                backoffSets: (serverRx.backoff ?? []).map { ($0.weight, $0.reps, $0.repsHigh, $0.rpe) },
                formCue: serverRx.form,
                tempo: serverRx.tempo,
                restSeconds: Self.parseRestString(serverRx.rest),
                isRevision: serverRx.revised ?? false
            )
            prescriptions = [rx] + clientParsed.dropFirst()
        } else {
            prescriptions = clientParsed
        }

        // Same-exercise updates: carry forward any phase the coach dropped.
        // Mid-exercise Claude often re-sends only the phase it's prescribing
        // next ("Back-off: BW x8" after a working set). Accepting that block
        // wholesale wiped the working set off the card, and the completion
        // math ("first N non-warmups are working sets") then counted the
        // logged working set as the back-off — showing it checked off and
        // prefilling a phantom next set. Phases already on screen are ground
        // truth; only non-empty incoming phases may replace them.
        // A `Revised:` block is exempt: the coach explicitly marked the new
        // structure as deliberate (e.g. the athlete asked to drop a warm-up),
        // so applying it verbatim is the whole point — reconciling it would
        // put the removed sets straight back on the card.
        if let current = currentPrescription,
           let first = prescriptions.first,
           first.exerciseName == current.exerciseName,
           !first.isRevision {
            prescriptions[0] = mergingDroppedPhases(into: first, from: current)
        }

        if !prescriptions.isEmpty {
            let newFirstName = prescriptions.first?.exerciseName
            let wantsDifferentExercise = newFirstName != oldExercise
            let blockChange = !allowExerciseChange
                && wantsDifferentExercise
                && !isCurrentExerciseComplete()
            if !blockChange {
                // Merge new prescriptions into the existing plan instead of
                // replacing it wholesale. A set-log response typically only
                // mentions one exercise; replacing `allPrescriptions` with
                // that single entry would wipe the full plan that was loaded
                // at workout start — destroying the "up next" list and
                // preventing `nextExerciseMentioned` from ever matching.
                //
                // On a *fresh resume* (no current exercise yet) the coach
                // re-sends the whole plan from exercise 1, but the athlete
                // may have been three exercises deep. Pick the exercise they
                // were actually mid-way through — derived from the session
                // log — instead of blindly snapping to the first one.
                if oldExercise == nil, let resumed = resumeExercise(among: prescriptions) {
                    currentPrescription = resumed
                } else {
                    currentPrescription = prescriptions.first
                }
                mergeIntoAllPrescriptions(prescriptions)
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
                // Hydrate per-exercise state from the session-wide log so
                // a resume picks up any sets already logged against this
                // exercise — without this, swiping back into a workout
                // forgot every set on the current lift and the chip
                // display + phase tracker started from zero.
                let matching = loggedSets.filter {
                    PrescriptionParser.normalizeExerciseName($0.exercise) == rx.exerciseName
                }
                exerciseSetsForCurrentExercise = matching
                exerciseSetIndex = matching.count
            }
            // If the coach left warm-ups out of a re-prescription but the
            // athlete has already logged some on this exercise (the resume
            // case — Claude tends to skip done phases), reattach them so
            // the card still shows them as ✓ instead of vanishing the
            // whole WARM-UP section.
            currentPrescription = backfillWarmupsFromLog(rx)
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

    /// Reconciles a same-exercise re-prescription against the one on screen.
    /// The coach is instructed to reply mid-set with either plain narrative
    /// or a FULL block, but it sometimes sends a partial block carrying only
    /// what's left — a lone "Back-off:" line after a working set, or a
    /// "Warm-up:" line listing just the remaining warm-up ("62.5kg x6" after
    /// warm-up 1 of 2). Accepting that wholesale erased planned sets and
    /// their checkmarks from the card and made the phase tracker skip ahead
    /// (the next warm-up would have logged as a working set). A partial
    /// block must never shrink the plan; it may only update upcoming targets.
    private func mergingDroppedPhases(
        into incoming: ExercisePrescription,
        from current: ExercisePrescription
    ) -> ExercisePrescription {
        let warmupsDone = exerciseSetsForCurrentExercise.filter { $0.isWarmup == true }.count
        let nonWarmupsDone = exerciseSetsForCurrentExercise.count - warmupsDone
        let workingDone = min(nonWarmupsDone, current.workingSets.count)
        let backoffDone = max(0, nonWarmupsDone - current.workingSets.count)

        var merged = incoming
        merged.warmupSets = reconciledPhase(
            incoming: incoming.warmupSets, current: current.warmupSets, done: warmupsDone
        )
        merged.workingSets = reconciledPhase(
            incoming: incoming.workingSets, current: current.workingSets, done: workingDone
        )
        merged.backoffSets = reconciledPhase(
            incoming: incoming.backoffSets, current: current.backoffSets, done: backoffDone
        )
        if merged.formCue == nil { merged.formCue = current.formCue }
        if merged.tempo == nil { merged.tempo = current.tempo }
        if merged.restSeconds == nil { merged.restSeconds = current.restSeconds }
        return merged
    }

    /// Merges one phase of a same-exercise re-prescription. A re-list with
    /// at least as many sets as planned is trusted verbatim. Anything
    /// shorter is a partial block naming only the remaining sets: keep the
    /// planned sets and overlay the incoming targets onto the next unlogged
    /// slots, so "make warm-up 2 62.5kg" updates the target without
    /// shrinking the phase.
    private func reconciledPhase<T>(incoming: [T], current: [T], done: Int) -> [T] {
        guard incoming.count < current.count else { return incoming }
        var merged = current
        for (i, set) in incoming.enumerated() {
            let slot = done + i
            if slot < merged.count {
                merged[slot] = set
            } else {
                merged.append(set)
            }
        }
        return merged
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

    /// Merges a coach-returned prescription list into `allPrescriptions`
    /// without wiping exercises the coach didn't mention this time.
    ///
    /// When the response contains a full session plan (workout start),
    /// `allPrescriptions` will be replaced entirely — the initial plan is
    /// the definitive list. During a set-log reply that only mentions one
    /// exercise, the matching entry is updated in place (or inserted at
    /// the front if it's genuinely new), preserving the rest of the plan
    /// so transitions and "up next" keep working.
    /// Picks the exercise the athlete was actually working on when a session
    /// is resumed from the log, rather than the first exercise in the
    /// coach's re-sent plan. The exercise of the most recently logged set is
    /// "where they were"; if that exercise is already fully logged, resume
    /// on the next one in the plan. Returns nil when nothing is logged yet
    /// or the logged exercise isn't in the plan (caller falls back to first).
    private func resumeExercise(among prescriptions: [ExercisePrescription]) -> ExercisePrescription? {
        guard !loggedSets.isEmpty else { return nil }
        let sorted = loggedSets.sorted { ($0.loggedAt ?? "") < ($1.loggedAt ?? "") }
        guard let lastName = sorted.last.map({ PrescriptionParser.normalizeExerciseName($0.exercise) }),
              let idx = prescriptions.firstIndex(where: { $0.exerciseName == lastName })
        else { return nil }

        let rx = prescriptions[idx]
        let exSets = loggedSets.filter {
            PrescriptionParser.normalizeExerciseName($0.exercise) == lastName
        }
        let warmupsDone = exSets.filter { $0.isWarmup == true }.count
        let nonWarmupsDone = exSets.count - warmupsDone
        let complete = warmupsDone >= rx.warmupSets.count
            && nonWarmupsDone >= (rx.workingSets.count + rx.backoffSets.count)
        if complete, idx + 1 < prescriptions.count {
            return prescriptions[idx + 1]
        }
        return rx
    }

    private func mergeIntoAllPrescriptions(_ incoming: [ExercisePrescription]) {
        guard !incoming.isEmpty else { return }
        // Heuristic: if the coach sent 3+ prescriptions, treat it as a full
        // plan refresh (the start-of-session response or a "re-send the
        // plan" reply). Below that, merge.
        if incoming.count >= 3 {
            allPrescriptions = incoming
            return
        }
        var merged = allPrescriptions
        for rx in incoming {
            let name = rx.exerciseName
            if let idx = merged.firstIndex(where: { $0.exerciseName == name }) {
                merged[idx] = rx
            } else {
                merged.insert(rx, at: 0)
            }
        }
        // Keep the current exercise at the front
        if let current = currentPrescription,
           let idx = merged.firstIndex(where: { $0.exerciseName == current.exerciseName }),
           idx != 0 {
            let item = merged.remove(at: idx)
            merged.insert(item, at: 0)
        }
        allPrescriptions = merged
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

    /// If the supplied prescription has no warm-up sets but the athlete
    /// has logged warm-ups for this exercise (the resume scenario where
    /// the coach drops already-completed phases), rebuild the warmup
    /// list from the persisted target/actual columns so the chip
    /// section still renders. Falls through unchanged when the
    /// prescription already carries warm-ups or no warm-ups were ever
    /// logged.
    private func backfillWarmupsFromLog(_ rx: ExercisePrescription) -> ExercisePrescription {
        guard rx.warmupSets.isEmpty else { return rx }
        let loggedWarmups = exerciseSetsForCurrentExercise
            .filter { $0.isWarmup == true }
            .sorted { $0.setNumber < $1.setNumber }
        guard !loggedWarmups.isEmpty else { return rx }
        var merged = rx
        merged.warmupSets = loggedWarmups.map { set in
            // Prefer the prescribed target so the chip text matches what
            // was originally on screen — fall back to actuals when the
            // target columns weren't populated (sets logged before the
            // target columns were added).
            let weight = set.targetWeightKg ?? set.actualWeightKg ?? 0
            let reps = set.targetReps ?? set.actualReps ?? 0
            return (weight: weight, reps: reps)
        }
        return merged
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
                let t = rx.workingSets[phaseSetIndex]
                return (t.weight, t.reps, t.rpe)
            case .backoff:
                guard phaseSetIndex < rx.backoffSets.count else { return nil }
                let t = rx.backoffSets[phaseSetIndex]
                return (t.weight, t.reps, t.rpe)
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
                let t = rx.workingSets[phaseSetIndex]
                return (t.weight, t.reps, t.rpe)
            case .backoff:
                guard phaseSetIndex < rx.backoffSets.count else { return nil }
                let t = rx.backoffSets[phaseSetIndex]
                return (t.weight, t.reps, t.rpe)
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
        isResting = false
        restEndDate = nil
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
