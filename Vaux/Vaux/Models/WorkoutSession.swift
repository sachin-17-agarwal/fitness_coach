// WorkoutSession.swift
// FitnessCoach

import Foundation

/// Represents a workout session row from the Supabase `workout_sessions` table.
struct WorkoutSession: Codable, Identifiable, Sendable {
    var id: UUID?
    var date: String
    var type: String
    var status: String
    var startTime: String?
    var endTime: String?
    var tonnageKg: Double?
    /// Where in the mesocycle this session was trained, stamped at start
    /// (see `WorkoutService.startSession`). Rows from before stamping began
    /// carry nil and are positioned by `BlockCalendar` from the rotation.
    var mesocycleWeek: Int?
    var mesocycleDay: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case type
        case status
        case startTime = "start_time"
        case endTime = "end_time"
        case tonnageKg = "tonnage_kg"
        case mesocycleWeek = "mesocycle_week"
        case mesocycleDay = "mesocycle_day"
    }
}
