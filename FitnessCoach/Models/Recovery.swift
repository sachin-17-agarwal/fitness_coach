// Recovery.swift
// FitnessCoach

import Foundation

/// Represents a single day's recovery snapshot from the Supabase `recovery` table.
struct Recovery: Codable, Identifiable, Sendable {
    var id: UUID?
    var date: String
    var sleepHours: Double?
    var hrv: Double?
    var hrvStatus: String?
    var restingHr: Double?
    var heartRate: Double?
    var steps: Int?
    var activeEnergyKcal: Double?
    var weightKg: Double?
    var bodyFatPct: Double?
    var exerciseMinutes: Int?
    var respiratoryRate: Double?
    var vo2Max: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case sleepHours = "sleep_hours"
        case hrv
        case hrvStatus = "hrv_status"
        case restingHr = "resting_hr"
        case heartRate = "heart_rate"
        case steps
        case activeEnergyKcal = "active_energy_kcal"
        case weightKg = "weight_kg"
        case bodyFatPct = "body_fat_pct"
        case exerciseMinutes = "exercise_minutes"
        case respiratoryRate = "respiratory_rate"
        case vo2Max = "vo2_max"
    }
}
