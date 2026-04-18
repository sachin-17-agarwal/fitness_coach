// Recovery.swift
// Vaux

import Foundation

/// Represents a single day's recovery snapshot from the Supabase `recovery` table.
struct Recovery: Codable, Identifiable, Sendable {
    var id: UUID? = nil
    var date: String
    var sleepHours: Double? = nil
    var hrv: Double? = nil
    var hrvStatus: String? = nil
    var restingHr: Double? = nil
    var heartRate: Double? = nil
    var steps: Int? = nil
    var activeEnergyKcal: Double? = nil
    var weightKg: Double? = nil
    var bodyFatPct: Double? = nil
    var exerciseMinutes: Int? = nil
    var respiratoryRate: Double? = nil
    var vo2Max: Double? = nil

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
