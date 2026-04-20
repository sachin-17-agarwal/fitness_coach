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

// MARK: - Composite recovery score

/// Weighted recovery score (0-100) combining sleep, HRV deviation from
/// baseline, and resting HR deviation from baseline. Each component is
/// mapped to 0-100 via piecewise-linear anchors and then weighted. If a
/// metric is missing, its weight is redistributed across the rest.
///
/// Weights when all three are present:
///   - Sleep: 40 %
///   - HRV (vs 7-day avg): 40 %
///   - Resting HR (vs 7-day avg): 20 %
extension Recovery {

    /// Computes the composite score. Returns `nil` when no usable signal is
    /// available (no sleep, and either HRV or RHR lacks a baseline).
    func compositeScore(hrv7DayAvg: Double?, rhr7DayAvg: Double?) -> Int? {
        var weightedSum: Double = 0
        var totalWeight: Double = 0

        if let sleep = sleepHours {
            weightedSum += Self.sleepComponent(hours: sleep) * 0.40
            totalWeight += 0.40
        }
        if let hrv, let avg = hrv7DayAvg, avg > 0 {
            weightedSum += Self.hrvComponent(ratio: hrv / avg) * 0.40
            totalWeight += 0.40
        }
        if let rhr = restingHr, let avg = rhr7DayAvg, avg > 0 {
            weightedSum += Self.rhrComponent(ratio: rhr / avg) * 0.20
            totalWeight += 0.20
        }

        guard totalWeight > 0 else { return nil }
        let score = weightedSum / totalWeight
        return min(100, max(0, Int(score.rounded())))
    }

    // Anchors: 8h+→100, 7.5h→92, 7h→82, 6h→58, 5h→32, 4h→15, <4h trails to 0.
    // A 5-hour night produces ~32, so a score near 100 is impossible without
    // solid sleep regardless of HRV and RHR.
    static func sleepComponent(hours: Double) -> Double {
        switch hours {
        case 8...:       return 100
        case 7.5..<8:    return interp(hours, 7.5, 8.0, 92, 100)
        case 7.0..<7.5:  return interp(hours, 7.0, 7.5, 82, 92)
        case 6.0..<7.0:  return interp(hours, 6.0, 7.0, 58, 82)
        case 5.0..<6.0:  return interp(hours, 5.0, 6.0, 32, 58)
        case 4.0..<5.0:  return interp(hours, 4.0, 5.0, 15, 32)
        case 3.0..<4.0:  return interp(hours, 3.0, 4.0, 5, 15)
        default:         return max(0, hours * 1.5)
        }
    }

    // Higher HRV vs baseline = better recovery.
    static func hrvComponent(ratio: Double) -> Double {
        switch ratio {
        case 1.10...:       return 100
        case 1.00..<1.10:   return interp(ratio, 1.00, 1.10, 85, 100)
        case 0.90..<1.00:   return interp(ratio, 0.90, 1.00, 65, 85)
        case 0.80..<0.90:   return interp(ratio, 0.80, 0.90, 40, 65)
        case 0.70..<0.80:   return interp(ratio, 0.70, 0.80, 20, 40)
        case 0.60..<0.70:   return interp(ratio, 0.60, 0.70, 10, 20)
        default:            return 5
        }
    }

    // Lower resting HR vs baseline = better recovery.
    static func rhrComponent(ratio: Double) -> Double {
        switch ratio {
        case ..<0.95:       return 100
        case 0.95..<1.00:   return interp(ratio, 0.95, 1.00, 100, 85)
        case 1.00..<1.05:   return interp(ratio, 1.00, 1.05, 85, 65)
        case 1.05..<1.10:   return interp(ratio, 1.05, 1.10, 65, 40)
        case 1.10..<1.15:   return interp(ratio, 1.10, 1.15, 40, 20)
        default:            return 10
        }
    }

    private static func interp(_ x: Double, _ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double) -> Double {
        let t = (x - x0) / (x1 - x0)
        return y0 + t * (y1 - y0)
    }
}
