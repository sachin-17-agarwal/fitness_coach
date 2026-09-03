// WorkoutService.swift
// FitnessCoach
//
// Manages workout sessions and sets via the Supabase `workout_sessions`,
// `workout_sets`, and `memory` tables.

import Foundation

// MARK: - Supporting types

/// Transient in-memory representation of the workout state stored in `memory`.
struct WorkoutState: Sendable {
    /// `"active"` or `"inactive"`.
    var workoutMode: String
    /// UUID string of the current session.
    var currentSessionId: String
    /// 1-based index of the next set to log.
    var currentSetNumber: Int
    /// Name of the exercise currently being performed.
    var currentExerciseName: String
    /// ISO-8601 timestamp when the session started.
    var sessionStartTime: String

    var isActive: Bool { workoutMode == "active" }
}

/// Summary returned when a session is ended.
struct WorkoutSummary: Sendable {
    var tonnage: Double
    var totalSets: Int
    var duration: TimeInterval
    var prs: [PRResult]
    var avgHR: Int? = nil
    var maxHR: Int? = nil
    var minHR: Int? = nil
    var coachRecap: String? = nil
    var topExercise: String? = nil
    var topExerciseWeight: Double? = nil
    var topExerciseReps: Int? = nil
}

/// Result of a personal-record check using the Epley 1RM formula.
struct PRResult: Sendable {
    var exercise: String
    var isPR: Bool
    var estimated1RM: Double
    var previous1RM: Double
}

/// Model for a single set row in `workout_sets`.
struct WorkoutSet: Codable, Identifiable, Sendable {
    var id: UUID?
    var workoutSessionId: UUID?
    var date: String?
    var exercise: String
    var setNumber: Int
    var isWarmup: Bool?
    var targetWeightKg: Double?
    var targetReps: Int?
    var targetRpe: Double?
    var actualWeightKg: Double?
    var actualReps: Int?
    var actualRpe: Double?
    var restSeconds: Int?
    var notes: String?
    var loggedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case workoutSessionId = "workout_session_id"
        case date
        case exercise
        case setNumber = "set_number"
        case isWarmup = "is_warmup"
        case targetWeightKg = "target_weight_kg"
        case targetReps = "target_reps"
        case targetRpe = "target_rpe"
        case actualWeightKg = "actual_weight_kg"
        case actualReps = "actual_reps"
        case actualRpe = "actual_rpe"
        case restSeconds = "rest_seconds"
        case notes
        case loggedAt = "logged_at"
    }
}

// MARK: - Service

final class WorkoutService: Sendable {

    private let client: SupabaseClient

    init(client: SupabaseClient = .shared) {
        self.client = client
    }

    // MARK: - Sessions

    /// Creates a new workout session, marks it `in_progress`, and updates the
    /// workout state in the `memory` table.
    /// - Parameters:
    ///   - mesocycleWeek: which week of the 4-week wave this session belongs to
    ///   - mesocycleDay: the rotation position (1-4)
    ///
    /// The mesocycle position is stamped at creation because it cannot be
    /// reconstructed afterwards. A deload holds week-3 loads and cuts reps, so
    /// a 5-rep set at RPE 7 is either the protocol working exactly as designed
    /// or a session run a full point under target — and with no week on the
    /// row, nothing distinguishes them. The coach is told to check which week
    /// he is in before judging effort, and until now had no way to.
    ///
    /// The insert retries without the two columns if the database rejects
    /// them, so an app build that ships ahead of
    /// migrations/001_workout_session_mesocycle.sql still starts workouts.
    func startSession(type: String) async throws -> WorkoutSession {
        let sessionId = UUID()
        let today = Self.todayString()
        let now = ISO8601DateFormatter().string(from: Date())

        // One training day is one row. Starting the same day's session again —
        // after an END tap, a back-swipe, or the app closing the workout and the
        // athlete carrying on — reuses the row that is already there instead of
        // minting a second one.
        //
        // cleanupStaleSessions already knew about this ("an accidental
        // back-swipe used to mint a fresh session on every re-entry") but swept
        // up afterwards rather than preventing it, and its sweep FINALISES a
        // duplicate that holds sets rather than deleting it — so the row
        // survives. 21 of the athlete's sessions were one training day written
        // twice, which splits the day's work in half (each row then reads as
        // missing most of the template) and, because the mesocycle week is
        // reconstructed by counting rotation positions, shifts the recorded week
        // of every earlier session by one.
        //
        // Deliberately matches on date and type WITHOUT filtering on status:
        // the open-only lookup the view model uses is exactly what stopped
        // finding the session once it had been closed, which is when the
        // duplicate got created.
        if let rows: [WorkoutSession] = try? await client.fetch(
            "workout_sessions",
            query: ["date": "eq.\(today)", "type": "eq.\(type)"],
            order: "start_time.desc",
            limit: 1
        ), var existing = rows.first, let existingId = existing.id {
            // Reopen a closed row so logging continues into it. Best-effort:
            // failing to flip the status must not stop the athlete training,
            // and the row is still the right one to log against either way.
            if !SessionStatus.openRawValues.contains(existing.status) {
                _ = try? await client.update(
                    "workout_sessions",
                    body: ["status": SessionStatus.openStored],
                    match: ["id": existingId.uuidString]
                )
                existing.status = SessionStatus.openStored
            }
            let resumedState = WorkoutState(
                workoutMode: "active",
                currentSessionId: existingId.uuidString,
                currentSetNumber: 1,
                currentExerciseName: "",
                sessionStartTime: existing.startTime ?? now
            )
            try? await setWorkoutState(resumedState)
            return existing
        }

        var body: [String: Any] = [
            "id": sessionId.uuidString,
            "date": today,
            "type": type,
            "status": SessionStatus.openStored,
            "start_time": now,
        ]
        // Stamp the mesocycle position onto the session. It has to be recorded
        // here because it cannot be recovered afterwards: the week advances on
        // completion of a full rotation, not per calendar week, and yoga days
        // and session swaps deliberately don't advance it — so a session's week
        // is not a function of its date. The coach's PEAK WEEK REFERENCE LOADS
        // block reads this to answer "what did he lift in week 3", which is what
        // a deload holds and what the next cycle opens above.
        //
        // Best-effort: a failed read must not block starting a workout, so the
        // stamp is omitted and the backend treats the week as unknown.
        if let state = try? await MesocycleService(client: client).loadState() {
            body["mesocycle_week"] = state.week
            body["mesocycle_day"] = state.day
        }

        // The insert degrades rather than fails. A database that has not run
        // migrations/001_workout_session_mesocycle.sql rejects the unknown
        // columns, and an app build must never be undeployable because a
        // migration has not been applied yet — the session row matters more
        // than the stamp on it.
        let session: WorkoutSession
        do {
            session = try await client.insertAndDecode("workout_sessions", body: body)
        } catch {
            guard body["mesocycle_week"] != nil || body["mesocycle_day"] != nil else {
                throw error
            }
            body.removeValue(forKey: "mesocycle_week")
            body.removeValue(forKey: "mesocycle_day")
            session = try await client.insertAndDecode("workout_sessions", body: body)
        }

        // Best-effort: persist workout state to memory table.
        // Session row is already created above — don't lose it if state fails.
        let state = WorkoutState(
            workoutMode: "active",
            currentSessionId: sessionId.uuidString,
            currentSetNumber: 1,
            currentExerciseName: "",
            sessionStartTime: now
        )
        try? await setWorkoutState(state)

        return session
    }

    /// Flip a finished session back to open so logging continues into it.
    ///
    /// Needed because the athlete's "continue the workout" is the app's "start
    /// a second session": once a row is `completed`, the open-only resume
    /// lookup stops finding it and a duplicate row gets created for the same
    /// training day.
    func reopenSession(id: UUID) async throws {
        _ = try await client.update(
            "workout_sessions",
            body: ["status": SessionStatus.openStored],
            match: ["id": id.uuidString]
        )
    }

    /// Ends a session: calculates tonnage, marks it `completed`, checks PRs,
    /// resets workout state, and returns a summary.
    @discardableResult
    func endSession(id: UUID) async throws -> WorkoutSummary {
        let sets = try await fetchSets(sessionId: id)
        let now = ISO8601DateFormatter().string(from: Date())

        // Tonnage = sum of (weight * reps) for every logged set
        let tonnage = sets.reduce(0.0) { total, set in
            let w = set.actualWeightKg ?? 0
            let r = Double(set.actualReps ?? 0)
            return total + (w * r)
        }

        // Update session row
        try await client.update(
            "workout_sessions",
            body: [
                "status": SessionStatus.finishedStored,
                "end_time": now,
                "tonnage_kg": tonnage,
            ],
            match: ["id": id.uuidString]
        )

        // Calculate duration from the stored start time
        let state = try await getWorkoutState()
        let duration: TimeInterval
        if let start = ISO8601DateFormatter().date(from: state.sessionStartTime) {
            duration = Date().timeIntervalSince(start)
        } else {
            duration = 0
        }

        // Check PRs for each unique exercise in this session
        var prs: [PRResult] = []
        let exerciseNames = Set(sets.map(\.exercise))
        for name in exerciseNames {
            let exerciseSets = sets.filter { $0.exercise == name }
            // Find the set with the best estimated 1RM in this session
            var bestWeight = 0.0
            var bestReps = 0
            var best1RM = 0.0
            for s in exerciseSets {
                let w = s.actualWeightKg ?? 0
                let r = s.actualReps ?? 0
                guard w > 0, r > 0 else { continue }
                let e1rm = Self.epley1RM(weight: w, reps: r)
                if e1rm > best1RM {
                    best1RM = e1rm
                    bestWeight = w
                    bestReps = r
                }
            }
            if best1RM > 0 {
                let pr = try await checkPR(exercise: name, weight: bestWeight, reps: bestReps)
                if pr.isPR { prs.append(pr) }
            }
        }

        // Best-effort: reset workout state to inactive
        let inactiveState = WorkoutState(
            workoutMode: "inactive",
            currentSessionId: "",
            currentSetNumber: 0,
            currentExerciseName: "",
            sessionStartTime: ""
        )
        try? await setWorkoutState(inactiveState)

        return WorkoutSummary(
            tonnage: tonnage,
            totalSets: sets.count,
            duration: duration,
            prs: prs
        )
    }

    // MARK: - Sets

    /// Logs a single set to the `workout_sets` table and advances the set counter
    /// in the `memory` table.
    ///
    /// Mirrors the backend's `log_set` dedup on
    /// `(workout_session_id, exercise, set_number, is_warmup)`: if a row with
    /// those four already exists we return it instead of inserting a second
    /// copy. The duplicate `#1`/`#2` warm-ups seen in history were getting
    /// in via this path — the resume flow used to reset `exerciseSetIndex`
    /// back to 0, so re-logging the first warm-up after a resume re-used
    /// `setNumber=1` and the insert went through unchallenged.
    func logSet(
        sessionId: UUID,
        exercise: String,
        setNumber: Int,
        weight: Double,
        reps: Int,
        rpe: Double? = nil,
        isWarmup: Bool = false,
        targetWeight: Double? = nil,
        targetReps: Int? = nil,
        targetRpe: Double? = nil
    ) async throws -> WorkoutSet {
        let today = Self.todayString()
        let now = ISO8601DateFormatter().string(from: Date())

        if let existing = try? await fetchExistingSet(
            sessionId: sessionId,
            exercise: exercise,
            setNumber: setNumber,
            isWarmup: isWarmup
        ) {
            // Keep the memory counters consistent with the highest set_number
            // we already have on disk so the next call advances cleanly.
            try? await setMemory(key: "current_set_number", value: String(setNumber + 1))
            try? await setMemory(key: "current_exercise_name", value: exercise)
            return existing
        }

        var body: [String: Any] = [
            "workout_session_id": sessionId.uuidString,
            "date": today,
            "exercise": exercise,
            "set_number": setNumber,
            "actual_weight_kg": weight,
            "actual_reps": reps,
            "is_warmup": isWarmup,
            "logged_at": now,
        ]
        if let rpe {
            body["actual_rpe"] = rpe
        }
        // Persist the prescribed target alongside the actual so the
        // live-workout context block injected into the coach prompt can
        // surface actual-vs-target per set without having to re-parse the
        // chat history. Without this, the coach has to guess what the
        // athlete was aiming for and tends to substitute the wrong phase's
        // numbers when reacting to the log.
        if let targetWeight {
            body["target_weight_kg"] = targetWeight
        }
        if let targetReps {
            body["target_reps"] = targetReps
        }
        if let targetRpe {
            body["target_rpe"] = targetRpe
        }

        // Retried here rather than through withRetry, because this operation is
        // idempotent in a way the generic helper cannot see and the insert body
        // is a [String: Any] that cannot cross a @Sendable boundary.
        //
        // The helper classes networkConnectionLost as "delivery unknown" and so
        // refuses to retry a write — correct in general, and wrong here. A set
        // is identified by (session, exercise, set_number, is_warmup) and the
        // guard at the top of this function already returns the existing row
        // rather than inserting a second. So re-checking that guard before each
        // retry makes the whole operation safe to repeat: if the first attempt
        // did land and only its response was lost, the re-check finds the row
        // and returns it instead of duplicating.
        //
        // Without this a dropped connection mid-workout simply lost the set —
        // the athlete saw "The network connection was lost", the row was never
        // written, and it later read as an exercise he had skipped.
        var logged: WorkoutSet?
        var lastNetworkError: Error?
        for attempt in 1...3 {
            do {
                logged = try await client.insertAndDecode("workout_sets", body: body)
                break
            } catch let urlError as URLError {
                lastNetworkError = urlError
                if attempt == 3 { break }
                try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt - 1)) * 1_000_000_000))
                // The attempt may have been delivered and committed. Ask.
                if let existing = try? await fetchExistingSet(
                    sessionId: sessionId,
                    exercise: exercise,
                    setNumber: setNumber,
                    isWarmup: isWarmup
                ) {
                    logged = existing
                    lastNetworkError = nil
                    break
                }
            }
        }
        guard let logged else {
            throw lastNetworkError ?? URLError(.unknown)
        }

        // Best-effort: advance set counter and exercise name in memory.
        // The set is already persisted above — don't lose it if state update fails.
        try? await setMemory(key: "current_set_number", value: String(setNumber + 1))
        try? await setMemory(key: "current_exercise_name", value: exercise)

        return logged
    }

    /// Correct a set that was logged wrong. Only the three values the athlete
    /// can actually mis-enter are editable — the target columns stay as
    /// prescribed, because the point of keeping them is to record what was
    /// asked for, not to retro-fit it to what happened.
    func updateSet(
        id: UUID,
        weight: Double,
        reps: Int,
        rpe: Double?
    ) async throws -> WorkoutSet {
        var body: [String: Any] = [
            "actual_weight_kg": weight,
            "actual_reps": reps,
        ]
        // NSNull rather than omission: leaving the key out would keep a stale
        // RPE on a set being corrected to a warm-up, which carries none.
        body["actual_rpe"] = rpe ?? NSNull()

        return try await client.updateAndDecode(
            "workout_sets", body: body, match: ["id": id.uuidString]
        )
    }

    func deleteSet(id: UUID) async throws {
        _ = try await client.delete("workout_sets", match: ["id": id.uuidString])
    }

    /// Close a session without the end-of-workout machinery.
    ///
    /// `endSession` also runs PR detection and resets the workout-state memory
    /// keys, neither of which suits a cardio or yoga entry — those log zero
    /// weight against a duration, so putting them through PR detection is
    /// meaningless. This just marks the row done so it stops sitting in
    /// history as `in_progress` forever waiting for a finish that never comes.
    func completeSession(id: UUID) async throws {
        let sets = try await fetchSets(sessionId: id)
        let tonnage = sets.reduce(0.0) { total, set in
            total + ((set.actualWeightKg ?? 0) * Double(set.actualReps ?? 0))
        }
        try await client.update(
            "workout_sessions",
            body: [
                "status": SessionStatus.finishedStored,
                "end_time": ISO8601DateFormatter().string(from: Date()),
                "tonnage_kg": tonnage,
            ],
            match: ["id": id.uuidString]
        )
    }

    /// Recompute and persist a session's tonnage from its sets.
    ///
    /// `tonnage_kg` is denormalised onto the session row when the session
    /// ends, so correcting or removing a set afterwards leaves it stale — the
    /// history card would keep showing a total that no longer matches the sets
    /// listed underneath it. Mirrors `endSession`'s arithmetic exactly,
    /// warm-ups included, so the stored number keeps meaning the same thing.
    @discardableResult
    func recalculateTonnage(sessionId: UUID) async throws -> Double {
        let sets = try await fetchSets(sessionId: sessionId)
        let tonnage = sets.reduce(0.0) { total, set in
            total + ((set.actualWeightKg ?? 0) * Double(set.actualReps ?? 0))
        }
        try await client.update(
            "workout_sessions",
            body: ["tonnage_kg": tonnage],
            match: ["id": sessionId.uuidString]
        )
        return tonnage
    }

    private func fetchExistingSet(
        sessionId: UUID,
        exercise: String,
        setNumber: Int,
        isWarmup: Bool
    ) async throws -> WorkoutSet? {
        let rows: [WorkoutSet] = try await client.fetch(
            "workout_sets",
            query: [
                "workout_session_id": "eq.\(sessionId.uuidString)",
                "exercise": "eq.\(exercise)",
                "set_number": "eq.\(setNumber)",
                "is_warmup": "eq.\(isWarmup)",
            ],
            limit: 1
        )
        return rows.first
    }

    /// Fetches all sets for a given session, ordered by set number.
    func fetchSets(sessionId: UUID) async throws -> [WorkoutSet] {
        // Chronological, NOT by set_number: set numbers restart at 1 for each
        // exercise, so sorting by them interleaves the whole session and the
        // history card ends up listing exercises in an arbitrary order (abs
        // appearing before leg press on a leg day whose finisher they are).
        // Callers either group by exercise, sum, or check emptiness, so none
        // depend on set_number ordering.
        try await client.fetch(
            "workout_sets",
            query: ["workout_session_id": "eq.\(sessionId.uuidString)"],
            order: "logged_at.asc"
        )
    }

    /// Fetches every set logged on or after `start`. PostgREST through
    /// `SupabaseClient.fetch` only accepts one filter per column, so the
    /// caller is responsible for trimming to a desired upper bound — for
    /// the weekly-volume use case we ask for ~14 days back and split the
    /// result into "this week" / "prior week" client-side.
    func fetchSets(since start: Date) async throws -> [WorkoutSet] {
        let f = Self.dateFormatter
        let startStr = f.string(from: start)
        // Newest-first with an explicit limit: PostgREST silently caps
        // un-limited responses (default 1000 rows), and with ascending
        // order that cap would drop the NEWEST sets once the window
        // outgrows it — making recently trained muscles look neglected.
        // Callers bucket by date and don't depend on response order.
        return try await client.fetch(
            "workout_sets",
            query: ["date": "gte.\(startStr)"],
            order: "date.desc",
            limit: 10000
        )
    }

    // MARK: - Session history

    /// Fetches sessions from the last N calendar days, newest first.
    func fetchSessionHistory(days: Int) async throws -> [WorkoutSession] {
        let since = Self.dateString(daysAgo: days)
        return try await client.fetch(
            "workout_sessions",
            query: ["date": "gte.\(since)"],
            order: "date.desc"
        )
    }

    /// Sweeps session rows left stuck open — an accidental back-swipe used
    /// to mint a fresh session on every re-entry because the view never
    /// called `endSession`. Empty rows get deleted; rows with sets get
    /// finalised so they stop showing as in_progress / active in history.
    ///
    /// Catches three failure modes:
    ///
    /// 1. Sessions from *prior* days that never ended (the original case).
    /// 2. Sessions created by the backend's implicit-start path — these are
    ///    the orphan "Pull / Push / Legs" cards with one stray set. Both
    ///    codebases now write `SessionStatus.openStored`, but rows predating
    ///    that still say `"active"`, which is why the sweep enumerates every
    ///    open spelling rather than one.
    /// 3. *Today's* sessions whose newest set is more than 6 hours old: a
    ///    legit workout never spans that long, so anything past that is a
    ///    forgotten session, not a currently-open one. Picks the most
    ///    recently active session (by latest `logged_at`) per (date, type)
    ///    as the survivor when several overlap.
    func cleanupStaleSessions() async {
        let today = Self.todayString()
        let openStatuses = SessionStatus.openRawValues

        var openSessions: [WorkoutSession] = []
        for status in openStatuses {
            if let rows: [WorkoutSession] = try? await client.fetch(
                "workout_sessions",
                query: ["status": "eq.\(status)"]
            ) {
                openSessions.append(contentsOf: rows)
            }
        }

        let staleCutoff = Date().addingTimeInterval(-6 * 60 * 60)
        let isoFormatter = ISO8601DateFormatter()

        // Group today's open sessions by type so we only kill the *idle*
        // siblings and never the one the user is actively logging into.
        var todaysByType: [String: [(WorkoutSession, Date?)]] = [:]
        var stalePast: [WorkoutSession] = []

        for session in openSessions {
            if session.date < today {
                stalePast.append(session)
                continue
            }
            if session.date == today {
                // Fall back to start_time when no sets have been logged
                // yet — a session created seconds ago must not be mistaken
                // for an idle one just because its sets list is empty.
                let lastActivity: Date? = await mostRecentSetLoggedAt(
                    sessionId: session.id, formatter: isoFormatter
                ) ?? session.startTime.flatMap { isoFormatter.date(from: $0) }
                todaysByType[session.type, default: []].append((session, lastActivity))
            }
        }

        var todaysToClose: [WorkoutSession] = []
        for (_, group) in todaysByType {
            guard group.count > 1 || group.contains(where: { ($0.1 ?? .distantPast) < staleCutoff }) else {
                continue
            }
            let sorted = group.sorted { ($0.1 ?? .distantPast) > ($1.1 ?? .distantPast) }
            // Keep the most recently active session in the group; treat the
            // others as orphans regardless of activity, since two open
            // sessions of the same type on the same day is always a bug.
            for (idx, entry) in sorted.enumerated() {
                if idx == 0 {
                    if (entry.1 ?? .distantPast) < staleCutoff {
                        todaysToClose.append(entry.0)
                    }
                } else {
                    todaysToClose.append(entry.0)
                }
            }
        }

        for session in stalePast + todaysToClose {
            await finaliseOrDelete(session)
        }
    }

    private func mostRecentSetLoggedAt(
        sessionId: UUID?,
        formatter: ISO8601DateFormatter
    ) async -> Date? {
        guard let sessionId else { return nil }
        let sets: [WorkoutSet]? = try? await client.fetch(
            "workout_sets",
            query: ["workout_session_id": "eq.\(sessionId.uuidString)"],
            order: "logged_at.desc",
            limit: 1
        )
        guard let raw = sets?.first?.loggedAt else { return nil }
        return formatter.date(from: raw)
    }

    private func finaliseOrDelete(_ session: WorkoutSession) async {
        guard let id = session.id else { return }
        let sets = (try? await fetchSets(sessionId: id)) ?? []

        if sets.isEmpty {
            _ = try? await client.delete(
                "workout_sessions",
                match: ["id": id.uuidString]
            )
        } else {
            let tonnage = sets.reduce(0.0) { total, s in
                guard s.isWarmup != true else { return total }
                return total + (s.actualWeightKg ?? 0) * Double(s.actualReps ?? 0)
            }
            _ = try? await client.update(
                "workout_sessions",
                body: ["status": SessionStatus.finishedStored, "tonnage_kg": tonnage],
                match: ["id": id.uuidString]
            )
        }
    }

    // MARK: - Workout state (memory table)

    /// Reads the current workout state from the `memory` key-value table.
    func getWorkoutState() async throws -> WorkoutState {
        let keys = "in.(workout_mode,current_session_id,current_set_number,current_exercise_name,session_start_time)"
        let rows: [MemoryRow] = try await client.fetch(
            "memory",
            query: ["key": keys]
        )

        var mode = "inactive"
        var sessionId = ""
        var setNumber = 0
        var exerciseName = ""
        var startTime = ""

        for row in rows {
            switch row.key {
            case "workout_mode":          mode = row.value
            case "current_session_id":    sessionId = row.value
            case "current_set_number":    setNumber = Int(row.value) ?? 0
            case "current_exercise_name": exerciseName = row.value
            case "session_start_time":    startTime = row.value
            default: break
            }
        }

        return WorkoutState(
            workoutMode: mode,
            currentSessionId: sessionId,
            currentSetNumber: setNumber,
            currentExerciseName: exerciseName,
            sessionStartTime: startTime
        )
    }

    /// Persists the full workout state to the `memory` key-value table.
    func setWorkoutState(_ state: WorkoutState) async throws {
        try await setMemory(key: "workout_mode", value: state.workoutMode)
        try await setMemory(key: "current_session_id", value: state.currentSessionId)
        try await setMemory(key: "current_set_number", value: String(state.currentSetNumber))
        try await setMemory(key: "current_exercise_name", value: state.currentExerciseName)
        try await setMemory(key: "session_start_time", value: state.sessionStartTime)
    }

    // MARK: - PR check

    /// Checks whether the given weight/reps combination represents a new PR
    /// for the exercise using the Epley estimated 1RM formula.
    func checkPR(exercise: String, weight: Double, reps: Int) async throws -> PRResult {
        let current1RM = Self.epley1RM(weight: weight, reps: reps)

        // Fetch all historical sets for this exercise to find the previous best 1RM
        let historicalSets: [WorkoutSet] = try await client.fetch(
            "workout_sets",
            query: ["exercise": "eq.\(exercise)"],
            order: "logged_at.desc"
        )

        var previous1RM = 0.0
        for set in historicalSets {
            let w = set.actualWeightKg ?? 0
            let r = set.actualReps ?? 0
            guard w > 0, r > 0 else { continue }
            let e = Self.epley1RM(weight: w, reps: r)
            if e > previous1RM { previous1RM = e }
        }

        return PRResult(
            exercise: exercise,
            isPR: current1RM > previous1RM,
            estimated1RM: current1RM,
            previous1RM: previous1RM
        )
    }

    // MARK: - Auto-suggest (last session sets)

    /// Returns the sets from the most recent completed session that included
    /// the given exercise.  Useful for auto-suggesting weights and reps.
    /// Pass `before` (yyyy-MM-dd, exclusive) to get the previous session's
    /// sets rather than the most recent — mid-workout, "most recent" is the
    /// session currently in progress, which makes a "last time" comparison
    /// show the athlete the sets they logged minutes ago.
    func getLastSessionSets(exercise: String, before date: String? = nil) async throws -> [WorkoutSet] {
        // Find the most recent set for this exercise to determine its session ID.
        var query = ["exercise": "eq.\(exercise)"]
        if let date { query["date"] = "lt.\(date)" }
        let recentSets: [WorkoutSet] = try await client.fetch(
            "workout_sets",
            query: query,
            order: "date.desc,set_number.asc",
            limit: 1
        )

        guard let lastSet = recentSets.first,
              let sessionId = lastSet.workoutSessionId else {
            return []
        }

        // Fetch all sets from that session for the same exercise.
        let sets: [WorkoutSet] = try await client.fetch(
            "workout_sets",
            query: [
                "workout_session_id": "eq.\(sessionId.uuidString)",
                "exercise": "eq.\(exercise)",
            ],
            order: "set_number.asc"
        )
        return sets
    }

    // MARK: - Helpers

    /// Epley 1RM formula: weight * (1 + reps / 30).
    /// For a true single (reps == 1) returns the weight itself.
    static func epley1RM(weight: Double, reps: Int) -> Double {
        guard reps > 1 else { return weight }
        return weight * (1.0 + Double(reps) / 30.0)
    }

    private func setMemory(key: String, value: String) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try await client.upsert(
            "memory",
            body: [
                "key": key,
                "value": value,
                "updated_at": now,
            ],
            onConflict: "key"
        )
    }

    // MARK: - Exercise history (for progression charts)

    func getExerciseHistory(exercise: String, days: Int = 90) async throws -> [WorkoutSet] {
        let since = Self.dateString(daysAgo: days)
        return try await client.fetch(
            "workout_sets",
            query: [
                "exercise": "eq.\(exercise)",
                "date": "gte.\(since)",
            ],
            order: "date.asc,set_number.asc"
        )
    }

    func getDistinctExercises(days: Int = 90) async throws -> [String] {
        let since = Self.dateString(daysAgo: days)
        let sets: [WorkoutSet] = try await client.fetch(
            "workout_sets",
            query: ["date": "gte.\(since)"],
            order: "date.desc"
        )
        var seen = Set<String>()
        var result: [String] = []
        for s in sets {
            let name = s.exercise
            if s.isWarmup == true { continue }
            if name.count > 40 || name.contains("I ") || name.contains("i ") { continue }
            if seen.insert(name).inserted { result.append(name) }
        }
        return result.sorted()
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

    private static func dateString(daysAgo: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return dateFormatter.string(from: date)
    }
}
