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
    func startSession(type: String) async throws -> WorkoutSession {
        let sessionId = UUID()
        let today = Self.todayString()
        let now = ISO8601DateFormatter().string(from: Date())

        let body: [String: Any] = [
            "id": sessionId.uuidString,
            "date": today,
            "type": type,
            "status": "in_progress",
            "start_time": now,
        ]

        let session: WorkoutSession = try await client.insertAndDecode(
            "workout_sessions", body: body
        )

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

    /// Ends a session: calculates tonnage, marks it `completed`, checks PRs,
    /// resets workout state, and returns a summary.
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
                "status": "completed",
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
    func logSet(
        sessionId: UUID,
        exercise: String,
        setNumber: Int,
        weight: Double,
        reps: Int,
        rpe: Double? = nil,
        isWarmup: Bool = false
    ) async throws -> WorkoutSet {
        let today = Self.todayString()
        let now = ISO8601DateFormatter().string(from: Date())

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

        let logged: WorkoutSet = try await client.insertAndDecode(
            "workout_sets", body: body
        )

        // Best-effort: advance set counter and exercise name in memory.
        // The set is already persisted above — don't lose it if state update fails.
        try? await setMemory(key: "current_set_number", value: String(setNumber + 1))
        try? await setMemory(key: "current_exercise_name", value: exercise)

        return logged
    }

    /// Fetches all sets for a given session, ordered by set number.
    func fetchSets(sessionId: UUID) async throws -> [WorkoutSet] {
        try await client.fetch(
            "workout_sets",
            query: ["workout_session_id": "eq.\(sessionId.uuidString)"],
            order: "set_number.asc"
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
        return try await client.fetch(
            "workout_sets",
            query: ["date": "gte.\(startStr)"],
            order: "date.asc"
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
    func getLastSessionSets(exercise: String) async throws -> [WorkoutSet] {
        // Find the most recent set for this exercise to determine its session ID.
        let recentSets: [WorkoutSet] = try await client.fetch(
            "workout_sets",
            query: ["exercise": "eq.\(exercise)"],
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
