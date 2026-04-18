// WorkoutSet.swift
// FitnessCoach

import Foundation

/// Represents a single set within a workout, from the Supabase `workout_sets` table.
struct WorkoutSet: Codable, Identifiable, Sendable {
    var id: UUID?
    var workoutSessionId: UUID?
    var date: String
    var exercise: String
    var setNumber: Int
    var isWarmup: Bool
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
