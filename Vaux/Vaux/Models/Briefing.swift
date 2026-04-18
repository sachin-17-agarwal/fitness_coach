// Briefing.swift
// Vaux

import Foundation

/// Composed morning briefing. Combines locally-derived data (recovery, plan)
/// with a Claude-generated coach note.
struct Briefing: Sendable {
    let date: String
    let recovery: Recovery?
    let hrv7DayAvg: Double?
    let rhr7DayAvg: Double?
    let mesocycle: MesocycleState
    let coachNote: String
    let generatedAt: Date

    /// Recovery score 0-100 based on HRV vs 7-day avg.
    var recoveryScore: Int {
        guard let hrv = recovery?.hrv, let avg = hrv7DayAvg, avg > 0 else { return 0 }
        return min(100, max(0, Int((hrv / avg) * 100)))
    }

    /// HRV delta vs 7-day avg ("+3ms", "-2ms", or "—").
    var hrvDelta: String {
        guard let hrv = recovery?.hrv, let avg = hrv7DayAvg else { return "—" }
        let diff = Int(hrv - avg)
        if diff > 0 { return "+\(diff) ms" }
        if diff < 0 { return "\(diff) ms" }
        return "0 ms"
    }

    var recoveryLevel: BriefingRecoveryLevel {
        switch recoveryScore {
        case 70...: return .good
        case 40...: return .moderate
        default: return .low
        }
    }
}

enum BriefingRecoveryLevel {
    case good, moderate, low, unknown

    var label: String {
        switch self {
        case .good: return "Recovered"
        case .moderate: return "Moderate"
        case .low: return "Low"
        case .unknown: return "No data"
        }
    }
}

/// Persistable cache payload for today's briefing so we don't re-query Claude
/// on every app launch.
struct CachedBriefing: Codable, Sendable {
    let date: String
    let coachNote: String
    let generatedAt: Date
    var shown: Bool
}
